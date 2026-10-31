<!-- PR 标题请遵循 CONTRIBUTING.md 的提交守则：<type>(<scope>): 描述 -->

## 变更说明

<!-- 做了什么、为什么这么做。一个 PR 一个目标，与本次目标无关的改动请另开 PR -->

## 关联

<!-- 关联的 Issue / PR 编号（Closes #xxx） -->

## 验证记录

<!-- 写明跑了什么、结果如何；没跑的也要明确列出，不要省略。
     例：
     - [x] xcodebuild -scheme MAA build 通过
     - [x] xcodebuild test 全量通过（N 个套件）
     - [x] 手工验证路径：……
     - [ ] 未验证：……（原因） -->

## 自检清单

- [ ] 提交信息符合 [CONTRIBUTING.md](../CONTRIBUTING.md) 提交守则，一个 commit 一个目标
- [ ] fix 类变更附有能在未修复代码上失败的回归测试，或在验证记录中说明为何没有
- [ ] 新增文件已注册进 `MeoAsstMac.xcodeproj`（PBXBuildFile / PBXFileReference / 相位列表三处）
