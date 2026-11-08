//
//  LogView.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import SwiftUI

struct LogView: View {
    @Environment(NewViewModel.self) private var newModel
    @EnvironmentObject private var viewModel: MAAViewModel
    // U11: 卡片日志（WPF LogCardViewModels 主视图同位）；表格模式保留为切换面。
    @AppStorage("MAALogCardMode") private var cardMode = true

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if cardMode {
                    cardList
                } else {
                    table
                }
            }
            .toolbar {
                @Bindable var newModel = newModel
                ToolbarItemGroup {
                    Toggle(isOn: $newModel.trackTail) {
                        Label("现在", systemImage: "arrow.down.to.line")
                    }
                    .help("自动滚动到底部")
                    Toggle(isOn: $cardMode) {
                        Label("卡片", systemImage: "rectangle.split.3x1")
                    }
                    .help("切换卡片/表格日志视图")
                }
            }
            .onChange(of: newModel.logs) { _, newValue in
                if newModel.trackTail {
                    withAnimation {
                        proxy.scrollTo(newValue.last?.id ?? UUID())
                    }
                }
            }
            .onChange(of: newModel.trackTail) {
                if $1 {
                    withAnimation {
                        proxy.scrollTo(newModel.logs.last?.id ?? UUID())
                    }
                }
            }
        }
    }

    // MARK: - U11 卡片视图（WPF LogCardViewModels 同构：Divider 卡 + 分段卡 + 卡尾缩略图）

    private var cardList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(cards) { card in
                    if card.isDivider {
                        Divider()
                        if let header = card.header {
                            Text(header)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 2)
                        }
                    } else if !card.items.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(card.items) { log in
                                    logRow(log)
                                }
                                if let thumbnailID = card.thumbnailLogID,
                                    let thumbnail = viewModel.logThumbnails[thumbnailID] {
                                    Image(nsImage: thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: 320)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .accessibilityLabel("任务截图")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                        .id(card.items.last?.id)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func logRow(_ log: MAALog) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(log.date.maaGuiLogFormat)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(log.content)
                .textSelection(.enabled)
                .foregroundStyle(log.color.textColor)
        }
    }

    private var cards: [LogCard] {
        LogCardBuilder.build(logs: newModel.logs, thumbnailIDs: Set(viewModel.logThumbnails.keys))
    }

    // MARK: - 表格视图（既有面保留）

    private var table: some View {
        Table(newModel.logs) {
            TableColumn("时间", value: \.date.maaGuiLogFormat)
                .width(min: 100, ideal: 125, max: 150)
            TableColumn("信息") { log in
                Text(log.content)
                    .textSelection(.enabled)
                    .foregroundStyle(log.color.textColor)
                    .lineLimit(nil)
            }
            .width(min: 100, ideal: 300)
        }
    }
}

struct LogView_Previews: PreviewProvider {
    static var previews: some View {
        LogView()
            .environment(NewViewModel(parent: MAAViewModel()))
            .environmentObject(MAAViewModel())
    }
}
