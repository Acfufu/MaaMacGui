# 交接文档 — infra-3 修复循环中断点（2026-11-09）

## 一、状态快照

- **parity/auto-2026-11** @ `1a4b881`（tree c7ed06ce；35 delivery + 30 fix；xcstrings **1488** 键；未推送；master `27c6ef8` 未动）
- **task/infra-1** @ `48fa5d3`（0ded704 基建四条+⑦、48fa5d3 P01.1；已 rebase 到 1a4b881 上，评审用全量 diff `git diff 1a4b881..48fa5d3` sha256 `0d79e1ae…`）+ **infra-3 修复已改未提交**（2 文件，见下）
- worktree：`wt/s8-1`（已并入 1a4b881，可删）、`wt/infra-1`（infra-3 进行中）；`wt/doc-1`、`wt/test-1` 已删
- 主检出 /Users/acfufu/Codehub/MaaMacGui 在 **master** 上；证据目录与其下 review-debt/ 均为**文件系统工作区（不提交）**

## 二、INFRA-1/2 R3 判词（FAIL，2 中危）

报告：`/Users/acfufu/Codehub/MaaMacGui/review-debt/INFRA-1-R3.md`

- **F1（中危）**：①SKIP 诊断是死代码——`set -euo pipefail` 下 `dd_line="$(grep…|head -1)"` 无匹配先静默杀脚本（变异 A/B 均静默 exit 1 无输出），诊断块不可达；变异 B（`SKIP=""`）死于 :34 grep -v 空输入。债务 ① 实际未修。
- **F2（中危）**：②截断修复无效且回归——macOS/BSD awk 20200816 substr **恒按字节**（与 LC_ALL 无关，实测 6 字节劈字）；旧 `cut -c1-120` 在 UTF-8 环境本按字符且正确（实测 10 字节=5 字符）；新 awk 把 120 字节劈在汉字中间 → emit 的 tr `Illegal byte sequence` → **整轮盘点中止**。债务 ② 在 C locale 前提下也没修。
- **F3（低危）**：48fa5d3 提交消息键数 "1481→1482" stale（实际 1487→1488）。**F4（低危）**：证据只有中间态 58P/1F 日志（infra-inventory4.log），终态绿日志缺席。
- **立住部分**：③锚定/④SKIP(nested)/⑦JBird 全真修复；**P01.1 六面全部立住**（dispatchSeries 语义 -1/0 无误伤、静态注入写点唯一、下发面穷举无缺口、保存值不动、stub 同步、en/ko 探针双 HIT）；**2g 产品裁定可接受**——建议补 WPF divergence 注记（不阻断）。

## 三、infra-3 修复内容（已落 wt/infra-1 工作树，**未提交**）

1. `Tests/run-p00-baseline-inventory.sh`（F1+F2 重做+同类清扫）：
   - ①：`dd_line` 赋值挂 `|| true`（+2>/dev/null）→ 两级诊断可达；新增第二级检查：`dd_list` 解析为空 → fail-loudly（F1 变异 B 场景）。
   - ②：`trunc()` 改 **python3 -I 码点截断**（stdin.buffer 读 ≤480B → decode utf-8/replace → [:120] → stdout.buffer 写 utf-8/replace，编码不随环境漂移），`|| cut -c1-120` 兜底 + `command -v python3` 回退；emit 的两个 tr 改 **`LC_ALL=C`**（删除集全 ASCII 单字节，合法 UTF-8 下等价、非法字节免疫——判词真修方向）。
   - 同类清扫：:98/:112/:115 三处 detail 提取 grep 包 `{ … || true; } | trunc`（grep 无匹配不再静默杀盘点）+ for 循环前注释。
2. `MeoAsstMac/Task Configurations/FightConfiguration.swift`：P01.1 doc 注记补 WPF 对照段（2g 裁定可接受：WPF 无资源上限/不钳制/SeriesList 静态 0/10..1/-1，Mac「钳制下发+保存不动」为有意单侧加固 divergence）。
3. `bash -n` 语法检查已过；探针复现已确认（awk 6B 劈字 / cut 10B=5 字符）。

## 四、下一步（按序）

1. **跑验证沙盒** `/tmp/infra3-fix/run-tests.sh`（上次运行被取消，**结果未知，必须重跑**；预计 2-3 分钟）：
   - F1 变异 A（SKIP=" 字面量消失）/B（SKIP=""）→ 必须有 stderr 诊断 + exit 1；
   - F2 端到端：straddle 夹具（'PASS: '+龙×41+'a'，字节 120 劈 han39）→ 盘点存活 + JSON 合法 + detail 48 码点无损；cap 夹具（'PASS: '+龙×150）→ detail = 'PASS: '+龙×114（码点上限非字节上限）；
   - 负对照：旧 awk 管道同 straddle 输入 → `Illegal byte sequence`（证明修复有意义）；旧管道 cap → 120B='PASS: '+38 汉字（对比 114）；
   - 真树：盘点 59P/0F/3SKIP(arch)/1SKIP(nested)/4NOT_RUN(dd) exit=0 → 写 `$EV/infra-inventory-final.log`；ci-check → `$EV/infra-cicheck-final.log`；fight-config → `$EV/infra-fightconfig-final.log`（覆盖 FightConfiguration 注记编译）。
   - `$EV` = `/Users/acfufu/Codehub/MaaMacGui/docs/replan-evidence-2026-11-05/delivery-2026-11-08/infra-1/`（追加新文件，不重写 infra-inventory4.log——时点工件纪律）。
2. **写 infra-3 修复 RESULT** 到 `$EV/`（F1/F2/F3/F4 逐条对应 + 测试矩阵 + 负对照证据）。
3. **提交 infra-3**（task/infra-1，规范身份：`GIT_COMMITTER_NAME="acfufu" GIT_COMMITTER_EMAIL="73582072+Acfufu@users.noreply.github.com" git commit --author="acfufu <73582072+Acfufu@users.noreply.github.com>"`）。提交消息须含：F1/F2 重做描述、F3 勘注（键数实际 1487→1488）、F4 证据补齐说明、2g 注记、测试矩阵。
4. **派 R3 复审**（后台代理，并发平台限 2）：对象 = infra-3 新提交，基 48fa5d3；要求核对 F1 两变异诊断可达、F2 多字节端到端存活、负对照、无新回归；判词含 `VERDICT: PASS/FAIL` 行。**复审在飞期间禁碰 wt/infra-1**（s8-1/infra-1 已两次 rebase-under-review，须入台账教训）。
5. **PASS 后**：ff 并入 parity/auto-2026-11（1a4b881→新头）→ 合并树套件（盘点/CI-check/Debug build，有 dd 则 63P）→ 删 wt/infra-1、wt/s8-1（保分支）。
6. **四批合并台账五处**（doc-1 2370136 / test-1 1447870 / s8-1+S8.2 1a4b881 / infra-1+2+3）：DELIVERY §4 进度行 / closing-checklist 快照（.omo/evidence/auto-2026-11/_session/closing-checklist.md，现快照 84）/ 总报告 docs/auto-run-report-2026-11-01.md §6 / replan docs/maa-main-parity-replan-2026-11-05.md 执行更新块 / features CSV（CRLF+BOM 保持）。**必须含**：S8 低-1 Other=false 迁移披露原文、低-2 「最低需求：」尾随空白勘注、记录-1 残留边缘（v1.2.3-beta.1 WPF 收/Mac 拒；"01.2.3"/"+1.2.3" Swift Int 收/WPF 拒）、记录-2 版本来源措辞勘误、rebase-under-review 教训两次、P12-[w] UI 形态注记（拖拽↔按钮）、infra F1-F4 判词与 infra-3 修复记录、P01.1 2g divergence 注记指引。
7. **目标范围收尾盘点**：目标范围内全部清零（仅真机验收 W7 P30–P33、真实材料消耗/§2 实机债/R02/T18、§7 上游 21 条在飞 PR 仍排除——需推送授权）。

## 五、纪律与坑（血泪清单）

- **复审在飞期间禁碰其 worktree**（已犯两次）。
- **时点工件永不重写**（run.json、commit 消息、中间态日志）——勘误走追加块/内联标记。
- `set -euo pipefail` 下**任何** grep 赋值都可能静默杀脚本——新加管道赋值一律 `|| true`（infra-3 已清扫全文件）。
- python3 -I 须用 `stdin.buffer/stdout.buffer` 显式字节 IO（文本模式编码随 locale 漂移会 UnicodeEncodeError）。
- .py 套件用 `python3`、.sh 用 `bash`（.py/.sh 混调已犯三次）；沙盒 python 一律 `python3 -I`；macOS sed 用 `sed -i ''`。
- 并发：用户授 ≤3，**平台实际限 2**，派发失败就排队重试。
- 沙盒方法：变异一律在 /tmp 副本仓（需 git init + 提交，盘点脚本 `git rev-parse HEAD` 依赖）；真 worktree 保持零残留。
- 资源目录：`MAA_INVENTORY_RESOURCE_DIR=/Users/acfufu/resource`（version.json 在）；DerivedData 无标准路径，评审人是自建 dd；无 dd 时盘点 59P 形态。

## 六、排除范围（不变）

真机验收（W7 P30–P33）、真实材料消耗/实机债（§2、R02、T18）、§7 上游 PR（21 条在飞，需推送授权）。

> **闭环注记（2026-11-11）**：§四 步骤 1–7 全部执行完毕——沙盒重跑 20 检查 0 失败（含 7B 前缀夹具几何勘正：交接文档 6B 前缀劈不开字不可作负对照；负对照双 locale 勘正：C.UTF-8 亦为多字节 locale 同 abort）；infra-3=e764851；R3 复审 PASS（review-debt/INFRA-3-R3.md，F1–F4 全核销+R-1..R-4 记录级）；ff 并入 parity/auto-2026-11=1a4b881→e764851（树 2224fc1e）；合并树三件套绿（盘点 59P/ci-check/fight-config）；wt/infra-1、wt/s8-1 已移除（分支保留）；台账五处落账（S8.2 复审通过条件披露文本在 DELIVERY §4 四批 bullet）；目标范围收尾盘点见 docs/maa-main-parity-remaining-2026-11-07.md §14。本交接文档使命完成。
