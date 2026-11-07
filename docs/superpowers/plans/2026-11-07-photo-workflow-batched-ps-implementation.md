# Photo Workflow Batched Photoshop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox syntax for tracking. 用户要求本轮只写规范、计划与交接，下一位 agent 也必须先获得开始某项的指令；每项独立 review、提交后停止，不自动执行下一项，不自动创建新聊天。

**Goal:** 在画质和恢复边界不变的前提下，减少相邻 Photoshop 步骤的重复开关文档，并以实测选择交错或集中处理方式。

**Architecture:** 沿用 WorkflowExecutor、PhotoshopWorkflowBridge、单路 AI worker 和现有 PS coordinator。先建立可比较基线，再加合成后输入预备和仅在单个 bridge 服务内的文档复用，最后增加不改变外部阶段的集中 matte 调度候选；默认切换必须经过实测门禁。

**Tech Stack:** Swift／SwiftUI、actors、CoreGraphics／ImageIO、Photoshop ExtendScript、Python／Pillow／PyTorch MPS；不新增运行依赖。

**Spec:** [合成后预备输入与分阶段 PS 处理规范](../specs/2026-11-07-photo-workflow-batched-ps-design.md)。必须连同上一轮性能规范和任务 7 验收一起读。

## Global Constraints

- 固定 BiRefNet revision `5d6b6f8adcb5b417c871b1d84ceaae9871355b7f`、FP32、2048×2048，预／后处理不变；不启用 CPU fallback、不换后端、不量化、不训练、不下载模型。
- 高清 JPEG 0.82、不额外缩放；4K 4096×4096、默认安全边距 256、UI 范围 0…512；居中取整误差最多半像素，手动偏移有效，不重复旋转；预览底色 #74BFFF 不写入成品。
- 保留分层 PSD、可编辑蒙版和画布外像素；原 JPG／PSD／成品／原清单只读，写测试必须复制并重定向全部路径。
- 保留全批 stack／matte 边界、四个检查开关、双面确认、失败分类、归属／版本检查、原子发布与全部恢复记录。
- PS 一路、AI 一路，本地导出上限 2；不新增用户性能开关或通用调度框架，deployment target 26.5 不变。
- 启动时检查当前状态，不覆盖 `project.pbxproj` 并行修改、`output/` 图标产物、AI 的 `scripts/export_psd_sample.py` 或新出现的修改。当前基线 Toolkit `3938dea`、AI `43f0e46`；先确认分支包含它们。
- 所有下述新类型、方法、测试与开关均为**待实现接口**，不要误当作当前已有代码。保留旧入口的默认行为，直到 Task 5 放行。

## Review Focus

1. PSD 已成功、PNG 失败或返回前崩溃：只补 PNG，不能覆盖工作 PSD 重做合成。由 Task 2 验证。
2. 提前生成 PNG 后人工改 PSD、伪 sRGB／广色域／低 Alpha：旧缓存失效，保持像素和色彩，禁止绕过检查。由 Task 2 验证。
3. 租约内 dirty 文档、原子替换后的旧 documentID、暂停清理与手工优先：不误关、不误存、不提前释放。由 Task 3 验证。
4. 只完成 AI 就崩溃、失败面、致命会话错误、迟到回调：不得提前 matte completed、清缓存或在安装段启动 AI。由 Task 4 验证。
5. 旧清单、16 种检查组合、部分双面选择、换目录和已发布成品：仍按原边界停留、重启和重试。由 Task 4、5 验证。

## 文件地图与运行约定

`T/` 是 `/Users/hans/Developer/butterfly-toolkit`，`A/` 是 `/Users/hans/Developer/butterfly-ai`。

| 文件 | 责任 |
|---|---|
| `T/Butterfly Toolkit/Core/FocusStackProcessor.swift` | 合成保存后可选输入导出钩子，独立景深工具默认不变 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/PhotoshopWorkflowBridge.swift` | 输入验证／版本绑定、PS 操作内文档寿命、细分计时 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowExecutor.swift` | stack 结果接线、集中 matte 子阶段、当前授权及持久化 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowStateMachine.swift` | matte 子阶段存储后回 pending 的内部事件；不加持久化状态枚举 |
| `T/Butterfly Toolkit/Core/PhotoshopExecutionCoordinator.swift` | 沿用既有租约／人工优先；原则上不改 |
| `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowModels.swift` | 原 StackPNG／MatteArtifact／PSDSnapshot 契约；不要求新 manifest 字段 |
| 新 `T/Butterfly Toolkit/Features/PhotoWorkflow/WorkflowPerformanceSample.swift` | 仅默认关闭的操作级观测值与闭包类型，不做框架 |
| 新 `T/Butterfly ToolkitTests/WorkflowStackPreparationTests.swift` | 合成输入融合的普通测试及 opt-in 同内容等价测试 |
| 既有 `WorkflowBridgeTests.swift`、`WorkflowExecutorTests.swift`、`WorkflowStateTests.swift`、`WorkflowIntegrationTests.swift`、`WorkflowOutputTests.swift` | 文档寿命、子阶段、失败／暂停／恢复与检查组合 |
| `T/Butterfly ToolkitTests/WorkflowPipelinePerformanceTests.swift` | A/B/C/D、完整合成与相同堆栈基准、实际内存／暂停证据 |
| `T/scripts/verify_workflow_png_pairs.py` | 已有原始像素／色彩核验工具，复用，不放宽阈值 |
| `A/scripts/toolkit_bridge.py`、`A/scripts/run_birefnet_baseline.py` | 沿用现有 worker 和计时，本轮原则上不改 AI 数学实现 |

标准命令（使用独立 DerivedData；每轮日志和 xcresult 必须使用新的证据路径）：

```sh
cd /Users/hans/Developer/butterfly-toolkit
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/butterfly-next-perf-build ENABLE_TESTABILITY=YES test

cd /Users/hans/Developer/butterfly-ai
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B -m unittest discover \
  -s scripts -p test_toolkit_bridge.py -v
```

Swift 聚焦命令在 `test` 前加 `-only-testing:'Butterfly ToolkitTests/类名/方法名'`。每项先 RED（必须是行为失败而非编译错误），再最小实现、GREEN、指定类与完整 Swift 回归；AI 未改时至少首末两轮运行 Python 全套。每项记录实际通过／跳过／失败数、命令墙钟与真实性能范围，独立 reviewer 通过后仅暂存该项文件提交并停止。

## Task 1: 建立新的完整基线及细分观测

**Files:** 新增 `WorkflowPerformanceSample.swift`；修改 bridge、`WorkflowPipelinePerformanceTests.swift`，新增 `docs/validation/2026-11-07-photo-workflow-batched-ps-task-1.md`。只做观测，不改变调度和保存路径。

**Interfaces:** `nonisolated struct WorkflowPerformanceSample: Codable, Sendable { let taskID: UUID?; let operation: String; let seconds: Double }`；`typealias WorkflowPerformanceObserver = @Sendable (WorkflowPerformanceSample) -> Void`。Bridge initializer 增加 `performanceObserver: WorkflowPerformanceObserver? = nil`。测试用锁保护收集器，不为计时往版本检查与同步 publish 之间加 await。

- [ ] 写 `testPerformanceObserverIsOptInAndPreservesResults`、`testLeaseWaitIsSeparateFromOperationTime`：默认无观测，开启时输入／输出及事件次序不变；用 gate 分辨排队和执行区间，不能仅断言耗时大于零。
- [ ] 运行上述聚焦测试取得 RED；记录插桩前完整基线的 Swift／Python 结果，失败先定因。
- [ ] 实现默认关闭的操作级观测。PS 脚本将可选内部 open/save/encode/close 时长随 Metadata 返回；Swift 记录 invoke 总耗时、hash/copy/capture、租约等待。保持脚本错误传播及已有字段解码兼容。无法精确拆出的项明确列为包含，不编造纯设备时间。
- [ ] 扩展实测入口 `testNextRoundSavedStacksWhenRequested`、`testNextRoundFullBatchWhenRequested`；真实入口使用下文环境变量且必须 opt-in。验证正式测量计时包含应有操作，setup 不偷藏输入预备。
- [ ] 按规范 §6 留下 A 的固定堆栈及完整 JPG 流程基线、保护哈希、计数和事件日志。与未插桩版本比较观测开销；影响正式墙钟时关掉细分观测另跑诊断组。
- [ ] 跑 `WorkflowBridgeTests`、`WorkflowPipelinePerformanceTests` 和完整回归；记录、review 后提交 `test(workflow): establish batched Photoshop performance baseline`，停止。

## Task 2: 景深合成保存后顺便准备输入 PNG

**Files:** 修改 `Core/FocusStackProcessor.swift`、bridge、executor；新增 `WorkflowStackPreparationTests.swift`；复用既有 PNG 比较脚本。新增本任务验证记录。

**Interfaces:** 在 bridge 文件定义 `nonisolated struct WorkflowStackPreparation: Sendable { let snapshot: PSDSnapshot; let input: StackPNG? }`；新增 `stackWithInput(job: FocusStackJob, owner: UUID) async throws -> WorkflowStackPreparation`。Services 新增默认 nil 的可选 `stackWithInput: (@Sendable (FocusStackJob, UUID) async throws -> WorkflowStackPreparation)?`，旧 stack 保留作 A 对照。FocusStackProcessor 的 `process`／`jsx` 增加默认 nil 的 `workflowPNGExportScript: String?`，仅由 bridge 生成固定可信脚本，在 PSD save 成功后、stackDocument 关闭前执行；不是用户脚本入口。

- [ ] 写 `testStackExportRunsAfterSaveBeforeClose`：事件严格 save→PNG→close，PNG 不另开堆栈；原始分层内容保留；独立景深工具不传钩子时完全走旧路径。
- [ ] 写 `testPNGFailureKeepsPublishedStack`、`testResumeAfterStackPublicationOnlyRetriesPNG`：PNG 故障不使有效 PSD 重做；崩溃后可按既有归属恢复；正式 PSD 发布失败时不能采用孤立 PNG；同名外来 PSD 仍拒绝。
- [ ] 写 `testPreparedInputCannotBypassStackReview`、`testEditedStackInvalidatesPreparedInput`：打开检查点时 infer=0；确认前保存变更使旧 PNG／AI 失效；旧 manifest 缺 input 时仍可补导出。
- [ ] 跑新类和对应 executor 测试取得 RED。实现钩子失败仅使候选 PNG 不可用，PSD 正常发布继续；主合成／保存失败仍抛错。输入先输出在本任务临时路径，正式 PSD capture 成功后验证并绑定 contentVersion，移入原 `data/processed/<owner>/` 命名契约；阶段结果在 executor actor 中保存 snapshot 和可选 input。
- [ ] 实现 opt-in `testFusedStackPNGMatchesReopenedExportWhenRequested`：同一次合成保存内容的关闭前导出与重新打开导出，真实四面及 sRGB8／AdobeRGB8／sRGB16／软 Alpha 夹具逐项比较原始像素和 ICC。内存中的 stackDocument 使用原有 saveAs(copy) 行为，必须证明导出的内容与保存 PSD 相同，不能只因路径名相同就绑定版本。
- [ ] 计时 A 对 B，记录省掉的 open／close 次数、仍然必要的 PSD 保存和哈希次数。全套、独立 review、记录后提交 `perf(workflow): prepare AI input during focus-stack save`，停止；默认优化是否启用由 Task 5 决定。

## Task 3: 复用单个 PS 服务内打开的文档

**Files:** 修改 bridge；扩充 `WorkflowBridgeTests.swift`、`WorkflowExecutorTests.swift`；新增本任务验证记录。不改 PS coordinator 的租约规则，不移除执行器跨服务验证。

**Interfaces:** bridge 内私有 `OpenedWorkflowDocument: Sendable` 保存 `documentID: Int`、`url: URL`、`openedByWorkflow: Bool`；私有 `withOpenDocument<T: Sendable>(at: URL, operation: @Sendable (OpenedWorkflowDocument) async throws -> T) async throws -> T` 仅允许从已经取得 coordinator 租约的代码调用。initializer 增加默认 false 的 `reuseDocumentsWithinOperation: Bool` 供 A/B 对照。持久化模型不新增 PS documentID。

- [ ] 写 `testApplyKeepsDocumentOpenThroughSaveAndCapture`、`testInstallReusesOnlyLeaseOwnedDocuments`：相同读取保持检查次数和先后关系，但减少实际打开／关闭；PS 服务峰值仍 1，临时副本数量有界。
- [ ] 写 `testPublicationReplacesDocumentHandle`：发布旧文档已关闭，新版重新验证；finally 不能用旧 ID 关闭被重新打开的用户文档。写 `testDirtyBorrowedDocumentIsNotSavedOrClosed`、`testPauseWaitsForDocumentCleanupBeforeManualLease`、`testPhotoshopRestartDoesNotReuseOldDocumentID`。
- [ ] 跑新测试取得 RED；最小实现操作内句柄复用。每次操作仍核对 ID／路径／保存状态；用户打开文档不得当作自动拥有。出现 dirty／不确定状态不强行保存或丢弃，暂停并保留人工处理入口；失败清理不以取消为由提前放弃租约。
- [ ] 将 installMatte／applyGeometry 中相邻 verify、脚本修改、capture 接到同一次操作内的已打开文档；原子替换处明确结束旧句柄、重新取得新句柄。保留 capture 的前后检查与所有内容哈希，不把内存中刚保存的状态直接当作磁盘回读已通过。
- [ ] 比较 B 对 C 的完整流程、A 对 C 的同堆栈后半程；记录文档次数、内存、PS 细分成本。输入、角色、最终输出精确比较；正常与 prepared／published／几何保存中断都要恢复。
- [ ] 指定 bridge／executor／integration 测试及完整回归，独立 review 后提交 `perf(workflow): reuse PSD documents within protected operations`，停止。

## Task 4: 增加集中 matte 调度候选，默认仍交错

**Files:** 修改 executor、state machine；扩充 `WorkflowStateTests.swift`、`WorkflowExecutorTests.swift`、`WorkflowIntegrationTests.swift`、`WorkflowOutputTests.swift`、性能类；新增本任务验证记录。

**Interfaces:** `nonisolated enum WorkflowMatteScheduling: Sendable { case interleaved, phased }`；executor initializer 新增 `matteScheduling: WorkflowMatteScheduling = .interleaved`。私有 `runPhasedMatte(batchID: UUID) async throws`、`prepareMatteInput(batchID: UUID, taskID: UUID) async throws`、`inferPreparedMatte(batchID: UUID, taskID: UUID) async throws`、`installPreparedMatte(batchID: UUID, taskID: UUID) async throws`。新增内部事件 `WorkflowEvent.mattePreparationStored(taskID: UUID, expectedVersion: Int)`，不新增磁盘状态。

- [ ] 写 `testMattePreparationStoredRemainsPending`：事件仅接收 running／当前 revision／有效 snapshot 与同版本 StackPNG；保留 stackPNG／matteArtifact，回 pending、revision+1、error=nil，outputVersion／confirmedVersion 为空，其他阶段和文件不变。陈旧事件、暂停后迟到事件均拒绝。
- [ ] 写 `testPhasedMatteCompletesInputsBeforeStartingWorker`、`testPhasedMatteWaitsForWorkerExitBeforeInstall`：全批输入完成才开始 worker；AI 期间 PS 调用为 0；AI 峰值 1；worker exit 先于首次 install；总面任务不得超过现有上限。
- [ ] 写 `testPreparedInferenceDoesNotCompleteMatteOrCleanFiles`、`testInstallPhaseCannotInferAgain`：仅有 AI 结果时仍 pending，不能触发 matte 检查完成或几何；输入和结果仍在；安装遇到缺失／不匹配缓存应失败等待显式重试，不偷启 worker。
- [ ] 写 `testPhasedResumeReusesArtifactsAcrossAllBoundaries`、`testPhasedFailurePreservesOtherFacesAndBatchBarrier`、`testPhasedFatalWorkerErrorCannotAutoRestart`。覆盖输入后、AI 后、prepared、published、PS 退出、缓存篡改、用户保存变化；已安装但旧清单未收尾沿原 refresh／validateInstalledMatte 恢复，不重复安装／推理；失败面阻止整批几何，不自动排除。
- [ ] 跑上述聚焦测试取得 RED；实现 input→AI→shutdown→install 四段。输入和 AI helper 各自 stageStarted、检查、写缓存、mattePreparationStored 并 persist；不得调用原 execute(.matte) 的完成／cleanup 尾部。安装成功才按原逻辑 stageCompleted 和清理。缓存已有效则不重复工作；snapshot 已含有效 roles 的恢复任务不强制重新生成已清理的 AI 输入。
- [ ] 在一个 runStages 保护区内完成子阶段，复用运行句柄和取消机制；每次派发重新读取 eligible／state，失败字段按现有分类保存；任何异常退出也关闭 worker并排空当前 PS 操作，不能自动落回 interleaved。准备失败的面跳过后续子阶段，但其他有效面仍可完成本阶段。
- [ ] 两种模式都跑全部 16 开关组合、整只选择／未选面、换目录和旧 manifest 恢复；测 C 对 D，保存所有样本，不改默认。全套和独立 review 后提交 `perf(workflow): add phased matte scheduling candidate`，停止。

## Task 5: 完整对照、选择默认与最终交付

**Files:** 性能测试、必要的生产初始化默认值、CHANGELOG、`docs/validation/2026-11-07-photo-workflow-batched-ps-final.md`。仅更改已通过候选的选择，不新增优化。

**Interfaces:** 测试初始化组合固定如下：A=旧 stack／reuse=false／interleaved，B=stackWithInput／false／interleaved，C=stackWithInput／true／interleaved，D=stackWithInput／true／phased。live 默认接线在本任务才依据门禁改变；保留内部测试控制用于回退对照。

- [ ] 先核对 Task 1–4 证据及无未解决 review；为最终选择写 `testLiveConfigurationMatchesAcceptedCandidate`，断言准确配置，不以墙钟阈值写普通单测。
- [ ] 完成规范 §6 的三层测量、三轮四配置与最终至少五轮配对。完整批次的 A 必须真实运行当前优化后的交错流程，不用旧 237 秒串行结果充当基线。
- [ ] 同固定堆栈验证 Float32 Alpha、原始 RGBA／ICC／方向／尺寸、几何解；安装和几何中的已有误差容限保持原样，不能拿内部容限代替跨配置精确一致断言。
- [ ] 额外真实故障／恢复专项：活动 AI 中暂停、安装 prepared/published 暂停、几何保存边界、输出发布中断及手工编辑；记录恢复推理／安装／旋转次数、迟到发布、worker 退出及人工获租顺序。所有写入在副本上。
- [ ] 按规范门槛选择 A/B/C/D：完整四面五轮中位数至少改善 5%、至少四轮更快、2 面不退化超过 5%、同堆栈不退化；画质／恢复失败立即保留旧路径，内存恶化则回退相应部分。没有胜出候选时如实报告，不为完成计划强行改默认。
- [ ] 最终 Swift／Python 全量、正式 Release build（不带测试变量），空闲时用独立应用和全路径副本验收；恢复原批次页面及选择，保护哈希前后相同；没有权限／锁屏则写未验证。
- [ ] 记录每项“启用／保留旧路径／未验证”、收益范围、文件体积／内存代价、失败样本；独立 review 后提交 `perf(workflow): select measured Photoshop scheduling defaults`（若不改默认，用 docs 提交），停止。推送／安装按当时用户指令执行。

## 真实测试入口约定

新增 opt-in 测试读取 `WORKFLOW_NEXT_MODE=A|B|C|D`、`WORKFLOW_NEXT_BATCH`、`WORKFLOW_NEXT_STACKS`、`WORKFLOW_NEXT_ENGINE`、`WORKFLOW_NEXT_EVIDENCE`、`WORKFLOW_NEXT_COUNT=1|2|4`；经 xcodebuild 传递时全部加 `TEST_RUNNER_` 前缀。完整 JPG 批次仅 COUNT=2／4（完整标本），参考批次只用于源文件清单，测试自己复制 JPG 并构造空白新批次；不复用旧 completed 字段。

EVIDENCE 必须尚不存在；任一写目标解析后不在临时根下直接拒绝。真实来源：`/Users/hans/Developer/tmp/origin`，参考只读清单 `~/Library/Application Support/Butterfly Toolkit/PhotoWorkflow/5FF0CED2-FA21-4D17-8DA4-2F8D8B62BCE2/batch.json`。旧堆栈列表 `/tmp/butterfly-perf-task2-20261107/stack-fixtures.json` 若仍存在先核对哈希；若已清理，生成新受保护副本，不虚构旧证据。

调用示例（先构建包含新入口的测试二进制，runner 创建尚不存在的证据路径；其他必需变量同上）：

```sh
TEST_RUNNER_WORKFLOW_NEXT_MODE=A \
TEST_RUNNER_WORKFLOW_NEXT_EVIDENCE="$next_evidence_path" \
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/butterfly-next-perf-build ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:'Butterfly ToolkitTests/WorkflowPipelinePerformanceTests/testNextRoundFullBatchWhenRequested' \
  test-without-building
```

本轮只交付计划，不执行上述新接口、测试或任何产品修改。接手摘要见[交接文案](../../handoffs/2026-11-07-photo-workflow-next-round.md)。
