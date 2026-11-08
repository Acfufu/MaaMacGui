//
//  RecruitView.swift
//  MAA
//
//  Created by hguandl on 18/4/2023.
//

import SwiftUI

struct RecruitView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @State private var lv3ShortTime = false
    /// 最近一次干员识别的持有潜能表（id → 1-6）；无快照或读取失败时为 nil。
    @State private var potentialByID: [String: Int]?

    var body: some View {
        VStack {
            configView()

            Divider()

            Group {
                if let recruit = viewModel.recruit {
                    resultView(recruit: recruit)
                } else {
                    Text("RecruitmentRecognitionTip")
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.top)
        }
        .padding()
        .task(id: viewModel.inventoryScope) { reloadPotential() }
        .onChange(of: viewModel.operBoxHistoryRevision) { _, _ in reloadPotential() }
        .onChange(of: viewModel.recruitConfig.showPotential) { _, enabled in
            // 关闭开关立即清空缓存；重新开启由 revision/scope 变化或重进页面兜底刷新。
            if !enabled { potentialByID = nil } else { reloadPotential() }
        }
    }

    @ViewBuilder private func configView() -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Toggle("自动设置时间", isOn: $viewModel.recruitConfig.set_time)
                Text("自动选择 Tags：")
            }

            VStack(alignment: .leading) {
                Toggle("3星设置7:40而非9:00", isOn: $lv3ShortTime)
                HStack {
                    Toggle("3星", isOn: autoSelect(level: 3))
                    Toggle("4星", isOn: autoSelect(level: 4))
                    Toggle("5星", isOn: autoSelect(level: 5))
                    Toggle("6星", isOn: autoSelect(level: 6))
                }
            }
        }
        .onChange(of: lv3ShortTime) {
            viewModel.recruitConfig.recruitment_time["3"] = $1 ? 460 : 540
        }
    }

    @ViewBuilder private func resultView(recruit: MAARecruit) -> some View {
        Text(recruit.tags.joined(separator: ", "))
        List(recruit.result, id: \.tags.hashValue) { result in
            Section {
                ForEach(result.annotatedOpers(
                    potentialByID: potentialByID,
                    showPotential: viewModel.recruitConfig.showPotential
                )) { annotated in
                    Text(verbatim: annotated.oper.name + (annotated.annotation?.displayText ?? ""))
                }
            } header: {
                Text("\(result.level)★ \(result.tags.joined(separator: " "))")
            }
        }
    }

    /// 持有数据与工具页历史干员快照同源（OperBoxHistoryStore，按账号/区服隔离）：
    /// 损坏或缺失快照按无数据降级为不标注，不阻断公招识别展示。
    private func reloadPotential() {
        guard viewModel.recruitConfig.showPotential else {
            potentialByID = nil
            return
        }
        let snapshot = try? viewModel.operBoxHistoryStore.load(scope: viewModel.inventoryScope)
        potentialByID = snapshot?.operators.ownedOperators.reduce(into: [:]) {
            $0[$1.id] = $1.potential
        }
    }

    // MARK: - State Bingings

    private func autoSelect(level: Int) -> Binding<Bool> {
        Binding {
            viewModel.recruitConfig.select.contains(level)
        } set: { newValue in
            if newValue {
                var levels = Set(viewModel.recruitConfig.select)
                levels.insert(level)
                viewModel.recruitConfig.select = levels.sorted()
            } else {
                viewModel.recruitConfig.select.removeAll { $0 == level }
            }
        }
    }
}

struct RecruitView_Previews: PreviewProvider {
    static var previews: some View {
        RecruitView()
            .environmentObject(MAAViewModel())
            .frame(width: 360, height: 480)
    }
}
