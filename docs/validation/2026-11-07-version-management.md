# 本地版本管理验证 — 2026-11-07

> 历史验证记录：结果与命令以当时环境为限。当前操作见 [版本管理](../VERSIONING.md)，日常检查见 [测试指南](../TESTING.md)。

## 范围

验证统一版本配置、显式升级脚本、留档保护与应用产物版本。用户确认本地自用，不发布 App Store。本轮未安装应用、未提交或打稳定标签。

现有 `PhotoshopWorkflowBridge.swift`、`WorkflowBridgeTests.swift` 和照片工作流性能验证文档是开始前已有改动，本轮未编辑；构建使用当前工作区，包含这些已有改动。

## 脚本

`python3 -m unittest discover -s scripts/tests -v`：**14 项通过**。测试使用独立临时 Git 仓库，覆盖四种升级的进位与 Build、非法/重复配置不写入、Xcode 覆盖与引用缺失、脏工作区、浅历史、变更记录与 Build 不匹配、标签复用、产品版本和 Build 倒退、轻量标签、同名分支与产物字段不匹配。

初次编写测试时，成功路径因缺少入口而失败；之后新增的单字符说明用例暴露了过严的非空校验，修正后全部通过。并非每个拒绝用例都曾单独观察到 RED。

当前工作区 `python3 scripts/version.py check` 通过；`check --milestone` 按预期拒绝尚未提交的工作区。真实仓库未创建任何测试标签。

## Xcode 与实际产物

Debug、Release 的 `xcodebuild -showBuildSettings -json` 均解析为 `MARKETING_VERSION=1.0.0`、`CURRENT_PROJECT_VERSION=1`。

两个配置均执行以下构建（分别替换 CONFIGURATION）：

```sh
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration CONFIGURATION -destination 'platform=macOS' \
  -derivedDataPath /tmp/toolkit-version-validation-CONFIGURATION \
  CODE_SIGNING_ALLOWED=NO build
```

首次受限环境下 SwiftUI 宏插件被 `sandbox_apply: Operation not permitted` 阻止，两个构建退出 65。使用正常本机执行权限重试后，**Debug / Release 均 BUILD SUCCEEDED，退出 0**。重试日志分别为 `/tmp/toolkit-version-build-Debug-retry.log` 与 `/tmp/toolkit-version-build-Release-retry.log`。AppIntents 元数据提取被跳过的提示仍存在（项目没有该依赖），不影响构建。

两份 `.app` 均通过 `python3 scripts/version.py check --app <path>`，读回的 Bundle ID 为 `com.hans.Butterfly-Toolkit`、版本 `1.0.0`、Build `1`：

- `/tmp/toolkit-version-validation-Debug/Build/Products/Debug/Butterfly Toolkit.app`
- `/tmp/toolkit-version-validation-Release/Build/Products/Release/Butterfly Toolkit.app`

独立审查检查了脚本、Xcode 继承及说明，未发现重要缺陷。`git diff --check` 通过。

## 未验证范围

没有运行照片工作流等既有业务测试全量，也没有进行关于页目视验收或业务流程实测。本次结果只证明版本机制与两种配置可构建，不代表照片处理质量或整款应用的稳定版本验收。未签名产物只用于本次验证，未替换已安装应用。
