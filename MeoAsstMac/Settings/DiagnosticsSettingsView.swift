import AppKit
import SwiftUI

/// P29/U12+U13+U14: 诊断与支持面（环境信息一键复制/支持报告打包/截图缓存清理/界面语言）。
struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @State private var feedback: String?
    // U14: 语言独立选择（system=跟随系统；AppleLanguages 重启生效）。
    @AppStorage("MAAAppLanguage") private var appLanguage = ""
    @AppStorage("MAAClientChannel") private var clientChannel = MAAClientChannel.Official

    private var resourceVersionText: String {
        (try? viewModel.resourceChannel.version().1.last_updated) ?? "-"
    }

    var body: some View {
        Form {
            Section("环境与支持") {
                Button("复制环境信息") {
                    let info = DiagnosticsReport.currentEnvironmentInfo(
                        resourceVersion: resourceVersionText,
                        clientChannel: clientChannel.rawValue,
                        coreVersion: MAAHandle.coreVersion())
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                    feedback = String(localized: "环境信息已复制到剪贴板")
                }
                Button("生成支持报告") {
                    do {
                        let supportDirectory = MAAViewModel.userDirectory
                            .appendingPathComponent("Diagnostics", isDirectory: true)
                        let destination = supportDirectory.appendingPathComponent(
                            "support-report-\(Int(Date().timeIntervalSince1970)).zip")
                        try DiagnosticsReport.buildSupportReport(
                            to: destination,
                            logFileURL: logFileURL,
                            resourceVersionURL: resourceVersionURL,
                            environment: DiagnosticsReport.currentEnvironmentInfo(
                                resourceVersion: resourceVersionText,
                                clientChannel: clientChannel.rawValue,
                                coreVersion: MAAHandle.coreVersion())) { source, target in
                            try FileManager.default.zipItem(at: source, to: target)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                        feedback = String(localized: "支持报告已生成并在访达中定位")
                    } catch {
                        feedback = String(localized: "支持报告生成失败：") + error.localizedDescription
                    }
                }
                Button("清理截图缓存") {
                    let removed = DiagnosticsReport.clearScreenshotCaches(
                        debugDirectory: MAAViewModel.userDirectory.appendingPathComponent("debug", isDirectory: true))
                    feedback = String(localized: "已清理 \(removed) 个截图文件")
                }
                if let feedback {
                    Text(feedback).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("语言") {
                Picker("界面语言", selection: $appLanguage) {
                    Text("跟随系统").tag("")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("한국어").tag("ko")
                }
                // 高1（P29-1-R3）：选择→AppleLanguages 的生产接线点（此前
                // applyAppLanguage 生产零调用，重启语言永不变化——假承诺）。
                .onChange(of: appLanguage) { _, newValue in
                    DiagnosticsReport.applyAppLanguage(newValue)
                }
                // 中1（P29-1-R3）：zh-Hant 摘档——Mac 无繁中资源，选繁中重启
                // 会解析为英文（preferredLocalizations 探针实证）；台账 P29-[b]。
                Text("切换后重启应用生效。干员名语言跟随资源区服，暂无独立选项。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var logFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("gui.log")
    }

    private var resourceVersionURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("resource")
            .appendingPathComponent("version.json")
    }
}
