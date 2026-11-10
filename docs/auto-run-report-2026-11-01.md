# 自动追平运行总报告(auto-run 2026-11-01)· 2026-11-11 终稿

> 覆盖:MaaMacGui 对 MaaHelper(WPF) 的追平运行——规划线(maa-main-parity-plan)、auto 线(auto-2026-11,P00–P08+A+B 评审合并)、replan 线(replan-2026-11-05,W0–W6 执行线)三条线的总收口视图。本终稿取代 2026-11-08 收口版:终态推进至 `parity/auto-2026-11 = 473ad4e`(上游吸收+作战日报+CI+推 origin),评审债与全部代码面债批销账;11-08 版的评审债执行全录原样保留于附录 A。真机/专用环境验收面(W7 与 §2 实机债)按既定范围单列,不在本报告闭合范围内。

## 1. 终态总览(2026-11-11 实测)

| 项 | 终态 |
| --- | --- |
| 集成线 | `parity/auto-2026-11` = **`473ad4e`**(树 `1de4a39e`),**已推 origin**(fork 首次推集成线);领先 upstream/master 313 提交(含 21 PR 组合全史) |
| 集成线构成 | replan 线 35 交付 + 33 修复/债批提交 + 作战日报 4 提交(008f727/51d3e40/3b1f454/2e8f557)+ fork CI e7073e3 + 上游吸收 merge 0f1c160 + 日报并入 merge 473ad4e |
| master 线 | `27c6ef8` → ff `100c6d8`(upstream)→ 文档收口批 `c6f4b88`(remaining doc + review-debt R3 三件),**已推 origin**(27c6ef8..c6f4b88) |
| 回归 | 合并树盘点 **60P/0F/3SKIP(arch)/1SKIP(nested)/4NOT_RUN(dd)** exit=0 + dd 四套件(Mall 1194/exit-log 16/settlement 17/blackflow 8)+ 日报 51 checks + ci-check all passed;Debug 产物冒烟启动 20s+/退出干净/无崩溃报告 |
| 键数 | xcstrings **1544 键**(2026-11-11 实测 parity 树;账本前值 1490 = 0f1c160 时点,日报批 +51 与小件后终态数首次落账即本行) |
| Core pin | **MAACORE_PIN = `901e01c6`**(主仓库 v6.22.0 tag,RelWithDebInfo arm64 本机产物;指纹 core `99c06282…`/resource `3d3d6ed8…` 逐位复核) |
| 上游面 | upstream/master `100c6d8`(WebGPU/Dawn/JBird 换源)已吸收;21 个在途 PR 全部 rebase + force-push,**21/21 CLEAN/MERGEABLE** |
| 评审债 | **35/35 全批审结销账**(18 修复链闭环全 PASS + 12 首轮 PASS + W0 记录核验;官方计数口径见 remaining doc §12) |
| 代码面债批 | S5/S6/S7/S8 + DOC-1 + TEST-1 + 基建五条全部关账;**目标范围(除真机/实机/上游)追平清单清零** |

## 2. 三线结构与执行历程

| 线 | 范围 | 终态 |
| --- | --- | --- |
| 规划线 | plan 文档 + 4 CSV(195 功能/43 包/111 成就/165 参数) | CSV 副本幸存(docs/,原为本地单副本);plan 文档本体随 8bfd/a007 清理丢失,结构校验按 CSV 重建 10 项全 PASS |
| auto 线 | P00–P08.2 + X05/X06/X07/P34,A+B(±R3) 评审合并 | 24 包闭合,全部独立评审通过 |
| replan 线 | W0–W6(P08.3–P29.2)35 增量 | 代码面全闭合 + **独立评审债 35/35 销账** + 评审后债批(S5–S8/DOC/TEST/infra)全关账 |
| 上游吸收(11-11) | upstream 解冻 4 提交 + v6.22.0 日报移植 + fork CI | 并入集成线,21 PR rebase 完毕 |

阶段历程:W0 交付链重建(11-08)→ W1–W6 逐包交付与 R3 评审(11-08/09,35/35 销账)→ 评审后债批四批(11-09/11,快照 85)→ 上游解冻吸收与全量推进(11-11,快照 86 + remaining doc §15/§16)。

## 3. 交付与集成链

1. **三不变量实测复现**(暂存区补丁 `4cc2445e`/树 `2c80bc93`/全树补丁 `3aeaa9aa`;2026-11-11 终测命中后 wt/p09-1 以 fossil 分支存证并清理,见 §8)。
2. **交付重放**:以 execution-*/ 累计全树补丁逐状态重建 35 树 → `commit-tree` 重放为 `task/p09-1-delivery`(链上 28 个有文字记录的收口态哈希全命中;终树 `a32263f7` 与 wt/p09-1 工作树 bit 级一致)。
3. **合并序列**:`parity/auto-2026-11` ff `80f06e6 → 0f633454` → 评审修复链/债批逐单 ff(终 `e764851`)→ 上游吸收 merge **`0f1c160`** → 作战日报 4 提交 + CI e7073e3 → merge **`473ad4e`**。每步合并树回归全绿(口径见 §1)。
4. **推送**:parity/auto-2026-11、task/ci-dawn、task/daily-report-1 三分支推 origin(11-11);master 推 origin(27c6ef8..c6f4b88)。证据:`docs/replan-evidence-2026-11-05/delivery-2026-11-08/`(DELIVERY.md 全程口径)。

## 4. 收口五件套(五件全落)

1. **总报告**:本文(2026-11-11 终稿,含健壮性 backlog ①–⑤ 终态,见 §6.3;随终稿入库)。
2. **CSV 回写**:完成(2026-11-08 刷新 + 后续 I05 排序腿/I10 指针/T12 已接勘正随快照 85 落账)。
3. **结构校验**:重建 10 项全 PASS(`.omo/evidence/maa-main-parity-plan-2026-11-01/plan-validation.json`;provenance 注明原版模块路径检查因 plan 文档缺失不可复现)。
4. **证据树索引**:`.omo/evidence/auto-2026-11/_session/evidence-index-2026-11-08.md`。
5. **未跟踪盘点**:2026-11-08 盘点后,remaining doc + review-debt 三件(INFRA-1-R3/INFRA-3-R3/HANDOFF)已随 `c6f4b88` 入库,本报告终稿同批入库;**余量风险**:docs/*.csv、replan doc、replan-evidence-2026-11-05、auto-handoff 等仍在 `/docs` 局部排除下为本地单副本(8bfd 同类风险,入库需 `git add -f`,分支/时机待用户裁定)。

## 5. divergence 与裁定终态

23+ 条显式差异入档(详见 replan doc divergence 节与各 RESULT),**§6 行为面裁定批已全批裁毕**(S7.1 + S8):

- **落码对齐**:P13-[f](技能 0...3 缺省 0)/P13-[g](prtsCode OrdinalIgnoreCase)/P12-[u](排除集+5)/P17-[a](clear_store=true)/P16-[h](导出 10 属性同构)/P17-[c](PixelPaint 空图拒启)/P17-[d](四预设五语映射)/P17-[e](MinimumRequired Tip)/P12-[w](计划重排)。
- **裁定维持(有意分化)**:P17-[b](PixelPaint 常驻化,保证入口可达)/P21-[a](不收窄维持现状)。
- **澄清摘除**:P08 divergence[12] 实为 P08.1 设施缺省集且裁定已落地(2026-11-08 P08-3-R3)。
- **数据源缺失维持**:apCost 无数据源(P12-[g],v6.22.0 无规划面 apCost,日报理智走运行时回调不依赖);C15 PRTS 公开 API 需认证(FEASIBILITY_BLOCKED,过渡=网页链接)。
- **机制差异留档**:WPF fire-and-forget vs Mac 同步等待;SMTP 自写(Network.framework)vs MailKit;Hibernate 无 macOS 等价 + IfNoOtherMaa;Core 51dac87 态 yituliu_id 误传 penguin_id(pin 升级即生效);卫戍协议三期=资源驱动 WPF 牛杂工具箱面,Mac 无通用工具箱(台账);#150 关窗行为未采纳候选。

## 6. 债务终态

### 6.1 独立评审债(35/35 销账)

replan 线 35 增量全部审结:**W0 记录核验 PASS** + 12 增量首轮 PASS(P11.2/P11.3、P11.5/P11.6、P08.3、P09.2、P10、P13.2、P17.1、P16.2 等)+ 修复链闭环(FAIL→修复→原评审员复验 PASS→ff 并入,逐链如下;全部细节见附录 A 与 review-debt/):

| 链 | 修复提交 | 链 | 修复提交 |
| --- | --- | --- | --- |
| P24.1→P24.2 | ca7381e(SMTP 状态机重写+凭据脱敏) | P27.1→P27.2 | 8df3902(U06 生产布局断裂+socks5 旁路) |
| P26.1→P26.2 | f22c115(三循环并发恢复+可信回执) | P21.1→P21.2 | f122fcd(one-shot 停用时序+强启档位) |
| P23.1→P23.2 | 1a73cc9(通知启动同步+僵尸撤除) | P20.1→P20.2 | 766312a(找回链+初始化重入门) |
| P13.1→P13.3 | d0ab57e(活态竞态+降级存档保护) | P22.1→P22.2 | 5d6b386(触发门两路放行+脚本语义) |
| P25.1→P25.2 | b47093c(触发接线+打包语义) | P14.1→P14.2 | d3277b3(条件面 formation/吃药分派) |
| P28.1→P28.2 | 3ff05d7(台账口径勘误+警示本地化) | P12.2→P12.8 | 4ec994f(删除入口+手输开关接线) |
| P16.1→P16.2 | 45f83db(JSON 三属性全反+导出 owned-only) | P12.5→P12.7 | 5e276ad(FormatNumber 注释勘误) |
| P29.1→P29.2/29.3 | 2fa497a+419889f(语言接线+键补齐) | P11.4→P11.7 | dafa2d6(R10 开关门控同源) |
| P09.1→P09.1b | 33d15ec(G17 文案对齐 WPF) | P18.1→P18.2 | 80741ff(三键真实 zh-Hans) |
| P15.1→P15.2→P15.3 | 23b9095+bbee17a(触发面断链+loadObject 取腿) | P12.4/P12.3 | 纯文档修复闭环(零代码变更) |

### 6.2 评审后债批(S5–S8/DOC/TEST/infra,全关账)

| 批 | 内容 | 终态 |
| --- | --- | --- |
| S5 | ⑨装载日志+⑩注释口径+⑲weeklyDays 值域(**0...6 三方实证**,评审 1...7 处方被定性活性回归并修正)+P10-[a] | S5.2 `1e7995d` 复验 PASS 并入 |
| S6 | ⑦stem 三处收敛+⑧switchProfile 文案+P12-[n] 21 处文案清扫+P12-[q] | S6.2 `11f4655` 复验 PASS 并入(depot 变体键补插) |
| S7 | 行为面裁定批(§5) | S7.1 `981daf1` PASS 并入 |
| S8 | P17-[d]/[e]+P12-[w] 实施 | S8.2 `1a4b881` 复验 PASS 并入 |
| DOC-1/TEST-1 | 文档卫生+测试债 | `2370136`/`dbb1b42+1447870` PASS 并入 |
| infra | 基建五条+⑦JBird 注记(见 §6.3) | infra-3 `e764851` 复审 PASS 并入 |

### 6.3 健壮性 backlog ①–⑤ 终态(基建五条,全关账)

| 项 | 债务 | 修复 | 复审 |
| --- | --- | --- | --- |
| ① | ci.yml `SKIP="` 字面量硬依赖无诊断 | infra-1 首版被判**不可达死代码**(F1)→ infra-3 `e764851` 重做:管道级 `\|\| true`+二级空值检查,两变异(A 格式漂移/B `SKIP=""`)stderr 诊断+exit 1 实测 | INFRA-3-R3 PASS(核销) |
| ② | emit `tr` 不覆盖 `\r`/ESC、C locale `cut` 劈多字节 | infra-1 首版改 awk substr 被判**恒按字节假修+macOS 回归**(F2)→ infra-3 重做:python3 显式 bytes IO 码点截断(fallback cut),cap=120 码点;负对照双 locale `tr: Illegal byte sequence` abort 实证 | INFRA-3-R3 PASS(核销);夹具几何勘正:真 straddle 须 7B 前缀(`'PASS: X'+龙×41+'a'`),6B 前缀劈不开字不可作负对照 |
| ③ | arch_skip grep 建议加 `^SKIP` 前缀 | infra-1 `0ded704`:锚定正则,假套件变异正反双向实证 | INFRA-1-R3 成立 |
| ④ | P00.2 未按名排除 run-ci-inventory-check.sh(嵌套 ~40s) | infra-1 `0ded704`:SKIP(nested) 识别+summary 新字段 | INFRA-1-R3 成立 |
| ⑤ | P01.1 旧资源下超限存量值无启动拦截 | infra-2 `48fa5d3`:dispatchSeries 越界钳制下发+保存值不动,8 例矩阵+全仓 appendTask 下发面穷举+三提取套件 stub 同步;**WPF 对照=无钳制单侧加固,裁定可接受**(2g 注记 `e764851` 补 WPF 潜伏缺陷对照) | INFRA-1-R3 全部立住 |
| ⑦ | JBird Package.resolved 显式提交规则 | infra-1:ci.yml 注记规则固化;实体文件留待涉依赖锁定提交显式 `git add -f`(非本轮可执行项,如实留档) | INFRA-1-R3 成立 |

评审记录:`review-debt/INFRA-1-R3.md`(FAIL,F1/F2 中危+F3/F4 低危)、`review-debt/INFRA-3-R3.md`(PASS,F1–F4 全核销+R-1..R-4 记录级),均已随 `c6f4b88` 入库。

## 7. 上游线终态(2026-11-11 吸收)

- **upstream 解冻**:master 冻结 39 天后前进 `27c6ef8 → 100c6d8`(hguandl:依赖更新 b2c99a8 含 JBird 换源 vsanthanam>=3.0.0、Dawn.xcframework 5745fcf+8ad65e5、WebGPU 后端 100c6d8);主仓库 submodule pin 同步前进(8f25d1e,#19222)。
- **吸收合并**:四文件冲突(phpxproj/MAAViewModel/SystemSettingsView/xcstrings)全部「双侧保留+上游行按原邻位插入」;结构断言全过(无标记残留/plutil OK/Dawn 4 挂载点/184 PBXBuildFile 零悬挂)。
- **作战日报移植**(v6.22.0 桌面端新功能,Mac 零实现实锤后全量移植):Collector/Store/ViewModel/View/Math 六 Swift 文件 + HGCalendar 游戏日三原语 + MaaMessage 五钩子 + 工具栏入口 + 独立 Window;`run-daily-report-tests.sh` 51 checks PASS;测试 51 checks/库存回调探针 18 断言。
- **小件**:#19140 培养清空二次确认、#19098 两日志钩子、WebGPU 两空键补译。
- **Core pin 前进**:v6.22.0(901e01c6)本机产物+指纹逐位复核;fork maacore-setup 加 MaaDeps v2.15.1 双防护(CoreML 头/库失配+ORT 双版本歧义)+ makefile 显式 6 目标(含 Dawn);**fork CI 全链路实跑待验证**(action 改动待 tag/workflow_dispatch)。
- **21 PR**:rebase+force-push 后 21/21 CLEAN/MERGEABLE(备份 refs/backup/pr-168..181);**#182 仍零维护者回应**,追评/@ 待拍板。
- **潜伏面**:WebGPU 开关缺省 false,旧 Core 不认 static option key 2,随 R02 新 Core pin 解除;JBird 大版本换源兼容性由本地 Swift 套件全绿佐证。

## 8. 仓库终态(2026-11-11 收敛,经用户逐项拍板)

- **worktree**:7 → 2(主检出 + wt/integration);wt/p09-1 巨型暂存化石(160 文件 +20780/−2375,parity 已含更完整版本)以 `fossil/p09-1-staged-20261111`(`f5c95d3`)存证——**已推 origin,本地分支已删**;wt/p12-6/p23-2/p24-2/p26-2 移除。
- **分支**:36 → 3(删 33 个已并入 parity 的 task/*——commit 均从 origin/parity 可达,抽查 `merge-base --is-ancestor` 通过;fossil 分支推送 origin 后本地删除)。保留 `master`/`parity/auto-2026-11`/`codex/infrast-clue-controls`。
- **保留分支**:`codex/infrast-clue-controls`(在途上游功能,无对应 PR,出手前先提 issue 认领)。
- **master**:`c6f4b88`(docs 收口批:remaining doc + review-debt 三件)**已推 origin**;与 parity 的合流(313 提交)是收口最终动作,未执行(见 §9)。

## 9. 剩余事项(单列面,收口后仍开放)

| 项 | 内容 | 出口 |
| --- | --- | --- |
| W7 真机验收 | P30 成就 111 项证据/P32 全能力回归/P33 实际发行包/开放阻塞清零(P31 受限主题结局已勾闭) | 真机窗口 |
| §2 实机债 | 按域归组:真实作业端到端/九渠道真实投递/远控服务/原生 GUI 实点/更新链 U01 端到端等(remaining doc §2 全表) | 真机/专用环境 |
| R02 | 新 Core pin(v6.22.0)真机端到端:编队回归 D04/资源回退/bundle 快照;dd 四套件重建需 Dawn.xcframework | pin 已就位,只欠实跑 |
| T18 | 真机实测单列项 | 真机窗口 |
| 上游 | #182 追评+是否 @ hguandl(待拍板);single.2 发版节奏视 #182 回应;fork CI 全链路实跑 | 用户拍板 |
| master 合流 | parity(473ad4e,313 提交)合回 master;docs 提交 c6f4b88 仅在 master(重放或 merge) | 收口最终动作 |

## 10. 事故与教训

1. **P12.4 交付树假绿漂移**:声称的套件数字在交付树不成立(补桩后才入树)——台账计数失实的实锤案例,催生「交付树 bit 级断言+复验探针」纪律。
2. **INFRA-1 假修**:①②「声称已修、实测未修」(死代码+平台回归)——修复声明必须配变异/负对照实证,不能以「exit≠0」顶替诊断可达。
3. **xcstrings 整文件重写事故**:json.dumps 重排 24k 行→checkout 回滚改锚点手术(两次踩坑,11-11 复咬一次)。
4. **P18.1 评审派发丢失**(无 agent 痕迹):重派机制+快照留痕。
5. **证据工件丢失**:8bfd/a007 清理丢失 plan 原件与 CSV 原件——本地单副本(/docs 排除)是持续风险,收口批入库后余量见 §4.5。
6. **MaaDeps v2.15.1 双坑**:CoreML 头/库失配+ORT 双版本歧义,均以 CI 防护固化;install dylib 保留 tarball mtime 致陈旧产物 "up to date" 假绿(先 rm 再重建)。
7. **环境坑**:noclobber 拦 `>`/`2>`(须 `>|`/`2>|`);zsh `$sha:r` 历史修饰符/`^` glob;xcodebuild 必须宏校验跳过(JBird);证据必须实读日志尾行(假绿三变体)。

## 附录 A:评审债执行全录(2026-11-08 收口版 §6.1 原文保留)

<details>
<summary>11-08 收口版 §6.1 增量堆叠长段的处置说明</summary>

该段为 2026-11-08→11-09 逐单 FAIL→修复→复验→并入的增量堆叠叙事,彼时本文件尚在 `/docs` 局部排除下未入库(无 git 历史可回溯)。终稿不再重录该段,其全部事实内容(逐链 commit、断言计数、复验口径)与以下 committed/在档源一一对应,以彼为准:

- `docs/maa-main-parity-remaining-2026-11-07.md` §9–§14(c6f4b88 已入库:交付链、评审债 25/35→29/35→35/35 逐单、S5–S8/infra 四批);
- 活账本 `.omo/evidence/auto-2026-11/_session/closing-checklist.md` 快照 39–86(最细粒度,含每单复验探针计数);
- 各单 R3 verdict 文件(delivery-2026-11-08/review-debt/ 与 review-debt/ 已入库三件)。

</details>

## 附录 B:证据索引

- 交付链:`docs/replan-evidence-2026-11-05/delivery-2026-11-08/`(DELIVERY.md、trees.txt、commit-list.txt、infra-*/日志)。
- 各增量证据:`.omo/evidence/auto-2026-11/<包>/`(auto 线)与 `docs/replan-evidence-2026-11-05/execution-*/`(replan 线,36 目录)。
- 会话台账:`.omo/evidence/auto-2026-11/_session/closing-checklist.md`(活账本,快照 39=交付链落地、85=债批四批终态、86=上游吸收)。
- 评审记录:`review-debt/`(INFRA-1-R3/INFRA-3-R3/HANDOFF 已入库;其余 R3 verdict 在 delivery-2026-11-08/review-debt/ 与各增量目录)。
- 收口视图:`docs/maa-main-parity-remaining-2026-11-07.md`(§16=2026-11-11 最新增量)。
- 上游线:issue #182(#161–#181 合并顺序)、`docs/upstream-contribution/`、`docs/RELEASE.md`(single 发版配方)。
