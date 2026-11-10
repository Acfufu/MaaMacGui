# INFRA-3 R3 对抗独立评审报告（F1/F2 重做核销）

- 评审对象：task/infra-1 分支修复提交 **e764851**（父提交实测 = 48fa5d37db4c…，单提交修复），对 INFRA-1-R3 判词（FAIL，F1/F2 中危 + F3/F4 低危）的重做。
- 全量 diff：`git diff 48fa5d3..e764851`，仅两文件——`Tests/run-p00-baseline-inventory.sh`（+45/-14）与 `MeoAsstMac/Task Configurations/FightConfiguration.swift`（+5 行 doc comment），无越界改动。
- worktree：/Users/acfufu/Codehub/wt/infra-1（HEAD=e764851，评审全程只读执行；评审前后 `git status --porcelain -uall` 均 0 行）。
- 本评审独立沙盒：/tmp/infra3-r3-review/（副本仓 git init+commit a1134e963a4002682de472ef3dc19e17f2969144；python 一律 `python3 -I`；探针脚本 `set -euo pipefail`）。修复方 RESULT 与工件（INFRA-3-RESULT.md、infra3-fix-artifacts/）仅作对照基准，判词只依据本人复现。
- 指纹核对：真树脚本 sha256 = `447c82e6f6af0ff94a1849bf59189a1fdfc2711c00d9e85c0e06436c78df34f7`、FightConfiguration.swift sha256 = `6965588390d35debf2258f7b3b640e893a0bf36d905cd853a0a42bc7a82a5731`，与 RESULT 自述逐字一致（本机 shasum 实测）。

## 判词：F1/F2 真修成立，F3/F4 核销成立，2g 注记成立

R3 判词 F1（SKIP 诊断死代码）、F2（截断假修+回归）两条中危均按 R3 处方真修，且修复方对交接文档夹具几何的勘正（6B 前缀劈不开字）经我独立几何计算与 e2e 实测**证明正确**；F3/F4 低危两条均已落账。修复未引入新的中/高危回归面（残余面见记录级 R-1～R-4）。

---

## 逐条核销

### F1【中危→核销】SKIP 诊断死代码重做：两变异 stderr 诊断 + exit 1 + stdout 空，全过

**机制核对（diff 全文）**：`dd_line` 赋值挂管道级 `|| true`（+`2>/dev/null`）——`set -euo pipefail` 下 grep 无匹配不再经赋值杀脚本，R3 指出的诊断块不可达问题消除；新增 `dd_list` 空值二级检查，拦 `SKIP=""`（R3 变异 B 场景）与纯空白列表。`2>/dev/null` 使 ci.yml 文件缺失也走同一诊断出口（fail-loudly 语义不破）。

**独立复现（/tmp 副本仓，夹具 ci.yml 取自真树）**：

| 变异 | exit | stderr | stdout |
|---|---|---|---|
| A：删除含 `SKIP="` 的行 | 1 | `ERROR: ci.yml SKIP=" literal not found — format drift breaks dd-list parsing (infra-1 ①)` | 0 字节 |
| B：`SKIP=""` | 1 | `ERROR: ci.yml SKIP list parsed empty — dd suites would hard-fail without build products (infra-1 ①)` | 0 字节 |

与 R3 首版"静默 exit 1、诊断不可达"对比，行为差异真实存在。回归面自查：两处 `|| true` 只容忍"无匹配/空输入"这一种失败模式，其后均有显式空值检查与诊断出口，未发现吞掉不该吞的失败；脚本其余 grep 均在 if 条件或已包 `{ … || true; }`（见 F2），无同类残留。

### F2【中危→核销】多字节截断重做：几何勘正证实 + 端到端断言全过 + 双 locale 负对照 abort

**几何论断独立验证（python3 -I 计算 + 实测）**：
- straddle `'PASS: X'+龙×41+'a'` = 131B/49 码点；字节 120（1 起始）= b[119] = 0xbe = 第 38 条龙（E9 BE 99）三字节的中间位 → 旧管道 120B 字节截断必劈字。实测旧 awk（LC_ALL=en_US.UTF-8）输出 120B、尾部 hex `…e9 be`（半个龙）。
- 交接文档 6B 前缀 `'PASS: '+龙×41+'a'`：字节 120 = 0x99 = 第 38 条龙**尾字节**（6+38×3=120 恰落字符边界）→ 劈不开字。e2e 实测旧管道对该夹具**存活且 120 码点无损**——修复方"6B 夹具不可用作负对照"的勘正**属实**，且这是对交接文档错误的正确更正而非狡辩。
- cap `'PASS: '+龙×150` = 456B/156 码点。

**新 trunc 单元（与修复版逐字同一实现，三 locale C / en_US.UTF-8 / C.UTF-8）**：straddle 均 49 码点无损；cap 均 = `PASS: `+龙×114（120 码点，码点上限非字节上限）。显式 stdin.buffer/stdout.buffer 字节 IO，编码不随环境漂移；480B 预读 ≥ 120 码点 × 4B 上限，边界劈字由 decode replace 兜底为 U+FFFD，输出恒为合法 UTF-8。

**端到端（真 emit 管道，夹具套件经 bash runner 走修复版盘点全流程）**：exit=0、`python3 -I json.load` 合法、failed=0、straddle detail 与期望逐字相等（49 码点）、cap detail=`PASS: `+龙×114。

**负对照（48fa5d3 旧管道 awk+locale tr 跑同一夹具）**：
- straddle：C.UTF-8 与 en_US.UTF-8 **双 locale 均 exit 1 + `tr: Illegal byte sequence` + stdout 非合法 JSON（半截，JSONDecodeError）**——C.UTF-8 亦为多字节 UTF-8 locale 的独立复核成立（本机原生 LANG 即 C.UTF-8，即实际环境必触发）。
- cap：旧管道存活但字节截断——最终 JSON detail = 120B = `PASS: `+38 龙，对比新管道 348B/114 龙。
- LC_ALL=C tr 语义核查：删除/翻译集全为 ASCII 单字节，字节级操作不可能劈多字节序列；实测劈字输入在 LC_ALL=C 下 tr 直通（rc=0）——对合法 UTF-8 等价、对非法字节免疫的论证成立。

**回归面自查**：
- `|| cut -c1-120` 兜底实测可达：python3 为坏 shim（exit 2）时 cut 接管（straddle 49 码点无损、cap 114 龙，与 python 路径同结果）；PATH 无 python3 时走 else 分支同样正常。残余面见 R-3。
- 三处 detail 提取 grep 包 `{ … || true; }`：提交消息锚定旧版 :98/:112/:115 行号核实无误（48fa5d3 版三行恰为三处 emit 内 grep 提取）；无匹配降级空 detail，不再经 pipefail 杀盘点。FAIL 分支用 `tail -1`（恒成功）无需包裹，覆盖完整无遗漏。

### 2g 注记【成立】

FightConfiguration.swift +5 行纯 `///` doc comment（dispatchSeries P01.1 注记块内），补 WPF 对照段：WPF 无资源上限/不钳制、SeriesList 静态列表 0/10..1/-1、超限存量原样下发为 WPF 侧潜伏缺陷、Mac「钳制下发+保存不动」为有意单侧加固 divergence 非对齐缺口——与 R3 (g) 裁定及建议逐点对应。编译面：真树 `bash Tests/run-fight-configuration-tests.sh` rc=0（该套件编译生产 FightConfiguration.swift，series encode/upper bound 6 vs 10 等断言全过）。

### F3【低危→核销】键数勘注已入提交消息且数字本身准确

e764851 消息含「F3 勘注：48fa5d3 消息键数 "1481→1482" 实为 1487→1488」。我独立计数（`git show <rev>:Resources/Localizable.xcstrings` + python3 -I json）：1a4b881=1487、48fa5d3=1488、e764851=1488——勘注数字与实测一致。时点工件不回改历史消息、勘注随新提交的处理合理。

### F4【低危→核销】终态绿日志补齐 + 被杀截断工件保留

- `infra-inventory-final.log`：59P/0F/3SKIP(arch)/1SKIP(nested)/4NOT_RUN(dd)、67 套件、code_sha=48fa5d3（出证时点 infra-3 尚未提交，与 RESULT 口径自洽）——本评审真树复跑（code_sha=e764851）summary 完全一致。
- `infra-cicheck-final.log`：尾行 "CI inventory: all checks passed"——本评审复跑 rc=0、checks_failed=0 一致。
- `infra-fightconfig-final.log`：4 行 PASS 在案——本评审复跑 rc=0 一致。
- `infra-inventory-final.log.run-killed-2026-11-09`：7534B、JSON 解析失败（截断属实）、头部 code_sha=48fa5d3——原样保留未重写，时点纪律在案。

## 真树复跑（本机 Darwin 27.2.1 arm64，MAA_INVENTORY_RESOURCE_DIR=/Users/acfufu/resource）

| 项 | 实测 |
|---|---|
| `bash Tests/run-p00-baseline-inventory.sh` | exit=0，59P/0F/3SKIP(arch)/1SKIP(nested)/4NOT_RUN(dd)，JSON 67 套件合法，code_sha=e764851、core_pin=51dac87、resource fda2ef97/10094 文件 |
| `bash Tests/run-fight-configuration-tests.sh` | exit=0（2g 注记编译面覆盖） |
| `bash Tests/run-ci-inventory-check.sh` | exit=0，checks_failed=0，"all checks passed" |

## 评审过程记录（含失败尝试，均系本评审探针自身问题，与修复无关）

1. 沙盒夹具自检首跑失败：预期"捕获后 132B"错写了命令替换剥尾 LF 的事实（应为 131B），修正自检口径后过——夹具本身无问题。
2. F2 探针脚本 `echo "…rc=$rcC（…"` 在 `$rcC` 后紧跟全角括号 U+FF08 触发 bash 变量名解析怪癖报 unbound variable，改 `${rcC}` 后过——探针写法问题。
3. 兜底路径探针首版嵌套引号被 shell 搅碎（unexpected EOF / zsh glob 报错），改写独立脚本文件后过；R4 的 `env PATH=<无bash目录> bash` 报 No such file or directory 属我自设 PATH 缺 bash，改绝对路径后取得记录。
4. 旧管道 cap 的"121B"口径：awk trunc 原始输出为 120B+ORS=121B，但经 emit 管道后命令替换剥尾换行，最终 JSON detail 实为 120B——修复方 RESULT 的 121B 指 trunc 原始输出，两边实测不矛盾（R-4）。

## 新发现（均记录级，不阻断）

- **R-1（记录级）**：emit 的 JSON 净化集（`tr -d '"\\\r\033'`）未覆盖其余 C0 控制字符（\b \f \v 等）——若某套件尾行输出含此类字符，detail 将携带原始控制字节使严格 JSON 解析判非法。此为 48fa5d3 既有删除集、本修复未改动，现网 67 套件实测无此输出，非本批引入，备查。
- **R-2（记录级）**：RESULT 自述"沙盒 18 检查 0 失败"，其 verify-2026-11-11.log 实数 20 条 PASS 行（fails=0 属实）——计数口径小误，不影响证据实质。
- **R-3（记录级）**：trunc 的 cut 兜底在「python3 缺席/坏 shim + 宿主 LC_ALL=C」双退化环境下按字节劈字（实测 120B 劈字）；该环境连 .py 套件都无法运行，脚本注释已声明回退仅为截断自身容错、不改变 python3 依赖事实——可接受残余。
- **R-4（记录级）**：旧管道 cap 字节数口径差（trunc 原始输出 121B vs 最终 JSON detail 120B），见评审过程记录 4。

## 结论

F1/F2 按 R3 处方真修并经变异/端到端/负对照三面独立复现，夹具几何勘正经计算与实测双重证实；F3 勘注在案且数字准确，F4 绿日志与被杀工件两全；2g 注记落位且编译面绿。真树三件套复跑全绿，worktree 零残留。INFRA-1-R3 判词的 F1/F2/F3/F4 四条全部可核销。

VERDICT: PASS
