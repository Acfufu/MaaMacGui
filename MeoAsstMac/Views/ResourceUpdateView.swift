//
//  ResourceUpdateView.swift
//  MAA
//
//  Created by hguandl on 2024/11/9.
//

import SwiftUI
import ZIPFoundation

struct ResourceUpdateView: View {
    let onUpdate: () async throws -> Void

    @State private var progress: (String, Double)? = ("", 0)
    @State private var error: Error?
    @State private var shouldUpdate = true

    @Environment(\.dismiss) private var dismiss
    @AppStorage("ResourceUpdateChannel") var resourceChannel = MAAResourceChannel.github
    // P27/U08: 代理会话注入（空 = 系统默认）。
    @AppStorage("MAAResourceUpdateProxyEnabled") var resourceProxyEnabled = false
    @AppStorage("MAAResourceUpdateProxy") var resourceProxy = ""

    private var updateSession: URLSession {
        ResourceUpdateNetwork.session(for: resourceProxyEnabled ? resourceProxy : "")
    }

    private var extractURL: URL {
        switch resourceChannel {
        case .github:
            tmpURL.appendingPathComponent("MaaResource-main", isDirectory: true)
        case .mirrorChyan:
            tmpURL.appendingPathComponent("resource", isDirectory: true)
        }
    }

    private var sourceURL: URL {
        switch resourceChannel {
        case .github:
            extractURL.appendingPathComponent("resource", isDirectory: true)
        case .mirrorChyan:
            extractURL
        }
    }

    var body: some View {
        VStack {
            if !shouldUpdate {
                Text("无需更新资源")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                Button("好") {
                    dismiss()
                }
            } else if let progress {
                if let error {
                    Text("更新失败：\(error.localizedDescription)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                } else {
                    ProgressView(progress.0, value: progress.1)
                }
                Button("取消") {
                    dismiss()
                }
            } else {
                Text("更新完成")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        dismiss()
                    }
            }
        }
        .animation(.smooth, value: progress?.0)
        .padding()
        .task {
            do {
                let session = updateSession
                let url = try await resourceChannel.latestURL(session: session)
                try await downloadResource(from: url, session: session)
                try await extractResource()
                // P27/U06: 隔离 staging → 原子切换 → onUpdate（资源重载/门控）失败即回退。
                let stagingURL = documentsURL.appendingPathComponent("resource.staging", isDirectory: true)
                let backupURL = documentsURL.appendingPathComponent("resource.backup", isDirectory: true)
                try ResourceUpdateNetwork.stageResource(source: sourceURL, staging: stagingURL)
                try await ResourceUpdateNetwork.atomicApply(staging: stagingURL, target: targetURL, backup: backupURL) {
                    try await onUpdate()
                }
                progress = nil
            } catch MAAResourceChannel.Error.noNeedUpdate {
                self.shouldUpdate = false
            } catch {
                self.error = error
            }
            try? FileManager.default.removeItem(at: localURL)
            removeExtracts()
        }
    }

    private func downloadResource(from remoteURL: URL, session: URLSession) async throws {
        try? FileManager.default.removeItem(at: localURL)
        for try await progress in session.downloadTo(localURL, from: remoteURL) {
            try Task.checkCancellation()
            self.progress = (String(localized: "正在下载…"), progress.fractionCompleted)
        }
    }

    private func extractResource() async throws {
        removeExtracts()

        let progress = Progress()
        let title = String(localized: "正在解压…")

        let observation = progress.observe(\.fractionCompleted) { p, _ in
            Task { @MainActor in
                self.progress = (title, p.fractionCompleted)
            }
        }
        defer {
            observation.invalidate()
        }

        let task = Task.detached {
            try FileManager.default.unzipItem(at: localURL, to: tmpURL, progress: progress)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            progress.cancel()
        }
    }

    private func removeExtracts() {
        try? FileManager.default.removeItem(at: extractURL)
        try? FileManager.default.removeItem(at: changesURL)
    }
}

private let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
private let tmpURL = FileManager.default.temporaryDirectory

private let targetURL = documentsURL.appendingPathComponent("resource", isDirectory: true)
private let localURL = tmpURL.appendingPathComponent("MaaResource.zip")
private let changesURL = tmpURL.appendingPathComponent("changes.json", isDirectory: false)

#Preview {
    ResourceUpdateView {}
}
