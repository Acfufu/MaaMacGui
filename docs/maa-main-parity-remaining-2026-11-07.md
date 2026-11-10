# MaaMacGui 追平剩余事项清点 · 2026-11-07

> 定位：时点快照——盘点追平 run（parity/auto-2026-11）在**代码面阶段（W0–W6）全部闭合**后剩余的事项。活账本在 `.omo/evidence/auto-2026-11/_session/closing-checklist.md`（git 局部排除、不入库），本文为入库收口视图；执行细节以各增量 RESULT 与 replan 主文档为准。

## 0. 状态基线（2026-11-07 会话终核验）

- 代码面 W0–W6 全闭合：P05–P29 全包；全量盘点 **64 PASS / 0 FAIL / 3 SKIP(arch) exit=0**。
- patch 链终态 `3aeaa9aa`（每增量 before bit 级命中）；暂存区不变量 `4cc2445e` / 树 `2c80bc93`（wt/p09-1，2026-11-07 复核复现）。
- xcstrings 1458 键；pbxproj F138；replan 线 21+ 条 divergence 台账在案。
- **全部 replan 产出未提交**，在 worktree `wt/p09-1`（task/p09-1，HEAD=80f06e6，160 个变更文件）；集成分支 `parity/auto-2026-11`（wt/integration，HEAD=80f06e6）尚未吸收任何 replan 线产出；master `27c6ef8` 未动。
- 恢复会话先跑 closing-checklist §0 实况核验 + 三不变量（暂存区/树/全树）。

## 1. W7 验收面四包（真机/专用环境，代码无法再推进）

| 包 | 内容 | 出口条件 |
| --- | --- | --- |
| **P30** | 111 成就项证据逐项闭合 | 全部成就真实证据链 |
| **P31** | 受限主题结局后端 | 真机实走 |
| **P32** | 全部既有能力回归 | 全能力真实回归通过 |
| **P33** | 实际发行包 | 正式安装/升级通过（含 P28 U01 端到端） |
| — | 开放阻塞清零 | MX 未完成项独立列出 |

## 2. 真机/专用环境验收债（NOT_RUN 单列，按域归组）

| 域 | 事项 | 来源包 |
| --- | --- | --- |
| Core/资源 | **R02 新 Core pin + 真机端到端**（真实编队回归 D04、资源回退、bundle 快照） | P02/P14 等 |
| 作业与工具 | 真实作业端到端：资料辅助预匹配、评分服务、视频转译、小游戏运行、窥屏速率实测 | P13/P14/P15/P17/P18 |
| 作业与工具 | 隔离 GUI 实点（下载/编辑器/卡片日志渲染/长会话内存） | P13/P14/P29 等 |
| 账号与库存 | 真实一图流服务（用户 Token）/ UtilityDetail 完整界面；库存保持真实端到端 | P11/P12 |
| 系统集成 | 关窗/登录项/热键/Sparkle 重启链原生 GUI 实点 + 正式签名 | P20 |
| 系统集成 | 真实交接/睡眠唤醒/正式签名 agent | P21 |
| 系统集成 | 真实系统动作（锁屏/睡眠/关机/退模拟器） | P22 |
| 系统集成 | 通知真实投递/点击/撤销 | P23 |
| 外部服务 | 九渠道真实投递（凭据）与触发过滤长跑 | P24/P25 |
| 外部服务 | 真实远控服务端到端（默认不连任何第三方） | P26 |
| 更新链 | 真实下载/代理连通性；U01 端到端（旧包升级/回滚/EdDSA 签名） | P27/P28 |
| 真机通用 | AdbLite 关闭 + RawByNc 配方（本机排障 memory）下的实测面 | — |

## 3. 交付链（产出落库 → 集成 → 评审）

1. **提交**：wt/p09-1 全部产出按增量拆分提交（暂存区不变量 `4cc2445e` 依赖存活，宜先落地）。
2. **合并**：逐增量 rebase → squash → `parity/auto-2026-11`（wt/integration）；每合并一包跑全量盘点回归。
3. **独立评审债**：replan 线 P09–P29 各增量均未走独立评审；>300 行增量强制 R3 规则待补执行。
4. **纪律**：temp-index 全程导出 `GIT_INDEX_FILE`、操作后复核 staged sha（P12.4 暂存区事故先例）；共享面纪律（MAAViewModel/Core wrapper/档案 schema/运行结果统一负责人）。

## 4. 收口五件套

1. 总报告 `auto-run-report-2026-11-01.md`（含健壮性 backlog ①–⑤，见 §5）。
2. 四份 CSV plan_status/runtime 回写——**8bfd 原件已随 worktree 清理丢失**（G 区事件台账），回写面向本目录 `maa-main-parity-*-2026-11-05.csv` 副本（195 功能 / 43 工作包 / 111 成就 / 165 参数；features/P12 包行等已按增量更新）。
3. 结构校验重跑 → 更新 `.omo/evidence/maa-main-parity-plan-2026-11-01/plan-validation.json`（覆盖/重复/依赖环/模块路径/索引一致）。
4. 证据树索引：`.omo/evidence/auto-2026-11/` 全任务目录可追溯。
5. 未跟踪清单盘点。

## 5. 健壮性 backlog

**基建 5 条（收口总报告议题）**
1. ci.yml `SKIP="` 字面量硬依赖无诊断；
2. emit `tr` 不覆盖 `\r`/ESC、C locale `cut` 劈多字节；
3. arch_skip grep 建议加 `^SKIP` 前缀；
4. P00.2 未按名排除 run-ci-inventory-check.sh（嵌套 ~40s）;
5. P01.1 旧资源下超限存量值无启动拦截。

**实现面（快照 4 起增补）**
6. BlackflowStartSupport 指纹已对齐 51dac87（P02.2-F，bundle 快照构建期注入）；
7. ~~stem 谓词三处拷贝待收敛~~ **已关账（S6.1=5d9b178，2026-11-09）**——URL.copilotFileStem 单点（MAACopilot.swift，三 copilot 套件 verbatim 面均含免 strip 同步）；收敛 CopilotConfiguration:476/VideoRecognitionImport:54/CopilotContent:26 三处；CopilotFileOperations:55（整名搬运）/MAACopilot:96（目录名）不可收敛如实留档；数字谓词第二份拷贝（私有 digits）移动会破单文件编译布局，注记留档（S6-1-R3 低-1 已补）；
8. ~~switchProfile 拒绝文案与收口窗口状态不符~~ **已关账（S6.1=5d9b178）**——isStartStopInFlight 分支改「当前正在启动或停止任务，请稍后重试。」（既有键），其余保持原文案；两串均既有键零目录改动；R3 生命周期六点核证；
9. ~~启动期 unsupportedIndexVersion 静默吞~~ **已关账（S5.2=1e7995d，2026-11-09）**——loadIndex 两 throw 点源头 logger.error，VM try? 语义零变更；S5.1 VM 侧方案被 R3 证伪后改源头，复验 PASS；
10. ~~eligibleIDs 注释口径~~ **已关账（S5.1=3058632+S5.2 对齐）**——不追踪 Core 追加结果、追加失败仍计入，收紧为后续；
19. ~~weeklyDays 值域~~ **已关账（S5.2=1e7995d）**——值域订正 **0...6**（HGCalendar 0 基+双 UI Array(0...6)+WPF DayOfWeek Sunday=0），偏离评审 1...7 处方获采纳；S5.1 的 1...7 被定性活性回归并一并修复；双类型登记（Fight+Infrast）+fight 五态/infrast 三态断言。

**已入档候选**：#150 关窗行为未采纳候选；Hibernate 无 macOS 等价 + IfNoOtherMaa；P12-[g] apCost 缺数据源暂无消费面。

## 6. divergence 待裁定

- ~~P08 divergence[12]：班次缺省集（R3 审中提出）~~ **（2026-11-08 P08-3-R3 评审澄清：该项实为 P08.1 R3-5 的「设施缺省集」，用户裁定已落地、交付树解码缺省已全 9 类——非待裁定项，从待裁清单摘除；原文保留备考）**；
- P12-[g]：理智药耗尽证明无 apCost 数据源；
- **增补（2026-11-09，S7 裁定落账）**：P17-[b]（PixelPaint 常驻化）=**裁定保留**（有意分化——常驻化保证入口可达，OTA 驱动面不完整）；P21-[a]=**裁定维持现状**（P21.2 已同序，收紧归 §5-⑩ 注记）；P13-[h]=更正已立（run.json 时点工件不回改）；**余 S8 实施**：P17-[d]（四预设+客户端五语映射+Other 门控+Distinct）、P17-[e]（MinimumRequired 版本 Tip）、P12-[w]（计划重排入口）。
- 其余 21+ 条差异台账（含 WPF fire-and-forget vs Mac 同步等待、SMTP 自写 vs MailKit 等）见 [replan 主文档](maa-main-parity-replan-2026-11-05.md) divergence 节。

## 7. 上游线（独立轨道）

- 21 个在途 PR 按序合并（#182 优先）+ 发版链路 + 主仓库 Discussions 渠道核实 → `docs/upstream-contribution/`（a55b51b）。

## 8. 建议次序

代码面已收口，最大悬空风险是 wt/p09-1 未提交产出。宜先走 **§3 交付链**（提交/合并/评审），再安排真机验收窗口（§2 → §1 W7），收口五件套（§4）随合并节奏并行消化。

## 9. 增补（2026-11-08）：§3 交付链提交/合并两步落地

- **§0 三不变量实测复现**：暂存区补丁 `4cc2445e` / 暂存区树 `2c80bc93` / 全树补丁 `3aeaa9aa` 全中（口径：SHA-256 补丁文本 + index 内容寻址树）。
- **§3.1 提交完成**：以 execution-*/ 累计全树补丁逐状态重建 35 个树（P09.1=原暂存区树），`commit-tree` 重放为线性分支 **`task/p09-1-delivery`**（80f06e6 起 35 提交：P09.1→W0→P08.3→P09.2→P10→P11.1-6→P16.1-2→P12.1-5→P13.1-2→P14.1→P15.1→P17.1→P18.1→P20.1→P23.1→P22.1→P21.1→P24.1→P25.1→P26.1→P27.1→P28.1→P29.1→P29.2）。终树 `a32263f7` 与 wt/p09-1 工作树 bit 级一致；链上 28 个有文字记录的收口态哈希全部命中；P10–P16.2 九个补丁文件为 GNU diff 混合格式（未跟踪文件段无 `diff --git` 头），逐态文件集合比对全一致。**暂存区不变量已落地（P09.1=087f39bf），wt/p09-1 本体零改动。**
- **§3.2 合并完成**：`parity/auto-2026-11` ff `80f06e6 → 0f633454`（wt/integration 干净，树 `a32263f7`；未 push 未建 PR；回滚点 80f06e6）。
- **合并后回归**：`run-ci-inventory-check.sh` all-passed；`run-p00-baseline-inventory.sh` **60P/0F/3SKIP(arch)/4NOT_RUN(dd) exit=0**（4 个 dd 手动套件的既有通过证据因树 bit 级一致继续覆盖）。
- 证据：`docs/replan-evidence-2026-11-05/delivery-2026-11-08/`（DELIVERY.md 全程口径）。
- 剩余：§3.3 独立评审债（24 增量，>300 行优先）、§4 收口五件套；§1/§2 真机与实机面按既定范围单列。

## 10. 增补（2026-11-08 会话 II）：§3.3 评审债推进至 25/35

- **实况核验**：集成线 `parity/auto-2026-11` = `33d15ec`（树 `b4308a9`，35 交付+16 修复提交，xcstrings 1460 键，wt/integration 干净未 push）；master `27c6ef8` 未动；wt/p09-1 三不变量可复测。
- **W0 审结（记录核验口径）**：patch==提交 sha256 bit 级；交付树复放 `88c89da5` REGEN-EXACT 命中；RESULT 结果表 9 行逐项对账原始工件全命中；代码面判例由 P09-1-R3 对 `5d372a4` 交付树的独立构建/盘点复现覆盖（`review-debt/W0-R3.md`）。
- **台账计数订正**：先前「审结 23/35」少计 P14.1（快照 55 已闭环并入）——35 增量 × verdict 文件逐一对账实数 24/35，W0 闭合后 **25/35**；DELIVERY §4 进度行已订正补录。
- **在飞**：P11.1（上会话中断重派）+ P15.1（双席，并发 ≤2）。**余 10**：未派 P08.3/P09.2/P11.4/P11.6/P12.2/P12.5/P16.2/P18.1（P16.2 经 P16-1-R3 scope 核对确认未覆盖，须独立评审）。
- 排除面不变：W7（P30–P33）与 §2 实机债按目标指令单列；§4 收口五件套已闭合；§5 backlog 实现面与 §6 行为面裁定批排在评审债销账之后。

## 11. 增补（2026-11-09 会话 II 终核验）：§3.3 评审债推进至 29/35

- **新增审结 4+1 单**：W0（记录核验 PASS，`review-debt/W0-R3.md`）、P11.1（首轮 PASS，P11-[j]/[k] 注册）、P08.3（首轮 PASS，P08-[a]-[c] 注册；**§6 divergence[12] 澄清摘除**——实为 P08.1 设施缺省集且裁定已落地）、P09.2（首轮 PASS，P09-[f] 注册；名字归一与 WPF BuildNameIndex 逐键同构=P09-[c] 交付态闭合）、**P15.1 修复链闭环**（FAIL 触发面死代码→P15.2 `23b9095`→复验 FAIL 门③取腿姿势→二轮 `bbee17a`（loadObject，json 拖入腿同根因一并恢复）→二轮复验 PASS）。
- **集成线 = `bbee17a`（树 `9494133d`，35 交付+17 修复提交，xcstrings 1461，未 push）**；合并树套件/盘点 60P/CI 全绿；wt/p15-2 已移除（分支保留）。
- **余 6**：P11.4/P12.5 在飞+未派 P11.6/P12.2/P16.2/P18.1；全批审结后评审债销账→§5 backlog/§6 行为面裁定批。

## 12. 增补（2026-11-09 会话 II 终态）：§3.3 评审债 35/35 全批审结销账

- **续推审结 6 单**：P16.2（本体首轮 PASS——P16-1-R3 明注未覆盖的缺口闭合，P16-[g]/[h] 注册）、P11.6（首轮 PASS，写读点穷举+真实端点 60002 探针，零新注册）、**P11.4 修复链闭环**（FAIL 安慰剂开关→P11.7 开关移工具页与门控同源+5 重变异锚点）、**P12.5 修复链闭环**（FAIL FormatNumber 同构声称→P12.7 纯注释勘误+[q][r][s] 注册）、**P12.2 修复链闭环**（FAIL onDelete macOS 无触发 UI+isStageManually 零写点→P12.8 行内删除按钮+手输 Toggle+绑定链锚点+[t]-[w] 注册）、**P18.1 修复链闭环**（FAIL zh-Hans 键名回显→P18.2 三键真实中文+Automatic 三语同步，构建产物 plutil 三语探针复验）。过程事故：P18.1 首次派发丢失（无 agent 痕迹）→ 全新重派成功（快照 78）。
- **集成线终态：`parity/auto-2026-11` = `80741ff`（树 `b6e170ea`，35 交付+21 修复提交，xcstrings 1461 键，wt/integration 干净未 push）**；master `27c6ef8` 未动；wt/p09-1 三不变量复测命中；全部修复增量并入且合并树套件全绿。
- **§3.3 独立评审债销账：审结 35/35**（18 修复闭环全 PASS+12 首轮 PASS+W0 记录核验）；本会话净增 12 单。
- **§4 收口五件套**已闭合（此前面）；**待办债合并清单终版**见 closing-checklist 快照 80：文案清扫批（P12-[n] 21 处+P10-[a]+[q] 行号 nit）/行为面裁定批（P17-[a]-[f]、P13-[f]-[h]、P21-[a]、P16-[h]、P12-[w]/[u]）/小批（⑦stem 收敛、⑨装载日志、⑩注释口径、19 weeklyDays 值域）/测试债（P29.3 两项、P14.2 B3、P11.5 直测、harness 死支）/文档卫生（P12.5 两条、DataExport 注释、R10 编号收编）/基建 5 条。
- **排除面**：W7（P30-P33）、§2 实机债、R02 真机回归、T18 真机实测——按目标指令单列不推进；§7 上游线（21 在途 PR）需 push/建 PR 授权。**下一阶段=§5 robustness backlog 实现面+§6 行为面裁定批。**

## 13. 增补（2026-11-09 会话 III 实测核验）：S5–S7+TEST/DOC 债批全落——纯代码面仅余 S8 三项+基建五条

- **集成线现态**：`parity/auto-2026-11` = `1447870`（树 `28b51191`；`80f06e6` 起 66 提交 = 35 交付 + 31 修复/批提交；xcstrings 1487 键实测；wt/integration 干净未 push）；master `27c6ef8` 未动；wt/p09-1 三不变量在案。
- **S5 批闭环**：S5.1 `3058632`（⑨装载日志+⑩注释口径+⑲weeklyDays+P10-[a]）→ R3 FAIL（高-1 `.public` 隐私+中-1 可达面失实+中-2 值域处方误）→ S5.2 `1e7995d`（高-1 回缺省隐私；⑨改 loadIndex 源头日志；⑲订正 **0...6** 三方实证获采纳，评审自认 1...7 为活性回归）→ 复验 PASS（byte-identical+write-tree 位级）并入。⑨⑩⑲+P10-[a] 关账。
- **S6 批闭环**：S6.1 `5d9b178`（⑦ stem 三处收敛+⑧ switchProfile 文案+P12-[n] 21 处清扫+P12-[q] 勘正）→ R3 FAIL（中-1 depot 变体「按最新库存重算缺口」键漏插——清扫实为 20/21）→ S6.2 `11f4655` 补 depot 变体键（swiftc+构建产物 plutil 双探针）→ `S6-1-R3-verify` **PASS**（2 记录级 nit）并入。文案清扫批关账（21/21）。
- **S7.1 审结 PASS 并入**（`981daf1`，`S7-1-R3`）：§6 行为面裁定批——落码六项（P13-[f] 技能面 1...3→**0...3** 缺省 0、P13-[g] PRTS 前缀 OrdinalIgnoreCase 12 例矩阵、P12-[u] 材料排除集+5、P17-[a] T03 clear_store 缺省 true、P16-[h] OperBoxJSONRow 三 Optional、P17-[c] PixelPaint 空图拒启）+ 裁定六项（P17-[b] 常驻化=有意分化、P21-[a] 不收窄维持、P13-[h] 已更正、P17-[f] T11 勘误收口等）。**裁定 P17-[e]/P17-[d]/P12-[w] 三项归 S8 实施**。
- **DOC-1 审结 PASS 并入**（`2370136`，`DOC-1-R3`）：文档卫生批（P12.5 RESULT 两条失实勘误、DataExport.swift:12 头注、R10-[a]/[b]/[c] 收编 P11 编号）关账。
- **TEST-1 审结 PASS 并入**（`dbb1b42`+`1447870` 低-1 勘误，`TEST-1-R3`）：测试债批（P29.3 clearLogs :143+nit-2、P14.2 B3 收编、P11.5 catch 直测、dispatch harness 死支、CSV I10 指针）关账。
- **纯代码债余量**：S8 实施批三项（P17-[e] OTA 条目 MinimumRequired Tip、P17-[d] T12 四类预设关键词、P12-[w] 计划列表重排 UI）+ §5 基建 5 条（ci SKIP 字面量/emit tr/arch_skip 前缀/P00.2 排除/P01.1 拦截）+ JBird Package.resolved 显式提交；余为总报告 §6 终态与台账五处终更。
- **排除面不变**：W7（P30–P33）、§2 实机债、R02 真机回归、T18 真机实测单列；集成线未 push 未建 PR，§7 上游线（21 在途 PR）待授权。

## 14. 增补（2026-11-11）：S8/infra 四批闭环——目标范围（除真机/实机/上游）全清

- **集成线终态**：`parity/auto-2026-11` = `e764851`（树 `2224fc1e`；`80f06e6` 起 68 提交 = 35 交付 + 33 修复；xcstrings 1488 键实测；wt/integration 干净未 push）；master `27c6ef8` 未动；wt/p09-1 不变量（index 树 `a32263f7`）2026-11-11 复测命中。
- **四批链条**：doc-1（2370136 文档卫生）+test-1（dbb1b42+1447870 测试债）R3 PASS 并入；S8.1（8444f70）R3 FAIL（中-1 尾 Distinct+中-2 parseVersion）→S8.2（1a4b881）复验 PASS 并入——**S8 三项（P17-[d]/[e]/P12-[w]）关账，披露文本按复审通过条件落账**（DELIVERY §4 四批 bullet）；infra-1（0ded704 ⑥基建四条+⑦）+infra-2（48fa5d3 P01.1 ⑥末条）R3 FAIL（F1/F2 中危，INFRA-1-R3.md）→infra-3（e764851）重做→R3 复审 PASS（review-debt/INFRA-3-R3.md，F1–F4 全核销+R-1..R-4 记录级）并入——**⑥基建五条+⑦ 关账**。
- **夹具几何勘正（对 11-09 交接文档）**：straddle 夹具 6B 前缀（'PASS: '+龙×41）字节 120 恰落龙 38 尾字节、劈不开字不可作负对照；真 straddle 须 7B 前缀（'PASS: X'+龙×41+‘a’）。负对照实测：旧管道 en_US.UTF-8 与 C.UTF-8 **双 locale** 均 tr Illegal byte sequence abort（C.UTF-8 亦为多字节 locale）；新 trunc 三 locale 码点无损、cap 114 龙码点 vs 旧 120B/38 龙字节。修复方沙盒 20 检查 0 失败（复审勘误 RESULT 计数 18→20 已追加）。
- **合并树回归全绿**：盘点 59P/0F/3SKIP(arch)/1SKIP(nested)/4NOT_RUN(dd) exit=0（code_sha=e764851）+ci-check all passed+fight-config exit=0；wt/s8-1、wt/infra-1 已移除（分支 task/s8-1、task/infra-1 保留）。
- **§13 纯代码债余量清账**：S8 三项✓、§5 基建 5 条✓、⑦ stem✓（S6.1）、JBird Package.resolved=ci.yml 注记规则固化（infra-1 ⑦；实体文件留待涉依赖锁定提交显式 git add -f——非本轮可执行项）；总报告 §6 终态（item 5）与台账五处终更✓（含 CSV I05 排序腿/T12 已接勘正，BOM+CRLF 保持）。
- **排除面（不变）**：W7（P30–P33）+§2 实机债+R02 新 Core pin+T18 真机实测+§7 上游 21 条在飞 PR（push/建 PR 需授权）。**目标范围内追平清单清零。**

## 15. 增补（2026-11-11 会话 II）：§7 上游线本地推进——吸收 upstream/master 4 提交入集成线

- **上游态势**：master 冻结 39 天后首次前进 `27c6ef8→100c6d8`（hguandl 回归：11-03 b2c99a8 依赖更新含 JBird 换源、11-09 5745fcf+8ad65e5 Dawn.xcframework、11-10 100c6d8 WebGPU 后端）；21 个在途 PR 仍全 OPEN、#182 零回应。冲突面实测：集成线 4 文件 7 hunks；21 PR 中 **12 CLEAN、9 仅 pbxproj 单文件**（#168/#170/#173–#181，全为加新文件 PR）；prw/* 分支已清理，PR head 存 upstream refs/pull（本地 uppr/* 引用）。
- **吸收合并**：`parity/auto-2026-11` = **0f1c160**（merge commit e764851+100c6d8，树 `96d78b64`，68 提交哈希保留）。四文件解法均为「双侧保留+上游行按原邻位插入」（pbxproj SwitchTheme×4/Dawn 自动落位；VM @AppStorage 单行；Settings WebGPU Toggle；xcstrings 2 空键按上游邻位插入，parity 键与翻译零改动）。
- **断言与回归全绿**：无标记残留/plutil OK/xcstrings 1490 键/Dawn 4 挂载点+F1xx 家族计数全中/JBird vsanthanam>=3.0.0/initialize 序完整（闸门→WebGPU 条件下发→loadResource）/swiftc -parse ×3/pbxproj 184 PBXBuildFile 零悬挂零重复；盘点 no-dd **59P/0F/3SKIP/1SKIP/4NOT_RUN(dd) exit=0** 与 e764851 基线逐项一致 + ci-check all passed。dd 面重建需 Dawn.xcframework（新 Core 产物，R02 排除面）。
- **下游事实**：构建新增 Dawn.xcframework 前置（fork CI maacore-setup 显式 5 目标清单需扩第 6 产物，未动）；JBird 大版本换源兼容性由本地 Swift 套件全绿佐证；WebGPU 开关缺省 false、旧 Core 不认 static option key 2（潜伏面随 R02 解除）。
- **§7 剩余**：9 PR 单文件 rebase（等 #182 维护者认可顺序）+ push/建 PR/评论需授权；§1/§2/R02/T18 实机面单列不变；master `27c6ef8` 未动。

## 16. 增补（2026-11-11 会话 III）：全量推进——上游解冻吸收 + 作战日报移植 + 上游面 rebase 全部落地

- **集成线终态**：`parity/auto-2026-11` = **473ad4e**（树 `1de4a39e`；0f1c160 + 作战日报 008f727/51d3e40/3b1f454/2e8f557 + CI e7073e3 + merge 473ad4e；**已推 origin**，fork 首次推集成线）；主检出 master ff→100c6d8。
- **T0 Core pin v6.22.0（901e01c60）**：MaaDeps v2.15.1 两坑（CoreML 头/库失配、ORT 双版本歧义）实锤并进 fork maacore-setup 双防护；$HOME/build 六产物（Dawn 在位）；MAACORE_PIN 前进；makefile 显式 6 目标须带 `build/` 前缀、install dylib 保留 tarball mtime 致陈旧产物 "up to date" 假绿（先 rm 再重建）。
- **T1 上游面**：实测 11 PR 冲突（#168/#170/#173–#181，全 pbxproj-only）；备份 refs/backup/pr-168..181；「master 版+PR 增量 3-way 重放+插入对插入双侧保留」批量 rebase+force-push 后 **21/21 CLEAN/MERGEABLE**。
- **T2 作战日报**（v6.22.0 桌面端新功能，Mac 无实现实锤后全量移植）：Collector/Store/ViewModel/View/Math 六文件 + HGCalendar 游戏日三原语 + MaaMessage 五钩子 + 工具栏入口 + 独立 Window + xcstrings +51 键（Tip 用 %n$ 位置参数）；测试 `run-daily-report-tests.sh` 51 checks PASS；库存回调探针同步采集链（18 断言）。
- **T0-5 指纹**：core=99c06282…、resource=3d3d6ed8…（v6.22.0 本机构建+206 资源文件），Swift 同函数逐位复核；compatibleOTATaskFingerprint 维持 10-29 OTA 钉值待重审。
- **小件**：#19140 培养清空确认（新增按钮+二次确认）、#19098 两日志钩子、WebGPU 两空键补译；卫戍协议三期=资源驱动 WPF 牛杂工具箱面（Mac 无该通用面，台账）；P12-[g] 维持（v6.22.0 无规划面 apCost，日报理智走运行时回调不依赖）。
- **回归全绿**：盘点 60P/0F（含新日报套件）、dd 四套件（Mall 1194/exit-log 16/settlement 17/blackflow 8）、ci-check、合并树复跑同绿；Debug 产物冒烟启动 20s+/退出干净/无崩溃报告。
- **剩余单列**：§1 W7（P30–P33）、§2 实机债、R02 真机（Core pin 就位待跑）、T18、#182 追评/@、single.2 发版、fork CI 全链路实跑（action 改动待 tag/workflow_dispatch 验证）。
