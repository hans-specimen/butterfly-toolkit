# Toolkit 本地版本管理设计

## 目标与约束

用户确认：本地开发、自己使用，不发布 App Store。需要识别当前安装版本、记录可用更新、找回稳定代码。沿用 Xcode 和 Git，不增加第三方依赖、后台服务、自动上传或签名流程；普通编译不写回仓库。

## 方案比较

- 继续在 Xcode 中手工改数值：最少文件，但 Debug/Release 容易不同步，缺少检查。
- **采用统一 xcconfig + Python 标准库小脚本 + 变更日志 + 可选本地标签**：配置直接被 Xcode 使用，日常只需一个升级命令，符合本地自用规模。
- 自动生成每次构建编号、接入自动发布平台：对当前需求增加环境依赖和维护成本，不采用。

第二项为实现选择；用户确认的是本地自用范围，不代表其要求自动发布。

## 规则与边界

- `Config/Version.xcconfig` 是版本唯一来源。项目 Debug/Release 共同继承；关于页从产物 Info.plist 读取，不伪造默认版本。
- 当前 `1.0 (1)` 规范为 `1.0.0 (1)`，只是管理基线，尚未留档或宣称完成产品质量验收。
- 产品版本 `MAJOR.MINOR.PATCH`：不兼容的数据/工作流约定升 major，兼容新增功能升 minor，兼容修复升 patch；minor/major 重置其下级数字。
- Build 为独立递增正整数，不随产品版本重置。准备安装或保留一份新构建时升级；普通调试编译不升级。不在 Bundle 数字版本中加入 beta、日期或 Git 哈希。
- `scripts/version.py show / bump {major,minor,patch,build} / check`；升级只修改版本配置，四种升级均使 Build +1。
- `check --milestone` 用于可选的稳定版本留档：干净且完整的 Git 仓库、当前版本对应的日期/Build/非空变更记录、相对本地版本标签的版本与 Build 递增。已有同名标签仅在它是指向当前提交的附注标签时接受。
- 可选 `check --app /path/to.app` 对照真实产物的 Bundle ID、版本和 Build。它只验证这些字段，不证明二进制来自当前提交。
- `CHANGELOG.md` 的 Unreleased 记录在制变更；稳定版本人工确认记录后创建本地附注标签 `vX.Y.Z`。不自动提交、打标签或联网。
- 工作流 JSON schema、AI 模型版本与应用版本独立。旧版能否读取新版数据需单独验证；回退代码不等于迁移数据。

## 验证

在临时 Git 仓库中测试升级、错误配置、脏工作区、版本/Build 倒退、标签复用和产物不一致；检查 Xcode 两种配置解析，构建 Debug/Release 并读回 Info.plist。现有照片工作流改动保留。
