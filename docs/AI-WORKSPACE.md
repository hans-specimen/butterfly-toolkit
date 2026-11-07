# AI 工作区交付记录（更新于 2026-11-03）

## 提交范围整理：2026-11-03

按用户明确要求，交付版本舍弃素材库与装裱设计：移除其源码、专用测试、导航入口、文档类型注册和设计文档。它们此前仅存在于本地开发分支；本次从远端 `main` 整理提交，不包含这些功能的开发提交。保留 AI 工作区、原有图片工具及项目根目录结构整理。

清理后重新构建，全部 15 项应用测试通过，日志为 `staging/github-delivery-20261103/toolkit-tests.log`；AI 接口 33 项测试、基础推理合成自检和依赖检查通过。下方 37／40 项应用测试及装裱文件保护描述为清理前的实现阶段记录。

## 2026-11-07：照片工作流接口兼容修复

照片工作流与本机 `butterfly-ai/scripts/toolkit_bridge.py` 必须同步更新。旧引擎不接受 `--workspace`，会把目录误识别为命令；单独删除参数也无法读取批次目录中的合成图。

工作流现在传入批次的 `.work` 根目录：`--workspace <批次/.work> infer --input <合成 PNG> --device mps`。引擎仅接受该根目录的 `data/processed/` 中的派生 PNG，结果另存到 `outputs/toolkit-ai/`，拒绝越界符号链接；模型仍从 AI 项目读取。未传入此参数的原 AI 工作区行为不变。

验证：AI 接口 36 项测试通过；应用全套测试通过。使用失败批次第一只标本的正反面 5168 × 3448 合成 PNG 完成真实 MPS 推理，尺寸、ICC、RGB、Alpha、输入哈希及 App 像素校验通过。本次未自动重试整批或回写用户 PSD。重启后打开原批次，使用“更多操作 → 重试失败项”；批次暂停时再点“明确继续批处理”，无需重做景深合成。

## 2026-11-03：独立待抠原图入口

在「AI 抠图」点右上角 ＋「添加待抠图片」，可单选或多选 `.png`、`.jpg`、`.jpeg`，无需人工答案。选择图片后点「开始抠图」，结果仍另存原尺寸透明 PNG。多选是一次导入多张，推理目前逐张发起。

训练素材的 ＋ 仍单独导入原图和人工答案 PNG；普通待抠图片不进入训练表或训练选择。PSD 图层直接导入本步尚未增加。

导入为每张图片建立独立副本：源文件字节副本、方向校正后的推理 PNG 和导入记录。保留 RGB ICC、像素和半透明 Alpha；JPEG 的 EXIF 方向会展开且清除重复旋转标记。普通无色彩配置图片按 sRGB 解释并在界面标注。16 位 PNG、CMYK 等未支持格式，以及无 ICC 的特殊 gamma／色度 PNG 会明确拒绝，不静默降精度或改色。

Python 新增 `import-image`，Swift 通过现有后台进程读取 `imported` 事件。导入部分文件失败时保留成功项并汇总失败原因；记录能重新加载。即使没有既有测试批次，也能连接模型并添加图片。

本轮 40 项应用测试、33 项 Python 测试通过。独立审查中的导入事件遗漏、特殊 PNG 色彩、原图完整性提示、空训练库导航问题均已修正。实际窗口验证和构建日志在 `staging/ai-import-20261103/`。

本轮实际从 Toolkit 载入并处理了 PNG 和 JPEG 两张独立原图，结果分别写入 `20261103-002933-822esauy` 和 `20261103-002820-k66iu3ac`。两份输出均为 3179 × 2544，保留推理原图 RGB 和 ICC，Alpha 包含 256 个值；两张源文件哈希保持不变。JPEG 结果通过系统另存窗口另存，文件与推理结果逐字节一致。推理时背景菜单正常响应；重启后图片和结果仍可载入。

训练页仍仅显示 5 组成对素材，新增无答案图片没有进入训练列表。真实导入损坏 JPEG 会显示「无法识别图片内容，文件可能损坏或并非有效的 PNG／JPEG」，未新增无效行。用户自行加入的帖蛱蝶照片及其结果保留；开始前五个无关未提交文件哈希仍一致。文件校验记录在 AI 仓库 `outputs/toolkit-original-import-verification/verification.json`。

- [JPEG 原图与真实抠图结果](../staging/ai-import-20261103/01-jpeg-result.png)
- [PNG 原图与真实抠图结果](../staging/ai-import-20261103/02-png-result.png)
- [训练素材隔离](../staging/ai-import-20261103/03-training-isolation.png)
- [损坏图片的中文提示](../staging/ai-import-20261103/04-import-error.png)

以下为首轮交付详情；本节新增功能优先于首轮范围说明。

已在现有 Butterfly Toolkit 应用加入原生 SwiftUI 的 AI 抠图、训练素材、模型训练、模型版本四页，保留其他工具入口。Toolkit 与 butterfly-ai 仍为两个独立仓库。

首轮实际启动的构建：`build/AI-Workspace/Butterfly Toolkit.app`；未替换 `/Applications` 中的旧安装。源码交付范围以本文开头的提交整理记录为准。

## 使用与真实功能

- 工具栏「AI 项目」选择本机 butterfly-ai 项目目录；目录和测试批次由本地偏好保存，业务代码不固定机器上的绝对路径。使用该项目已有的 `.venv`、模型文件和测试记录。
- AI 抠图：双栏原图／人工参考／透明度、整图／测试记录中的翅缘区域、黑底／白底／透明格、样本缩略图、共享缩放与观察中心、可折叠检查器。图像在后台解码。
- 推理：后台进程直接调用轻量 Python 适配器，显示真实处理阶段，可取消；支持已有 CPU／MPS 推理。没有伪造百分比或预计时间。当前固定基础模型为 `5d6b6f8adcb5b417c871b1d84ceaae9871355b7f`。
- 每次结果写入 AI 项目的 `outputs/toolkit-ai/` 独立目录，保留原尺寸、RGB、ICC 和连续透明度；包含透明 PNG、Alpha PNG、浮点 Alpha、结果记录。另存使用系统文件选择窗口，拒绝覆盖已有文件。
- 训练素材：读取真实配对、尺寸、对齐证据；可无损复制导入原图与人工答案 PNG，并标记人工精扣或人工修正来源。未确认对齐或明确错位的素材不能选择训练。
- 标本组和训练／验证／测试用途按整组保存，同一只标本的正反面和裁切须填写同一组编号。不能凭文件名或同尺寸自动认定分组和对齐。
- 当前图片、答案或结果与记录的内容校验不一致时，撤销相应对齐认可／隐藏旧结果，并说明原因，避免把旧预测关联到新输入。
- 训练页面提供任务名称、样本选择、基础模型、准备检查和折叠高级设置；模型页面展示现有验证信息、中文测试报告入口和真实空状态。

## 未接入与范围限制

- 真实模型训练、训练任务保存与调度、训练曲线、训练模型比较和选用均未接入，相应操作明确禁用。名称和样本选择只是当前会话的准备信息。
- 不包含应用内人工修图、自动几何对齐、自动识别同一标本、任意图片目录批处理。人工修正后可通过成对 PNG 导入。
- 没有安装依赖、下载模型或运行真实训练；没有新增训练版本。基础模型的白色缘毛质量仍未达人工精修标准，数值对照通过不代表质量验收通过。
- 当前五份记录中四份对齐正常；回纹彩袄蛱蝶仍明确阻止用于训练。既有样本的标本组尚需人工确认，因此训练候选数为零。

## 实际验证

- 最终 Xcode 构建和全部 37 项应用测试通过，其中 8 项覆盖 AI 数据分组、坐标同步、文件保护、后台错误读取和资源失效。Python 适配器 25 项测试通过，现有基础推理脚本自检也通过。
- 实际启动 Toolkit 四页，检查样本切换、三个对比模式、三种背景、整图及不同翅缘区域、按钮同步缩放、检查器开关。检查了 1200 × 852 和 2880 × 1508 窗口的布局。
- 从应用两次启动同一真实派生样本的 MPS 推理。两次分别写入 `20261102-225801-hy2huktj` 与 `20261102-231458-mmben28t`。推理期间切换页面和选中其他样本，窗口保持响应，完成结果仍归属于启动任务的样本。
- 两次输出均为 3179 × 2544，RGB 和 ICC 保持，透明度包含 256 个取值，浮点与 PNG Alpha 对照一致，输入哈希未变。最后一次记录的模型前向等计算为 3.74 秒，**这不是完整处理耗时**。
- 用系统「另存」实际导出 PNG，导出文件与推理结果逐字节相同。拒绝覆盖由应用测试验证。
- 导入独立生成的 96 × 80 合成测试图片，确认未勾选对齐时仍不可训练；其缺失 ICC，实际推理明确报错「原图必须是含 ICC 色彩信息的 RGB／RGBA PNG」。没有生成假结果。该测试行已从工作目录的素材列表移除，证据文件保留。
- 核对五份原始 PSD、25 份既有派生文件／记录的内容、大小和修改时间均未变。Toolkit 开始前五个无关未提交文件的哈希均未变。
- 独立代码审查发现的导入素材失效和历史结果来源校验问题已修复并补充测试。

**尚未完成的手势验收：** 自动操作工具在普通和放大窗口中均以 `windowNotFoundAtPosition` 拒绝坐标拖拽，无法发出实际拖动。共享坐标计算的单元测试、区域切换和按钮缩放通过；鼠标拖动与触控板捏合不能据此宣称实测通过，仍需人工操作确认。

## 真实窗口截图与证据

截图来自上述 Toolkit 构建，不是设计样机。

- [AI 抠图](../staging/ai-workspace/01-cutout.png)
- [缘毛细节](../staging/ai-workspace/02-fringe-detail.png)
- [训练素材与错位状态](../staging/ai-workspace/03-samples.png)
- [训练准备](../staging/ai-workspace/04-training.png)
- [模型版本](../staging/ai-workspace/05-models.png)
- [真实处理状态](../staging/ai-workspace/06-processing.png)
- [真实失败提示](../staging/ai-workspace/07-error-visible.png)
- [训练选择限制](../staging/ai-workspace/08-training-guard.png)
- [透明度](../staging/ai-workspace/10-alpha.png)、[白底原图](../staging/ai-workspace/11-white-original.png)、[透明格](../staging/ai-workspace/12-checker.png)
- [隐藏检查器](../staging/ai-workspace/13-inspector-hidden.png)、[放大窗口](../staging/ai-workspace/14-wide-window.png)
- 应用测试日志：`staging/ai-workspace/final-tests.log`。
- AI 输出校验：AI 仓库 `outputs/toolkit-ui-verification/verification.json`。
- 图片、模型、本地环境、测试证据和构建结果均留在忽略目录，不纳入 Git 提交。

## 本次源码文件清单

| 仓库 | 文件 | 作用 |
|---|---|---|
| Toolkit | `Butterfly Toolkit/Views/ContentView.swift` | 四页导航与工作区入口 |
| Toolkit | `Butterfly Toolkit/App/Butterfly_ToolkitApp.swift` | 默认窗口大小 |
| Toolkit | `Butterfly Toolkit/Features/AI/AIModels.swift` | 数据、标本分组和共享观察坐标 |
| Toolkit | `Butterfly Toolkit/Features/AI/AIProcessRunner.swift` | 后台 Python 进程与事件读取 |
| Toolkit | `Butterfly Toolkit/Features/AI/AIWorkspaceStore.swift` | 项目连接、素材、推理和安全另存 |
| Toolkit | `Butterfly Toolkit/Features/AI/AIFileValidation.swift` | 素材与历史结果内容校验 |
| Toolkit | `Butterfly Toolkit/Features/AI/AIComparisonView.swift` | 图像对比、缩放和缩略图 |
| Toolkit | `Butterfly Toolkit/Features/AI/AIWorkspaceView.swift` | 工作区、检查器与素材导入表单 |
| Toolkit | `Butterfly Toolkit/Features/AI/AITrainingViews.swift` | 素材表、训练准备和版本页 |
| Toolkit | `Butterfly ToolkitTests/AIWorkspaceTests.swift` | AI 数据、文件保护、导入与进程测试 |
| Toolkit | `docs/superpowers/plans/2026-11-02-ai-workspace.md`、`2026-11-03-ai-original-import.md`、本文件 | 实施及验收记录 |
| butterfly-ai | `scripts/toolkit_bridge.py` | catalog／import-image／infer 命令行适配器 |
| butterfly-ai | `scripts/test_toolkit_bridge.py` | 33 项适配器测试 |

素材库与装裱设计相关实现、测试、导航和注册已按用户最新要求从交付版本舍弃。
