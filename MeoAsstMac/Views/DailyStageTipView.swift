//
//  DailyStageTipView.swift
//  MAA
//
//  Created by zhangweijian on 5/9/2026.
//

import SwiftUI

/// 内嵌于刷理智设置页底部的今日开放关卡展示。
/// P05.2：接 OTA 活动数据（修 F03 的 activities:nil），与关卡目录共用
/// 同一开放谓词（StageCatalog）；每分钟刷新以跨越 04:00 游戏日边界。
struct DailyStageTipView: View {
    let channel: MAAClientChannel
    var activities: MAAStageActivity?

    @Environment(\.defaultMinListRowHeight) private var rowHeight

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            LabeledContent {
                ScrollView {
                    content(at: timeline.date)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 2 * rowHeight)
                .alignmentGuide(.firstTextBaseline) { d in
                    d[.top]
                }
            } label: {
                VStack(alignment: .trailing) {
                    Text("今日关卡小提示")
                        .font(.headline)
                    Text("游戏内历法：\(channel.calendar.weekdaySymbol(for: timeline.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .alignmentGuide(.firstTextBaseline) { d in
                    d[.top]
                }
            }
        }
    }

    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isResourceCollectionAllOpen(at: date) {
                Text("资源关卡全开放中")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
            ForEach(tipRows(at: date), id: \.code) { row in
                Text("\(row.code)：\(row.drop)")
                    .font(.callout)
            }
            if activities == nil {
                Text("活动数据未加载，仅显示常驻资源关卡")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 数据面（与关卡选择同一 StageCatalog 谓词；测试直接断言）

    func tipRows(at date: Date) -> [(code: String, drop: String)] {
        catalog.tips(at: date).map { (code: $0.code, drop: StageDropLabel.text($0.drop)) }
    }

    func isResourceCollectionAllOpen(at date: Date) -> Bool {
        catalog.isResourceCollectionAllOpen(at: date)
    }

    private var catalog: StageCatalog {
        StageCatalog(context: StageActivityContext(channel: channel, activities: activities))
    }
}

struct DailyStageTipView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            DailyStageTipView(channel: .Official, activities: nil)
        }
    }
}
