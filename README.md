# Butterfly Toolkit

本地自用的 macOS 蝴蝶图片处理工具，使用 SwiftUI 开发。用 Xcode 打开 `Butterfly Toolkit.xcodeproj`，选择 `Butterfly Toolkit` scheme 运行。

## 版本管理

版本只维护在 `Config/Version.xcconfig`，Xcode 的 Debug、Release 和“关于”页共同使用。

```sh
python3 scripts/version.py show
python3 scripts/version.py bump patch
python3 scripts/version.py check
```

`bump patch` 用于修复更新；新增功能用 `minor`，不兼容变更用 `major`，同一版本的新本地构建用 `build`。每种升级都会让 Build 加一，普通编译不会改变版本。

详细操作见 [本地版本管理](docs/VERSIONING.md)，更新记录见 [CHANGELOG](CHANGELOG.md)。AI 工作区说明见 [AI-WORKSPACE](docs/AI-WORKSPACE.md)。
