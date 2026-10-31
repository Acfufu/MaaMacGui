# 贡献指南

> 本仓库是 [MaaAssistantArknights/MaaMacGui](https://github.com/MaaAssistantArknights/MaaMacGui) 的个人维护 fork，仓库定位、分支说明与免责声明见 [README](README.md)。
> 欢迎一切形式的贡献：Issue 反馈、文档改进、代码 PR 均可。

## 环境与构建

开发环境搭建与 MaaCore 构建见 [README 开发一节](README.md)；`prw/single` 独立发版的完整流程与已知坑见 [docs/RELEASE.md](docs/RELEASE.md)。

要点速记：

- 产物是 `MAA.app`（非 MeoAsstMac.app），Release 构建需显式 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`
- 本仓库 Release 为 ad-hoc 签名，与正式版钥匙串数据不通用
- 提交时不要携带本地个人签名配置的改动

## 分支模型与上游同步

| 分支 | 用途 |
|---|---|
| `prw/single` | 默认分支，集成版主线。在此开发、打 tag 发版（`X.Y.Z-single.N`） |
| `master` | 上游镜像分支，仅作基线参照，不在此开发 |

同步上游（只 merge 不 rebase，`prw/single` 上已有已发布的 tag）：

```bash
git fetch upstream
git checkout prw/single
git merge upstream/master
```

与上游的合并顺序协调见[上游 issue #182](https://github.com/MaaAssistantArknights/MaaMacGui/issues/182)。

## 提交守则

提交信息格式（conventional commits，与本仓库现有历史一致）：

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
| `merge` | 合并上游或合并分支（本仓库固有用法） |

**规则**：

1. **一个 commit 一个目标。** 两个不相关的修复分两个 commit，各自附验证记录——这样回滚可以只回一个，事后也能从历史判断哪个测试守护哪个变更。顺手发现的修复单独开 commit，不混进当前提交。
2. **body 记录验证方式。** subject 说改了什么，body 写「跑了什么、结果如何」。大改动只留一行 subject，事后无法审查；提交前自问：半年后读到这条提交的人能不能复现验证？
3. **fix 尽量附回归测试。** 测试应能在未修复的代码上失败（先还原修复跑一遍确认会红，再恢复修复确认转绿）。确实无法自动化覆盖的（纯 UI 路径等），在 commit body 或 PR 验证记录中说明手工验证方式与原因。
4. **改动要覆盖同类问题的全部位置。** 修复一个 bug 前先搜同类模式：同一个错误处理在几处出现？同样的逻辑在别的 Task/View 有没有？只修报告里那一处，往往意味着第二个 release。
5. **PR 标题遵循同一格式**，内容遵循 PR 模板（验证记录必填，没跑的项明确列出而不是省略）。
6. **新增 Swift 文件记得注册进 `MeoAsstMac.xcodeproj`**（PBXBuildFile / PBXFileReference / 对应相位列表三处），漏注册是本仓库合并构建出过事的坑。

反例可参考 [yetone/magpie 的 code-standards](https://github.com/yetone/magpie/blob/main/docs/code-standards.md)（其 Commits 与 Acceptance criteria 两节的实践，即上述第 1–3 条的出处）。

## Issue 与 PR

- Issue 请使用模板（Bug 反馈 / 需求建议），模板引用的 labels 用 `bash .github/scripts/setup-labels.sh` 一键创建
- 属于上游通用行为的问题建议[直接反馈到上游](https://github.com/MaaAssistantArknights/MaaMacGui/issues)，MaaCore / 资源层面问题到[主仓库](https://github.com/MaaAssistantArknights/MaaAssistantArknights/issues)
- PR 合并前需在本仓库构建通过并附验证记录

## 反哺上游

上游 MaaMacGui 是本仓库的源头，能反哺的改动（bug 修复、通用功能）优先反哺：

- 为上游准备的治理文件中性版（不含 fork 专属信息）在 [docs/upstream-contribution/](docs/upstream-contribution/)，可直接拷入上游 `.github/`
- 修改本仓库 `.github/` 模板时，请同步检查 `docs/upstream-contribution/` 下的对应文件是否需要更新
- 打给上游的 PR 遵循上游仓库自身的约定；涉及与在途 PR 的合并顺序时先看上游 issue #182
