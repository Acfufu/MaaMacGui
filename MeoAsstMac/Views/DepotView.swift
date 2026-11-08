//
//  DepotView.swift
//  MAA
//
//  Created by hguandl on 18/4/2023.
//

import JBird
import SwiftUI
import UniformTypeIdentifiers

struct DepotView: View {
    @Environment(NewViewModel.self) private var viewModel

    @JSONRepresentable fileprivate struct Item: Identifiable {
        let id: String
        let have: Int
        let name: String
    }

    @State private var nameTaskToken: UUID?
    @State private var items = [Item]()
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            List(items) { item in
                Text("\(item.name)：\(item.have)")
            }
            .task(id: viewModel.depot?.items) {
                guard let items = viewModel.depot?.items else {
                    self.items = []
                    nameTaskToken = nil
                    return
                }
                let token = UUID()
                nameTaskToken = token
                let names = await MAAProvider.shared.itemNames(for: items.keys)
                guard !Task.isCancelled else {
                    if nameTaskToken == token {
                        nameTaskToken = nil
                    }
                    return
                }
                self.items = items.sorted {
                    $0.key < $1.key
                }.map { (key, value) in
                    Item(key: key, value: value, name: names[key])
                }
                nameTaskToken = nil
            }

            HStack(spacing: 20) {
                Text("复制结果JSON至剪贴板：")

                Button("企鹅物流") {
                    guard copyToPasteboard(text: arkplannerPayload) else { return }
                    NSWorkspace.shared.open(URL(string: "https://penguin-stats.cn/planner")!)
                }
                .disabled(nameTaskToken != nil)
                Button("明日方舟工具箱") {
                    guard copyToPasteboard(text: arkntoolsPayload) else { return }
                    NSWorkspace.shared.open(URL(string: "https://arkntools.app/#/material")!)
                }
            }
            .disabled(viewModel.depot?.done != true)

            // T07 仓库 Markdown/CSV 导出（WPF ExportToMarkdown/ExportToCsv 同构：
            // 空集不产生文件；CSV 按 RFC 4180 转义；无 BOM UTF-8）。
            HStack(spacing: 20) {
                Text("导出仓库文件：")
                Button("导出 Markdown") { exportDepot(markdown: true) }
                Button("导出 CSV") { exportDepot(markdown: false) }
            }
            .disabled(items.isEmpty)
            if let exportMessage {
                Text(exportMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.default, value: items)
        .padding()
    }

    private func copyToPasteboard(text: String?) -> Bool {
        guard let text else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func exportDepot(markdown: Bool) {
        let rows = items.sorted { $0.id < $1.id }.map { (id: $0.id, name: $0.name, count: $0.have) }
        let lines = markdown ? DataExport.depotMarkdownLines(rows: rows) : DataExport.depotCsvLines(rows: rows)
        guard let content = DataExport.joinedLines(lines) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [markdown ? UTType.plainText : UTType.commaSeparatedText]
        panel.nameFieldStringValue = markdown ? "Arknights_Depot_Export.md" : "Arknights_Depot_Export.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DataExport.write(content, to: url, withBOM: false)
            exportMessage = String(localized: "已导出：\(url.path)")
        } catch {
            exportMessage = String(localized: "导出失败：\(error.localizedDescription)")
        }
    }

    private var arkntoolsPayload: String? {
        guard let items = viewModel.depot?.items else { return nil }
        return try? JSON(items).stringify()
    }

    private var arkplannerPayload: String? {
        let json = JSON {
            "@type" => "@penguin-statistics/depot"
            "items" => {
                for item in items {
                    item
                }
            }
        }
        return try? json.stringify()
    }
}

extension DepotView.Item: Hashable {
    init(key: String, value: Int, name: String?) {
        id = key
        have = value
        if let name, !name.isEmpty {
            self.name = name
        } else {
            self.name = key
        }
    }
}

struct DepotView_Previews: PreviewProvider {
    static var previews: some View {
        DepotView()
            .environment(NewViewModel(parent: MAAViewModel()))
    }
}
