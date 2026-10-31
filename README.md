# MAA Mac GUI

> [!NOTE]
> **关于本仓库（个人维护 fork）**
>
> 这是 [MaaAssistantArknights/MaaMacGui](https://github.com/MaaAssistantArknights/MaaMacGui) 的个人维护分支：在上游合并队列停滞期间，将社区增强 PR（#161–#181）整合为单一可用版本继续维护与发版。
>
> - **`prw/single`**（默认分支）：集成版主线，在此开发、打 tag 发版（版本号 `X.Y.Z-single.N`），发版配方见 [docs/RELEASE.md](docs/RELEASE.md)
> - **`master`**：上游镜像分支，仅作基线参照，不在此开发
> - 与上游的合并顺序协调：[上游 issue #182](https://github.com/MaaAssistantArknights/MaaMacGui/issues/182)；上游恢复活跃后本分支按需 merge 上游（只 merge 不 rebase，tag 已发布）
>
> **免责声明**：本仓库 Release 为个人构建，采用 ad-hoc 签名（无 Developer ID 证书），首次打开需右键 →「打开」或在「系统设置 → 隐私与安全性」中放行；内嵌 MaaCore 为构建时快照，具体版本见各 Release 说明。代码源自上游 MaaMacGui 仓库。

MAA 的意思是 MAA Assistant Arknights

一款明日方舟游戏小助手

本 Repo 为 MAA 的 Mac GUI 仓库，是 MAA 主仓库的 submodule。 更多关于 MAA 的信息请参考 [MAA Assistant Arknights 主仓库](https://github.com/MaaAssistantArknights/MaaAssistantArknights)。

## 开发

### clone 代码
1. clone [主仓库](https://github.com/MaaAssistantArknights/MaaAssistantArknights)
2. 初始化 submodule `git submodule update --init --recursive`

### Build MAA Core
> 为方便使用，现已将编译过程写成一键脚本。在版本迭代过程中，脚本可能无法及时更新。这时请以 workflow 定义中与 macOS 相关的内容为准

1. 安装依赖 `brew install ninja`
2. 运行位于主仓库的脚本 `MAA_DEBUG=1 ./tools/build_macos_universal.zsh`

> 公招「保留标签」依赖 MaaCore ≥ 6.11.0 引入的 `preserve_tags` 参数，更早版本会静默忽略该设置

🎉 打开 Xcode 可以尝试 build 了

### Q&A

1. 无法获取签名怎么办？
    - 开发时可以在本地更换为个人开发者签名， 但是提交代码时请不要提交这部分修改
2. 各种依赖下载失败/超时？
    - 科学上网
3. 本地测试环境的 Mirror 酱 CDK 和正式版不同？
    - 此功能涉及到钥匙串访问。由于签名问题，测试环境和正式版无法通用。
