import AppKit
import SwiftUI

/// S13/S18 共用的主窗口可见性操作。
/// S18 统一行为：关闭最后一个窗口不退出（对齐 WPF 关窗驻留与上游 #144 方向），
/// 应用保留在 Dock，经 Dock 点击/重新激活/热键找回窗口；⌘Q 显式退出路径不变。
@MainActor final class MainWindowTracker {
    static let shared = MainWindowTracker()
    weak var window: NSWindow?
    /// 主窗口对象被 SwiftUI 释放后的兜底重建入口（由 ContentView 注入 openWindow(id: "main")）。
    var reopenHandler: (() -> Void)?
}

@MainActor enum MainWindowVisibility {
    /// S13: 显隐主窗口。可见则隐藏（关窗驻留语义，不触发退出），不可见则前置。
    @discardableResult
    static func toggle(tracker: MainWindowTracker) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = tracker.window else {
            tracker.reopenHandler?()
            return true
        }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// S18: Dock 点击/重新激活时找回主窗口；SwiftUI WindowGroup 会在无窗口时自行重建。
    static func reopen(tracker: MainWindowTracker) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = tracker.window {
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        } else {
            tracker.reopenHandler?()
        }
    }
}

/// S18: 登记主窗口的 NSView 桥（附着于 ContentView 背景，随 SwiftUI 更新刷新弱引用）。
struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI 保证主线程调用；assumeIsolated 兼容本 SDK 的非隔离协议签名。
        MainActor.assumeIsolated {
            MainWindowTracker.shared.window = nsView.window
        }
    }
}
