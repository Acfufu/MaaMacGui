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
    private var pollFailureLogged = false
    private var reportFailureLogged = false

    private let defaults: UserDefaults
    private let sendJSON: @Sendable (URLRequest) async -> (Int, Data)?

    struct Hooks {
        var startFull: (@Sendable () async -> Bool)?        // 忙/启动失败→false（评审中2 失败通道）
        var startSubset: (@Sendable (String) async -> Bool)?
        var gacha: (@Sendable (Bool) async -> Bool)?        // 忙（taskAlreadyRunning）→false
        var captureImage: (@Sendable (Bool) async -> String)?
        var setConnectAddress: (@Sendable (String) async -> Void)?
        var setStage1: (@Sendable (String) async -> Bool)?  // 无启用战斗任务→false
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

    /// WPF RegenerateDeviceIdentity 同构（GUID N 格式，小写——ToString("N") 小写 hex，
    /// 评审低2：同形不同值域会被服务端视为不同形态）。
    func regenerateDeviceIdentity() {
        deviceIdentity = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        objectWillChange.send()
    }

    /// 设置视图的通用读取。
    func defaultsString(forKey key: String) -> String {
        defaults.string(forKey: key) ?? ""
    }

    /// 设置视图的通用写入（UserDefaults 背书属性经此驱动 objectWillChange）。
    /// 端点键变更即时启停轮询——WPF RemoteControlGetTaskEndpointUri setter 显式调用
    /// InitializePollJobTask()（RemoteControlUserControlModel.cs:26-31）：首次配置/清空
    /// 后再配置，本会话轮询必须能启动，而非等重启（评审高3）。
    func setValue(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
        if key == Self.keys.getTaskEndpoint {
            if RemoteControlProtocol.isEndpointValid(value) {
                startPolling()
            } else if isPolling {
                stopPolling()
            }
        }
    }

    // MARK: - 轮询循环

    /// WPF 三条并发循环同构（RemoteControlService.cs:89-151）：poll 入队、sequential
    /// 消费（长任务上阻塞整场运行、currentSequentialTaskID 全程保持）、instant 消费
    /// （并发——HeartBeat 在 sequential 执行期间读到真实 id、StopTask 在 PollIntervalMs
    /// 内可达；评审高1/高2：单循环塌缩曾使心跳载荷恒空、急停在子集运行期不可达）。
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
            }
        }
        sequentialDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.sequentialQueue.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                await self.drainSequentialOnce()
            }
        }
        instantDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.instantQueue.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
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

    /// 一次轮询：拉取任务并幂等入队（WPF _enqueueTaskIds 同构）。失败日志按失败期节流
    /// （连续失败只记一次、成功复位——评审中4：WPF 走文件日志，UI 面不逐条刷屏）。
    func pollOnce() async {
        guard let (status, data) = await postJSON(endpoint: getTaskEndpoint,
                                                  body: RemoteControlProtocol.pollBody(user: userIdentity, device: deviceIdentity)),
              (200..<300).contains(status) else {
            if !pollFailureLogged {
                await hooks.log?("远控轮询失败（端点或网络不可用）")
                pollFailureLogged = true
            }
            return
        }
        pollFailureLogged = false
        await ingest(tasks: RemoteControlProtocol.parseTasks(from: data))
    }

    /// 幂等入队：id 保留在分类**之前**（WPF _enqueueTaskIds 同序，RemoteControlService.cs:261-266）——
    /// 未知类型同样保留 id 后静默，否则同 id 会以轮询频率重复日志（评审中3）。
    func ingest(tasks: [RemoteControlTask]) async {
        for task in tasks {
            guard !task.id.isEmpty, !enqueuedTaskIDs.contains(task.id) else { continue }
            enqueuedTaskIDs.insert(task.id)
            switch RemoteControlProtocol.classify(task) {
            case .sequential:
                sequentialQueue.append(task)
            case .instant:
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
    /// LinkStart/Toolbox-Gacha/Settings-Stage1 具失败通道（忙/无目标如实 FAILED，
    /// 评审中2：无失败通道的假 SUCCESS 曾使回执对远端不可信）。
    func execute(_ task: RemoteControlTask) async -> RemoteControlReport {
        var payload = ""
        var status = RemoteControlReport.success
        let data = task.params ?? ""
        switch task.type {
        case "LinkStart":
            if await hooks.startFull?() != true { status = RemoteControlReport.failed }
        case "LinkStart-Base", "LinkStart-WakeUp", "LinkStart-Combat", "LinkStart-Recruiting",
             "LinkStart-Mall", "LinkStart-Mission", "LinkStart-AutoRoguelike", "LinkStart-Reclamation":
            let name = task.type.split(separator: "-").dropFirst().joined(separator: "-")
            if await hooks.startSubset?(String(name)) != true {
                status = RemoteControlReport.failed
            }
        case "Toolbox-GachaOnce":
            if await hooks.gacha?(true) != true { status = RemoteControlReport.failed }
        case "Toolbox-GachaTenTimes":
            if await hooks.gacha?(false) != true { status = RemoteControlReport.failed }
        case "Toolbox-Reclamation":
            // WPF 走工具箱 StartReclamation（工具箱自身配置、无任务队列依赖，
            // ReclamationUserControlModel.cs:215-230）；Mac 无工具箱生息演算面，走
            // LinkStart 子集链（恰一启用日常任务）——差异入档 P26-[a]。
            if await hooks.startSubset?("Reclamation") != true {
                status = RemoteControlReport.failed
            }
        case "CaptureImage", "CaptureImageNow":
            // WPF 两类均强制实时帧（AsstProxy.cs:373-401/474-502 forceScreencap）——
            // 映射对齐为恒 requestFresh（评审中5：原 CaptureImage→缓存帧系反转）；
            // Mac 运行中强制缓存的差异见 Maa.swift requestFresh 门（P26-[b]）。
            payload = await hooks.captureImage?(true) ?? ""
            if payload.isEmpty { status = RemoteControlReport.failed }
        case "Settings-ConnectAddress":
            await hooks.setConnectAddress?(data)
        case "Settings-Stage1":
            if await hooks.setStage1?(data) != true { status = RemoteControlReport.failed }
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
            if !reportFailureLogged {
                await hooks.log?("远控回执上报失败")
                reportFailureLogged = true
            }
            return
        }
        reportFailureLogged = false
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
