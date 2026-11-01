#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${1:-}"
# P00.2 基线盘点：代码/Core/资源指纹 + 全部测试套件清单与运行结果。
# 输出 JSON（stdout）：每套件 status ∈ PASS/FAIL/SKIP(architecture)/NOT_RUN(dd)，
# 汇总 passed/failed/skipped_architecture/not_run。任一套件 FAIL 时退出码非 0。
ci_yml="$repo_root/.github/workflows/ci.yml"
pin_file="$repo_root/MAACORE_PIN"
resource_dir="$repo_root/../../resource"

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
dd_list="$(printf '%s' "${dd_line#SKIP=\"}" | sed 's/"$//' | tr ' ' '\n' | grep -v '^$')"
# 架构替代型 SKIP 脚本：运行时打印 SKIP 且 exit 0
arch_skip_re='superseded by'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; fail=0; skip_arch=0; skip_ci=0; not_run=0
printf '{\n'
printf '  "code_sha": "%s",\n  "core_pin": "%s",\n' "$code_sha" "$core_pin"
printf '  "resource_version_sha256": "%s",\n  "resource_file_count": "%s",\n' "$resource_fp" "$resource_files"
printf '  "os": "%s %s",\n' "$(uname -s)" "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
printf '  "derived_data": "%s",\n' "${derived_data:-<none>}"
printf '  "suites": [\n'

first=1
emit() { # emit <name> <status> <detail>
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    # detail 可能携带脚本输出里的引号/反斜杠，先剔除保证 JSON 合法
    detail="$(printf '%s' "$3" | tr -d '"\\' | tr '\n\t' '  ')"
    printf '    {"suite": "%s", "status": "%s", "detail": "%s"}' "$1" "$2" "$detail"
}

for script in "$repo_root"/Tests/run-*.sh "$repo_root"/Tests/run-*.py; do
    name="$(basename "$script")"
    # 排除自身，避免盘点脚本递归执行自己
    [ "$script" = "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ] && continue
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
            if out="$("${run_cmd[@]}" 2>&1)"; then
                emit "$name" PASS "$(printf '%s' "$out" | grep -E 'PASS|passed|checks' | tail -1 | cut -c1-120)"
                pass=$((pass+1))
            else
                emit "$name" FAIL "$(printf '%s' "$out" | tail -1 | cut -c1-120)"
                fail=$((fail+1))
            fi
        else
            emit "$name" "NOT_RUN(dd)" "needs DerivedData"
            not_run=$((not_run+1))
        fi
        continue
    fi
    if out="$("${runner[@]}" "$script" 2>&1)"; then
        if printf '%s' "$out" | grep -Eq "$arch_skip_re"; then
            emit "$name" "SKIP(architecture)" "$(printf '%s' "$out" | grep 'SKIP' | head -1 | cut -c1-120)"
            skip_arch=$((skip_arch+1))
        else
            emit "$name" PASS "$(printf '%s' "$out" | grep -E 'PASS|passed|checks' | tail -1 | cut -c1-120)"
            pass=$((pass+1))
        fi
    else
        emit "$name" FAIL "$(printf '%s' "$out" | tail -1 | cut -c1-120)"
        fail=$((fail+1))
    fi
done
printf '\n  ],\n'
printf '  "summary": {"passed": %d, "failed": %d, "skipped_architecture": %d, "skipped_ci_dd": %d, "not_run": %d}\n' "$pass" "$fail" "$skip_arch" "$skip_ci" "$not_run"
printf '}\n'
[ "$fail" -eq 0 ]
