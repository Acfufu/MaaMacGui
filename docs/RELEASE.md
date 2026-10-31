# 单版本发版配方

记录 `prw/single` 独立发版的完整流程与已知坑。最后一次实操：**v6.21.0-single.1**（2026-10-31，MaaCore 为 Debug 快照 4d948320d，2026-10-29 构建）。

## 0. 前置条件（MaaCore 环境）

- 在 MAA 主仓库（MaaAssistantArknights）手动构建 xcframework，产出复制到 `$HOME/build/`（**符号链接 xcodebuild 不认，必须 `cp -R`**）：

  ```bash
  # 绕过 build_macos_universal.zsh（脚本 ccache 判断有坑），单架构 Debug：
  cmake -B build-arm64 -GNinja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_ARCHITECTURES=arm64
  cmake --build build-arm64
  cmake --install build-arm64 --prefix install-arm64
  make -f tools/xcframework.makefile MAA_DEBUG=1
  # build/ 产出五个 xcframework → cp -R 到 $HOME/build/
  ```

- 自检：`ls $HOME/build/MaaCore.xcframework/macos-arm64/` 下应有 `libMaaCore.dylib`；`$HOME/build` 偶被清理成空壳目录，构建报 "There is no XCFramework found" 时先查这里，缺了从主仓库 `build/` 重新复制
- `ln -s <主仓库>/resource $HOME/resource`（pbxproj 相对路径按 xcodeproj 上级目录解析）

## 1. 版本号

`Version.xcconfig`（仓库根）：

```
MARKETING_VERSION = 6.21.0-single.N
CURRENT_PROJECT_VERSION = YYYYMMDD
```

- 基数 `X.Y.Z` 跟随上游（当前 6.21.0）
- `MeoAsstMac/Info.plist` 确认无 `SUFeedURL`（防 Sparkle 把本版"升级"回官方版；`SUPublicEDKey` 保留无害）

## 2. 构建

```bash
# zsh noclobber 会拦 > 覆盖已有日志，用 >| 或换日志名
nohup xcodebuild -scheme MAA -configuration Release \
  -derivedDataPath artifacts/rd-single \
  -skipMacroValidation CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build >| artifacts/build-single.log 2>&1 &
```

- `-skipMacroValidation`：JBird 宏校验
- **`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` 必须显式传**：Release 配置默认编 universal（Debug 才 ONLY_ACTIVE_ARCH），本地 Core 只有 arm64 slice，x86_64 会报 symbol not found
- xcodebuild 直接前台跑偶发 "There is no XCFramework found at $HOME/build/..."，先查 0 的自检项，再改用 nohup 后台方式
- **构建期间切勿切分支**
- 产物为 `artifacts/rd-single/Build/Products/Release/MAA.app`（注意是 MAA.app，非 MeoAsstMac.app；含 LaunchAgents plist 与 MacOS/MAAScheduleAgent 内嵌，约 400MB）

## 3. 签名与打包

```bash
APP=artifacts/rd-single/Build/Products/Release/MAA.app

# CODE_SIGNING_ALLOWED=NO 产物无签名，arm64 门禁会拒：ad-hoc 深签
codesign --force --deep -s - "$APP"

hdiutil create -volname MAA -srcfolder "$APP" -ov -format UDZO \
  MAA-vX.Y.Z-single.N-arm64.dmg
```

## 4. Tag 与 Release

```bash
git tag vX.Y.Z-single.N && git push origin vX.Y.Z-single.N

gh release create vX.Y.Z-single.N MAA-vX.Y.Z-single.N-arm64.dmg \
  --title "vX.Y.Z-single.N" --notes-file release-notes-single-vX.Y.Z.md
```

- release notes 必写：MaaCore 快照 commit 与 Debug/Release 属性、arm64-only、ad-hoc 签名的打开方式
- 已知坑：`gh release create` 偶报 422 "asset name already exists"（gh 对草稿的内部重试假象，草稿被回滚）——确认 tag/release 均不存在后，原命令重试即成

## 5. 后续可选

- [ ] Release Core 重编 + 双架构 universal（届时去掉 `ARCHS=arm64` 限定）
- [ ] tag 触发的构建 CI（与上游 #182 承诺的最小 workflow 共用一份，fork 一份即可）
