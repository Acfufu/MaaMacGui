# 上游治理文件中性版

本目录是准备反哺 [MaaAssistantArknights/MaaMacGui](https://github.com/MaaAssistantArknights/MaaMacGui) 的治理文件**中性版**：内容不含本 fork 的专属信息（单版本号、分支模型、反哺说明等），可直接提交给上游。

## 打包方式

拷入上游仓库对应位置（均为上游缺失的纯增量文件，零冲突）：

```
.github/ISSUE_TEMPLATE/bug-report.yaml          ← ISSUE_TEMPLATE/bug-report.yaml
.github/ISSUE_TEMPLATE/feature-request.yaml     ← ISSUE_TEMPLATE/feature-request.yaml
.github/ISSUE_TEMPLATE/config.yml               ← ISSUE_TEMPLATE/config.yml
.github/PULL_REQUEST_TEMPLATE.md                ← PULL_REQUEST_TEMPLATE.md
CONTRIBUTING.md                                 ← CONTRIBUTING.md
.github/scripts/setup-labels.sh                 ← 需一并带上（模板引用的 labels 靠它创建）
```

上游 PR 提交后，labels 需仓库维护者执行一次脚本（或手动建标）：`bug`、`enhancement`、`question`、`mac`、`need-more-info`、`upstream-related`。

## 与本仓库 `.github/` 版本的差异

| 文件 | 差异点 |
|---|---|
| `bug-report.yaml` | 获取渠道选项去掉「本仓库 Release」 |
| `feature-request.yaml` | 无差异 |
| `config.yml` | 去掉指向上游 MaaMacGui 的 contact link（对上游而言即本仓库） |
| `PULL_REQUEST_TEMPLATE.md` | 去掉「反哺上游」一节 |
| `CONTRIBUTING.md` | 去掉分支模型、反哺上游两节及 fork 定位引言 |

## 维护规则

修改本仓库 `.github/` 模板或 `CONTRIBUTING.md` 时，同步检查本目录对应文件是否需要跟进，保持上表差异之外的内容一致。
