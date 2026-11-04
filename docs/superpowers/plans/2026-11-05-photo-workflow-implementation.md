# 分阶段照片工作流 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现可整批暂停检查、实时旋转裁切、分别确认高清与 4K、可恢复导出派生图的收藏照片流水线。

**Architecture:** 原生 SwiftUI 页面与可持久化的阶段状态机驱动已有 Photoshop 堆栈及 AI runner；新增 Photoshop 角色层适配器、蒙版几何分析与统一输出渲染。所有 Photoshop 操作共享串行租约，交互预览在本地进行，确认后保存并读回 PSD。每面和每项资产分别绑定源版本，避免重试时重做全部任务。

**Tech Stack:** 现有 Swift／SwiftUI、Foundation、CoreGraphics／ImageIO、XCTest、本地 JSON、现有 AppleScript／JSX Photoshop 桥接及 Python AI bridge。保持工程当前 macOS 26.5 deployment target 与 Swift 5.0 设置，不在本任务升级依赖或工具链。

**Spec:** [分步骤操作与验收规范](../specs/2026-11-05-photo-workflow-design.md)。执行者必须同时阅读该规范。本文件是工程任务清单，面板操作与产品文案以规范为准。

## Global Constraints

- 收藏 JPG 每只 6 张，正反面各 3 张；默认按自然文件名顺序分组，名字每行一只；输出沿用 F/U。
- 第 1、2 步各有“完成后检查”开关，整批阶段结束才暂停或自动继续；第 3、5 步始终需要人工确认。
- 高清比例支持自适应、5:4、11:8.5、1:1，默认自适应；最窄相对留白默认 10%，不额外缩放。
- 复用当前 PSD 保存版本的前景蒙版，翅顶对齐；禁止重新调用 Vision、覆盖人工蒙版、切主体或自动补背景。
- 4K 为 4096×4096 透明 PNG、默认安全边距 256 px；1K 为 1000×1000 纯白 PNG、默认安全边距 10 px。
- 闲鱼沿用 2000×2000、RGB 238、既有阴影／水印；素材 PNG 从本次 4K 紧裁、不额外缩放。
- 源 JPG 只读；产物只覆盖本任务所有的同路径旧版本。人工 PSD 保存、预览、导出必须有一致的版本记录。
- 用户已于本轮明确授权按步骤实现、独立 review、测试和提交；每步全部通过后继续。授权不包含推送、合并 main 或发布；保留其他工作区修改。

## Review Focus

1. 数量刚好但中途试拍／补拍造成错组：必须可查看及固定映射，不能悄悄顺移名称。由任务 1 验证。
2. 堆栈边角透明或蒙版与 PNG 同尺寸但方向／输入不一致：不能靠矩形尺寸或同名文件放行。由任务 2、3 验证。
3. 拖动较快、旧预览稍后返回或 Photoshop 保存未结束：不能用旧预览确认新参数或读到半文件。由任务 2、6 验证。
4. 用户精修蒙版后只调整 4K：不能重新 AI，也不能改动高清已确认几何。由任务 1、5 验证。
5. 文件落盘后进程退出、清单未更新或同名文件来自另一任务：应识别已有有效产物或报冲突，不能静默覆盖。由任务 1、4、7 验证。

---

## 0. 开始实施时的基线

文档编写时只局部核验了下列事实，不代表它们已通过新流程集成验收：

| 现有文件 | 复用边界 |
|---|---|
| `Butterfly Toolkit/Core/FocusStackProcessor.swift` | `makePlan(inputFolder:outputFolder:namesText:)` 自然排序、每名六张、F/U；`process(_:photoshopApplicationName:)` 执行合成。旧逻辑遇同名文件直接跳过，新流水线不能照搬这个完成判断 |
| `Butterfly Toolkit/Features/AI/AIProcessRunner.swift` | `run(engine:arguments:onEvent:)`，使用已配置引擎下 `.venv/bin/python` 与 `scripts/toolkit_bridge.py` |
| `Butterfly Toolkit/Features/AI/AIWorkspaceStore.swift` | 已有 `infer --input … --device …` 及 `result.json/inputSha256` 校验；抽取服务复用，不耦合工作区当前选中样本 |
| `Butterfly Toolkit/Features/AI/AIFileValidation.swift` | SHA256 与输出内容核验；不能代替蒙版方向／坐标校验 |
| `Butterfly Toolkit/Core/ButterflyCropProcessor.swift` | 旧 Vision／背景差异与镜像评分只作对照，不作为新收藏分析入口 |
| `Butterfly Toolkit/Core/PSDExportProcessor.swift` | 读取 PSD 可见合成图；无法独立提取底图／抠图角色。JPEG 质量当前为 0.82 |
| `Butterfly Toolkit/Core/XianyuProductProcessor.swift` | `createProductImage(sourceURL:destinationURL:watermark:)` 复用现有视觉参数 |
| `Butterfly Toolkit/Core/TransparentPNGTrimProcessor.swift` | 复用 alpha 范围紧裁行为；新流程独立管理目的路径与产物版本 |
| `Butterfly Toolkit/Views/ContentView.swift` | NavigationSplitView 中增加入口，保持旧页面可用 |

- [ ] 开始实施前检查当前分支、差异和项目级 AGENTS，不恢复或覆盖其他工作。
- [ ] 核验 Photoshop、现有 AI 引擎及本机可用 Xcode；实际验证都在本次任务输出目录，源照片只读。
- [ ] 确认 scheme `Butterfly Toolkit` 与 test target `Butterfly ToolkitTests` 仍可用。本轮仅通过 `xcodebuild -list` 核对名称，未运行构建或测试。

下面新增的文件和接口是实现约定，尚不存在。每个任务的验证完成后进行针对该任务的差异审查；提交仅在用户授权时执行，不在文档编写阶段产生提交。

## Task 1：任务身份、阶段状态与可恢复清单

**Files:**
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowModels.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowStateMachine.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowBatchStore.swift`
- Test: `Butterfly ToolkitTests/WorkflowStateTests.swift`

**Interfaces:**

在 `WorkflowModels.swift` 定义这些 Codable、Sendable 数据约定，后续任务不另建同义类型：

| 类型 | 必须包含的信息 |
|---|---|
| `WorkflowStage` | stack、matte、geometry、hd、png4k、derivatives |
| `WorkflowSide` | front、back；文件后缀映射 F、U |
| `WorkflowAssetKind` | hd、png4k、xianyu、white1k、footage |
| `WorkflowBatch` | UUID、源／输出目录、两个检查开关、标本列表、版本化预设、当前阶段 |
| `WorkflowSpecimen` | UUID、基础名称、两面任务；每面固定三张源文件及指纹 |
| `WorkflowStageRecord` | 阶段、状态、输入版本、输出版本、人工确认版本、错误／排除原因 |
| `WorkflowArtifact` | 所有者任务 UUID、种类、路径、源指纹、预设指纹、文件指纹、状态 |
| `PSDSnapshot` | 面任务 UUID、工作 PSD URL、不可变快照 URL、内容版本、像素尺寸、角色标识、结构摘要；stack 阶段允许角色尚未建立，从 matte 完成起强制存在 |
| `StackPNG` | 源快照版本、全尺寸 PNG URL、内容指纹、尺寸／方向／色彩、有效背景 alpha URL（全不透明时可空） |
| `MatteArtifact` | 输入 PNG 指纹、alpha URL／指纹、透明图 URL／指纹、方向和尺寸 |
| `GeometryRequest` | 比例枚举、目标留白、角度策略、可选中心覆盖；角度策略为自动翅顶／两点／手动度数 |
| `GeometrySolution` | 源版本、角度、两翅顶、主体范围、源坐标裁切框、输出尺寸、实际四边留白、可应用性与原因 |
| `RoleImages` | 快照版本、已变换底图 PNG、抠图 RGBA PNG、当前蒙版、共同像素尺寸与坐标起点、完整可编辑像素范围及当前裁切视口 |
| `SquareLayout` | 画布边长、安全边距、中心位置；4K 默认 4096／256，1K 默认 1000／10 |

`WorkflowStateMachine.reduce(batch: WorkflowBatch, event: WorkflowEvent) throws -> WorkflowBatch` 为纯函数。`WorkflowEvent` 覆盖阶段完成／失败、整批继续、选择标本确认、明确排除、源版本变化和预设变化，事件必须带当前版本用于拒绝过期操作。

`actor WorkflowBatchStore` 提供 `load(from: URL) throws -> WorkflowBatch`、`save(_ batch: WorkflowBatch, to: URL) throws`；原子存储并保留上一有效清单。

- [ ] 编写 `testFourCheckpointCombinations`：两只标本共四面；完成一面或一只不能触发整批继续；组合 TT／TF／FT／FF 正确停在第 1、2 步或到达第 3 步，绝不自动通过第 3、5 步。
- [ ] 编写 `testFailureRequiresRetryOrExplicitExclusion`、`testGroupingDoesNotShiftAfterExclusion`、`testStaleConfirmationRejected`、`test4KChangeKeepsHDAndMatte`，分别断言失败可见、固定映射、版本拒绝和精确失效范围。
- [ ] 运行本任务测试，确认缺少新类型／行为而失败；实现上述纯状态与持久化，不加入 Photoshop 或 UI 依赖。
- [ ] 验证 JSON 往返、损坏清单回退、取消后重开；清单内没有临时 UI 选择或不可序列化的图像对象。
- [ ] 运行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowStateTests' CODE_SIGNING_ALLOWED=NO`。预期本任务测试通过。

## Task 2：Photoshop 与 AI 真实小样闭环

**Files:**
- Create: `Butterfly Toolkit/Core/PhotoshopExecutionCoordinator.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/PhotoshopWorkflowBridge.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowMatteService.swift`
- Modify: `Butterfly Toolkit/Views/FocusStackView.swift`（现有 Photoshop 调用接入共享队列）
- Reuse: `Core/FocusStackProcessor.swift`、`Features/AI/AIProcessRunner.swift`、`Features/AI/AIFileValidation.swift`
- Test: `Butterfly ToolkitTests/WorkflowBridgeTests.swift`

**Interfaces:**

`PhotoshopExecutionCoordinator` 负责真正的互斥队列与人工编辑占用，不以 actor 名称代替跨 await 的串行保证。提供 `run<T: Sendable>(owner: UUID, operation: @Sendable () async throws -> T) async throws -> T`、`beginManualEditing(owner: UUID) async throws`、`endManualEditing(owner: UUID) async`。旧堆栈页也必须使用同一实例。

可注入的 `PhotoshopWorkflowBridge` 提供：

```swift
func stack(job: FocusStackJob, owner: UUID) async throws -> PSDSnapshot
func exportStackPNG(snapshot: PSDSnapshot) async throws -> StackPNG
func installMatte(snapshot: PSDSnapshot, matte: MatteArtifact) async throws -> PSDSnapshot
func applyGeometry(snapshot: PSDSnapshot, solution: GeometrySolution) async throws -> PSDSnapshot
func extractRoles(snapshot: PSDSnapshot) async throws -> RoleImages
func refreshSavedPSD(document: URL, owner: UUID) async throws -> PSDSnapshot
```

`extractRoles` 须能提取当前可恢复的画布外像素并记录原点／视口，使扩大留白预览有真实来源；不能从旧高清 JPG 或已裁切的合成图补背景。`renderHD` 按记录的当前裁切视口输出；`render4K` 按有效主体独立排版。

`WorkflowMatteService.infer(input: StackPNG) async throws -> MatteArtifact`：注入已配置引擎与设备，复用现有 runner 参数及结果校验。由本服务验证完整结果，调用者不能仅因退出码为零就继续。

- [ ] 先写假的桥接器／进程事件测试：输入身份不符、alpha 缺失／翻转／尺寸异常、输出存在但不可读，都不能标记成功。
- [ ] 写 `testPhotoshopLeaseSurvivesAwait`、`testManualEditingBlocksAutomaticWrites`、`testUnsavedPSDRejectsRefresh`；以可控挂起操作断言无重叠、退出人工编辑后才继续、保存期间不创建新快照。
- [ ] 实现已有堆栈服务适配及 alpha 回写脚本；创建明确角色组，不覆盖原堆栈蒙版。JSX 具体命令以本机 Photoshop 小样验证结果确定，不用臆测的图层 API。
- [ ] 使用复制到任务输出目录的真实六张 JPG，做一个双面样本：合成 → 导出 PNG → AI → 写回蒙版 → 保存 → 角色提取。比对触角、白缘毛、坐标、角色与背景缺口。
- [ ] 在样本中人工修改蒙版、保存并刷新，断言提取的是最新蒙版；删除／合并角色时必须报结构问题。验证非破坏裁切可重新扩大画布恢复隐藏像素。
- [ ] 运行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowBridgeTests' CODE_SIGNING_ALLOWED=NO`。预期单元测试通过，并另记录真实 PSD 小样证据；两者不能相互替代。

此任务的小样失败时先修正桥接约定，再继续完整页面；不得绕过蒙版读回或把展平图片当成可编辑蒙版交付。

## Task 3：蒙版翅顶、比例与有效背景几何

**Files:**
- Create: `Butterfly Toolkit/Core/MaskGeometryProcessor.swift`
- Test: `Butterfly ToolkitTests/MaskGeometryProcessorTests.swift`

**Interfaces:**

`MaskGeometryInput` 包含源版本、源像素尺寸、当前蒙版 URL、有效背景 alpha URL；`MaskGeometryProcessor.analyze(input: MaskGeometryInput, request: GeometryRequest) throws -> GeometrySolution`。方法不调用 Vision 或 AI，不修改源图片或蒙版。输出所有坐标都属于同一明确记录的源像素坐标系，统一处理 ImageIO／Photoshop／预览坐标方向。

- [ ] 先写几何测试：下列期望值来自规范，不复写实现流程来冒充测试。

```swift
// 使用完整背景、主体 2400×1800 的固定夹具。
XCTAssertEqual(adaptive.outputSize, CGSize(width: 3000, height: 2250))
XCTAssertEqual(square.outputSize, CGSize(width: 3000, height: 3000))
XCTAssertEqual(square.leftMarginFraction, 0.10, accuracy: 0.001)
XCTAssertEqual(square.topMarginFraction, 0.20, accuracy: 0.001)
// GeometrySolution 的四边留白可用计算属性命名为上述字段。
```

- [ ] 增加 `test11By8Point5Uses22By17Units`、`testAntennaeDoNotBecomeWingTips`、`testDamagedWingRequiresReview`、`testFullBoundsKeepTailAndFineHair`、`testBackgroundHolesRejectOtherwiseValidRectangle`、`testImpossibleFixedRatioDoesNotSilentlyChangeRatio`。
- [ ] 实现翅区上缘定位、旋转后完整范围、规范第 6.2 节公式、整数像素裁切与有效区域约束。固定比例无法满足时返回不可应用原因，不返回伪成功的其他比例。
- [ ] 在真实已接受蒙版上标出自动翅顶，与用户认可参考点比较；定位不确定保留原角度并输出待调整状态，两点手动模式绕过自动定位但仍执行完整范围检查。
- [ ] 运行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/MaskGeometryProcessorTests' CODE_SIGNING_ALLOWED=NO`。预期合成夹具全通过；真实照片另报告错旋转、截断与降级。

## Task 4：高清、4K 与三类派生资产

**Files:**
- Create: `Butterfly Toolkit/Core/WorkflowAssetRenderer.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowArtifactStore.swift`
- Reuse: `Core/XianyuProductProcessor.swift`、`Core/TransparentPNGTrimProcessor.swift`
- Test: `Butterfly ToolkitTests/WorkflowAssetRendererTests.swift`

**Interfaces:**

渲染器只写传入的临时 URL；产物发布与所有权由 `WorkflowArtifactStore.publish(temp: URL, artifact: WorkflowArtifact) throws -> WorkflowArtifact` 执行。`WorkflowAssetRenderer` 提供：

```swift
func renderHD(roles: RoleImages, destination: URL) throws
func render4K(roles: RoleImages, layout: SquareLayout, destination: URL) throws
func renderWhite1K(source4K: URL, destination: URL) throws
func renderFootage(source4K: URL, destination: URL) throws
func renderXianyu(source4K: URL, watermark: URL, destination: URL) throws
```

高清从底图角色读取、JPG 质量 0.82；4K 保留 alpha；1K 纯白且输出 PNG。1K 和素材范围来自 4K 的有效 alpha。Xianyu 复用现有方法，给它任务临时路径，不调用其“同名存在则跳过”的目录扫描来判断完成。

- [ ] 编写方形透明主体夹具，分别断言：

```swift
XCTAssertEqual(png4k.pixelSize, CGSize(width: 4096, height: 4096))
XCTAssertEqual(png4k.subjectBounds, CGRect(x: 256, y: 256, width: 3584, height: 3584))
XCTAssertEqual(white1k.pixelSize, CGSize(width: 1000, height: 1000))
XCTAssertEqual(white1k.subjectBounds, CGRect(x: 10, y: 10, width: 980, height: 980))
// 真正像素断言由测试读取解码后的结果；主体边界允许抗锯齿造成的 1 px 误差。
```

- [ ] 增加长尾非方形夹具，断言等比、完整、另一个方向留白更多；检查 4K 角落透明、1K 角落 RGB255、闲鱼角落 RGB238。1K 不能继承缩小后的 4K 留白。
- [ ] 写 `testHDUsesBaseRole`、`testForeignSameNameIsConflict`、`testPublishValidatesDecodedImage`、`testMissingWatermarkOnlyFailsXianyu`，然后实现渲染与原子发布。
- [ ] 与两张用户参考图进行并排视觉核对，使用规范记录的尺寸与边距；不修改参考文件。检查白缘毛透明边缘没有黑边、白边污染或意外阴影。
- [ ] 运行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowAssetRendererTests' CODE_SIGNING_ALLOWED=NO`。预期像素／尺寸／所有权测试通过。

## Task 5：串起六个阶段与恢复操作

**Files:**
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowExecutor.swift`
- Test: `Butterfly ToolkitTests/WorkflowExecutorTests.swift`

**Interfaces:**

`actor WorkflowExecutor` 注入任务 1 的 batch store／状态机、任务 2 的 PS／AI 服务、任务 3 的几何处理器及任务 4 的渲染／产物存储。提供：

```swift
func runPending(batchID: UUID) async throws
func continueAfterReview(batchID: UUID, stage: WorkflowStage, specimenIDs: [UUID]) async throws
func confirmGeometry(batchID: UUID, solutions: [UUID: GeometrySolution], exportHD: Bool) async throws
func confirm4K(batchID: UUID, layouts: [UUID: SquareLayout]) async throws
func retry(batchID: UUID, specimenIDs: [UUID], stage: WorkflowStage) async throws
func pause(batchID: UUID) async
```

字典键统一为面任务 UUID。所有确认入口读取已保存的当前版本，校验阶段与选中标本的两面均就绪；不能凭 UI 按钮状态代替校验。第 3 步确认后由导出高清勾选项控制第 4 步；第 5 步确认后对本次选定派生资产自动执行第 6 步。

- [ ] 用假的可控服务写 `testHappyPathBothCheckpointsOn` 和 `testAutomaticUntilGeometryWhenOff`，记录调用顺序和阶段保存，不启动真实 Photoshop。
- [ ] 写 `testSaveAndReadbackBeforeHD`、`test4KRequiresSeparateConfirmation`、`testMaskEditDoesNotRunAI`、`test4KLayoutChangeDoesNotTouchHD`、`testRetryOnlyFailedAsset`。
- [ ] 实现阶段循环、取消安全边界、版本失效、失败隔离和明确排除；复用 `FocusStackJob` 中固定的三张源文件，不能处理时再次扫描目录重新分组。
- [ ] 模拟在“文件写好／清单未写”处退出并恢复，验证产物归属与指纹后接续；过期快照不得替换更新版本的完成状态。
- [ ] 运行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowExecutorTests' CODE_SIGNING_ALLOWED=NO`。预期调用顺序、确认与恢复测试通过。

## Task 6：原生六步页面及实时构图

**Files:**
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/PhotoWorkflowStore.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/PhotoWorkflowView.swift`
- Create: `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowGeometryPreview.swift`
- Modify: `Butterfly Toolkit/Views/ContentView.swift`
- Test: `Butterfly ToolkitTests/WorkflowPreviewTests.swift`

**Interfaces:**

`@MainActor PhotoWorkflowStore` 负责页面状态与命令转发，不执行同步 PS 或大图解码。`WorkflowGeometryPreview` 使用任务 3 的请求／结果和任务 2 的当前源图缓存。

预览服务接口：`preview(source: RoleImages, solution: GeometrySolution, maximumPixelSize: Int) async throws -> CGImage`。默认展示缓存最长边 2048 px，精看可加载局部／原图；数值计算使用完整源坐标。保存来源角色未准备好时停留加载，不能用旧标本图片冒充当前预览。

- [ ] 写 `testOldPreviewCannotReplaceLatestRequest`、`testConfirmationDisabledWhileValidating`、`testViewportZoomDoesNotChangeOutput` 和坐标往返测试，先看到缺少行为的失败。
- [ ] 建立规范第 3 节页面；第 1、2 步显示开关与整批检查，第 3 步显示四种比例、10% 滑块与翅顶定位，第 5 步显示独立 256 px 安全框，第 6 步显示资产结果和重试。
- [ ] 实现最新请求优先的预览取消／版本过滤；拖动期间本地变换显示，停止后精确校验。无效背景区在预览可见并阻止错误确认，不裁掉主体来掩盖。
- [ ] 将确认按钮连接任务 5；PS 精修期间暂停自动队列，保存读回后刷新最新版本，不能仅监听文件修改时间就重新启动全部步骤。
- [ ] 运行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowPreviewTests' CODE_SIGNING_ALLOWED=NO`。预期过期预览与坐标测试通过。
- [ ] 启动真实 SwiftUI 应用，在两面切换、拖动角度／留白、改比例、两点扶正、往返 PS、进入 4K 等操作中截图并记录预览响应。目标 p95≤100 ms 的测量排除首次解码和 PS 写入；未达目标需优化或如实记录，不用旧 HTML 演示代替。

## Task 7：完整回归、真实素材验收和交付

**Files:**
- Create: `Butterfly ToolkitTests/WorkflowIntegrationTests.swift`
- Create: `docs/validation/2026-11-05-photo-workflow-acceptance.md`（执行时可改为真实日期）
- Modify: 仅修复本轮发现问题所需的上述文件

**Interfaces:** 使用 `WorkflowExecutor` 的公共命令，测试不绕过状态机或直接改完成字段。

- [ ] 先写自动化集成夹具覆盖：两个标本／四面、四种检查开关组合、单面失败与显式排除、PS 未保存、同名外来文件、重启恢复、只改 4K、1K 重新构图、水印缺失。
- [ ] 运行集成测试并修复；然后使用真实六图／双面小批完整执行第 1～6 步，逐项比对规范第 12 节。
- [ ] 用至少 20 只／40 面的建议比较集校准扶正与裁切，记录每面输入、自动角度、人工角度、是否截断、是否需要调整和原因。不把人工修正后的结果当作自动算法一次成功。
- [ ] 全量执行：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build CODE_SIGNING_ALLOWED=NO`，预期 `TEST SUCCEEDED`；已有 AI 和旧工具回归不得被删除以换取通过。
- [ ] 验收报告分别列出代码／单元测试、真实 SwiftUI、真实 Photoshop 往返、AI 蒙版质量、输出图及性能证据，明确未验证项。仅测试通过不能标记用户实图质量通过。
- [ ] 审查任务范围，交付变更清单、输出示例、已知限制及恢复方法；提交／安装／推送按届时用户指令执行。

## 文档检查记录

2026-11-05：规范经独立 builder check，结果为 `nothing important left`。本计划按规范自查阶段覆盖、接口与数据命名、失败恢复和输出参数。以上任务全部尚未执行；本轮没有运行产品测试或修改 Swift 代码。
