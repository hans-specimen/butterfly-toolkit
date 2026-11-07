# 本地版本管理

Toolkit 只在本地开发和自用。本机制解决“当前装的是哪一版、改了什么、哪次代码可用”，不包含 App Store、自动上传、自动更新服务或签名发布。

## 一个来源、两种编号

`Config/Version.xcconfig` 是唯一版本来源，项目 Debug/Release 直接继承。不要在 Xcode Target 的 General / Build Settings 中另填版本覆盖它，也不要在构建命令中覆盖版本设置。关于页读取当前运行应用的 Info.plist，因此修改源码中的版本后，需要重新构建并运行新应用才能看到变化。

| 字段 | 用途 | 例子 |
| --- | --- | --- |
| `MARKETING_VERSION` | 产品版本 `主版本.次版本.修订号` | `1.2.3` |
| `CURRENT_PROJECT_VERSION` | 独立递增的正整数 Build，不随产品版本重置 | `18` |

采用语义化版本的三段数字规则：兼容修复升 patch；兼容新增功能升 minor 并将 patch 清零；不兼容变更升 major 并将 minor/patch 清零。这里的兼容约定包括已保存的批次/配置能否继续使用，以及约定的输入输出行为。视觉调整或内部优化不必升 major。

应用版本与批次 JSON 的 `schemaVersion`、AI 模型版本、处理预设版本分别管理；升应用版本不会自动迁移数据。

## 日常更新：只需升级、记录、构建

在项目根目录使用 Xcode 附带的 Python 3（无 pip 依赖）：

```sh
python3 scripts/version.py show

# 按本次更新选一个命令，勿把下面四项连续执行：
python3 scripts/version.py bump patch  # 1.2.3 (18) → 1.2.4 (19)
python3 scripts/version.py bump minor  # 1.2.3 (18) → 1.3.0 (19)
python3 scripts/version.py bump major  # 1.2.3 (18) → 2.0.0 (19)
python3 scripts/version.py bump build  # 1.2.3 (18) → 1.2.3 (19)

python3 scripts/version.py check
```

每次准备**安装或保留一份不同的新构建**时升级一次，避免两份不同的应用都显示同一编号。尚在同一轮修改中反复编译时不用升号。同一份代码重新验证也不必升号。脚本不会在每次编译时自动写文件，不以提交数量或当前时间推算 Build。

把值得记住的变化写到 `CHANGELOG.md` 的 `Unreleased`，然后用 Xcode 构建、运行。`bump` 只改配置，保留注释，不会提交、打标签、安装或改写变更日志；`check` 只读且允许工作区有未完成改动。

实际安装位置因人而异，安装后可核对该应用（替换为真实路径）：

```sh
python3 scripts/version.py check --app '/Applications/Butterfly Toolkit.app'
```

检查会比较 Bundle ID、产品版本和 Build。它**只验证这些元数据**，不证明二进制与当前源码完全一致，也不能替代实际运行验收。选择归档文件时，可传入 `.xcarchive/Products/Applications/Butterfly Toolkit.app` 的路径。

## 可选：给稳定版本留一个本地标签

不是每次调试、提交或 Build 都需要标签。确认一版适合长期保留时：

1. 完成功能验证和相关测试；版本及 Build 应高于之前的稳定留档。若产品版本已有标签，先升 patch/minor/major。
2. 将这次完成的 Unreleased 条目移到下述格式的新章节，保留 Unreleased 供后续使用。日期填写实际留档日，Build 使用 `show` 的当前值。尚未完成的条目留在 Unreleased。
3. 提交准备留档的代码、版本配置与记录；检查工作区，不把无关或尚未完成的工作混入稳定版本。
4. 执行留档检查；通过后创建附注标签。标签只保存在本地，不自动推送。

例如当前值为 `1.2.3 (18)` 时：

```markdown
## [Unreleased]

## [1.2.3] - 2026-11-07

Build: 18

- 修复……
- 新增……
```

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/version.py check --milestone
git tag -a v1.2.3 -m 'Toolkit 1.2.3 (18)'
```

示例日期、版本和 Build 必须替换成实际值。首次基线可直接记录为 `1.0.0 (1)`，不必为了留档强行升成 `1.0.1`。此时仍需验证、记录、提交，不能把“引入机制”视为整款应用通过验收。

`--milestone` 检查完整 Git 历史、干净工作区（含未跟踪文件）、最新留档章节的版本/有效日期/Build/非空说明，以及相对所有本地 `vX.Y.Z` 标签的版本和 Build 递增。已有同名标签仅在它是指向当前提交的附注标签时允许重复检查。标签对应提交内也必须保存同一份版本配置；`vX.Y.Z` 命名保留给本机制，不用于临时标签。

检查不联网。如果以后在多个克隆或电脑间同步，留档前主动 `git fetch --tags` 并核对远端，合并后重新检查版本和 Build；单台电脑无需为此增加网络步骤。忽略的构建目录、未纳入仓库的 AI 模型和外部数据不在检查范围内。多个分支并行升号可能分配相同编号，最终合并/安装前需重新升级并检查。

留档后可另存已验证 `.app` 或 Xcode Archive，文件名带版本与 Build，例如 `Butterfly-Toolkit-1.2.3-build18.app`。如需精确找回某个安装包，应保留该产物；Git 标签保存代码状态，不保存外部工具、模型和完整构建环境。

## 找回旧代码

```sh
git tag --list 'v*' --sort=-version:refname
git show v1.2.3
git worktree add --detach ../butterfly-toolkit-v1.2.3 v1.2.3
```

在独立目录打开旧工程，当前未完成工作可继续保留。不要移动或覆盖已有稳定标签。已知有问题的旧版修复后以新版本留档。

旧应用不保证能读取新版生成的数据。回退前备份批次清单与工作文件，避免直接用旧版继续写入重要的新数据。

## 维护与验证

脚本只依赖 Python 3 标准库、Git 和 macOS 的 `plutil`；不修改业务代码、模型或数据。普通 `check` 会发现 Xcode 中的重复/条件版本覆盖以及脱离统一配置的引用。如果未来要引入其他 xcconfig，请同时调整继承关系与检查，并用真实构建产物验证。

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/version.py check
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration Release -derivedDataPath /tmp/toolkit-version-build \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/version.py check \
  --app '/tmp/toolkit-version-build/Build/Products/Release/Butterfly Toolkit.app'
```

以上未签名构建命令用于配置验证；正常本地运行仍沿用项目现有 Xcode 设置。

规则依据：[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html)、Apple 的 [版本字段](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)、[Build 字段](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion)及 [Xcode 配置文件](https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project)。
