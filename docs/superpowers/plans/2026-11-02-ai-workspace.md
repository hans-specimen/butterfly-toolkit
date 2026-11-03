# Butterfly Toolkit AI 工作区实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development. 本次用户已授权按确认设计实施，无需再次确认设计。

**Goal:** 在现有 macOS 应用落实四个原生 SwiftUI 页面，接入离线推理与真实素材记录。
**Architecture:** Toolkit 保持独立仓库。SwiftUI + Foundation.Process 后台调用 AI 仓库中的轻量命令行适配器。文件夹由用户选择并保存偏好；JSON 传输元数据与处理状态，图片仍位于原目录。训练没有后端，不生成模拟任务。
**Tech Stack:** SwiftUI / AppKit / ImageIO；现有 Python 3.12 环境、Pillow、PyTorch、固定 BiRefNet。
**Spec:** 当前用户完整需求与 AI 仓库 outputs/toolkit-ai-design/20261102 下五张确认截图、Design.swift（仅布局参考）。

## Global Constraints
- 不动现有 ArtDesign 未提交修改，不提交或推送任何仓库。
- 不安装依赖、不下载模型、不训练、不触碰原始 PSD；输入只读，所有推理另存 outputs/toolkit-ai/ 唯一目录。
- 固定模型 5d6b6f8adcb5b417c871b1d84ceaae9871355b7f；数值通过不等于质量验收。
- 未确认对齐或缺少参考答案不可训练；同标本正反面及裁切共用分组用途。
- 本机连接为可选配置，不固化用户绝对路径或样本名。

## Review Focus
- 路径含空格中文、资源丢失、损坏 JSON：显示原因，不能伪装成功。
- 同尺寸但几何错位：以验证记录判断，绝不仅因尺寸一致自动通过。
- 中途切换样本／页面：任务归属于启动时样本；窗口可操作。
- 结果另存及失败：不覆盖现有文件，失败保留可读诊断。
- 缩放、平移与窗口变化：两边共用原图坐标、比例；检查器可隐藏。

## Task 1: AI 命令行适配器
Files: AI scripts/toolkit_bridge.py, scripts/test_toolkit_bridge.py。
- [x] 先写小型测试：catalog 读取真实格式测试记录、未知对齐不放行、拒绝覆盖、输出 RGB/ICC/Alpha 保留；测试不加载大模型。
- [x] 实现 catalog / infer 子命令，复用现有模型加载和推理函数；stdout 逐行 JSON，库日志到 stderr。
- [x] catalog 从现有 run.json、验证与导出记录生成元数据，支持指定 run，默认最新完整测试批次。
- [x] infer 只用已安装模型；状态为真实阶段，结束返回文件路径；输出原尺寸连续 Alpha + PNG。
- [x] 运行测试，再由 Toolkit 实际触发一个已有派生样本推理。

接口（双方严格遵循）:
`python -u -B scripts/toolkit_bridge.py catalog [--run RUN_DIR]` 最后一行 `{"event":"catalog","catalog":{...}}`。
Catalog: `schemaVersion:Int, model:Model, samples:[Sample], runPath:String, reportPath:String?`。
Model: `name:String, revision:String, available:Bool, inputSize:Int, numericStatus:String, numericCheckPath:String?, qualitySummary:String, testedSamples:Int`。
Sample: `id:String, name:String, original:String, reference:String?, alpha:String?, prediction:String?, predictionAlpha:String?, width:Int, height:Int, color:String, alignment:String, alignmentNote:String, rois:[ROI]`。
ROI: `name:String, x:Double, y:Double, width:Double, height:Double`，像素坐标。
`infer --input PATH [--device mps|cpu]` 创建唯一 outputs/toolkit-ai 下目录，最后 `{"event":"completed","input":PATH,"outputDirectory":PATH,"prediction":PATH,"predictionAlpha":PATH}`；进度 `{"event":"status","message":中文}`；错误 `{"event":"error","message":中文}` 并非零退出。

## Task 2: Toolkit 数据与后台任务
Files: Features/AI/AIModels.swift, AIWorkspaceStore.swift, AIProcessRunner.swift; Tests/AIWorkspaceTests.swift。
- [x] 数据模型、分组用途、未对齐阻止逻辑的测试先行。
- [x] 可选择 AI 仓库及测试批次；调用 adapter 并显示真数据。
- [x] 本地持久化素材组、用途、人工答案来源；可导入原图与人工修正 PNG，尺寸验证后要求人工确认对齐与标注。
- [x] 后台 Process 读取 JSON 状态，执行／取消／失败可见；结果绑定原始样本，安全另存拒绝覆盖源。

## Task 3: 四页与原生导航
Files: Views/ContentView.swift; Features/AI/AIWorkspaceView.swift, AIComparisonView.swift, AITrainingViews.swift。
- [x] 左侧分区增加四页，保留所有现有工具入口。
- [x] 双栏原图／人工参考／Alpha、整图／ROI、黑白棋盘、同步缩放平移、缩略图、检查器。
- [x] 素材表与对齐对比、同标本组用途编辑及人工修正参考接入。
- [x] 训练名称／样本选择／基础模型／准备信息／折叠高级设置；训练禁用且原因可见。
- [x] 基础模型与验证记录、已有测试入口；训练版本真实空状态、比较／选择禁用。

## Task 4: 验证与交付
- [x] Xcode 构建和项目测试，保留已有故障说明。
- [ ] 原生 UI 验收部分完成：四页、样本／对比／背景切换、按钮同步缩放、检查器和窗口缩放已实测并截图。鼠标拖动与捏合未实测：自动操作工具拒绝坐标拖拽；详见 docs/AI-WORKSPACE.md。
- [x] App 内实际运行已有派生样本；校验输出原尺寸／ICC／Alpha、输入 hash 未变、第二次另存、错误可见。
- [x] 独立代码审查，修复实质问题；列出完成、未接入、验证和文件清单。
