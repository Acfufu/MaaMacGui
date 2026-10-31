import ServiceManagement
import SwiftUI

struct SystemSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel

    @State private var showHooks = false
    @State private var showHotkeys = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LoginItemSettingsView()

            Divider()
            Button("日常任务前后脚本…") { showHooks = true }
            Button("全局热键…") { showHotkeys = true }

            Toggle(isOn: $viewModel.preventSystemSleeping) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("阻止系统睡眠")
                    Text("日常任务定时执行会在系统休眠之后失效, 打开此功能可以阻止系统自动睡眠")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showHooks) {
            VStack {
                HookSettingsView(store: viewModel.hookSettings)
                Button("完成") { showHooks = false }.keyboardShortcut(.defaultAction).padding(.bottom)
            }.environmentObject(viewModel)
        }
        .sheet(isPresented: $showHotkeys) {
            HotkeySettingsView(service: viewModel.globalHotkeys)
        }
    }
}

struct SystemSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SystemSettingsView()
            .environmentObject(MAAViewModel())
    }
}
