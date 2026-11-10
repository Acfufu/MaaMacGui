//
//  TaskButtons.swift
//  MAA
//
//  Created by hguandl on 30/4/2023.
//

import SwiftUI

struct TaskButtons: View {
    @EnvironmentObject var viewModel: MAAViewModel

    var body: some View {
        Button("开始任务") {
            Task {
                await viewModel.tryStartTasks()
            }
        }
        .keyboardShortcut("R", modifiers: .command)
        .disabled(!viewModel.canStartTasks)

        Button(viewModel.roguelikeWaitingForCombat ? String(localized: "立即停止") : String(localized: "停止任务")) {
            Task {
                try await viewModel.stop()
            }
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!viewModel.canStopTasks)
        .help(viewModel.roguelikeWaitingForCombat
              ? String(localized: "正在等待当前肉鸽战斗结束；再次停止将立即中断。")
              : String(localized: "停止当前任务；肉鸽战斗中先等待战斗结束，最多 10 分钟。"))

        Button("全部启用") {
            for (index, task) in viewModel.tasks.enumerated() {
                switch task.task {
                case .roguelike, .reclamation, .custom, .operProgress:
                    continue
                default:
                    viewModel.tasks[index].enabled = true
                }
            }
        }
        .keyboardShortcut("E", modifiers: [.command, .shift])

        Button("全部取消") {
            for (index, _) in viewModel.tasks.enumerated() {
                viewModel.tasks[index].enabled = false
            }
        }
        .keyboardShortcut("D", modifiers: [.command, .shift])
    }
}

struct TaskButtons_Previews: PreviewProvider {
    static var previews: some View {
        TaskButtons().environmentObject(MAAViewModel())
    }
}
