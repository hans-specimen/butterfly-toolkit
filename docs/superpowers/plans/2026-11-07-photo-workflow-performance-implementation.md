# Photo Workflow Performance 1–8 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox syntax for tracking. 用户指定交给下一位 agent 实施；本轮只编写计划。无需重新讨论已确定的 1–8 范围，不自动创建新聊天。

**Goal:** 在画质、透明度、文件保护和检查点行为不变的前提下，消除照片工作流的重复工作并缩短整批处理时间。

**Architecture:** 先扩展现有内容缓存和已验证的无损 PNG 路径，再共享有界的几何分析与单次操作解码结果。随后增加仅供照片工作流使用的单路 AI worker，最后用现有执行器和 PS 租约实现最多两个面任务的错峰执行；不建立另一套工作流框架。

**Tech Stack:** Swift／SwiftUI、actors、CoreGraphics／ImageIO、Photoshop ExtendScript、Python／Pillow／PyTorch MPS；沿用现有依赖。

**Spec:** 必须先读[本轮设计与验收边界](../specs/2026-11-07-photo-workflow-performance-design.md)，再读本计划。原流程设计的历史差异以该补充规范说明为准。

## Global Constraints

- 本轮规范 §3 的全部约束适用于每项任务。输出 `4096 × 4096`、默认 `256 px` 安全边距、JPEG `0.82`、AI `FP32`／`2048 × 2048` 和固定模型 revision 不变。
- Toolkit deployment target 保持当前 `macOS 26.5`；新实现不提高版本底线、不增加依赖。
- 当前两仓库基线为 Toolkit `615fa09`、AI `0d86a55`。这两次提交已包含上一轮修复；不要重复实现或覆盖。
- 用户已要求提交本次修改；已提交内容及本文档不需要再次提交。下一轮按任务形成独立、可审查的变更；推送远端不属于本次交接要求。
- AI 仓库未跟踪的 `scripts/export_psd_sample.py` 保持原样。先检查下一轮启动时的工作区，新增的用户修改不能覆盖。
- 只实施 1–8；不改模型精度、不删浮点 Alpha 诊断文件、不把派生工具加回主流程、不改用户输出目录。

## Review Focus

1. **同内容不同路径与不同归属：** 正式发布可以复用提取；其他任务／被改归属不可以。由任务 1、3 验证。
2. **保存中、缓存被改、负坐标隐藏像素：** 缓存命中不能忽略当前源与坐标身份。由任务 1、3、4 验证。
3. **低 Alpha、完全透明 RGB、ICC：** 比较原始 RGBA 与色彩元数据，不能只看肉眼或预乘结果。由任务 2、6、8 验证。
4. **全选多个标本与延迟返回的预览：** 可见面优先不代表未选面获准；缓存淘汰不应导致永远不能确认。由任务 4、5 验证。
5. **并发时暂停、手工编辑、单面失败与重启：** 不发布过期结果，不双重旋转，不误读另一面 AI 事件。由任务 7、8 验证。

## 0. 接手清单、文件地图和运行命令

- [ ] 阅读本轮规范，检查两个仓库 `git status --short` 与 `git log -3 --oneline`，确认包含上述基线提交。
- [ ] 在当前包含基线的工作区继续；若隔离工作区，先确认两仓库版本都齐全，不能从旧 HEAD 开始后用 checkout 覆盖现有文件。
- [ ] 记录当前 App 是否忙碌。性能测试输出使用新建 `/tmp` 目录；有写 PSD 的测试必须先复制 fixture，禁止在用户原批次确认或重新导出。
- [ ] 先执行一次当前基线的全量测试并保存结构化结果；失败则先区分环境问题和实现回归。

### 文件地图

以下 `T/` 指 `/Users/hans/Developer/butterfly-toolkit`，`A/` 指 `/Users/hans/Developer/butterfly-ai`。这是文档缩写，不是需创建的目录。

| 文件 | 责任／涉及任务 |
|---|---|
| `T/Butterfly Toolkit/Features/PhotoWorkflow/PhotoshopWorkflowBridge.swift` | PSD 保存版本、提取缓存、PNG 保存；1、2、3 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowExecutor.swift` | 确认、服务接线、版本栅栏、调度；3、4、7、8 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/PhotoWorkflowStore.swift` | UI 门禁、预览调度、共享服务生命周期；4、5、8 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowGeometryPreview.swift` | 缩略图、预览坐标与 Canvas；4、5 |
| `T/Butterfly Toolkit/Core/MaskGeometryProcessor.swift` | 全尺寸分析；4；不改算法阈值和裁切语义 |
| 新建 `T/Butterfly Toolkit/Core/WorkflowGeometryCache.swift` | 有界、可合并在途请求的共享分析缓存；4 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowMatteService.swift` | 推理输入／结果验证，现有 WorkflowRaster；6、8 |
| `T/Butterfly Toolkit/Core/WorkflowAssetRenderer.swift` | JPG／4K 本地渲染；6 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowArtifactStore.swift` | 文件发布、归属收据、历史与恢复；6 |
| 新建 `T/Butterfly Toolkit/Features/AI/AIInferenceWorker.swift` | 单进程推理队列；8；独立 AI 工作区仍用原 AIProcessRunner |
| `A/scripts/toolkit_bridge.py` | 工作流 PNG 压缩、worker 命令与复用模型；2、8 |
| `A/scripts/run_birefnet_baseline.py` | 固定模型加载、推理函数的复用依据；默认不改数学实现 |

没有列出的旧工具不要顺手重构。新 Swift 文件确认被 Xcode target 收录；项目现有同步目录机制可直接收录时不额外改项目文件。

### 标准验证命令

Toolkit 全量（各任务聚焦测试在命令中加入下文给出的 `-only-testing`）：

```sh
cd /Users/hans/Developer/butterfly-toolkit
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/butterfly-workflow-perf-build \
  ENABLE_TESTABILITY=YES test > /tmp/butterfly-workflow-perf-tests.log 2>&1
```

AI 合成夹具测试，不启动真实模型：

```sh
cd /Users/hans/Developer/butterfly-ai
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B -m unittest discover \
  -s scripts -p test_toolkit_bridge.py -v
```

每项顺序为：写能检出原问题的测试 → 跑红 → 最小实现 → 跑绿 → 检查 diff／记录测量。不要用脆弱的耗时阈值替代调用次数、同步栅栏和像素断言；并发测试用可控 gate，不用固定 sleep。

## 实施顺序

| 批次 | 原编号 | 交付边界 |
|---|---|---|
| A | 1 → 2 → 3 → 5 | 去掉重复提取、慢速中间压缩和无用渲染；可单独交付 |
| B | 4 → 6 | 共享分析、复用解码；可单独交付 |
| C | 8 | 常驻单路推理进程；必须先证明取消和请求身份正确 |
| D | 7a → 7b | 先独立导出两路，再开启最多两面蒙版任务错峰；依赖 8 |

保留 1–8 编号便于对应用户要求。任何批次出现回归，仅回退该批次，不丢掉已经通过的前序优化。

## 任务 1：跨临时／正式路径复用同版本角色图片

**Files:** 修改 `T/Butterfly Toolkit/Features/PhotoWorkflow/PhotoshopWorkflowBridge.swift`；测试 `T/Butterfly ToolkitTests/WorkflowBridgeTests.swift`。

**Interfaces:** 保留 `installMatte(snapshot:matte:)`、`extractRoles(snapshot:)`、`RoleCache` 收据格式。新增私有比较函数 `sameExtractionSource(_ lhs: PSDSnapshot, _ rhs: PSDSnapshot) -> Bool`，只用于判定角色图片是否可复用。

- [ ] 写 `testPublishedCopyReusesRoleExtractionWithoutTrustingWorkingPath`：同 owner 的临时／正式 PSD 内容相同，发布只改 workingURL；用已有 fake ScriptRunner 计数，refresh/extract 总共只运行一次角色导出。
- [ ] 写 `testRoleReuseRejectsChangedOwnerRolesAndImmutableSnapshot`：相同字节不能跨 owner 放行；角色身份、summary、尺寸或不可变副本被改时拒绝或重新提取。保留现有未保存、图片损坏、缺文件、收据损坏测试。
- [ ] 聚焦运行 `-only-testing:'Butterfly ToolkitTests/WorkflowBridgeTests'`，先确认第一条在旧实现中因提取两次而失败。
- [ ] 比较内容身份时忽略 `workingURL`，仍比较 taskID、contentVersion、snapshotURL、pixelSize、roles、structureSummary；不修改全局 `PSDSnapshot.Equatable`。工作文件的保存、归属和哈希检查留在 capture/verify/recoverInstall 边界。
- [ ] 复用现有旧收据，不强制清空用户缓存；命中时仍检查三张 PNG 的哈希。发布前后蒙版等价校验不能删，只复用同版本的提取结果。
- [ ] 跑绿并扩充 `testRecordedMattePublicationRecoversAfterPSDWasSavedBeforeOwnershipFinalization`，确认 prepare/publish 两个中断点仍可恢复且不重复 install。

**完成证据：** 同一保存内容的 staged→published 提取次数从 2 降为 1，原 PSD 与外来归属用例不变。

## 任务 2：快速无损压缩覆盖 AI 中间输入／输出

**Files:** 修改上述 bridge、`A/scripts/toolkit_bridge.py`；测试 `T/Butterfly ToolkitTests/WorkflowBridgeTests.swift` 和 `A/scripts/test_toolkit_bridge.py`。

**Interfaces:** 复用 bridge 已验证的 `wfRolePNG(doc,path)` 快速保存能力；可统一命名为 `wfIntermediatePNG`，但全部调用与测试须一起调整。Python `save_prediction(directory,rgb,icc,native,engine,*,compress_level=6)` 增加明确的可选编码参数；工作流 `workspace != None` 时传 `1`，独立 AI 工作区保持原默认。

- [ ] 扩充 Python `test_save_preserves_original_size_white_rgb_icc_and_soft_alpha`，比较 level 1 与原路径：原始 RGBA、ICC、尺寸相同，Alpha 含 0/1/64/128/255；浮点 Alpha 文件仍保存并验证。
- [ ] 写工作流输入导出集成夹具：旧 Save for Web 与快速保存从相同不可变堆栈导出，包含半透明边缘和被隐藏的蓝色底层；比较原始 RGBA、ICC、方向、尺寸。不能只拿回写后角色图代替未回写的堆栈输入。
- [ ] 将 `exportScript` 中的 AI 输入 PNG 改用快速保存；8-bit RGB 显式嵌入 ICC，其他位深／模式继续沿用原路径。不能换成会漏 ICC 的普通 `PNGSaveOptions`。
- [ ] `infer_file` 仅在工作流模式为两个 PNG 传 level 1；不改恢复 Alpha、量化、白底合成、模型或 result.json 输入身份规则。
- [ ] 运行 bridge 聚焦测试与 Python 全部测试；真实 PSD fixture 输出只写临时目录。
- [ ] 测量编码＋写盘＋回读总耗时和文件大小。记录空间代价；若写盘后抵消了收益，保留结果一致性并记录该路径是否仍值得启用。

**完成证据：** AI 输入与输出均有前后像素／ICC 对照；不能直接引用上一轮角色 PNG 的对照当作本任务验收。

## 任务 3：确认路径只做一次受保护的当前角色读取

**Files:** 修改 `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowExecutor.swift`；测试 `WorkflowExecutorTests.swift`、`WorkflowBridgeTests.swift`、`WorkflowIntegrationTests.swift`。

**Interfaces:** 不新增 refresh API。已有 `PhotoshopWorkflowBridge.extractRoles(snapshot:)` 会检查工作文档保存状态、结构、归属及工作／不可变文件哈希。保留 `Services.extract: (PSDSnapshot) async throws -> RoleImages` 和私有 `readCurrentRoles(_:_:stage:)` 的签名。

- [ ] 写 `testConfirmationUsesSingleVerifiedExtraction`：确认几何或 4K 时，`Services.refresh` 调用数为 0、`Services.extract` 每面为 1；结果写回对应 task.roleImages，其他任务的版本栅栏仍执行。
- [ ] 在真实 bridge fake runner 测试中证明：缓存命中的 extract 只调用一次 inspect、不做角色导出；未保存、保存后改变、删角色、损坏不可变快照仍失败。
- [ ] 在 `readCurrentRoles` 用 `services.extract(snapshot)` 替代 refresh→比较→extract；保留调用后的 `check`、角色版本验证和上层 `checkSelection`。不能因减少一个服务调用而删掉“双面一起确认”的前后检查。
- [ ] 保留手工 `refreshSavedPSD`、安装事务恢复和初始堆栈恢复的原路径，这些场景需要读新版本，不能替换成只允许旧版本的 extract。
- [ ] 更新依赖旧 mock 调用位置的测试，把“外部 PSD 改变”注入到 extract 边界，而不是删除断言。重点跑 `testSavedPSDChangedOutsideExecutorRejectsGeometryConfirmation`、`test4KWholePairRejectsFirstSideInvalidationWhileSecondReads`、`testGeometryWholePairRejectsFirstSideInvalidationWhileSecondApplies`。
- [ ] 聚焦运行 executor、bridge、integration 三个测试类，测量实际确认路径的 PS 调用数和耗时。原 opt-in 测试仍显式 refresh+extract，需新增“确认使用的单次 extract”测量栏，不能用旧测量代码宣称本项无效／完成。

**完成证据：** 正常确认每面从 3 次 inspect 降到 1 次，PNG 提取仍为 0（有效缓存），接受／拒绝边界不变。

## 任务 5：删除生成后丢弃的裁切预览

**Files:** 修改 `PhotoWorkflowStore.swift`、`WorkflowGeometryPreview.swift`；测试 `WorkflowPreviewTests.swift`。

**Interfaces:** UI 继续使用 `displayImage(for:)` 的角色缩略图和 `WorkflowGeometryPreview` Canvas。`WorkflowPreviewService.geometry(...)` 仍负责精确验证；不以“图已经显示”取代 gate。

- [ ] 用现有预览测试确认过期 token、未保存手工编辑、切换到 4K 后角色图、拖动未松开和原图细节身份都受保护；给 store 预览调用加可注入计数探针，断言一次 requestPreview 不需要额外裁切位图。
- [ ] 删除 `requestPreview` 内 `_ = try await previews.preview(...)`；保留几何分析后的 token／sourceVersion 检查、loading 和 canConfirm 更新。
- [ ] 全仓搜索 `preview(source:solution:maximumPixelSize:)`。产品无剩余消费者时删除该方法及只测试它的 `testRenderedPreviewUsesFullSourceOriginAndCurrentCrop`，同时将负坐标和当前视口断言保留在实际 Canvas 坐标／store 路径测试中；不能只删除覆盖。
- [ ] 运行 `-only-testing:'Butterfly ToolkitTests/WorkflowPreviewTests'`。用 App 检查底图／抠图／蒙版切换及 4K 天蓝背景、框线、滑块，确认显示仍来自当前角色图。

**完成证据：** 无消费者的 bitmap render 为 0，现有确认门禁不放宽。

## 任务 4：共享有界几何分析缓存

**Files:** 新建 `Core/WorkflowGeometryCache.swift`；修改 `MaskGeometryProcessor.swift`、`WorkflowGeometryPreview.swift`、`PhotoWorkflowStore.swift`、`WorkflowExecutor.swift`；测试新增 `WorkflowGeometryCacheTests.swift` 并保留预览／几何测试。

**Interfaces:**

```swift
actor WorkflowGeometryCache {
    func geometry(source: RoleImages, request: GeometryRequest,
                  savedCandidate: GeometrySolution? = nil) async throws -> GeometrySolution
    func removeAll() async
}
```

`WorkflowPreviewService.init(geometry: WorkflowGeometryCache)` 与 `WorkflowExecutor.Services.live(bridge:matte:geometry:)` 接收同一实例；测试可使用默认独立实例。缓存 prepare，不缓存一次滑动的最终参数结果。

- [ ] 写 `testPreviewAndConfirmationPrepareSameSourceOnce`、`testConcurrentRequestsJoinOnePreparation`：同源连续和并发请求只 prepare 一次，请求角度变化仍各自 analyze。
- [ ] 写 `testGeometryKeyIncludesRolePathsExtentOriginAndViewport`：键包含 snapshotVersion、mask/base 的规范路径、pixelSize、coordinateOrigin、editableExtent、cropViewport，任一改变均不误命中。关键确认前仍由任务 3 校验文件哈希，不能拿预览缓存代替源验证。
- [ ] 实现 LRU 淘汰，默认最多 4 项且估算保留内存不超过 512 MiB；`PreparedMaskGeometry` 增加 `estimatedStorageBytes: Int`，统计保留的 support、行／列索引、背景积分表，超预算的单项仅供当前调用使用，不入缓存。
- [ ] 不同键的全尺寸 prepare 最多 1 个在途；同键合并请求。一个预览调用取消不取消另一个调用共享的 prepare；`removeAll` 使用 generation 防止旧在途结果重新入新批次缓存。
- [ ] 写 `testLRUEvictsOneEntryAndHonorsByteBudget`、`testCancelledWaiterDoesNotCancelSharedPreparation`、`testOldPreparationCannotRepopulateClearedCache`，用小预算／gate 验证，不创建巨图凑内存。
- [ ] Store 每个批次会话共享同一 geometry cache；优先派发当前标本两面，再依次处理其他已选面。保留所有已选面的最终 GeometrySolution 和所需缩略图，**不要直接改成只准备可见面**：当前 `canConfirm` 要求所有选中面有图、有有效 gate、有对应版本解，缺一会使整批确认失效。
- [ ] `Services.analyze` 和 `Services.validateGeometry` 通过此缓存；preview service 不再维护第二份 prepared 字典。批次切换、关闭时清理会话缓存；同批角度和留白调整只重算参数。
- [ ] 运行 cache、preview、MaskGeometryProcessor、executor 测试。4K 支持范围来自 cutout Alpha，而几何分析来自 mask＋背景 Alpha，二者不能直接共用一个 subjectBounds；本任务不改该语义。

**完成证据：** 可见面的预览→确认不重复 prepare；跨四面不会“满两条全清空”；全选仍可双面确认，缓存和在途任务有明确上限。

## 任务 6：单次操作复用解码和发布像素检查

**Files:** 修改 `WorkflowMatteService.swift` 中 WorkflowRaster、`Core/WorkflowAssetRenderer.swift`、`WorkflowArtifactStore.swift`；测试 `WorkflowAssetRendererTests.swift`、`WorkflowOutputTests.swift`。

**Interfaces:** 新增 `WorkflowDecodedImage { let image: CGImage; let raster: WorkflowRaster }`；`WorkflowRaster.decode(_ url: URL) throws -> WorkflowDecodedImage`，原 `read(_:)` 调用它并返回 raster。公开 render／publish 接口保持不变。

- [ ] 写 `testRenderDecodesEachRoleOnce`：renderHD 仅解码底图一次，render4K 每个角色一次；以解码注入探针计数。新增软 Alpha、透明 RGB、非 sRGB ICC 的渲染对照。
- [ ] 从一次 ImageIO 解码同时取得原始 CGImage 和现有归一化 raster；验证仍用 raster，绘制仍用原始 CGImage。不能用 sRGB 预乘数组重新拼一张图代替旧绘制源，否则可能改变颜色／边缘舍入。
- [ ] 渲染器只在当前调用内保留解码结果，不建立无界的整批全尺寸 CGImage 缓存；不合并语义不同的 mask 支持范围和 cutout 支持范围。
- [ ] 写 `testPublicationDecodesCandidateOnceAndVerifiesCopiedBytes`：候选图片完整验证一次，复制后的 sibling 用相同哈希证明字节一致；加入复制被篡改的夹具，必须拒绝发布。
- [ ] 发布中建立私有、仅本次调用有效的验证结果：hash-before → decode/validate → hash-after 必须一致，再复制并核对 sibling hash。只有这些条件成立才省去 sibling 的第二次完整解码；外来目标、已有文件前后检查、归属收据、历史归档和原子 rename 保留。
- [ ] 重跑同名冲突、损坏图片、相同像素新 recipe、pending receipt 恢复和旧版本保留测试；用四张实图比较 RGBA、色彩元数据及最终 JPG／PNG。

**完成证据：** 角色重复解码和相同候选副本重复解码消失，修改文件／外来归属仍失败，最终输出不变。

## 任务 8：同批单路 AI worker

**Files:** 新建 `Features/AI/AIInferenceWorker.swift`、`Butterfly ToolkitTests/AIInferenceWorkerTests.swift`；修改 `WorkflowMatteService.swift`、`WorkflowExecutor.swift`、`PhotoWorkflowStore.swift`；修改 `A/scripts/toolkit_bridge.py` 和其测试。独立 AIWorkspaceStore／AIProcessRunner 的单次命令行为保留。

**Interfaces:**

```swift
nonisolated struct WorkflowInferenceRequest: Sendable {
    let engine: URL
    let workspace: URL
    let input: URL
    let device: String
}
actor AIInferenceWorker {
    func infer(_ request: WorkflowInferenceRequest) async throws -> AIEvent
    func shutdown() async
}
```

WorkflowMatteService 的注入 `Run` 改为 `(WorkflowInferenceRequest) async throws -> AIEvent`，更新现有测试，避免从字符串参数中反向解析请求。同一个 service 会话捕获同一个 worker；提供 `shutdown() async`，通过 `Services.endInferenceSession: @Sendable () async -> Void` 接入执行器，测试默认为 no-op。

Python 保留 `infer` 单次命令，增加 `--workspace <root> serve --device mps`。`serve` 的 stdout 为逐行 JSON：

```json
{"event":"ready","protocol":1}
{"event":"status","requestID":"UUID","message":"..."}
{"event":"completed","requestID":"UUID","input":"...","prediction":"...","predictionAlpha":"...","outputDirectory":"..."}
{"event":"error","requestID":"UUID","message":"..."}
```

stdin 请求为 `{"requestID":"UUID","input":"/absolute/derived.png"}`；EOF 退出。启动参数固定 workspace、device、模型 revision。可在 worker 私有 envelope 解码 requestID 和现有 AIEvent，无需改独立 AI 工作区协议。

- [ ] Python 新增 `InferenceSession`，`infer_file(..., session=None)` 可接收同一会话；没有 session 时保留单次行为。会话惰性加载原模型，并继续使用原 `engine.infer`、FP32 和预／后处理。
- [ ] 先写 `test_worker_loads_once_for_two_requests`、`test_worker_validates_each_input_and_keeps_unique_outputs`：用 fake load/infer 验证两请求只 load 一次，每次输入哈希和路径边界独立，目录不复用；不在普通测试中加载真实模型。
- [ ] 写 `test_worker_error_does_not_mislabel_next_request`、`test_worker_rejects_duplicate_ids_and_path_escape`：请求错误有对应 requestID；不能把日志当协议，JSON 禁 NaN；每次仍验证 workspace 边界及输出 symlink。
- [ ] 实现 Swift 明确队列／lease，actor 跨 await 可重入不能充当串行保证。最多一个请求在 Python 执行；排队请求取消只移除自己，不杀死别人的活动请求。错误 requestID、错误 input、EOF 或损坏 JSON 不得完成另一个请求。
- [ ] 用临时 fake Python worker 写 Swift 测试：两请求共用一个进程；故意错序／错 ID／大量 stderr；取消排队项；取消活动项；worker 中途退出。进程崩溃只报失败，下次用户重试才重启，不自动重复推理或发布。
- [ ] 活动请求取消时终止对应 worker 并等待退出，清理其队列，允许后续显式重试重建。shutdown 必须幂等，不能遗留子进程或阻塞管道。
- [ ] 整批 matte 阶段结束并进入检查／后续阶段、暂停、关闭／切换批次、切换引擎时 shutdown。GPU 内存不在用户长时间看图时常驻；同一批连续面之间则保留。
- [ ] 聚焦 Swift worker、AIWorkspace、bridge／executor 测试和 Python 全量。独立 `catalog`、`import-image`、`infer` 的现有调用仍通过。
- [ ] opt-in 实图按单次进程和 worker 处理相同 1、2、4 个输入：比较保存 Alpha／RGBA／ICC 精确一致，并分别记录进程启动、import、load、传输／首次推理、后续推理、保存。出现差异时不放宽 Alpha 阈值；查明来源并保留原路径作为回退。

**完成证据：** 同会话两次推理 load=1、活动推理峰值=1；生命周期测试通过；模型与算法参数完全不变；有实测收益和内存记录后才能默认切换工作流。

## 任务 7：在现有执行器中受限并发

**Files:** 修改 `WorkflowExecutor.swift`，必要时增加仅该执行器使用的运行句柄；测试 `WorkflowExecutorTests.swift`、`WorkflowIntegrationTests.swift`、`WorkflowOutputTests.swift`。不替换 PhotoshopExecutionCoordinator。

**Interfaces:** 新增私有 `runStageTasks(batchID: UUID, stage: WorkflowStage, taskIDs: [UUID], limit: Int) async throws`。复用 `execute(_:_:stage:)` 和现有 Services；Services 的共享 worker 来自任务 8。

### 7a：先并发纯本地导出

- [ ] 写 `testExportsOverlapWithMaximumTwoActiveRenders`：四面任务用 gate 证明两面可以同时 render，但峰值不超过 2；publish 仍在执行器版本检查后进行。
- [ ] 写 `testParallelExportPausePreventsLatePublication`、`testParallelExportFailureKeepsSuccessfulSide`：暂停停止新派发，过期结果不发布；一面失败不撤销另一面成功，只重试失败面。
- [ ] stage 为 hd／png4k 时最多派发两个任务，stack／geometry 保持原串行。每次派发前重新读当前 eligible/state，不把开始时的数组快照当持续授权。
- [ ] 所有任务状态修改、manifest 队列和发布前 fence 继续在 WorkflowExecutor actor 内；渲染在后台。不得把 `check` 后的 publish 分到另一个含 await 的步骤。
- [ ] 在途任务收尾后再 finish4KIntents／推进阶段；暂停／取消不清除未实际完成的 PS 租约。不得因为第一面完成就显示整只／整批完成。
- [ ] 跑 executor、integration、output 测试；四个检查开关组合、整只选择、换输出目录和重启恢复必须通过。

### 7b：最多两个蒙版任务错峰

- [ ] 在任务 8 完成后，写 `testMattePipelineOverlapsPSAndAIWithoutParallelAI`：A 面在 infer 时 B 面可以 exportStack；B 面 infer 时 A 面可以 install。fake PS coordinator 计数峰值 1，worker 活动 infer 峰值 1，总面任务峰值 2。
- [ ] matte 阶段使用同一 bounded runner，limit=2；PS 导出／回写仍走独占租约，AI 请求走共享单路 worker。每个面的 stackPNG、matteArtifact、install 事务继续先持久化再发布。
- [ ] 写 `testPipelinePauseAndManualLeaseDrainSafely`、`testPipelineRestartReusesCompletedInference`：暂停取消可取消的工作并停止派发，正在完成的不可中断 PS 操作不能放弃租约；人工编辑等待当前租约结束；重启复用已持久化结果而非重新推理或重复回写。
- [ ] 现有 `eligible` 的整批 stack／matte 边界保留。不得提前跨过打开的检查点；关闭检查点时才按既有逻辑自动继续。多任务失败不借“并发优化”自动排除标本。
- [ ] 真机对比串行与两面错峰：记录整批总时长、各阶段时间、内存与暂停行为。峰值=2 不是必然更快；若更慢、触发明显内存压力或结果不一致，将受影响阶段限制回 1，并在验收记录说明，不能删检查强行提速。

**完成证据：** 可证明的工作重叠、上限正确、端到端实测改善以及取消／恢复通过。几何应用仍串行，AI 仍单路，PS 仍单路。

## 9. 最终验证、现场保护和交付

当前真实批次清单（只读对照）：

```text
/Users/hans/Library/Application Support/Butterfly Toolkit/PhotoWorkflow/5FF0CED2-FA21-4D17-8DA4-2F8D8B62BCE2/batch.json
```

标本 22、33 四面此前全部完成，用户成品位于 `/Users/hans/Developer/tmp`。不要改 manifest 完成字段，不要覆盖这些 PNG／JPG。只读角色验证可使用已有 opt-in：

```sh
cd /Users/hans/Developer/butterfly-toolkit
perf_evidence_dir="$(mktemp -d /tmp/butterfly-perf-evidence.XXXXXX)"
TEST_RUNNER_WORKFLOW_EXPORT_BATCH='/Users/hans/Library/Application Support/Butterfly Toolkit/PhotoWorkflow/5FF0CED2-FA21-4D17-8DA4-2F8D8B62BCE2/batch.json' \
TEST_RUNNER_WORKFLOW_EXPORT_EVIDENCE="$perf_evidence_dir" \
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/butterfly-workflow-perf-build ENABLE_TESTABILITY=YES \
  -only-testing:'Butterfly ToolkitTests/WorkflowBridgeTests/testReal4KExportReuseAndPixelsWhenRequested' \
  test > /tmp/butterfly-workflow-perf-real.log 2>&1
```

该测试读取用户 PSD 并在临时 workspace 生成图片，不修改原文档。写入／并发蒙版测试必须另建临时 fixture，不能复用它直接 install/apply。测试里的 legacy 保存路径须真的仍调用旧 Save for Web，重命名 helper 后检查替换逻辑，防止新旧两组其实都走新代码。

- [ ] 增加 opt-in 分段测量：stack、AI 输入导出、进程／模型准备、infer、save_prediction、install、capture/hash、角色提取、prepareGeometry、render、publish；默认关闭，不在主路径逐像素写日志。
- [ ] 更新本轮证据，明确 cold／warm、测量次数、中位数、各项调用计数和内存。旧的单张 22.08 s 基线不能代表旧整批总耗时。
- [ ] 完成全部 Swift 与 Python 回归；新增 worker／并发测试必须在普通 suite 中运行，真实模型／PS 用例才 opt-in。记录真实通过／跳过数量，不照抄基线 165／36。
- [ ] 对照四面实际 RGBA、ICC／sRGB 标记、尺寸、Alpha、JPEG 参数；有问题时按任务回退。对比脚本仅写临时结果，不重新编码或覆盖原成品。
- [ ] `git diff --check`，检查两仓库范围及外来未跟踪文件，记录每批次 diff 和测试结果；用户要求的提交只包含本任务文件。
- [ ] 正式 Release build（不带测试环境变量），确认 App 空闲后启动。恢复原 batch.json、4K 页面和原预览选择，不能通过点击确认按钮测试已完成批次。
- [ ] 在 `docs/validation/` 新增本轮结果：逐项列出“完成／回退／未验证”，给出真实耗时和证据路径；不得把测试跳过或仅代码审查记为已验证。

交付给用户的说明只需：完成哪些编号、实际缩短多少、结果一致性、测试／提交号和仍有的限制。不要把计划中尚未实施的收益写成已经实现。
