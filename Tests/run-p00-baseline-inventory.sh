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
dd_line="$(grep -o 'SKIP="[^"]*"' "$ci_yml" | head -1)"
# ①（P00.2/健壮性 backlog）：SKIP=" 字面量是本清单与 ci.yml 的结构契约——
# 格式漂移时必须 fail-loudly，否则 dd 清单静默为空、四个 dd 套件无构建产物
# 硬跑必败且表现为无关失败。
if [ -z "$dd_line" ]; then
    echo "ERROR: ci.yml SKIP=\" literal not found — format drift breaks dd-list parsing (infra-1 ①)" >&2
    exit 1
fi
dd_list="$(printf '%s' "${dd_line#SKIP=\"}" | sed 's/"$//' | tr ' ' '\n' | grep -v '^$')"
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
# ②（P00.2）：detail 截断按字符（en_US.UTF-8 awk substr）——C locale 的
# trunc 按字节劈多字节中文；控制字符（\r/ESC）随引号/反斜杠一并剔除
# 保证 JSON 合法。
trunc() { LC_ALL=en_US.UTF-8 awk '{print substr($0, 1, 120)}'; }
emit() { # emit <name> <status> <detail>
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    # detail 可能携带脚本输出里的引号/反斜杠，先剔除保证 JSON 合法
    detail="$(printf '%s' "$3" | tr -d '"\\\r\033' | tr '\n\t' '  ')"
    printf '    {"suite": "%s", "status": "%s", "detail": "%s"}' "$1" "$2" "$detail"
}

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
                emit "$name" PASS "$(printf '%s' "$out" | grep -E 'PASS|passed|checks' | tail -1 | trunc)"
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
            emit "$name" "SKIP(architecture)" "$(printf '%s' "$out" | grep 'SKIP' | head -1 | trunc)"
            skip_arch=$((skip_arch+1))
        else
            emit "$name" PASS "$(printf '%s' "$out" | grep -E 'PASS|passed|checks' | tail -1 | trunc)"
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
