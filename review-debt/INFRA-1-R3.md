# INFRA-1 R3 对抗独立评审报告

- 评审对象：task/infra-1 分支 **0ded704**（⑥基建四条+⑦JBird 注记）+ **48fa5d3**（P01.1 旧资源超限倍率下发拦截），基 **1a4b881** = parity head（评审中途 rebase：原 29d1713+5c7b202/基 1447870，经逐字节比对两版基建文件与 P01.1 生产文件完全一致，发现全部沿用；测试块合并与 xcstrings 重放已按新基复核）。
- 全量 diff：`git diff 1a4b881..48fa5d3`，sha256 `0d79e1aed394b5bebd9b127835e9bdf5a63ca365fe544517d65deabd559ebd94`（与协调席口径一致）。
- worktree：/Users/acfufu/Codehub/wt/infra-1（HEAD=48fa5d3，评审全程零残留：变异一律在 /tmp/infra1-r3/sandbox 副本仓进行，主 worktree `git status` 干净）。
- 证据：docs/replan-evidence-2026-11-05/delivery-2026-11-08/infra-1/（commit.txt、双 patch、infra-ci2.log、infra-inventory4.log）。双 patch 与 `git diff 1447870..29d1713`（60bd4a7a…）/`git diff 1447870..5c7b202`（0b9a5607…）逐字节匹配。

## 判词：FAIL（2 中危）

四条基建中 ③④⑦ 为真修复且全绿，P01.1 生产面（钳制语义/静态注入/下发面覆盖/保存值不动/提取面/WPF 对照裁定）全部立住；但 **①② 两条均为"声称已修、实测未修"**——① 诊断块是不可达死代码，② 不仅没修还在主验证平台上把原本正确的行为改坏并引入盘点整轮中止的潜在故障。两条都落在台账失实（中危）。

---

## 发现

### F1【中危】①"SKIP=\" 字面量缺诊断"修复为不可达死代码——债务 ① 实际未修

**声称**（0ded704 提交消息①）：ci.yml SKIP=" 字面量缺诊断：解析为空即 fail-loudly。

**实测（/tmp 副本仓两变异 + 最小复现）**：

1. 变异 A（格式漂移：`SKIP="..."` 整体改为 YAML `env: SKIP: "..."` 形态，`SKIP="` 字面量完全消失）：盘点 **exit=1、stdout 空、stderr 空**——脚本在 `dd_line="$(grep -o 'SKIP="[^"]*"' "$ci_yml" | head -1)"`（脚本 :26）处就被 `set -euo pipefail` 杀死（grep 无匹配 exit 1，pipefail 传播到赋值），**新增的诊断块（:30-33）根本不会执行**。最小复现确认：赋值语句后第一行 echo 均未到达。
2. 变异 B（`SKIP=""` 空字面量——恰是注释声称要拦的"解析为空"场景）：:30 检查看到的 dd_line 非空（`SKIP=""`）→ 检查放行 → 死于 :34 `dd_list=... | grep -v '^$'`（空输入 grep exit 1，同样静默 exit 1 无任何输出）。
3. 两种漂移场景下诊断均不可达；该 if 块在一切输入下是死代码。补丁前（1447870）脚本同样有 `set -euo pipefail` 与同一句 grep 赋值——**补丁前后可观测行为逐字节一致（静默 exit 1）**，"带诊断"的验收目标未达成（exit≠0 是的，诊断没有）。

**判级**：中危（台账失实：声称的结构契约修复未交付，债务 ① 仍开放；exit≠0 的兜底是既有 set -e 而非本补丁）。不到高危：漂移时盘点仍然响亮失败（exit≠0），不存在假绿。若要真修，需 `dd_line="$(grep ... || true)"` 类容忍写法让检查可达，或在赋值行内联诊断。

### F2【中危】②截断修复无效，且在主验证平台（macOS）构成回归——债务 ② 实际未修+新引入盘点整轮中止隐患

**声称**（0ded704 提交消息②）：三处 `cut -c1-120`（C locale 按字节劈多字节中文）改 `LC_ALL=en_US.UTF-8 awk substr` **按字符截断**。

**实测（macOS awk version 20200816，/usr/bin/awk；CI runs-on macos-26 同代 awk）**：

1. **awk substr 与 locale 无关、恒按字节**：`printf 'abc一二三四五' | LC_ALL=en_US.UTF-8 awk '{print substr($0,1,5)}'` → 输出 5 字节（`abc`+`一`的前 2 字节），多字节字符被劈开。两次独立探针一致。
2. **旧 `cut -c1-120` 在 UTF-8 环境本就是按字符且正确**：同一 150 汉字输入，`cut -c1-120`（继承环境 en_US.UTF-8）输出 359 字节=120 个完整字符、UTF-8 合法；仅 `LC_ALL=C cut` 才按字节劈（121 字节、劈字）。即**旧代码在本地盘点（Darwin 27.2，证据日志的实际运行环境）是正确的，新代码改成了坏的**；而在债务 ② 前提所指的 C locale 环境，awk 依旧按字节劈——债务在那也没修。
3. **端到端后果（经真实盘点脚本复现）**：构造 PASS 行使字节 120 落在多字节字符中间 → emit 的 `tr -d '"\\\r\033'` / `tr '\n\t'` 收到非法 UTF-8 → **`tr: Illegal byte sequence` → set -e 杀死整个盘点（exit 1、JSON 半截、无 summary）**。旧代码同环境下 detail 截断合法，不可能触发此路径。
4. `tr -d '"\\\r\033'` 转义本身正确（单引号内 `\033` 由 tr 解释为 ESC；实测引号/反斜杠/CR/ESC 剔除、tab→空格、短中文 detail 输出 JSON 合法）——这半条真修复。
5. 现网 67 套件的 PASS detail 均为 ASCII（证据日志逐行核对），故该回归**当前潜伏未触发**：实测盘点 59P/0F（无 dd）/63P/0F（自建 dd）exit=0。任一套件未来输出超 120 字节的中文 detail 即整轮盘点死亡。

**判级**：中危（台账失实："按字符截断"在本平台为假；且把原来正确的路径改坏+引入整轮中止故障面）。不到高危：非假绿（坏 JSON/exit≠0 是响亮失败）、非生产代码。真修方向：按字节安全截断（如 `head -c` 后裁剪到字符边界）或确认目标平台 awk 为 gawk 时才用 substr，且 emit 的 tr 管道对非 UTF-8 输入免疫（`LC_ALL=C tr`）。

### F3【低危】48fa5d3 提交消息键数 "1481→1482" 已 stale

rebase 后实际 xcstrings 键数 1487→1488（实测 `git show` 计数）。消息描述的是 rebase 前状态，协调席交接已注明 1488 但提交消息未同步勘正。注记失准（低危），不影响功能。

### F4【低危/观察】交付证据只含中间态失败日志，终态绿日志缺席

infra-inventory4.log（code_sha=29d1713）显示 **58P/1F**——daily-prep swiftc 编译失败，这是开发中途（首版 P01.1 在工作树未提交时）的状态，而非任一提交的干净树状态。交付目录没有终态 59P/0F 日志。本评审已独立复现终态（59P/0F 无 dd、63P/0F 自建 dd，均 exit=0），提交消息声称的终态为真；但单看交付目录会得出与提交消息矛盾的印象——证据打包不完整。另：过程备注"首版经 VM 属性 coreCapabilities 直引破**三**提取套件"仅能由该日志佐证 1/3 套件损坏（daily-prep），被弃首版未入库、无法独立复核"三套件"计数；机制成立（三套件确为生产切片+stub 编译，见 2e），无反证，不判失实。

---

## 逐项核验（对抗清单）

### 1. 29d1713（现 0ded704）四条+⑦

| 项 | 结果 | 证据 |
|---|---|---|
| ① SKIP 诊断 | **不成立（F1）** | 两变异均静默 exit 1、无诊断输出；最小复现确认 set -e 先杀 |
| ② trunc | **不成立（F2）** | awk substr 恒按字节；与旧 cut 在 UTF-8 环境对比：旧=120 字符合法、新=120 字节劈字非法；端到端 tr 死亡复现 |
| ③ arch_skip 锚定 | **成立** | 正向：盘点 3SKIP(arch) 实测（run-task-startup/achievement-timer/task-operation 三套件识别无误）；负向：副本仓假套件输出 "PASS: 7 checks passed; 2 checks superseded by newer suite remain green"（行首非 SKIP）→ 新正则判 PASS、旧正则变异复跑判 SKIP(architecture) 误判，修复价值证明 |
| ④ SKIP(nested) | **成立** | 真实盘点：run-ci-inventory-check.sh → SKIP(nested)、skipped_nested=1；summary JSON 经 python3 -I json.load 校验合法、schema 含新字段 |
| ⑦ JBird 注记 | **成立** | ci.yml :34-35 注记在场（"Packages.resolved 变更默认被本地排除…git add -f"） |

### 2. P01.1（48fa5d3）

**(a) dispatchSeries 语义+8 例矩阵**：成立。`guard let stored, stored > upperBound else { (stored,false) }`→越界才钳到上限。-1（保留当前）/0（AUTO）是合法值且透传（矩阵含 (-1,6,-1,false)/(0,6,0,false)），**无误伤合法值**。8 例矩阵（nil/-1/0/3/6/7/10×bound6、10×bound10）位于 FightConfigurationTests.swift（P17-[e] 块之后顺排，与协调席合并说明一致），套件编译**生产** FightConfiguration.swift（run-fight-configuration-tests.sh :21），实跑 exit=0。

**(b) 静态注入正确性**：成立。全仓 grep：生产写点唯一（MAAViewModel.swift:2384，refreshCoreCapabilities 内）；其余命中为 stub 声明与注释。时序完备：refreshCoreCapabilities 挂在 reloadResources(:1293 defer)/loadResource(:1398 defer)/updateChannel(:1501)，下发需 handle，启动自跑有 10s 倒计时+canStartTasks 门——nil→10 窗口生产不可达。nil 缺省 10 与 CoreCapabilities.conservativeDefault（CoreCapabilities.swift:34-35，seriesUpperBound:10，注释明确挂钩 P01.1）及 seriesUpperBound(nil)→10（FightConfiguration.swift:151-152）三方一致。`nonisolated(unsafe)` 与 URL.externalCopilotDirectoryOverride 先例同款；单写点+MainActor 同域读写，无多点竞态。

**(c) 下发面穷举**：**无未覆盖面**。全仓 appendTask 调用点：daily-run fight 分支（:1927 入口拦全部 .fight runTasks→:1959 钳制→:1968 下发，logWarn 新键在场）；depot-maintain 逐计划战斗（:3348 与中途重算 :3424/:3429/:3434）经 DepotMaintainPlanner.dispatchFight **series 恒 ∈{0,1}**（useAutoSeries?0:1），构造上不可能越界；恢复路径 runRecoveryTask 四个调用点全为 .StartUp/.Custom，不含 Fight；copilot（NewViewModel.startCopilot→parent.startCopilot(tasks:)）为 Copilot 类型；appendTrackedTask 调用点为 .Recruit/.VideoRecognition/.Custom/.CloseDown；远控子集（"Combat":.Fight）与远控全量均经 startDailyTasks→同一钳制分支；MAATaskConfiguration.swift:44 `.fight` case 仅可从 ：2011 else 分支到达，而 .fight 在其前的 if-case 已被拦截，实际死路。手动单任务/定时/热键/启动自跑全部汇入 startDailyTasks 同一条钳制路径。

**(d) 保存值不动**：成立。钳制只写 `var dispatchConfig = config` 局部副本（:1964 全 VM 唯一 series 赋值点）；runTasks/tasks 无回写；Swift 值类型语义保证存储面零改动。FightSettingsView UI 侧本就保留超限存量值标签（"换旧资源后保留超限存量值"），与"保存不动"自洽。

**(e) 三提取套件 stub 同步**：成立。stub（DailyPreparationTestSupport.swift）dispatchSeries 三成员与生产**逐字相同**（diff 实测）；stub 环境 liveSeriesUpperBound 恒 nil→10→钳制路径不触发，与生产缺省论证自洽；medicine-log 套件编译的生产 enqueue 循环切片包含新钳制块（套件绿=切片可编译），三套件实跑全绿（medicine-log 75 / daily-prep 119 / inventory-prep 24）。

**(f) 新键三语+构建产物**：成立。xcstrings 键数 1488（=1487+P01.1 一键）；键含 en/ko 双语翻译，zh-Hans 以键即值（仓内 668/1488 键同款既定惯例，运行时回退键文本）；自建 Debug 构建产物探针：en.lproj/ko.lproj 的 Localizable.strings **双 HIT**，zh-Hans 表缺省同惯例（作战/基建换班等既有键同缺省）。

**(g) WPF 对照与产品裁定**：WPF 侧（/Users/acfufu/Codehub/MaaAssistantArknights @4d948320）实测：SeriesList 为**静态列表**（0/10..1/-1，无资源门控），全仓无 FightSeries/OldMethodFlag（无资源上限概念），AsstFightTask.Series（默认 1）原样序列化下发——**WPF 无任何钳制，旧资源下存量 7-10 会原样下发**（Core m_series 未定义行为即 WPF 侧潜伏缺陷）。Mac「钳制下发+保存不动」是单侧加固，**与本批唯一无 WPF 处方的设计项定位相符**。
**裁定：可接受**。理由：① Core m_series 契约 1..10（旧资源 UI 上限 6），越界下发确为未定义行为，拦截方向正确；② 仅钳下发+保存不动，资源升级自动恢复原意图，无数据损失；③ -1/0/nil 语义完整保留（矩阵钉死）；④ 与 Mac 既有 UI 上限口径（seriesUpperBound/FightSettingsView）同源同根解析（effectiveResourceRoot），口径一致。**建议**（不阻断）：按仓内 divergence 随实现记录惯例（如 DepotMaintainConfiguration 注记样式）在 FightConfiguration.swift P01.1 注记中补一句"WPF 无资源上限/不钳制，Mac 单侧加固"——当前注记只写了 Mac 行为未写 WPF 对照，属注记缺口而非覆盖缺口。

### 3. 回归复跑（本机 Darwin 27.2 arm64，自建 dd /tmp/infra1-r3/dd）

| 项 | 声称 | 实测 |
|---|---|---|
| 盘点（无 dd） | 59P/0F/3SKIP(arch)/1 SKIP(nested)/4NOT_RUN(dd) exit=0 | **一致**，JSON 合法 |
| 盘点（自建 dd） | —（清单要求可自建） | **63P/0F/3/1/0，exit=0**（四 dd 套件全 PASS） |
| run-ci-inventory-check.sh | exit=0 | **exit=0，checks_failed=0** |
| Debug build | exit=0 | **exit=0** |
| fight-config（含 P01.1 矩阵） | exit=0 | **exit=0** |
| medicine-log | 75 | **75 checks，exit=0** |
| daily-prep | （test-1 批 119 断言） | **119 production async assertions，exit=0，本树未破坏** |
| inventory-prep | 24 | **24 assertions，exit=0** |

### 4. 提交消息如实性

- 0ded704：③④⑦ 及"嵌套排除生效+架构跳过锚定不误伤"验证语**属实**；"盘点 59P/0F…"终态**属实**（本评审独立复现）；但 ①② 两条修复描述**与实测行为不符**（F1/F2）。
- 48fa5d3：dispatchSeries/静态注入/接线/stub/矩阵/全部验证语（build、四套件计数、盘点、CI、en 探针）**逐项属实**；"1481→1482" stale（F3）；过程备注"破三套件"部分不可复核（F4，无反证）。

## 结论

③④⑦ 与 P01.1 全部立住（P01.1 的设计裁定：**可接受**，建议补 divergence 注记）；但 ①② 是"声称已修、实测未修"的台账失实，② 还附带在主验证平台引入了盘点整轮中止的回归面。**本批不能按台账放行**：请把 ①② 从"已修"改回开放债务（或按 F1/F2 的真修方向重做后重提），①② 重做本身改动面极小（几行 shell），P01.1 部分无需返工。

VERDICT: FAIL
