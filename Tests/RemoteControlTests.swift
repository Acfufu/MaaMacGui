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

        // --- 幂等入队（WPF _enqueueTaskIds 同构；评审中3：id 保留在分类之前——未知类型同样保留）
        let suite = "MAARemoteControlTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = RemoteControlService(defaults: defaults) { _ in (200, Data()) }
        let logs = LogSink()
        service.hooks.log = { @Sendable line in Task { await logs.append(line) } }
        await service.ingest(tasks: [.init(type: "LinkStart", id: "a"), .init(type: "LinkStart", id: "a"),
                               .init(type: "HeartBeat", id: "b"), .init(type: "Nuke", id: "c")])
        check(service.sequentialQueue.count == 1 && service.instantQueue.count == 1, "idempotent enqueue")
        check(service.enqueuedTaskIDs == ["a", "b", "c"], "unknown type id reserved like WPF (no re-log)")
        await service.ingest(tasks: [.init(type: "Nuke", id: "c")])
        try? await Task.sleep(for: .milliseconds(80))
        check(logs.count == 1, "unknown type logged once (id reserved)")
        await service.ingest(tasks: [.init(type: "LinkStart", id: "a")])
        check(service.sequentialQueue.count == 1, "same id never re-enqueued")

        // --- 回执体形态
        let report = RemoteControlProtocol.reportBody(user: "u", device: "d", status: "SUCCESS", task: "a", payload: "p")
        let object = try JSONSerialization.jsonObject(with: report) as! [String: String]
        check(object == ["user": "u", "device": "d", "status": "SUCCESS", "task": "a", "payload": "p"],
              "report body shape mirrors WPF")

        // --- 命令分发（失败通道：LinkStart/Gacha/Stage1 忙/无目标如实 FAILED——评审中2）
        var subsetName = ""
        service.hooks.startSubset = { @Sendable name in subsetName = name; return name != "Combat" }
        var startedFull = false
        service.hooks.startFull = { @Sendable in startedFull = true; return true }
        var stopped = false
        service.hooks.stop = { @Sendable in stopped = true }
        var stageValue = ""
        service.hooks.setStage1 = { @Sendable value in stageValue = value; return true }
        var gachaOnce: Bool?
        var capturedFresh = [Bool]()
        service.hooks.gacha = { @Sendable once in gachaOnce = once; return true }
        service.hooks.captureImage = { @Sendable fresh in capturedFresh.append(fresh); return "cG5n" }

        let linkStartReport = await service.execute(.init(type: "LinkStart", id: "ls"))
        check(startedFull && linkStartReport.status == "SUCCESS", "LinkStart dispatches full start")
        let busyReport = await service.execute(.init(type: "LinkStart", id: "ls-busy"))
        service.hooks.startFull = { @Sendable in false }
        let busyReport2 = await service.execute(.init(type: "LinkStart", id: "ls-busy2"))
        check(busyReport2.status == "FAILED", "busy LinkStart reports FAILED (failure channel)")
        check(busyReport.status == "SUCCESS", "started LinkStart reports SUCCESS")
        let subsetReport = await service.execute(.init(type: "LinkStart-Combat", id: "c1"))
        check(subsetName == "Combat" && subsetReport.status == "FAILED", "subset failure surfaces FAILED")
        let subsetOK = await service.execute(.init(type: "LinkStart-Base", id: "b1"))
        check(subsetOK.status == "SUCCESS", "subset success")
        let stageReport = await service.execute(.init(type: "Settings-Stage1", id: "s1", params: "1-7"))
        check(stageValue == "1-7" && stageReport.status == "SUCCESS", "Settings-Stage1 carries params")
        service.hooks.setStage1 = { @Sendable _ in false }
        let stageFail = await service.execute(.init(type: "Settings-Stage1", id: "s2", params: "1-7"))
        check(stageFail.status == "FAILED", "Stage1 without enabled fight task reports FAILED")
        service.hooks.setStage1 = { @Sendable value in stageValue = value; return true }
        let gachaReport = await service.execute(.init(type: "Toolbox-GachaOnce", id: "g1"))
        check(gachaOnce == true && gachaReport.status == "SUCCESS", "GachaOnce dispatched")
        let gachaFail = await service.execute(.init(type: "Toolbox-GachaTenTimes", id: "g2"))
        check(gachaOnce == false, "GachaTenTimes dispatched once=false")
        check(gachaFail.status == "SUCCESS", "gacha success path")
        let stopReport = await service.execute(.init(type: "StopTask", id: "st"))
        check(stopped && stopReport.status == "SUCCESS", "StopTask fire-and-forget")
        _ = await service.execute(.init(type: "CaptureImage", id: "ci"))
        _ = await service.execute(.init(type: "CaptureImageNow", id: "cin"))
        check(capturedFresh == [true, true], "both capture types request fresh frame (WPF forceScreencap)")

        // sequential drain 语义（id 生命周期随 drain 收口）
        let drainService = RemoteControlService(defaults: defaults) { _ in (200, Data()) }
        drainService.hooks.startFull = { @Sendable in true }
        await drainService.ingest(tasks: [.init(type: "LinkStart", id: "seq-id")])
        await drainService.drainSequentialOnce()
        check(drainService.sequentialQueue.isEmpty, "drain consumes the queue")
        check(drainService.currentSequentialTaskID == "", "sequential id cleared after drain")

        // --- 配置持久化与设备标识再生成
        service.getTaskEndpoint = "https://rc.example.com"
        let reloaded = RemoteControlService(defaults: defaults) { _ in (200, Data()) }
        check(reloaded.getTaskEndpoint == "https://rc.example.com", "endpoints persist")
        reloaded.regenerateDeviceIdentity()
        let first = reloaded.deviceIdentity
        check(!first.isEmpty && !first.contains("-") && first == first.lowercased(),
              "device identity GUID N format (lowercase, WPF ToString(\"N\"))")
        reloaded.regenerateDeviceIdentity()
        check(reloaded.deviceIdentity != first, "identity regenerates")

        // --- 空端点 = 停用；轮询循环在端点清空后自动停止（独立 suite 防前段端点写入污染）
        let pollingSuite = "MAARemoteControlTests-Poll-\(UUID())"
        let pollingDefaults = UserDefaults(suiteName: pollingSuite)!
        defer { pollingDefaults.removePersistentDomain(forName: pollingSuite) }
        let idle = RemoteControlService(defaults: pollingDefaults) { _ in (200, Data()) }
        idle.startPolling()
        check(!idle.isPolling, "empty endpoint never starts polling")

        // --- 真实三循环并发路径（评审高1/高2：原单循环塌缩使心跳载荷恒空、急停在
        // sequential 运行期不可达——原断言为生产不可达的嵌套人工路径，此处以 startPolling
        // 全链重写）。stub 区分 poll/report：report 体含 status 键。
        final class ReportCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var bodies: [[String: String]] = []
            func append(_ data: Data) {
                if let o = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   o["status"] != nil {
                    lock.lock()
                    bodies.append(o)
                    lock.unlock()
                }
            }
            func report(for taskID: String) -> [String: String]? {
                lock.lock()
                defer { lock.unlock() }
                return bodies.last { $0["task"] == taskID }
            }
        }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
            func set() { lock.lock(); value = true; lock.unlock() }
        }
        final class Timestamp: @unchecked Sendable {
            private let lock = NSLock()
            private var stamp = Date.distantFuture
            var value: Date { lock.lock(); defer { lock.unlock() }; return stamp }
            func mark() { lock.lock(); stamp = Date(); lock.unlock() }
        }

        let loopsSuite = "MAARemoteControlTests-Loops-\(UUID())"
        let loopsDefaults = UserDefaults(suiteName: loopsSuite)!
        defer { loopsDefaults.removePersistentDomain(forName: loopsSuite) }
        let capture = ReportCapture()
        var served = false
        let stopFlag = Flag()
        let stopTime = Timestamp()
        let startTime = Timestamp()
        let loopsService = RemoteControlService(defaults: loopsDefaults) { request in
            if let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String] {
                if object["status"] != nil {
                    capture.append(request.httpBody ?? Data())
                    return (200, Data())
                }
                if !served {
                    served = true
                    return (200, Data(#"{"tasks":[{"type":"LinkStart","id":"seq-1"},{"type":"StopTask","id":"stop-1"},{"type":"HeartBeat","id":"hb-1"}]}"#.utf8))
                }
            }
            return (200, Data(#"{"tasks":[]}"#.utf8))
        }
        loopsService.pollIntervalMs = 50
        loopsService.getTaskEndpoint = "https://rc.test/get"
        loopsService.reportStatusEndpoint = "https://rc.test/report"
        loopsService.hooks.startFull = { @Sendable in
            try? await Task.sleep(for: .milliseconds(400))  // 模拟整场长任务运行
            startTime.mark()
            return true
        }
        loopsService.hooks.stop = { @Sendable in
            stopFlag.set()
            stopTime.mark()
        }
        loopsService.startPolling()
        var heartbeatPayload: String?
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(50))
            if let r = capture.report(for: "hb-1") { heartbeatPayload = r["payload"]; break }
        }
        for _ in 0..<80 {
            if capture.report(for: "stop-1") != nil && capture.report(for: "seq-1") != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        loopsService.stopPolling()
        check(heartbeatPayload == "seq-1", "real 3-loop path: heartbeat during sequential run carries its id")
        check(stopFlag.isSet && stopTime.value < startTime.value,
              "real 3-loop path: StopTask lands during the sequential run (not after)")
        check(capture.report(for: "seq-1")?["status"] == "SUCCESS", "sequential task reported")
        check(capture.report(for: "stop-1")?["status"] == "SUCCESS", "stop task reported")

        // --- 端点运行中配置即启动（评审高3：WPF setter → InitializePollJobTask 同构）
        let reconfigSuite = "MAARemoteControlTests-Reconfig-\(UUID())"
        let reconfigDefaults = UserDefaults(suiteName: reconfigSuite)!
        defer { reconfigDefaults.removePersistentDomain(forName: reconfigSuite) }
        let reconfig = RemoteControlService(defaults: reconfigDefaults) { _ in (200, Data(#"{"tasks":[]}"#.utf8)) }
        reconfig.pollIntervalMs = 50
        check(!reconfig.isPolling, "fresh service not polling before endpoint configured")
        reconfig.setValue("https://rc.test/get", forKey: RemoteControlService.keys.getTaskEndpoint)
        var restarted = false
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            if reconfig.isPolling { restarted = true; break }
        }
        check(restarted, "endpoint configured mid-session starts polling (no app restart)")
        reconfig.setValue("", forKey: RemoteControlService.keys.getTaskEndpoint)
        var stoppedLive = false
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            if !reconfig.isPolling { stoppedLive = true; break }
        }
        check(stoppedLive, "endpoint cleared mid-session stops polling")
        reconfig.stopPolling()

        // --- 失败日志节流（评审中4：连续失败只记一次、成功复位——WPF 走文件日志不刷 UI 面）
        let throttleSuite = "MAARemoteControlTests-Throttle-\(UUID())"
        let throttleDefaults = UserDefaults(suiteName: throttleSuite)!
        defer { throttleDefaults.removePersistentDomain(forName: throttleSuite) }
        let throttleLogs = LogSink()
        var failing = true
        let throttled = RemoteControlService(defaults: throttleDefaults) { _ in failing ? nil : (200, Data()) }
        throttled.getTaskEndpoint = "https://rc.test/get"
        throttled.hooks.log = { @Sendable line in Task { await throttleLogs.append(line) } }
        await throttled.pollOnce()
        await throttled.pollOnce()
        await throttled.pollOnce()
        try? await Task.sleep(for: .milliseconds(120))
        check(throttleLogs.count == 1, "consecutive poll failures logged once")
        failing = false
        await throttled.pollOnce()
        failing = true
        await throttled.pollOnce()
        try? await Task.sleep(for: .milliseconds(120))
        check(throttleLogs.count == 2, "success resets throttle; next failure logs again")

        print("RemoteControlTests: \(count) assertions passed")
    }
}

@MainActor final class LogSink {
    private var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    var count: Int { lines.count }
    var last: String? { lines.last }
}
