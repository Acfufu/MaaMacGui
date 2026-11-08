//
//  TaskDetail.swift
//  MAA
//
//  Created by hguandl on 19/4/2023.
//

import SwiftUI

struct TaskDetail: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Environment(NewViewModel.self) private var newModel
    let id: UUID?

    var body: some View {
        VStack {
            switch newModel.dailyTasksDetailMode {
            case .taskConfig:
                if let id, let task = viewModel.tasks[id] {
                    switch task {
                    case .startup(let config):
                        StartupSettingsView(config: taskConfigBinding(config, id: id))
                    case .recruit(let config):
                        RecruitSettingsView(
                            config: taskConfigBinding(config, id: id),
                            resourceDirectory: viewModel.recruitResourceDirectory,
                            resourceRevision: viewModel.recruitResourceRevision)
                    case .infrast(let config):
                        InfrastSettingsView(config: taskConfigBinding(config, id: id))
                    case .fight(let config):
                        FightSettingsView(config: taskConfigBinding(config, id: id))
                    case .mall(let config):
                        MallSettingsView(config: taskConfigBinding(config, id: id))
                    case .award(let config):
                        AwardSettingsView(config: taskConfigBinding(config, id: id))
                    case .switchTheme(let config):
                        SwitchThemeSettingsView(config: taskConfigBinding(config, id: id))
                    case .roguelike(let config):
                        RoguelikeSettingsView(config: taskConfigBinding(config, id: id),
                                              blackflowStartAvailable: viewModel.blackflowStartAvailable,
                                              supportsSeedInput: viewModel.touchMode != .MacPlayTools)
                    case .reclamation(let config):
                        ReclamationSettingsView(config: taskConfigBinding(config, id: id))
                    case .userdataupdate(let config):
                        UserDataUpdateSettingsView(config: taskConfigBinding(config, id: id))
                    case .custom(let config):
                        CustomSettingsView(config: taskConfigBinding(config, id: id))
                    case .operProgress(let config):
                        OperProgressSettingsView(config: taskConfigBinding(config, id: id))
                    case .closedown(_):
                        EmptyView()
                    }
                } else {
                    Text("Please select one task to config")
                }
            case .log:
                LogView()
            case .timerConfig:
                TaskTimerView()
            }
        }
        .padding()
        .toolbar(content: detailToolbar)
    }

    private func taskConfigBinding<T: MAATaskConfiguration>(_ value: T, id: UUID) -> Binding<T> {
        Binding {
            value
        } set: {
            viewModel.tasks[id] = $0.projectedTask
        }
    }

    /// Q05 任务级“仅一次”开关绑定到选中任务的 runOnce 标记。
    private func runOnceBinding(_ id: UUID) -> Binding<Bool> {
        Binding {
            guard let index = viewModel.tasks.firstIndex(id: id) else { return false }
            return viewModel.tasks[index].runOnce
        } set: { value in
            guard let index = viewModel.tasks.firstIndex(id: id) else { return }
            viewModel.tasks[index].runOnce = value
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func detailToolbar() -> some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                ForEach(defaultTaskConfigurations, id: \.type) { config in
                    Button(config.title) {
                        addTask(config: config)
                    }
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .help("添加任务")

            if let id, viewModel.tasks.firstIndex(id: id) != nil {
                Toggle("仅一次", isOn: runOnceBinding(id))
                    .help("该任务在下一次完整成功的运行结束后自动停用；失败或取消不消耗")
            }
        }

        ToolbarItem {
            @Bindable var newModel = newModel
            Picker("内容", selection: $newModel.dailyTasksDetailMode) {
                Label("选项", systemImage: "gearshape").tag(MAAViewModel.DailyTasksDetailMode.taskConfig)
                Label("日志", systemImage: "note.text").tag(MAAViewModel.DailyTasksDetailMode.log)
                Label("定时", systemImage: "clock.arrow.2.circlepath").tag(MAAViewModel.DailyTasksDetailMode.timerConfig)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Actions

    private func addTask<T: MAATaskConfiguration>(config: T) {
        viewModel.tasks.append(config: config)
        viewModel.newTaskAdded = true
    }
}

struct TaskDetail_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = MAAViewModel()
        let newModel = NewViewModel(parent: viewModel)
        TaskDetail(id: nil)
            .environmentObject(MAAViewModel())
            .environment(newModel)
    }
}
