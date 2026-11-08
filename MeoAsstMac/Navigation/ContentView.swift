//
//  ContentView.swift
//  MAA
//
//  Created by hguandl on 13/4/2023.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @EnvironmentObject private var announcements: AnnouncementStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedSidebar: SidebarEntry? = .daily
    @State private var selectedContent = ContentEntry()

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selectedSidebar, showUpdate: $viewModel.showResourceUpdate) {
                try await viewModel.reloadResources(channel: viewModel.clientChannel)
            }
        } content: {
            MAAContent(sidebar: $selectedSidebar, selection: $selectedContent)
        } detail: {
            MAADetail(sidebar: $selectedSidebar, selection: $selectedContent)
        }
        .toolbar { ToolbarItem { AnnouncementMenuButton(store: announcements) } }
        .background(MainWindowAccessor())
        .alert(
            "即将自动开始日常任务",
            isPresented: Binding(
                get: { viewModel.startupAutoRunRemaining != nil },
                set: { if !$0 { viewModel.cancelStartupAutoRun() } }
            ),
            actions: {
                Button("取消自动运行", role: .cancel) { viewModel.cancelStartupAutoRun() }
            },
            message: {
                Text("将在 \(viewModel.startupAutoRunRemaining ?? 0) 秒后自动开始日常任务")
            }
        )
        .task {
            // S18: Dock 点击/显隐热键在主窗口被 SwiftUI 释放后可经此重建。
            // 高1（P20-1-R3）：openWindow 只能寻址显式声明该 id 的 scene——
            // id 单源 MainWindowScene.id，与主 WindowGroup 同源。
            MainWindowTracker.shared.reopenHandler = { openWindow(id: MainWindowScene.id) }
            do {
                try await viewModel.initialize()
                // Core initialization/errors own the first window. Announcements load afterward without blocking it.
                await announcements.refresh()
                if !Task.isCancelled, announcements.automaticallyShow, announcements.hasUnread,
                    viewModel.status == .idle
                {
                    openWindow(id: "community-announcements")
                }
                // S02: 初始化就绪后再判定启动自动运行（WPF 在 Init 尾段同位）。
                if !Task.isCancelled {
                    viewModel.requestStartupAutoRun(cliSkipRequested: StartupAutoRunPolicy.cliSkipRequested)
                }
            } catch {
                viewModel.logError("初始化失败: \(error.localizedDescription)")
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(MAAViewModel())
            .environmentObject(AnnouncementStore())
    }
}
