# 贡献指南

MAA 的 Mac GUI（MeoAsstMac），是 [MAA 主仓库](https://github.com/MaaAssistantArknights/MaaAssistantArknights)的 submodule。环境搭建见 [README 开发一节](../README.md)。

## 提交守则

提交信息格式（conventional commits）：

```
<type>(<可选 scope>): 中文 subject
```

**type 取值**：

| type | 含义 |
|---|---|
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `docs` | 纯文档 |
| `refactor` | 重构，行为不变 |
| `perf` | 性能优化 |
| `test` | 测试 |
| `build` | 构建系统、工程配置（xcodeproj、xcconfig 等） |
| `ci` | CI workflow |
| `chore` | 其余杂项 |
| `revert` | 回滚 |
| `merge` | 合并（合并提交可沿用 GitHub 默认信息或自行概述） |

**规则**：

1. **一个 commit 一个目标。** 两个不相关的修复分两个 commit，各自附验证记录——这样回滚可以只回一个，事后也能从历史判断哪个测试守护哪个变更。顺手发现的修复单独开 commit，不混进当前提交。
2. **body 记录验证方式。** subject 说改了什么，body 写「跑了什么、结果如何」。大改动只留一行 subject，事后无法审查；提交前自问：半年后读到这条提交的人能不能复现验证？
3. **fix 尽量附回归测试。** 测试应能在未修复的代码上失败（先还原修复跑一遍确认会红，再恢复修复确认转绿）。确实无法自动化覆盖的（纯 UI 路径等），在 commit body 或 PR 验证记录中说明手工验证方式与原因。
4. **改动要覆盖同类问题的全部位置。** 修复一个 bug 前先搜同类模式：同一个错误处理在几处出现？同样的逻辑在别的 Task/View 有没有？只修报告里那一处，往往意味着第二个 release。
5. **PR 标题遵循同一格式**，内容遵循 PR 模板（验证记录必填，没跑的项明确列出而不是省略）。
6. **新增 Swift 文件记得注册进 `MeoAsstMac.xcodeproj`**（PBXBuildFile / PBXFileReference / 对应相位列表三处），漏注册会在别人本地构建时才暴露。

## Issue 与 PR

- Issue 请使用模板（Bug 反馈 / 需求建议）；模板引用的 labels 首次需要 `bash .github/scripts/setup-labels.sh` 一键创建（需 gh 已登录）
- 属于 MaaCore / 资源层面的问题到[主仓库反馈](https://github.com/MaaAssistantArknights/MaaAssistantArknights/issues)，使用咨询可去[主仓库 Discussions](https://github.com/MaaAssistantArknights/MaaAssistantArknights/discussions)
- PR 合并前需构建通过并附验证记录
