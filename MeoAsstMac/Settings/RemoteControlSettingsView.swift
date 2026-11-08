import SwiftUI

/// P26/E07+E08: 远控配置面（WPF RemoteControlUserControl 同位）。
/// 端点为空即整体停用；http 端点提示不安全但仍可保存（WPF WarningHttpUnsafe 同构）。
struct RemoteControlSettingsView: View {
    @ObservedObject var service: RemoteControlService
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Text("轮询任务端点接收远控命令（开始/停止/截图/设置等，命令矩阵与上游 WPF 一致），执行后向回执端点上报结果。任务端点为空即停用；同 id 命令不重复执行。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("任务端点", text: stringBinding(key: RemoteControlService.keys.getTaskEndpoint))
            if RemoteControlProtocol.isEndpointUnsafeHTTP(service.getTaskEndpoint) {
                Text("当前任务端点为 http 明文连接，存在被窃听/篡改的风险。")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextField("回执端点", text: stringBinding(key: RemoteControlService.keys.reportStatusEndpoint))
            TextField("用户标识", text: stringBinding(key: RemoteControlService.keys.userIdentity))
            HStack {
                TextField("设备标识", text: stringBinding(key: RemoteControlService.keys.deviceIdentity))
                Button("重新生成") { service.regenerateDeviceIdentity() }
            }
            TextField("轮询间隔（毫秒）", text: Binding(
                get: { String(service.pollIntervalMs) },
                set: { service.pollIntervalMs = Int($0) ?? 1000 }
            ))
            HStack {
                Button(isTesting ? "测试中…" : "测试连接") {
                    isTesting = true
                    testResult = nil
                    Task {
                        let ok = await service.connectionTest()
                        testResult = ok ? "连接成功" : "连接失败（检查端点与网络）"
                        isTesting = false
                    }
                }
                .disabled(isTesting || !RemoteControlProtocol.isEndpointValid(service.getTaskEndpoint))
                if let testResult {
                    Text(testResult).font(.caption)
                        .foregroundStyle(testResult == "连接成功" ? .green : .red)
                }
                Spacer()
                Text(service.isPolling ? "轮询中" : "未轮询")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 380)
    }

    /// UserDefaults 背书属性的通用绑定（写入即持久化并驱动 objectWillChange）。
    private func stringBinding(key: String) -> Binding<String> {
        Binding(
            get: { service.defaultsString(forKey: key) },
            set: { service.setValue($0, forKey: key) }
        )
    }
}
