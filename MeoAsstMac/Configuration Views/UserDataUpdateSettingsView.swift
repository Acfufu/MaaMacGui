import SwiftUI

struct UserDataUpdateSettingsView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var config: UserDataUpdateConfiguration
    @State private var latestDepot: UserDataSyncReceipt?
    @State private var latestOperators: UserDataSyncReceipt?
    @State private var historyUnavailable = false

    var body: some View {
        Form {
            Toggle("干员识别", isOn: $config.updateOperBox)
            receipt(latestOperators ?? config.lastOperBoxSync)
            Toggle("仓库识别", isOn: $config.updateDepot)
            receipt(latestDepot ?? config.lastDepotSync)
            Picker("触发间隔", selection: $config.triggerInterval) {
                ForEach(UserDataUpdateTriggerInterval.allCases, id: \.self) { interval in
                    Text(interval.description).tag(interval)
                }
            }
            Text("按区服游戏日凌晨四点与周一四点判断间隔。识别完整成功并保存后才更新对应记录；失败、取消或切换身份不会提前记为成功。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("同一身份下的手动识别也计入更新间隔。")
                .font(.caption).foregroundStyle(.secondary)
            if historyUnavailable { Text("历史资料不可用，下一次将重新识别。").font(.caption).foregroundStyle(.secondary) }
            if viewModel.userDataAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("尚未绑定本地账号标识：将每次识别。可在仓库或干员工具页绑定，以使用按天、按周的成功记录。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !config.updateDepot && !config.updateOperBox {
                Text("未选择识别内容，此任务将跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding()
        .task(id: viewModel.inventoryScope) { reloadReceipts() }
        .onChange(of: viewModel.operBoxHistoryRevision) { _, _ in reloadReceipts() }
        .onChange(of: viewModel.inventory.snapshot?.generation) { _, _ in reloadReceipts() }
    }

    private func reloadReceipts() {
        latestDepot = nil; latestOperators = nil; historyUnavailable = false
        do { latestDepot = try viewModel.successfulUserDataReceipt(.depot, scope: viewModel.inventoryScope) }
        catch { historyUnavailable = true }
        do { latestOperators = try viewModel.successfulUserDataReceipt(.operBox, scope: viewModel.inventoryScope) }
        catch { historyUnavailable = true }
    }

    @ViewBuilder private func receipt(_ value: UserDataSyncReceipt?) -> some View {
        if let value, value.scope == viewModel.inventoryScope {
            LabeledContent("当前身份上次成功更新") {
                Text(value.completedAt, format: .dateTime.year().month().day().hour().minute())
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
