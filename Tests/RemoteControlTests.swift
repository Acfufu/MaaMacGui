import Foundation

// P26/E07+E08: 远控协议模型层套件（分类矩阵/幂等/解析/回执/命令分发钩子；网络经注入桩）。
@main struct RemoteControlTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- 端点有效性（WPF IsEndpointValid 同构）
        check(RemoteControlProtocol.isEndpointValid("https://rc.example.com/tasks"), "https valid")
        check(RemoteControlProtocol.isEndpointValid("HTTP://rc.example.com"), "http tolerated (case-insensitive)")
        check(RemoteControlProtocol.isEndpointValid("ftp://rc") == false, "non-http rejected")
        check(RemoteControlProtocol.isEndpointValid("  ") == false, "empty rejected")
        check(RemoteControlProtocol.isEndpointUnsafeHTTP("http://a") && !RemoteControlProtocol.isEndpointUnsafeHTTP("https://a"),
              "unsafe-http flag only for http")

        // --- 分类矩阵（WPF switch 逐字对齐）
        let sequential = ["LinkStart", "LinkStart-Base", "LinkStart-WakeUp", "LinkStart-Combat",
                          "LinkStart-Recruiting", "LinkStart-Mall", "LinkStart-Mission", "LinkStart-AutoRoguelike",
                          "LinkStart-Reclamation", "Toolbox-Reclamation", "Toolbox-GachaOnce", "Toolbox-GachaTenTimes",
                          "CaptureImage", "Settings-ConnectAddress", "Settings-Stage1"]
        for type in sequential {
            check(RemoteControlProtocol.classify(.init(type: type, id: "1")) == .sequential, "\(type) sequential")
        }
        for type in ["CaptureImageNow", "HeartBeat", "StopTask"] {
            check(RemoteControlProtocol.classify(.init(type: type, id: "1")) == .instant, "\(type) instant")
        }
        check(RemoteControlProtocol.classify(.init(type: "Nuke", id: "1")) == .unknown, "unknown type classified")

        // --- 解析 {tasks:[...]}
        let payload = #"{"tasks":[{"type":"LinkStart","id":"a"},{"type":"HeartBeat","id":"b","params":"x"},{"type":""},{"id":"no-type"}]}"#
        let tasks = RemoteControlProtocol.parseTasks(from: Data(payload.utf8))
        check(tasks.count == 2, "valid tasks parsed, malformed dropped")
        check(tasks[0] == .init(type: "LinkStart", id: "a", params: nil), "task fields decoded")
        check(tasks[1].params == "x", "params decoded")
        check(RemoteControlProtocol.parseTasks(from: Data("{}".utf8)).isEmpty, "missing tasks empty")

        // --- 幂等入队（WPF _enqueueTaskIds 同构）
        let suite = "MAARemoteControlTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RemoteControlService(defaults: defaults) { _ in (200, Data()) }
        let logs = actorsLogs()
        service.hooks.log = { @Sendable line in Task { await logs.append(line) } }
        await service.ingest(tasks: [.init(type: "LinkStart", id: "a"), .init(type: "LinkStart", id: "a"),
                               .init(type: "HeartBeat", id: "b"), .init(type: "Nuke", id: "c")])
        check(service.sequentialQueue.count == 1 && service.instantQueue.count == 1, "idempotent enqueue")
        check(service.enqueuedTaskIDs == ["a", "b"], "unknown type not enqueued but id not reserved")
        await service.ingest(tasks: [.init(type: "LinkStart", id: "a")])
        check(service.sequentialQueue.count == 1, "same id never re-enqueued")

        // --- 回执体形态
        let report = RemoteControlProtocol.reportBody(user: "u", device: "d", status: "SUCCESS", task: "a", payload: "p")
        let object = try JSONSerialization.jsonObject(with: report) as! [String: String]
        check(object == ["user": "u", "device": "d", "status": "SUCCESS", "task": "a", "payload": "p"],
              "report body shape mirrors WPF")

        // --- 命令分发（sequential：LinkStart 子集失败→FAILED；Settings-Stage1 透传；HeartBeat 载荷）
        var subsetName = ""
        service.hooks.startSubset = { @Sendable name in subsetName = name; return name != "Combat" }
        var startedFull = false
        service.hooks.startFull = { @Sendable in startedFull = true }
        var stopped = false
        service.hooks.stop = { @Sendable in stopped = true }
        var stageValue = ""
        service.hooks.setStage1 = { @Sendable value in stageValue = value }

        let linkStartReport = await service.execute(.init(type: "LinkStart", id: "ls"))
        check(startedFull && linkStartReport.status == "SUCCESS", "LinkStart dispatches full start")
        let subsetReport = await service.execute(.init(type: "LinkStart-Combat", id: "c1"))
        check(subsetName == "Combat" && subsetReport.status == "FAILED", "subset failure surfaces FAILED")
        let subsetOK = await service.execute(.init(type: "LinkStart-Base", id: "b1"))
        check(subsetOK.status == "SUCCESS", "subset success")
        let stageReport = await service.execute(.init(type: "Settings-Stage1", id: "s1", params: "1-7"))
        check(stageValue == "1-7" && stageReport.status == "SUCCESS", "Settings-Stage1 carries params")
        let stopReport = await service.execute(.init(type: "StopTask", id: "st"))
        check(stopped && stopReport.status == "SUCCESS", "StopTask fire-and-forget")

        // HeartBeat 在 sequential 执行期间回读当前任务 id（WPF _currentSequentialTaskId 同构）
        final class Box: @unchecked Sendable { var value = "" }
        let box = Box()
        let drainService = RemoteControlService(defaults: defaults) { _ in (200, Data()) }
        drainService.hooks.startFull = { @Sendable in
            let heartbeat = await drainService.execute(.init(type: "HeartBeat", id: "hb-during"))
            box.value = heartbeat.payload
        }
        await drainService.ingest(tasks: [.init(type: "LinkStart", id: "seq-id")])
        await drainService.drainSequentialOnce()
        check(box.value == "seq-id", "heartbeat during sequential execution carries its id")
        check(drainService.sequentialQueue.isEmpty, "drain consumes the queue")
        check(drainService.currentSequentialTaskID == "", "sequential id cleared after drain")

        // --- 配置持久化与设备标识再生成
        service.getTaskEndpoint = "https://rc.example.com"
        let reloaded = RemoteControlService(defaults: defaults) { _ in (200, Data()) }
        check(reloaded.getTaskEndpoint == "https://rc.example.com", "endpoints persist")
        reloaded.regenerateDeviceIdentity()
        let first = reloaded.deviceIdentity
        check(!first.isEmpty && !first.contains("-"), "device identity GUID N format")
        reloaded.regenerateDeviceIdentity()
        check(reloaded.deviceIdentity != first, "identity regenerates")

        // --- 空端点 = 停用；轮询循环在端点清空后自动停止（独立 suite 防前段端点写入污染）
        let pollingSuite = "MAARemoteControlTests-Poll-\(UUID())"
        let pollingDefaults = UserDefaults(suiteName: pollingSuite)!
        defer { pollingDefaults.removePersistentDomain(forName: pollingSuite) }
        let idle = RemoteControlService(defaults: pollingDefaults) { _ in (200, Data()) }
        idle.startPolling()
        check(!idle.isPolling, "empty endpoint never starts polling")
        let live = RemoteControlService(defaults: defaults) { _ in (200, Data(#"{"tasks":[]}"#.utf8)) }
        live.getTaskEndpoint = "https://rc.example.com/poll"
        live.pollIntervalMs = 50
        live.startPolling()
        check(live.isPolling, "valid endpoint starts polling")
        live.getTaskEndpoint = ""
        await live.pollOnce()
        try? await Task.sleep(for: .milliseconds(150))
        check(!live.isPolling, "cleared endpoint stops polling loop")
        live.stopPolling()

        print("RemoteControlTests: \(count) assertions passed")
    }

    @MainActor static func actorsLogs() -> LogSink { LogSink() }
}

@MainActor final class LogSink {
    private var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
