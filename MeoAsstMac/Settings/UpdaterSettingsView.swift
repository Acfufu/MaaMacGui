//
//  UpdaterSettingsView.swift
//  MeoAsstMac
//
//  Created by hguandl on 13/3/2023.
//

import Sparkle
import SwiftUI

struct UpdaterSettingsView: View {
    private let updater: SPUUpdater

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    @AppStorage("MaaUseBetaChannel") private var useBetaChannel = false
    @AppStorage("AutoResourceUpdate") var autoResourceUpdate = false
    @AppStorage("ResourceUpdateChannel") var resourceChannel = MAAResourceChannel.github
    // P27/U03/U04/U08: token/定时检查/代理（键与 MAAViewModel 同名同缺省）。
    @AppStorage("MAAGitHubResourceToken") var githubResourceToken = ""
    @AppStorage("MAACheckResourceUpdateOnSchedule") var checkResourceUpdateOnSchedule = false
    @AppStorage("MAAResourceUpdateCheckIntervalHours") var resourceUpdateCheckIntervalHours = 24
    @AppStorage("MAAResourceUpdateProxyEnabled") var resourceProxyEnabled = false
    @AppStorage("MAAResourceUpdateProxy") var resourceUpdateProxy = ""

    init(updater: SPUUpdater) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    var body: some View {
        Form {
            Toggle("接收开发版更新", isOn: $useBetaChannel)

            Toggle("自动检查更新", isOn: $automaticallyChecksForUpdates)
                .onChange(of: automaticallyChecksForUpdates) {
                    updater.automaticallyChecksForUpdates = $1
                }

            Toggle("自动下载更新", isOn: $automaticallyDownloadsUpdates)
                .disabled(!automaticallyChecksForUpdates)
                .onChange(of: automaticallyDownloadsUpdates) {
                    updater.automaticallyDownloadsUpdates = $1
                }

            Divider()

            Picker("资源更新来源", selection: $resourceChannel) {
                ForEach(MAAResourceChannel.allCases, id: \.hashValue) { channel in
                    Text(channel.description).tag(channel)
                }
            }

            if resourceChannel == .mirrorChyan {
                SecureField("CDK", text: mirrorChyanCDK)
            } else if resourceChannel == .github {
                SecureField("GitHub Token（可选，用于解除限流）", text: $githubResourceToken)
            }

            Toggle("自动资源更新", isOn: $autoResourceUpdate)
            Toggle("定时检查资源更新", isOn: $checkResourceUpdateOnSchedule)
            if checkResourceUpdateOnSchedule {
                Stepper(value: $resourceUpdateCheckIntervalHours, in: 1...168) {
                    Text("每 \(resourceUpdateCheckIntervalHours) 小时检查一次")
                }
            }

            Divider()

            // P27/U08: 更新链网络代理（WPF Proxy/ProxyType 同位子集）。
            Toggle("使用代理更新资源", isOn: $resourceProxyEnabled)
            if resourceProxyEnabled {
                TextField("代理地址（如 127.0.0.1:7890 或 socks5://127.0.0.1:1080）",
                          text: $resourceUpdateProxy)
                Text("支持 http/https/socks5 代理；仅作用于资源更新链（查询与下载）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("重新打开应用后生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .animation(.default, value: resourceChannel)
        .padding()
    }
}

private let mirrorChyanCDK = Binding {
    MirrorChyan.getCDK() ?? ""
} set: {
    _ = MirrorChyan.setCDK($0)
}

struct UpdaterSettingsView_Previews: PreviewProvider {
    private static let updateController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    static var previews: some View {
        UpdaterSettingsView(updater: updateController.updater)
    }
}
