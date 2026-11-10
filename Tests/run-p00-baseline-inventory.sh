#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${1:-}"
# P00.2 基线盘点：代码/Core/资源指纹 + 全部测试套件清单与运行结果。
# 输出 JSON（stdout）：每套件 status ∈ PASS/FAIL/SKIP(architecture)/NOT_RUN(dd)，
# 汇总 passed/failed/skipped_architecture/not_run。任一套件 FAIL 时退出码非 0。
ci_yml="$repo_root/.github/workflows/ci.yml"
pin_file="$repo_root/MAACORE_PIN"
resource_dir="${MAA_INVENTORY_RESOURCE_DIR:-$repo_root/../../resource}"
evidence_dir="${MAA_TEST_EVIDENCE_DIR:-}"
[ -z "$evidence_dir" ] || mkdir -p "$evidence_dir"

code_sha="$(git -C "$repo_root" rev-parse HEAD)"
core_pin="$(tr -d '[:space:]' < "$pin_file")"
if [ -f "$resource_dir/version.json" ]; then
    resource_fp="$(shasum -a 256 "$resource_dir/version.json" | cut -d' ' -f1)"
    # -H 让 find 跟随资源目录符号链接（与 maacore-setup 的 resource 布局一致）
    resource_files="$(find -H "$resource_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
else
    resource_fp="MISSING"
    resource_files="0"
fi

# ci.yml 声明的 DerivedData 依赖清单（tests job 的 SKIP 列表）
# ①（P00.2/健壮性 backlog；infra-1-R3 F1 重做）：SKIP=" 字面量是本清单与
# ci.yml 的结构契约——格式漂移（字面量消失/解析为空）必须 fail-loudly，
# 否则 dd 清单静默为空、四个 dd 套件无构建产物硬跑必败且表现为无关失败。
# 首版教训（infra-1-R3 F1 变异 A/B）：set -euo pipefail 下 grep 无匹配会让
# 赋值行静默杀死脚本、诊断块成死代码——赋值行挂 || true 是诊断可达的前提。
dd_line="$(grep -o 'SKIP="[^"]*"' "$ci_yml" 2>/dev/null | head -1 || true)"
if [ -z "$dd_line" ]; then
    echo "ERROR: ci.yml SKIP=\" literal not found — format drift breaks dd-list parsing (infra-1 ①)" >&2
    exit 1
fi
dd_list="$(printf '%s' "${dd_line#SKIP=\"}" | sed 's/"$//' | tr ' ' '\n' | grep -v '^$' || true)"
# SKIP="" 空字面量同属契约漂移（infra-1-R3 F1 变异 B：原版死于本管道
# grep -v 空输入 exit 1，同样静默无输出）——解析为空即 fail-loudly。
if [ -z "$dd_list" ]; then
    echo "ERROR: ci.yml SKIP list parsed empty — dd suites would hard-fail without build products (infra-1 ①)" >&2
    exit 1
fi
# 架构替代型 SKIP 脚本：运行时打印 SKIP 且 exit 0
# ③（P00.2）：锚定行首 SKIP 前缀——裸 'superseded by' 会把输出中偶然含该
# 词组的失败/通过套件误判为架构跳过。
arch_skip_re='^SKIP.*superseded by'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0; skip_arch=0; skip_ci=0; skip_nested=0; not_run=0
printf '{\n'
printf '  "code_sha": "%s",\n  "core_pin": "%s",\n' "$code_sha" "$core_pin"
printf '  "resource_version_sha256": "%s",\n  "resource_file_count": "%s",\n' "$resource_fp" "$resource_files"
printf '  "os": "%s %s",\n' "$(uname -s)" "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
printf '  "derived_data": "%s",\n' "${derived_data:-<none>}"
printf '  "suites": [\n'

# Preserve every actual exit code and complete output when requested.
run_captured() {
    if out="$("$@" 2>&1)"; then suite_rc=0; else suite_rc=$?; fi
    if [ -n "$evidence_dir" ]; then
        printf '%s\n' "$out" > "$evidence_dir/$name.log"
        printf '%s\n' "$suite_rc" > "$evidence_dir/$name.exit"
    fi
    return "$suite_rc"
}

first=1
# ②（P00.2；infra-1-R3 F2 重做）：detail 截断须按字符且输出恒为合法 UTF-8。
# infra-1-R3 实测推翻首版方案：macOS/BSD awk substr 恒按字节（与 LC_ALL
# 无关），120 字节会把多字节中文劈开 → 下游 tr "Illegal byte sequence" →
# 整轮盘点中止；而 cut -c 在 UTF-8 环境本按字符、仅 C locale 按字节。
# python3 按码点截断、尾部半字符以 U+FFFD 兜底，任何 locale 下输出恒合法
# （经 stdin.buffer/stdout.buffer 显式字节 IO，编码不随环境漂移）；python3
# 缺席时回退 cut（本仓 .py 套件与 ci.yml 本就依赖 python3，回退仅为截断
# 自身容错，不改变依赖事实）。
trunc() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -I -c 'import sys
data = sys.stdin.buffer.read()[:480].decode("utf-8", "replace")[:120]
sys.stdout.buffer.write(data.encode("utf-8", "replace"))' || cut -c1-120
    else
        cut -c1-120
    fi
}
emit() { # emit <name> <status> <detail>
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    # detail 可能携带脚本输出里的引号/反斜杠，先剔除保证 JSON 合法。
    # LC_ALL=C 字节级 tr：删除集全为 ASCII 单字节（引号/反斜杠/CR/ESC），
    # 不可能劈开多字节序列，对非 UTF-8 输入免疫（infra-1-R3 F2 真修方向）；
    # 合法 UTF-8 输入下与 locale 感知版等价。
    detail="$(printf '%s' "$3" | LC_ALL=C tr -d '"\\\r\033' | LC_ALL=C tr '\n\t' '  ')"
    printf '    {"suite": "%s", "status": "%s", "detail": "%s"}' "$1" "$2" "$detail"
}

# detail 提取 grep 无匹配时管道 exit 1，pipefail 会经赋值静默杀死盘点
# （infra-1-R3 F1 同类）——提取降级为空 detail，不影响状态判定。
for script in "$repo_root"/Tests/run-*.sh "$repo_root"/Tests/run-*.py; do
    name="$(basename "$script")"
    # 排除自身，避免盘点脚本递归执行自己
    [ "$script" = "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ] && continue
    # ④（P00.2）：run-ci-inventory-check.sh 内嵌完整盘点（~40s）且只做结构
    # 一致性检查，按名排除并以 SKIP(nested) 记账。
    if [ "$name" = "run-ci-inventory-check.sh" ]; then
        emit "$name" "SKIP(nested)" "structural CI check excluded by name (infra-1)"
        skip_nested=$((skip_nested+1))
        continue
    fi
    case "$name" in
        *.py) runner=(python3) ;;
        *)    runner=(bash) ;;
    esac
    if printf '%s\n' "$dd_list" | grep -qx "$name"; then
        if [ -n "$derived_data" ] && [ -d "$derived_data/Build/Products/Debug" ]; then
            # blackflow 需要第二个参数（SourcePackages 路径），其余只用 DerivedData
            if [ "$name" = "run-blackflow-start-status-tests.py" ]; then
                run_cmd=("${runner[@]}" "$script" "$derived_data" "$derived_data/SourcePackages")
            else
                run_cmd=("${runner[@]}" "$script" "$derived_data")
            fi
            if run_captured "${run_cmd[@]}"; then
                emit "$name" PASS "$( { printf '%s' "$out" | grep -E 'PASS|passed|checks' | tail -1 || true; } | trunc)"
                pass=$((pass+1))
            else
                emit "$name" FAIL "$(printf '%s' "$out" | tail -1 | trunc)"
                fail=$((fail+1))
            fi
        else
            emit "$name" "NOT_RUN(dd)" "needs DerivedData"
            not_run=$((not_run+1))
        fi
        continue
    fi
    if run_captured "${runner[@]}" "$script"; then
        if printf '%s' "$out" | grep -Eq "$arch_skip_re"; then
            emit "$name" "SKIP(architecture)" "$( { printf '%s' "$out" | grep 'SKIP' | head -1 || true; } | trunc)"
            skip_arch=$((skip_arch+1))
        else
            emit "$name" PASS "$( { printf '%s' "$out" | grep -E 'PASS|passed|checks' | tail -1 || true; } | trunc)"
            pass=$((pass+1))
        fi
    else
        emit "$name" FAIL "$(printf '%s' "$out" | tail -1 | trunc)"
        fail=$((fail+1))
    fi
done
printf '\n  ],\n'
printf '  "summary": {"passed": %d, "failed": %d, "skipped_architecture": %d, "skipped_ci_dd": %d, "skipped_nested": %d, "not_run": %d}\n' "$pass" "$fail" "$skip_arch" "$skip_ci" "$skip_nested" "$not_run"
printf '}\n'
[ "$fail" -eq 0 ]
