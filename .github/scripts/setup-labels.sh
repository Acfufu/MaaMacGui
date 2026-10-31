#!/usr/bin/env bash
# 一键创建 ISSUE_TEMPLATE 引用的 labels（存在则更新为该定义）。
# 用法：在本仓库根目录，gh 已登录后运行：bash .github/scripts/setup-labels.sh
set -euo pipefail

# gh 对 fork 仓库默认以「上游」为 base repo，这里强制取 origin，
# 避免把 labels 建到上游仓库去（GH_REPO 已由外部指定时尊重之）
if [[ -z "${GH_REPO:-}" ]]; then
  REPO_URL=$(git remote get-url origin)
  GH_REPO="${REPO_URL#*github.com[:/]}"
  export GH_REPO="${GH_REPO%.git}"
fi

create() {
  gh label create "$1" --description "$2" --color "$3" --force
}

create bug             "缺陷反馈"                        "d73a4a"
create enhancement     "需求建议"                        "a2eeef"
create question        "使用咨询"                        "d876e3"
create mac             "macOS 平台专属问题"              "0e8a16"
create "need-more-info" "信息不足，等待反馈者补充"        "fbca04"
create "upstream-related" "需上游处理或计划反哺上游"      "1d76db"

echo "labels 就绪。"
