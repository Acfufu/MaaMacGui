//
//  TasksContent.swift
//  MAA
//
//  Created by hguandl on 14/4/2023.
//

import SwiftUI

struct TasksContent: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach($viewModel.tasks, id: \.id) { $task in
                switch task.task {
                case .startup(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .closedown(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .recruit(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .infrast(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .fight(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .mall(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .award(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .switchTheme(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .roguelike(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .reclamation(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .userdataupdate(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .depotMaintain(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .custom(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                case .operProgress(let config):
                    TaskCell(id: task.id, config: config, enabled: $task.enabled)
                }
            }
            .onMove(perform: moveTask)
        }
        .onChange(of: selection, updateViewMode)
        .toolbar(content: listToolbar)
        .animation(.default, value: viewModel.tasks)
        .onReceive(viewModel.$newTaskAdded, perform: selectLastTask)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func listToolbar() -> some ToolbarContent {
        ToolbarItemGroup {
            ProfilePickerMenu()
        }

        ToolbarItemGroup {
            Button(action: deleteSelectedTask) {
                Label("删除", systemImage: "trash")
            }
            .help("删除任务")
            .disabled(shouldDisableDeletion)
        }

        ToolbarItemGroup {
            switch viewModel.status {
            case .pending:
                Button(action: {}) {
                    ProgressView().controlSize(.small)
                }
                .disabled(true)
            case .busy:
                Button(action: stop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .help("停止")
            case .idle:
                Button(action: start) {
                    Label("开始", systemImage: "play.fill")
                }
                .help("开始")
                .disabled(!viewModel.canStartTasks)
            }
        }
    }

    // MARK: - Actions

    private func start() {
        Task {
            await viewModel.tryStartTasks()
        }
    }

    private func stop() {
        Task {
            try await viewModel.stop()
        }
    }

    private func deleteSelectedTask() {
        guard viewModel.tasks.count > 1,
            let selection,
            let index = viewModel.tasks.firstIndex(id: selection)
        else {
            return
        }
        viewModel.tasks.remove(id: selection)
        if index >= viewModel.tasks.count {
            self.selection = viewModel.tasks.last?.id
        } else {
            self.selection = viewModel.tasks[index].id
        }
    }

    private func moveTask(from: IndexSet, to: Int) {
        viewModel.tasks.move(fromOffsets: from, toOffset: to)
    }

    private func selectLastTask(_ shouldSelect: Bool) {
        if shouldSelect {
            selection = viewModel.tasks.last?.id
        }
    }

    private func updateViewMode(_: UUID?, selectedTaskID: UUID?) {
        guard selectedTaskID != nil else { return }
        viewModel.logStore?.setDailyTasksDetailMode(.taskConfig)
    }

    // MARK: - State Wrappers

    private var shouldDisableDeletion: Bool {
        if let selection, case .startup = viewModel.tasks[selection] {
            // 判断是否只剩一个 .startup
            var startupCount = 0
            for task in viewModel.tasks {  // 预期多账号也应在 1e2 以内
                if case .startup(_) = task.task {
                    startupCount += 1
                    if startupCount > 1 { break }  // 发现第二个时立即终止遍历
                }
            }
            return startupCount == 1
        } else {
            return selection == nil
        }
    }
}

// MARK: - Profile Management (P03.2 / Q03)

/// 任务列表工具栏中的档案选择菜单：列出注册表、当前档案打勾，
/// 切换即重载任务列表；运行期间禁用。
private struct ProfilePickerMenu: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @State private var isManaging = false

    var body: some View {
        Menu {
            ForEach(viewModel.profileIdentities) { identity in
                Button {
                    viewModel.switchProfile(identity.id)
                } label: {
                    if identity.id == viewModel.dailyTaskProfile {
                        Label(identity.displayName, systemImage: "checkmark")
                    } else {
                        Text(identity.displayName)
                    }
                }
            }
            Divider()
            Button("管理档案…") { isManaging = true }
        } label: {
            Label(activeName, systemImage: "person.crop.stack")
        }
        .disabled(!viewModel.canStartTasks)
        .help(viewModel.canStartTasks ? "切换任务档案" : "任务运行中，无法切换档案")
        .sheet(isPresented: $isManaging) { ProfileManageSheet() }
    }

    private var activeName: String {
        viewModel.profileIdentities.first { $0.id == viewModel.dailyTaskProfile }?
            .displayName ?? viewModel.dailyTaskProfile
    }
}

/// 档案管理面板：新建（命名）、复制、重命名、删除（活跃项禁用并说明），
/// 删除需确认。
private struct ProfileManageSheet: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var renaming: ProfileIdentity?
    @State private var renameText = ""
    @State private var deleting: ProfileIdentity?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("新档案名称", text: $newName)
                Button("新建") {
                    viewModel.createProfile(named: newName)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(viewModel.profileIdentities) { identity in
                    profileRow(identity)
                }
            }
            .frame(minHeight: 160)
            Text("勾选项为当前档案；活跃档案需先切换到其他档案后才能删除。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 340)
        .sheet(item: $renaming) { identity in
            VStack(alignment: .leading, spacing: 8) {
                Text("重命名档案「\(identity.displayName)」")
                TextField("档案名称", text: $renameText)
                HStack {
                    Spacer()
                    Button("取消") { renaming = nil }
                    Button("重命名") {
                        viewModel.renameProfile(identity.id, to: renameText)
                        renaming = nil
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(width: 320)
        }
        .confirmationDialog(
            "删除档案「\(deleting?.displayName ?? "")」？其任务列表将被移除，无法恢复。",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let deleting { viewModel.deleteProfile(deleting.id) }
                self.deleting = nil
            }
        }
    }

    private func profileRow(_ identity: ProfileIdentity) -> some View {
        let isActive = identity.id == viewModel.dailyTaskProfile
        return HStack {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(identity.displayName)
                Text(identity.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("复制") { viewModel.duplicateProfile(identity.id) }
            Button("重命名") {
                renameText = identity.displayName
                renaming = identity
            }
            Button("删除", role: .destructive) { deleting = identity }
                .disabled(isActive)
                .help(isActive ? "活跃档案不能删除，请先切换" : "删除该档案及其任务列表")
        }
        .padding(.vertical, 2)
    }
}

struct TasksContent_Previews: PreviewProvider {
    static var previews: some View {
        TasksContent(selection: .constant(nil))
            .environmentObject(MAAViewModel())
    }
}
