//
//  CopilotsView.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import SwiftUI
import UniformTypeIdentifiers

struct CopilotContent: View {
    @Environment(NewViewModel.self) var newModel

    struct Item: FileTreeItem {
        let url: URL
        let id: CopilotContext.ItemID

        init(url: URL) {
            self.url = url
            self.id = .init(url: url, isRaid: nil)
        }

        var children: [Item]?

        var name: String {
            url.deletingPathExtension().lastPathComponent
        }
    }

    @State private var bundledRoot = Item(url: .bundledCopilotDirectory)
    @State private var externalRoot = Item(url: .externalCopilotDirectory)

    @State private var tracker = FileTreeTracker()

    var body: some View {
        @Bindable var context = newModel.copilot
        List(selection: $context.selection) {
            switch context.category {
            case .bundled:
                FileTreeRoot(item: $bundledRoot, tracker: tracker) {
                    Text($0.name)
                }
            case .external:
                FileTreeRoot(item: $externalRoot, tracker: tracker) {
                    Text($0.name)
                }
            case .list:
                CopilotListContent(context: context)
            }
        }
        .contextMenu(forSelectionType: CopilotContext.ItemID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            if context.category == .list {
                context.selection = nil
                return
            }
            if let url = ids.first?.url {
                tracker.sendURLAction(of: url)
            }
        }
        .safeAreaInset(edge: .top, spacing: 6) {
            CapsulePicker(CopilotCategory.allCases, selection: $context.category, color: \.color) {
                Image(systemName: $0.systemImage)
            } text: {
                Text($0.title)
            } action: {
                context.selection = nil
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .background(.background)
        }
        .safeAreaInset(edge: .bottom) {
            if context.category == .list {
                CopilotListControls(context: context)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.background)
            }
        }
        .toolbar {
            CopilotListToolbar(externalRoot: $externalRoot)
        }
        .task(id: context.category) {
            switch context.category {
            case .bundled:
                await refreshItem(at: \.$bundledRoot)
            case .external:
                await refreshItem(at: \.$externalRoot)
            case .list:
                break
            }
        }
        .task {
            // C09 跨启动恢复：进作业页即尝试一次性恢复（内部有闸门）。
            await newModel.restoreCopilotList()
        }
        .task(id: newModel.lastImportedCopilot) {
            guard let url = newModel.lastImportedCopilot else {
                return
            }
            defer {
                newModel.lastImportedCopilot = nil
            }
            context.selection = .init(url: url, isRaid: nil)
            if url.isDirectory {
                // C09/C02：导入作业集的激活失败/部分成员跳过不再静默。
                if let listing = await context.updateSet(at: url) {
                    context.category = .list
                    if !listing.skipped.isEmpty {
                        newModel.appendLog(
                            .init(
                                date: .now,
                                content: String(
                                    localized:
                                        "作业集已激活，部分成员无法加载：\(listing.skipped.joined(separator: "、"))"
                                ),
                                color: .warning))
                    }
                } else {
                    newModel.appendLog(
                        .init(
                            date: .now,
                            content: String(
                                localized: "作业集无法激活：清单损坏或成员类型不一致。"),
                            color: .error))
                }
            } else {
                await refreshItem(at: \.$externalRoot)
                context.category = .external
            }
        }
        .onChange(of: context.copilotList.isEmpty, initial: true) {
            // 恢复闸门：跨启动恢复尚未尝试（restoreAttempted == false）时列表
            // 的短暂为空不触发分类回退，避免恢复被 UI 抢先切走。
            if $1, context.category == .list, context.restoreAttempted {
                context.category = .external
                context.selection = nil
            }
        }
        .onDrop(of: [.json, .movie], isTargeted: .none, perform: addCopilots)
    }

    // MARK: - Actions

    private func refreshItem(at keyPath: KeyPath<Self, Binding<Item>>) async {
        let binding = self[keyPath: keyPath]
        let newChildren = try? await binding.wrappedValue.children()
        binding.wrappedValue.children = newChildren ?? []
    }

    private func addCopilots(_ providers: [NSItemProvider]) -> Bool {
        // C13 触发面：拖入既接受作业 JSON 也接受视频，逐项按声明类型取 URL——
        // json 走作业导入，movie 走 recognizeVideo（WPF 已移除视频识别面而 Mac 按
        // CSV C13 有意恢复该面，divergence P15-[b]）。
        let jsonTypeID = UTType.json.identifier
        let movieTypeID = UTType.movie.identifier
        let canLoadAll = providers.allSatisfy { provider in
            provider.hasItemConformingToTypeIdentifier(jsonTypeID)
                || provider.hasItemConformingToTypeIdentifier(movieTypeID)
        }
        guard !providers.isEmpty, canLoadAll else { return false }

        let (stream, continuation) = AsyncStream<Result<URL, Error>>.makeStream()

        for provider in providers {
            let typeID = provider.hasItemConformingToTypeIdentifier(jsonTypeID)
                ? jsonTypeID : movieTypeID
            provider.loadItem(forTypeIdentifier: typeID) { item, error in
                if let error {
                    continuation.yield(.failure(error))
                } else if let url = item as? URL {
                    continuation.yield(.success(url))
                } else {
                    continuation.yield(.failure(CocoaError(.fileReadUnknown)))
                }
            }
        }

        Task.detached { [total = providers.count] in
            var count = 0

            for await result in stream {
                count += 1
                if count == total {
                    continuation.finish()
                }

                do {
                    let url = try result.get()
                    try await addCopilot(url: url)
                } catch {
                    print(error)
                }
            }
        }

        return true
    }

    private func addCopilot(url: URL) async throws {
        guard url.isFileURL, let type = url.contentType else {
            return
        }
        switch type {
        case _ where type.conforms(to: .json):
            async let dest = try FileManager.default.copyCopilotToExternalDirectory(at: url)
            newModel.lastImportedCopilot = try await dest
        case _ where type.conforms(to: .movie):
            try await newModel.recognizeVideo(url: url)
        default:
            break
        }
    }
}

// MARK: - Toolbar

private struct CopilotListToolbar: ToolbarContent {
    @Environment(NewViewModel.self) private var newModel
    @Binding var externalRoot: CopilotContent.Item

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: deleteSelectedCopilot) {
                Label("移除", systemImage: "trash")
            }
            .help("移除作业")
            .disabled(!canDeleteCopilot)
            .keyboardShortcut(.delete, modifiers: [.command])
        }

        ToolbarItemGroup {
            switch newModel.status {
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
                .disabled(!newModel.canStartTasks || !newModel.copilot.isReady)
            }
        }
    }

    private var canDeleteCopilot: Bool {
        if newModel.copilot.category == .list {
            return false
        }
        if let url = newModel.copilot.selection?.url {
            return url.isManagedCopilot
        } else {
            return false
        }
    }

    // MARK: - Actions

    private func stop() {
        Task {
            try await newModel.stop()
        }
    }

    private func start() {
        Task {
            do {
                try await newModel.startCopilot()
            } catch MAAError.taskOperationInProgress, MAAError.taskAlreadyRunning {
                // beginTaskOperation already reported these through the log channel.
            } catch {
                // Surface queueing failures (e.g. appendTask) that used to be
                // swallowed by the unobserved Task result.
                newModel.appendLog(
                    .init(
                        date: .now,
                        content: String(
                            localized: "作业启动失败：\(String(describing: error))"),
                        color: .error))
            }
        }
    }

    private func deleteSelectedCopilot() {
        guard let selection = newModel.copilot.selection?.url else {
            return
        }

        let nextSelection = externalRoot.possibleSibling(of: selection)

        Task.detached {
            await deleteCopilot(url: selection)
            let children = try? await externalRoot.children()
            await MainActor.run {
                externalRoot.children = children ?? []
                if let url = nextSelection?.url {
                    newModel.copilot.selection = .init(url: url, isRaid: nil)
                } else {
                    newModel.copilot.selection = nil
                }
            }
        }
    }

    @concurrent private func deleteCopilot(url: URL) async {
        guard url.isManagedCopilot else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension CopilotCategory: Identifiable {
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled:
            String(localized: "内置")
        case .external:
            String(localized: "外部")
        case .list:
            String(localized: "列表")
        }
    }

    var systemImage: String {
        switch self {
        case .bundled:
            "house"
        case .external:
            "doc"
        case .list:
            "doc.on.doc"
        }
    }

    var color: Color {
        switch self {
        case .bundled:
            .copilotBlue
        case .external:
            .copilotGreen
        case .list:
            .copilotIndigo
        }
    }
}

struct CopilotContent_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            CopilotContent()
        }
        .frame(maxWidth: 300)
        .environment(NewViewModel(parent: MAAViewModel()))
    }
}

extension CopilotContext {
    var isReady: Bool {
        if category == .list {
            return copilotSet != nil && !copilotList.isEmpty
        }
        if case .copilot = content {
            return true
        }
        return false
    }
}

// MARK: - Value Extensions

extension CopilotContent.Item {
    func possibleSibling(of url: URL) -> Self? {
        if self.url == url {
            return nil
        }
        var searchStack = [self]

        while !searchStack.isEmpty {
            let current = searchStack.removeLast()

            if let children = current.children {
                for index in children.indices {
                    let item = children[index]

                    if item.url == url {
                        let nextIndex = children.index(after: index)

                        if nextIndex != children.endIndex {
                            return children[nextIndex]
                        } else if index != children.startIndex {
                            let prevIndex = children.index(before: index)
                            return children[prevIndex]
                        }

                        return nil
                    }

                    if item.children != nil {
                        searchStack.append(item)
                    }
                }
            }
        }
        return nil
    }
}
