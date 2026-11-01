#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ci_yml="$repo_root/.github/workflows/ci.yml"
release_yml="$repo_root/.github/workflows/release.yml"
core_action="$repo_root/.github/actions/maacore-setup/action.yml"
pin_file="$repo_root/MAACORE_PIN"

# P00.3 CI 与构建盘点：结构一致性检查（不触发构建）。
# 任一检查失败退出码非 0，并给出失败项清单；全部通过输出 JSON 盘点记录。

failures=()
check() { # check <描述> <命令...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  ok    %s\n' "$desc" >&2
    else
        printf '  FAIL  %s\n' "$desc" >&2
        failures+=("$desc")
    fi
}

echo "== CI 结构一致性 ==" >&2
[ -f "$ci_yml" ] || { echo "missing ci.yml"; exit 1; }
dd_line="$(grep -o 'SKIP="[^"]*"' "$ci_yml" | head -1)"
dd_list="$(printf '%s' "${dd_line#SKIP=\"}" | sed 's/"$//' | tr ' ' '\n' | grep -v '^$')"
# case 匹配用空格分隔形态
dd_case="$(printf '%s\n' "$dd_list" | tr '\n' ' ')"

for name in $dd_list; do
    check "ci SKIP 名单成员存在: $name" test -f "$repo_root/Tests/$name"
    # DerivedData 依赖脚本必须声明参数用法或读取 Build/Products/Debug
    check "ci SKIP 成员声明 dd 依赖: $name" grep -qE 'Build/Products/Debug|Usage: .0 .DerivedData|sys.argv\[1\]' "$repo_root/Tests/$name"
done

# 非 SKIP 名单的套件必须自包含：不得硬性要求位置参数
for script in "$repo_root"/Tests/run-*.sh "$repo_root"/Tests/run-*.py; do
    name="$(basename "$script")"
    case " $dd_case " in *" $name "*) continue ;; esac
    case "$name" in run-p00-baseline-inventory.sh|run-ci-inventory-check.sh) continue ;; esac
    case "$name" in
        *.sh) arg_pat='\$\{1:\?' ;;
        *.py) arg_pat='sys\.argv\[1\]' ;;
    esac
    check "自包含(无必选参数): $name" sh -c "! grep -qE '$arg_pat' '$script'"
done

# 三个架构替代型 SKIP 脚本：无参运行必须 exit 0 且打印 superseded
for name in run-task-startup-tests.sh run-achievement-timer-tests.py run-task-operation-tests.py; do
    case "$name" in *.py) runner=(python3) ;; *) runner=(bash) ;; esac
    if out="$(cd "$repo_root" && "${runner[@]}" "Tests/$name" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'superseded by'; then
        printf '  ok    架构 SKIP 自证: %s\n' "$name" >&2
    else
        printf '  FAIL  架构 SKIP 自证: %s (rc=%s)\n' "$name" "$rc" >&2
        failures+=("架构 SKIP 自证: $name")
    fi
done

echo "== 发布链守卫 ==" >&2
check "Info.plist 无 SUFeedURL（release 守卫前提）" sh -c "! grep -q SUFeedURL '$repo_root/MeoAsstMac/Info.plist'"
check "Version.xcconfig 有 MARKETING_VERSION 行" grep -q '^MARKETING_VERSION = ' "$repo_root/Version.xcconfig"
check "Version.xcconfig 有 CURRENT_PROJECT_VERSION 行" grep -q '^CURRENT_PROJECT_VERSION = ' "$repo_root/Version.xcconfig"
check "MAACORE_PIN 为 40 位 hex" sh -c "grep -qE '^[0-9a-f]{40}[[:space:]]*$' '$pin_file'"
check "maacore-setup action 就位" test -f "$core_action"

echo "== 盘点记录 ==" >&2
# pin 缺失时记录 FAIL 并降级为占位，保证失败清单仍会输出
if [ -f "$pin_file" ]; then
    pin="$(tr -d '[:space:]' < "$pin_file")"
else
    pin="MISSING"
fi
# on: 块止于下一个顶格键；只取两空格缩进的触发器名（不含其嵌套键）
triggers_of() {
    awk '/^on:/{flag=1;next} flag && /^[^ ]/{exit} flag && /^  [A-Za-z0-9_-]+:$/{gsub(/[: ]/,"");print}' "$1" | tr '\n' ',' | sed 's/,$//'
}
# jobs: 块内两空格缩进的作业键（含下划线）
jobs_of() {
    awk '/^jobs:/{flag=1;next} flag && /^[^ ]/{exit} flag && /^  [A-Za-z0-9_-]+:$/{gsub(/[: ]/,"");print}' "$1" | tr '\n' ',' | sed 's/,$//'
}
printf '{\n'
printf '  "ci_triggers": "%s",\n' "$(triggers_of "$ci_yml")"
printf '  "ci_jobs": "%s",\n' "$(jobs_of "$ci_yml")"
printf '  "ci_skip_dd_suites": "%s",\n' "$(printf '%s' "$dd_list" | tr '\n' ' ' | sed 's/ $//')"
printf '  "arch_skip_suites": "run-task-startup-tests.sh run-achievement-timer-tests.py run-task-operation-tests.py",\n'
printf '  "release_triggers": "%s",\n' "$(triggers_of "$release_yml")"
printf '  "release_steps": "%s",\n' "$(grep -E '^      - name: ' "$release_yml" | sed 's/^      - name: //;s/ /_/g' | tr '\n' ',' | sed 's/,$//')"
printf '  "core_pin": "%s",\n' "$pin"
printf '  "actions": "%s",\n' "$(grep -ohE 'uses: [^ ]+' "$ci_yml" "$release_yml" | sed 's/^uses: //' | sort -u | tr '\n' ' ')"
printf '  "build_cmd_debug": "xcodebuild -scheme MAA -configuration Debug -derivedDataPath <dd> -skipMacroValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build",\n'
printf '  "build_cmd_release": "xcodebuild -scheme MAA -configuration Release -derivedDataPath <dd> -skipMacroValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build",\n'
printf '  "signing": "ad-hoc (codesign --force --deep -s -)",\n'
printf '  "checks_failed": %d\n' "${#failures[@]}"
printf '}\n'

if [ "${#failures[@]}" -gt 0 ]; then
    printf '失败项:\n' >&2
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
fi
echo "CI inventory: all checks passed" >&2
