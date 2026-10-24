# 开发签名与屏幕录制授权

日期：2026-10-25。

## 现象

用 Xcode 开发时，每次改代码重新运行 ScreenCutter，系统都像第一次截屏一样要求屏幕录制权限：

- 菜单里再次出现「未开启屏幕录制权限」；
- 系统设置里 ScreenCutter 的开关看着是打开的，但应用仍然认为没有授权；
- 必须先把旧的 ScreenCutter 条目删掉，再重新添加当前构建，开关才即时生效。

## 原因

此前工程的 Debug/Release 都写着：

```
CODE_SIGN_IDENTITY = "-"
CODE_SIGN_STYLE = Manual
```

`-` 是 **ad-hoc 签名**。TCC（屏幕录制授权）保存的不是“应用名”，而是应用的 **designated requirement**。ad-hoc 签名的 requirement 是 cdhash：

```
designated => cdhash H"f7814f3b..."
```

每次重新编译，cdhash 都会变，TCC 就认为这是一个新应用。旧条目还留在系统设置里，开关也是旧的，所以会出现“开关是开的，但新构建不生效”的现象。

## 现在的配置

签名设置集中在 `Config/Signing.xcconfig`，这个文件提交进仓库，但不含任何个人信息：

```xcconfig
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -

// 本机覆盖；没有这个文件也不会报错
#include? "Signing.local.xcconfig"
```

本机的证书名和 Team ID 放在 `Config/Signing.local.xcconfig`，这个文件 **不提交**（已加入 `.gitignore`）：

```xcconfig
CODE_SIGN_IDENTITY = Apple Development: 你的名字 (TEAMID)
DEVELOPMENT_TEAM = TEAMID
```

`#include?` 的问号表示文件不存在也不报错。新克隆或 CI 没有本地文件时会回退到 ad-hoc：仍然能编译和跑测试，只是每次重新构建都要重新授权。要在本机跨构建保留授权，创建这个文件即可。

确认本机配置生效：

```sh
xcodebuild -project ScreenCutter.xcodeproj \
  -target ScreenCutter -configuration Debug -showBuildSettings \
  | grep CODE_SIGN_IDENTITY
```

- 输出 `-`：没读到本地文件，走 ad-hoc；
- 输出 `Apple Development: ...`：读到了，签名会使用该证书。

签名后检查 designated requirement：

```sh
codesign -d -r- ScreenCutter.app
```

现在应该是基于证书的 requirement，而不是 cdhash：

```
designated => identifier "top.9191apps.screencutter"
  and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: ..."
  and certificate 1[field.1.2.840.113635.100.6.2.1]
```

同一证书重新签名后，这段 requirement 不变；TCC 授权原则上可以跨构建保留。

## 一次性迁移

从 ad-hoc 切换到证书签名，旧条目不能继续用，需要做一次干净迁移：

1. 完全退出 ScreenCutter。
2. 只清理 ScreenCutter 的旧授权：
   ```sh
   tccutil reset ScreenCapture top.9191apps.screencutter
   ```
3. 确认 `Config/Signing.local.xcconfig` 已填好，`codesign -d -r-` 不是 cdhash。
4. 用 Xcode 重新运行 scheme ScreenCutter。
5. 触发一次「截取区域」；系统会弹「ScreenCutter 想要录制此电脑的屏幕和音频」。
6. 在「系统设置 → 隐私与安全性 → 录屏与系统录音」里找到 ScreenCutter，打开开关。如果列表里没有，点列表下方的 **+**，选择当前构建的 `ScreenCutter.app`，再打开开关。
7. 系统提示需要退出应用时，选择退出并重新打开。
8. 之后再改代码、重新构建、重新运行，**不要再删条目或重新添加**；先验证 `codesign -d -r-` 的 requirement 没有变，权限应继续有效。

迁移过程中如果列表里同时有“旧 ScreenCutter”和“新 ScreenCutter”，用 **−** 删掉旧条目，只保留当前构建添加的那一条。

## 换机器或没有 Apple Development 证书

- 在新机器上创建 `Config/Signing.local.xcconfig`，填入自己的证书名和 Team ID；证书名可以在「钥匙串访问 → 我的证书」里看到。
- 没有 Apple Development 证书时，可以创建一个自签名 **Code Signing** 证书（钥匙串访问 → 证书助理 → 创建证书，证书类型选“代码签名”），把证书名填进 `CODE_SIGN_IDENTITY`，并删掉 `DEVELOPMENT_TEAM`。自签名证书同样能提供稳定的 designated requirement。
- 不要把 `Signing.local.xcconfig` 提交上去，也不要把证书名写回 `Signing.xcconfig`；这两个文件一旦进仓库，其他机器反而不能直接使用。
- CI 不需要本地文件，保持 `CODE_SIGN_IDENTITY = -` 即可；屏幕录制授权本来就不适合在无界面的 CI 里验证。

## 测试命令

Xcode 27 的 debug dylib 和 hosted test target 在当前工程里会冲突（`Multiple commands produce ...` 或找不到 `ScreenCutter.debug.dylib`）。本地跑测试时加：

```sh
xcodebuild -project ScreenCutter.xcodeproj -scheme ScreenCutter \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DD4 \
  ENABLE_DEBUG_DYLIB=NO test
```

这与签名无关；签名问题只看 `codesign -d -r-` 的 designated requirement。
