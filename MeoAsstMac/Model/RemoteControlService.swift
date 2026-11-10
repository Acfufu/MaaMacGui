import Foundation

/// URLSession 默认发送面（文件级函数：默认参数不能引用协变 Self）。
nonisolated func remoteControlDefaultSendJSON(_ request: URLRequest) async -> (Int, Data)? {
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    } catch {
        return nil
    }
}

// P26/E07+E08: 远控轮询客户端（WPF RemoteControlService.cs 同构）。
// 协议：POST get-task {user, device} → {tasks:[{type,id,params?}]}；同 id 幂等不入队；
// 命令分 sequential（逐条执行+回执）/ instant（即时执行+回执）双队列；每条任务执行后
// POST report {user, device, status, task, payload}。端点为空即整体停用（WPF 无独立开关）。

struct RemoteControlTask: Codable, Equatable {
    var type: String
    var id: String
    var params: String?
}

enum RemoteControlQueueKind: Equatable {
    case sequential, instant, unknown
}

enum RemoteControlProtocol {
    /// WPF PollJobTaskLoop 的分类矩阵（逐字对齐）。
    static let sequentialTypes: Set<String> = [
        "LinkStart", "LinkStart-Base", "LinkStart-WakeUp", "LinkStart-Combat",
        "LinkStart-Recruiting", "LinkStart-Mall", "LinkStart-Mission", "LinkStart-AutoRoguelike",
        "LinkStart-Reclamation", "Toolbox-Reclamation", "Toolbox-GachaOnce", "Toolbox-GachaTenTimes",
        "CaptureImage", "Settings-ConnectAddress", "Settings-Stage1",
    ]
    static let instantTypes: Set<String> = ["CaptureImageNow", "HeartBeat", "StopTask"]

    static func classify(_ task: RemoteControlTask) -> RemoteControlQueueKind {
        if sequentialTypes.contains(task.type) { return .sequential }
        if instantTypes.contains(task.type) { return .instant }
        return .unknown
    }

    /// 解析 {tasks: [...]}；缺 tasks 或结构异常返回空数组。
    static func parseTasks(from data: Data) -> [RemoteControlTask] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = object["tasks"] as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let type = item["type"] as? String, !type.isEmpty,
                  let id = item["id"] as? String, !id.isEmpty else { return nil }
            return RemoteControlTask(type: type, id: id, params: item["params"] as? String)
        }
    }

    /// WPF IsEndpointValid 同构：https 通过；http 放行（UI 层提示不安全）；其余拒绝。
    static func isEndpointValid(_ endpoint: String) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://")
    }

    static func isEndpointUnsafeHTTP(_ endpoint: String) -> Bool {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    static func pollBody(user: String, device: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["user": user, "device": device])) ?? Data()
    }

    static func reportBody(user: String, device: String, status: String, task: String, payload: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "user": user, "device": device, "status": status, "task": task, "payload": payload,
        ])) ?? Data()
    }
}

struct RemoteControlReport: Equatable {
    var status: String
    var task: String
    var payload: String

    static let success = "SUCCESS"
    static let failed = "FAILED"
}

/// 轮询与执行（WPF 三循环同构：poll 入队 + sequential/instant 两条消费循环）。
/// 命令执行经 Hooks 注入（MAAViewModel 接线；测试直填桩），网络经 sendJSON 注入。
@MainActor final class RemoteControlService: ObservableObject {
    static let keys = (
        getTaskEndpoint: "MAARemoteControlGetTaskEndpoint",
        reportStatusEndpoint: "MAARemoteControlReportStatusEndpoint",
        userIdentity: "MAARemoteControlUserIdentity",
        deviceIdentity: "MAARemoteControlDeviceIdentity",
        pollIntervalMs: "MAARemoteControlPollIntervalMs"
    )

    @Published private(set) var isPolling = false
    @Published private(set) var currentSequentialTaskID = ""
    private(set) var enqueuedTaskIDs: Set<String> = []
    private(set) var sequentialQueue: [RemoteControlTask] = []
    private(set) var instantQueue: [RemoteControlTask] = []
    private var pollTask: Task<Void, Never>?
    private var sequentialDrainTask: Task<Void, Never>?
    private var instantDrainTask: Task<Void, Never>?

    private let defaults: UserDefaults
    private let sendJSON: @Sendable (URLRequest) async -> (Int, Data)?

    struct Hooks {
        var startFull: (@Sendable () async -> Void)?
        var startSubset: (@Sendable (String) async -> Bool)?
        var gacha: (@Sendable (Bool) async -> Void)?
        var captureImage: (@Sendable (Bool) async -> String)?
        var setConnectAddress: (@Sendable (String) async -> Void)?
        var setStage1: (@Sendable (String) async -> Void)?
        var stop: (@Sendable () async -> Void)?
        var log: (@Sendable (String) async -> Void)?
    }

    var hooks = Hooks()

    init(defaults: UserDefaults = .standard,
         sendJSON: @escaping @Sendable (URLRequest) async -> (Int, Data)? = remoteControlDefaultSendJSON) {
        self.defaults = defaults
        self.sendJSON = sendJSON
    }



    // MARK: - 配置面（WPF RemoteControl.cs 同位；端点为空即停用）

    var getTaskEndpoint: String {
        get { defaults.string(forKey: Self.keys.getTaskEndpoint) ?? "" }
        set { defaults.set(newValue, forKey: Self.keys.getTaskEndpoint) }
    }

    var reportStatusEndpoint: String {
        get { defaults.string(forKey: Self.keys.reportStatusEndpoint) ?? "" }
        set { defaults.set(newValue, forKey: Self.keys.reportStatusEndpoint) }
    }

    var userIdentity: String {
        get { defaults.string(forKey: Self.keys.userIdentity) ?? "" }
        set { defaults.set(newValue, forKey: Self.keys.userIdentity) }
    }

    var deviceIdentity: String {
        get { defaults.string(forKey: Self.keys.deviceIdentity) ?? "" }
        set { defaults.set(newValue, forKey: Self.keys.deviceIdentity) }
    }

    var pollIntervalMs: Int {
        get { defaults.object(forKey: Self.keys.pollIntervalMs) as? Int ?? 1000 }
        set { defaults.set(newValue, forKey: Self.keys.pollIntervalMs) }
    }

    /// WPF RegenerateDeviceIdentity 同构（GUID N 格式）。
    func regenerateDeviceIdentity() {
        deviceIdentity = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        objectWillChange.send()
    }

    /// 设置视图的通用读取。
    func defaultsString(forKey key: String) -> String {
        defaults.string(forKey: key) ?? ""
    }

    /// 设置视图的通用写入（UserDefaults 背书属性经此驱动 objectWillChange）。
    func setValue(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }

    // MARK: - 轮询循环

    func startPolling() {
        guard !isPolling else { return }
        guard RemoteControlProtocol.isEndpointValid(getTaskEndpoint) else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(max(100, self.pollIntervalMs)))
                guard !Task.isCancelled else { return }
                guard RemoteControlProtocol.isEndpointValid(self.getTaskEndpoint) else {
                    // 端点被清空即整体停用（WPF _inited=false return 同构）。
                    self.stopPolling()
                    return
                }
                await self.pollOnce()
                await self.drainSequentialOnce()
                await self.drainInstantOnce()
            }
        }
    }

    func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
        sequentialDrainTask?.cancel()
        sequentialDrainTask = nil
        instantDrainTask?.cancel()
        instantDrainTask = nil
    }

    private func postJSON(endpoint: String, body: Data) async -> (Int, Data)? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await sendJSON(request)
    }

    /// 一次轮询：拉取任务并幂等入队（WPF _enqueueTaskIds 同构）。
    func pollOnce() async {
        guard let (status, data) = await postJSON(endpoint: getTaskEndpoint,
                                                  body: RemoteControlProtocol.pollBody(user: userIdentity, device: deviceIdentity)),
              (200..<300).contains(status) else {
            await hooks.log?("远控轮询失败（端点或网络不可用）")
            return
        }
        await ingest(tasks: RemoteControlProtocol.parseTasks(from: data))
    }

    /// 幂等入队：同 id 永不重复；未知类型记日志（WPF 404 成就面为平台差异）。
    func ingest(tasks: [RemoteControlTask]) async {
        for task in tasks {
            guard !task.id.isEmpty, !enqueuedTaskIDs.contains(task.id) else { continue }
            switch RemoteControlProtocol.classify(task) {
            case .sequential:
                enqueuedTaskIDs.insert(task.id)
                sequentialQueue.append(task)
            case .instant:
                enqueuedTaskIDs.insert(task.id)
                instantQueue.append(task)
            case .unknown:
                await hooks.log?("远控收到未知任务类型：\(task.type)（id=\(task.id)）")
            }
        }
    }

    // MARK: - 消费循环（逐条执行 + 回执）

    func drainSequentialOnce() async {
        guard !sequentialQueue.isEmpty else { return }
        let task = sequentialQueue.removeFirst()
        currentSequentialTaskID = task.id
        let report = await execute(task)
        await submitReport(report, taskID: task.id)
        currentSequentialTaskID = ""
    }

    func drainInstantOnce() async {
        guard !instantQueue.isEmpty else { return }
        let task = instantQueue.removeFirst()
        let report = await execute(task)
        await submitReport(report, taskID: task.id)
    }

    /// 命令矩阵执行（WPF ExecuteSequential/InstantJobLoop switch 同构）。
    func execute(_ task: RemoteControlTask) async -> RemoteControlReport {
        var payload = ""
        var status = RemoteControlReport.success
        let data = task.params ?? ""
        switch task.type {
        case "LinkStart":
            await hooks.startFull?()
        case "LinkStart-Base", "LinkStart-WakeUp", "LinkStart-Combat", "LinkStart-Recruiting",
             "LinkStart-Mall", "LinkStart-Mission", "LinkStart-AutoRoguelike", "LinkStart-Reclamation":
            let name = task.type.split(separator: "-").dropFirst().joined(separator: "-")
            if await hooks.startSubset?(String(name)) != true {
                status = RemoteControlReport.failed
            }
        case "Toolbox-GachaOnce":
            await hooks.gacha?(true)
        case "Toolbox-GachaTenTimes":
            await hooks.gacha?(false)
        case "Toolbox-Reclamation":
            // 生息演算完整执行（WPF 按工具箱形态，不进 LinkStart 批处理）。
            if await hooks.startSubset?("Reclamation") != true {
                status = RemoteControlReport.failed
            }
        case "CaptureImage", "CaptureImageNow":
            let fresh = task.type == "CaptureImageNow"
            payload = await hooks.captureImage?(fresh) ?? ""
            if payload.isEmpty { status = RemoteControlReport.failed }
        case "Settings-ConnectAddress":
            await hooks.setConnectAddress?(data)
        case "Settings-Stage1":
            await hooks.setStage1?(data)
        case "HeartBeat":
            payload = currentSequentialTaskID
        case "StopTask":
            // 远控停止与手动停止同语义；不等待完成，远端用心跳确认（WPF 注释同构）。
            await hooks.stop?()
        default:
            status = RemoteControlReport.failed
        }
        return RemoteControlReport(status: status, task: task.id, payload: payload)
    }

    private func submitReport(_ report: RemoteControlReport, taskID: String) async {
        guard RemoteControlProtocol.isEndpointValid(reportStatusEndpoint) else { return }
        let body = RemoteControlProtocol.reportBody(user: userIdentity, device: deviceIdentity,
                                                    status: report.status, task: taskID, payload: report.payload)
        guard let (reportStatus, _) = await postJSON(endpoint: reportStatusEndpoint, body: body),
              (200..<300).contains(reportStatus) else {
            await hooks.log?("远控回执上报失败")
            return
        }
    }

    /// WPF ConnectionTest 同构：POST get-task 端点验证连通性。
    func connectionTest() async -> Bool {
        guard RemoteControlProtocol.isEndpointValid(getTaskEndpoint) else { return false }
        guard let (status, _) = await postJSON(endpoint: getTaskEndpoint,
                                               body: RemoteControlProtocol.pollBody(user: userIdentity, device: deviceIdentity)) else {
            return false
        }
        return (200..<300).contains(status)
    }
}
