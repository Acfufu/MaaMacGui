//
//  MeoAsstMacApp.swift
//  MeoAsstMac
//
//  Created by hguandl on 8/10/2022.
//

import OSLog
import Sparkle
import SwiftUI

private let appLogger = Logger(subsystem: "com.hguandl.MeoAsstMac", category: "MeoAsstMacApp")

@main
struct MeoAsstMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var appViewModel: MAAViewModel
    @State private var newViewModel: NewViewModel
    @StateObject private var announcements = AnnouncementStore()

    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate = MaaUpdaterDelegate()

    init() {
        Self.applyConfigArgument()
        let viewModel = MAAViewModel()
        let newModel = NewViewModel(parent: viewModel)
        _appViewModel = StateObject(wrappedValue: viewModel)
        _newViewModel = State(wrappedValue: newModel)
        #if DEBUG
        let isRelease = false
        #else
        let isRelease = true
        #endif
        updaterController = .init(startingUpdater: isRelease, updaterDelegate: updaterDelegate, userDriverDelegate: nil)
        appDelegate.beforeTermination = {
            viewModel.globalHotkeys.shutdown()
            await viewModel.prepareForTermination()
            await newModel.waitLogStoreToFinish()
        }
        // P23/E01: 点击通知仅重新前置主窗口（S18 关窗驻留语义下的找回路径）。
        viewModel.localNotifications.installTapHandler { MainWindowVisibility.reopen(tracker: .shared) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .overlay(alignment: .topTrailing) { AchievementUnlockHint() }
                .environmentObject(appViewModel)
                .environment(newViewModel)
                .environmentObject(announcements)
                .onAppear {
                    BackgroundScheduleService.shared.attach(to: appViewModel)
                    TaskTimerManager.shared.connectToModel(viewModel: appViewModel)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenLogFileView()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                AnnouncementMenuButton(store: announcements)
            }
            SidebarCommands()
            TaskCommands(viewModel: appViewModel)
        }

        Window("Announcement.Title", id: "community-announcements") {
            AnnouncementView(store: announcements)
        }
        .defaultSize(width: 660, height: 580)

        Settings {
            TabView {
                ConnectionSettingsView()
                    .tabItem {
                        Label("连接设置", systemImage: "rectangle.connected.to.line.below")
                    }

                GameSettingsView()
                    .tabItem {
                        Label("游戏设置", systemImage: "gamecontroller")
                    }

                UpdaterSettingsView(updater: updaterController.updater)
                    .tabItem {
                        Label("更新设置", systemImage: "square.and.arrow.down")
                    }

                SystemSettingsView()
                    .tabItem {
                        Label("系统设置", systemImage: "wrench.adjustable")
                    }
            }
            .environmentObject(appViewModel)
            .frame(maxWidth: 360, minHeight: 240)
        }
    }
    /// Q04: `--config <id-or-name>` selects the active profile before the UI
    /// loads; ambiguous or unknown values log an error and keep the saved one.
    private static func applyConfigArgument() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--config") else {
            if let attached = arguments.first(where: { $0.hasPrefix("--config=") }) {
                appLogger.error("\(attached, privacy: .public) uses the unsupported --config=<value> form; pass \"--config <value>\" as two arguments")
            }
            return
        }
        guard index + 1 < arguments.count else { return appLogger.error("--config requires a profile id or name") }
        let store = ProfileStore(rootURL: ProfileStore.defaultRootURL())
        do {
            switch ProfileStore.resolveConfigArgument(arguments[index + 1], identities: try store.list()) {
            case .resolved(let profileID): try store.setActive(profileID)
            case .notFound(let value), .ambiguous(let value, _):
                appLogger.error("--config \(value, privacy: .public) matched no unique profile; keeping the active one")
            }
        } catch {
            appLogger.error("--config failed: \(error)")
        }
    }
}

final class MaaUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    @AppStorage("MaaUseBetaChannel") private var useBetaChannel = false
    // P28/U01: fork 自有更新源（上游 Info.plist 的 SUFeedURL 已被 fork 移除）。
    @AppStorage(UpdateFeedPolicy.feedURLDefaultsKey) private var updateFeedURL = ""

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // U02: 渠道面由 appcast 的 sparkle:channel 标记分流（stable/beta 两档；
        // WPF Nightly 渠道无 Mac appcast 支撑，不提供——差异入档）。
        UpdateFeedPolicy.allowedChannels(useBetaChannel: useBetaChannel)
    }

    /// U01: fork feed 注入。未配置时返回 nil——Sparkle 回退 Info.plist（fork 已移除，
    /// 即无 feed，检查失败有可见错误而非静默空转）。
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeedPolicy.feedURLString(configured: updateFeedURL)
    }

    // S02: Sparkle 更新重启不透传命令行参数；以一次性标记文件承担 WPF
    // --skip-startup-auto-run 的更新重启链语义（受 SkipStartupAutoRunAfterUpdate 门控）。
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        guard StartupAutoRunPolicy.skipAfterUpdateEnabled() else { return }
        try? StartupAutoRunMarker.write()
    }
}

private class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate var beforeTermination: (() async -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeTermination else { return .terminateNow }
        if terminationTask != nil { return .terminateLater }

        terminationTask = Task {
            await beforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // S18 统一行为：关窗不退出（定时任务/后台调度依赖进程存活），应用保留在
        // Dock；窗口经 Dock 点击/热键找回。显式退出（⌘Q）仍走 applicationShouldTerminate。
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindowVisibility.reopen(tracker: .shared) } }
        return true
    }
}
