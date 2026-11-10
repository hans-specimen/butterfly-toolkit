# 蒙版残留清理与裁切一致性实施方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 清除可确认的背景残留，让可编辑蒙版、透明成品和裁切使用同一完整主体范围，同时保护触角、细毛、尾突与半透明翅缘。

**Architecture:** 在现有 Swift 清理模块中统一完成可信主体识别、轮廓邻近细节保护和残留分类，返回连续 Alpha、主体支持范围与诊断结果。自动流程只生成派生产物；人工保存的 PSD 保持最高优先级，刷新和导出不重新清理。严格裁切、颜色和文件身份校验继续有效。

**Tech Stack:** Swift、CoreGraphics/ImageIO、现有 Photoshop 执行协调器、XCTest；不新增 Python 包或模型依赖。

**Spec:** 本文“已确认需求与边界”记录本次对话确认的规格；现行流程参见 [照片工作流](../../PHOTO-WORKFLOW.md)。下方任务清单保留原计划，实际执行结果以本节和 [验证记录](../../validation/2026-11-10-robust-matte-cleanup.md) 为准。

## 执行状态（2026-11-10）

- 任务 1–4：本地实现完成，包含失败复现、保守清理、完整范围统一、报告身份／保存版本绑定、人工结果保护和四类状态。部分测试合并进已有用例，名称不完全沿用原计划。
- 任务 5：最终常规测试 318 通过、19 项按需真实环境测试跳过；另行执行全批 20 面 Photoshop 副本回放和人工擦除／裁切保存测试，均通过。四个异常面恢复约 10% 留白；SC10140_V 有效背景限制保留约 9.56%，仍正确提示。
- 全批 23 个删除区域已由 agent 查看放大图与叠加图；用户最终画质验收尚未进行。保留不确定细节，不承诺所有输入自动清理成功。
- 几何模块直接采用保存结果的全部实际非零 Alpha，只共享可信核心用于方向估计；不重新调用自动清理。这是保护人工和历史结果的实施边界。
- 未运行模型推理，未提交、推送、合并或安装，版本仍为 1.3.2 (7)。

## 已确认需求与边界

- 保留四步工作流：图层堆栈或已有 PSD → AI 抠图与蒙版回写 → 裁切矫正并停下人工检查 → 合并导出。
- PSD 同时保留可恢复完整背景的可编辑「抠图」蒙版备份，以及默认选中、边界贴合实际非零 Alpha 的「透明成品」。不能靠销毁原 RGB 来缩小边界。
- 4K PNG 继续为 **4096 × 4096**，主体居中加留白；「底图」导出不为了匹配 4K 而重新构图。
- 识别范围应与实际输出一致：不能只在裁切计算中忽略残留，却在 PSD/PNG 中留下非零像素。
- 删除有充分证据的背景；不确定的分离细节保留并标记。不能保证仅凭 Alpha 自动区分所有细毛与噪声。
- 本轮仅写实施方案及交接。后续提交、推送、合并和安装按届时明确授权处理。

## Global Constraints

- 原照片、已有 PSD、原始 AI 结果和用户批次目录不覆盖；真实验证使用独立临时目录与素材副本。
- 刷新人工保存结果时不重跑抠图、清理、旋转、裁切或重建透明成品；旧批次不静默迁移。
- 保留源哈希、任务归属、阶段修订、保存版本、导出凭据、RGB、ICC、Alpha 和有效背景检查；不能放宽校验来制造通过。
- Photoshop 操作必须经过 `PhotoshopExecutionCoordinator`；未保存的人工编辑不能被自动保存或丢弃。
- `prepareStackInput`、`reuseDocumentsWithinOperation` 默认关闭，抠图默认 `.interleaved`；不随本次优化调整。
- 用户数据和模型不加入 Git；源码、测试与诊断说明使用中文职责注释，输出证据放 `/tmp`。
- 文档阶段不升版本；实施完成后按 [版本管理](../../VERSIONING.md) 决定升号。

## Review Focus

1. 主体或触角碰到画布边缘：不能仅因贴边、细长而删除。任务 1/2 覆盖。
2. 透明翅片、断开的触角末端、多块真实主体：不能仅保留最大连通块或高 Alpha 部分。任务 1/2 覆盖。
3. 一像素弱桥把主体连接到边缘残留：不能无条件扩张到整条边，也不能自动切断可能的真实触角。任务 2 覆盖。
4. 用户手动改层、裁切、隐藏备份后保存：刷新和导出必须尊重实际保存结果。任务 3/5 覆盖。
5. 旧批次重开、异步任务取消或输入被替换：旧结果不能覆盖新状态，不能暗中套用新的清理决策。任务 3/4 覆盖。

## 当前证据与根因

编写时主分支提交为 `489ff8f`。当前源码的 `MaskResidueCleanup.clean` 对含 Alpha ≥ 16 的分量，只有同时满足面积上限、峰值 < 32、均值 ≤ 8 才可能移除；矩形保护区又会保留部分远离实际轮廓的区域。`MeaningfulMaskSupport` 随后另外筛选一次，`isPlausibleDetail` 会保留含两个强像素的分量。这里存在两套主体判据。

本次三个标本涉及四个异常面，表现并不相同：

| 面 | 诊断到的外部残留 | 当前行为 |
| --- | --- | --- |
| SC10136_D | 底边两条残留，共 11,509 像素；峰值 25/18 | 自动裁切未应用 |
| SC10136_V | 左下分离斑块 615 像素；均值 5.30、峰值 23 | 已裁切，但留白约 7.5%，附警告 |
| SC10137_V | 左下分离斑块 738 像素；均值 3.70、峰值 19 | 已裁切，但留白约 8.7%，附警告 |
| SC10138_V | 底边条带 7,916 像素；均值 13.75、峰值 110 | 自动裁切未应用 |

这六个正反面快照均包含「透明成品」，不能归因于旧图层结构未升级。截图粉色为不可应用裁切的界面覆盖色，不是实际背景像素。

本地诊断报告：`/tmp/toolkit-three-diagnosis/report.json`；脚本：`/tmp/toolkit-three-diagnosis/main.swift`。内存中排除远处分量后，四面均得到可应用且约 10% 留白的结果。这仅支持“外部残留拉大主体范围”的诊断，**不是安全清理算法的验收**。该实验使用矩形与距离排除，不得直接复制成生产实现。

原批次清单：`/Users/hans/Library/Application Support/Butterfly Toolkit/PhotoWorkflow/EF526BEE-4DA1-4EFE-9C84-6470634FFDBF/batch.json`，诊断时 revision 278，10 只 / 20 面。输入目录：`/Users/hans/SynologyDrive/Butterfly/_Original_Sony/260701_栎蛱蝶/`。这些路径仅用于只读定位，不代表写入授权；临时报告丢失时从现存快照重新提取。

## 文件与职责

以下路径均相对仓库根目录；只修改必要部分，不整理无关结构。

| 文件 | 本次职责 |
| --- | --- |
| `Butterfly Toolkit/Core/ImageProcessing/MaskResidueCleanup.swift` | 统一分析、清理与结构化诊断，保留旧 `clean` 调用入口 |
| `Butterfly Toolkit/Core/ImageProcessing/SpecimenGeometry.swift` | 完整主体范围与渲染 Alpha 一致；翅顶估算可以使用独立的严格种子范围 |
| `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowMatteService.swift` | 验证原始结果后分析一次，生成独立清理产物与可追溯报告 |
| `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowModels.swift` | 在 `MatteArtifact` / `PSDSnapshot` 扩展可选诊断引用与版本，保持旧记录解码兼容 |
| `Butterfly Toolkit/Features/PhotoWorkflow/WorkflowExecutor.swift` | 传递诊断及处理版本，不改变人工保存优先级 |
| `Butterfly Toolkit/Features/PhotoWorkflow/PhotoWorkflowView.swift` | 清晰区分已裁切、留白不足、残留待检查和自动裁切未应用 |
| `Butterfly ToolkitTests/MaskResidueCleanupTests.swift`（新增） | 算法、不变量与困难输入测试 |
| `Butterfly ToolkitTests/MaskGeometryProcessorTests.swift` | 蒙版实际范围与裁切一致性 |
| `Butterfly ToolkitTests/WorkflowBridgeTests.swift`、`WorkflowFinalizationTests.swift` | 严格验证、旧流程与人工编辑保护 |
| `Butterfly ToolkitTests/WorkflowResidueLiveTests.swift` | 整批可选真实 Photoshop 回放和保存后读回 |
| `docs/TESTING.md`、`docs/PHOTO-WORKFLOW.md` | 最终行为及验证入口；历史证据另行注明范围 |

`PhotoshopWorkflowBridge.swift` 现有可编辑备份 + 透明成品机制优先复用；仅在回放证明必要时修改，不重写图层协议。

## 核心设计与接口

新增 `MaskResidueCleanup.analyze(_ values: [UInt8], width: Int, height: Int) throws -> MaskCleanupResult`。保留 `clean` 作为返回 `analyze(...).alpha` 的兼容入口。类型位于同一清理文件，均为 `Sendable`：

- `MaskCleanupResult`：`alpha: [UInt8]`、`subjectSupport: [UInt8]`、`coreSupport: [UInt8]`、`report: MaskCleanupReport`。
- `subjectSupport` 为 0/1，严格等于 `alpha > 0`；`coreSupport` 是可信种子集合，仅用于方向/翅顶分析，不能用于裁掉弱细节。
- `MaskCleanupReport`：`algorithmVersion: Int`、`removedPixelCount: Int`、`regions: [MaskCleanupRegion]`；可序列化，坐标为原始栅格像素，矩形使用左上坐标与宽高，不混入视图坐标。
- `MaskCleanupRegion`：`bounds: CGRect`、`pixelCount: Int`、`decision: MaskCleanupDecision`、`reason: MaskCleanupReason`。
- `MaskCleanupDecision`：`removedBackground` / `retainedDetail` / `uncertain`。
- `MaskCleanupReason`：`remoteHaze` / `edgeBand` / `nearContourDetail` / `connectedDetail` / `ambiguousConnection` / `noReliableCore`。

### 判定顺序

1. 输入尺寸、溢出、取消检查沿用严格约束。先按原图有效 Alpha 屏蔽不可见区域；坐标和 Alpha 合成方式沿用生产解码，不能以预览图替代。
2. 用多阈值连通性找到高可信前景种子，再恢复与它相连的较弱主体。多个有充分支持的种子都保留；没有可靠种子时返回原 Alpha 和不确定诊断，交后续严格检查，禁止猜测删除。
3. 保护区改为到**实际可信轮廓**的距离带，距离随图像尺寸归一化；不能用主体外接矩形膨胀代替。保护相连弱边缘和附近分离细节，不膨胀输出 Alpha 本身。
4. 对外围分量计算到轮廓的最近距离、Alpha 分布（含分位数/强像素比例）、面积相对值、形状、接触哪条图像边缘及接触长度。远处淡斑不能因面积稍大或少数亮点免于检查。
5. `remoteHaze` 需同时满足远离保护带、总体低置信度、没有可信前景种子；`edgeBand` 还需沿画布边缘延展的形态证据，不能仅凭贴边删除。峰值不是唯一否决或删除条件。
6. 弱桥连通、贴边真实主体、较强的远处分量等无法可靠区分时标记 `uncertain` 并保留；首版不尝试自动切断真实连通分量。局部重建使用迟滞/受限扩张思路，但不能让单条微弱路径无条件吞入整条边。
7. 仅把确认的背景设为 0，保留区域逐像素 Alpha 不变，不做整体二值化、模糊、侵蚀或统一截断。每个被删除区域必须有可回溯原因。

**参数确定规则：** 先在任务 1 建立人工核对的保留/删除区域，再用任务 2 的统一参数在全体夹具上验证。阈值集中为内部 `Policy`，对外只暴露算法版本；最终值及归一化单位写进测试和说明。禁止按标本名称分支、针对单图调参，禁止用“让四张通过”作为选值目标。若一组参数无法兼顾真细节和残留，保留不确定区域并说明限制，不继续放宽保护规则。本文不把尚未验证的数值包装成已确定算法。

## 任务 1：建立回归样本和可审计的判定基准

**文件：** 新增 `MaskResidueCleanupTests.swift`；扩展 `WorkflowResidueLiveTests.swift`。

**接口：** 消费现有批次快照；产生临时证据目录内的 `fixture-index.json`，每面记录源哈希、尺寸、坐标原点、原始/有效 Alpha、人工核对保留区和删除区。可提交的合成夹具用 Swift 生成，不提交用户照片或实际蒙版。

- [ ] 编写现有缺陷复现测试：`testLargeRemoteHazeIsRemoved`、`testEdgeBandWithBrightSpecksIsRemoved`，分别模拟 615/738 像素淡斑和带峰值 110 的底边条带；断言残留区归零、主体像素不变。用现有 `clean` 运行并确认失败原因确为残留保留。
- [ ] 编写保护测试：`testTouchingEdgeSubjectSurvives`、`testDetachedAntennaAndTranslucentWingSurvive`、`testMultipleTrustedComponentsSurvive`；断言标注区域每个 Alpha 值与输入一致。
- [ ] 从四个异常面及两面正常对照只读提取派生证据，生成“原 Alpha / 删除候选 / 保留细节”叠加图；核对候选确实不含蝴蝶结构。无法判断的区域标记不确定，不建立删除答案。
- [ ] 将回放测试的样本选择改为可枚举批次，移除 `name == "33"` 的固定像素数量断言；让每面断言来自该面证据，不能只统计裁切是否通过。

## 任务 2：实现统一清理与完整主体范围

**文件：** `MaskResidueCleanup.swift`、`SpecimenGeometry.swift`、`MaskResidueCleanupTests.swift`、`MaskGeometryProcessorTests.swift`。

**接口：** 实现上述 `analyze` 与结果类型；`MeaningfulMaskSupport` 消费结果。完整边界直接使用 `subjectSupport`，翅顶估计使用 `coreSupport`；删除 `isPlausibleDetail` 对完整主体范围的第二套接纳规则。

- [ ] 为新接口添加失败测试：`testCleanupIsIdempotent`（二次分析 Alpha 与第一次完全相等）、`testSupportMatchesEveryNonzeroAlphaPixel`、`testRetainedAlphaIsUnchanged`、`testWeakBridgeIsRetainedAndFlagged`、`testNoReliableCoreDoesNotDelete`。
- [ ] 按“判定顺序”实现分析，参数从夹具验证得到后固定；为不同尺寸、平移/旋转及距离带边界添加等价性测试。每个删除分量必须有诊断，不能用矩形内外判定替代实际轮廓距离。
- [ ] 更新几何完整范围计算；添加 `testCropContainsAllRetainedAlpha`，以及“真正背景不足仍不可应用”的反例。角度分析可过滤噪声，完整裁切不能过滤仍会渲染的像素。
- [ ] 运行该任务相关测试至通过；记录典型相机尺寸的运行时间与峰值内存，和旧实现对照。避免全图多份 `Int` 数组或每像素扫描所有轮廓点；保留取消响应测试。

## 任务 3：自动流程只生成一套派生结果，保护人工修改

**文件：** `WorkflowMatteService.swift`、`WorkflowExecutor.swift`、`WorkflowModels.swift`，以及相关 Bridge/Finalization 测试。

**接口：** `WorkflowMatteService` 在原始结果严格验证后调用 `analyze`；报告写入派生目录 `cleanup-report.json`。在 `MatteArtifact` / `PSDSnapshot` 添加可选 `cleanupReportURL: URL?`、`cleanupReportFingerprint: String?` 及 `cleanupAlgorithmVersion: Int?`，缺省值代表旧记录；读取旧记录不自动清理。快照引用绑定其保存版本，不能跨人工保存版本复用。

- [ ] 添加失败测试：`testCleanedMaskAndCutoutShareAlpha`、`testCleanupPreservesICCAndInputIdentity`、`testOldRecordWithoutCleanupReportLoads`。保留全部既有 RGB/Alpha/ICC 拒绝测试。
- [ ] 生成独立清理蒙版及抠图，复用当前写入和重新验证逻辑；报告与产物关联、哈希核对、取消清理仅作用于本次新建目录。
- [ ] 自动几何使用该清理后的蒙版；需要重复分析时保证相同版本且幂等。人工最终保存分支使用实际成品 Alpha 计算范围，不能重新调用清理；历史诊断不能冒充新保存版本的分析结果。
- [ ] 添加 `testManualRefreshNeverCleansOrRebuildsFinishedLayer`、`testStaleCleanupCannotReplaceNewSnapshot`、`testCancellationPreservesSourceAndBatch`；同时覆盖 `manualFinalization == false` 旧流程。
- [ ] 核对蒙版备份仍能恢复全幅 RGB，透明成品为实际应用蒙版后的像素层；不以破坏备份作为缩边手段。

## 任务 4：明确结果状态与残留位置

**文件：** `PhotoWorkflowView.swift`、诊断模型与现有相关测试；必要时局部调整 `WorkflowGeometryPreview.swift`。

**接口：** UI 读取已绑定当前自动处理版本的 `MaskCleanupReport`；裁切是否应用继续由真实几何结果决定。人工保存版本已变化时不继续展示旧删除区为当前问题。

- [ ] 添加状态映射测试：成功、成功但留白减少、保留不确定区域、自动裁切未应用四类，不能都显示为“失败”。
- [ ] 显示具体位置和行动，例如“下边缘发现条带残留，已清理”“左下有无法确定的分离细节，已保留，请检查蒙版”；不确定区域可定位高亮，覆盖层不得写入图像。
- [ ] 真正背景不足显示“完整主体已保留，原图有效背景不足以达到目标留白”；不可应用显示“自动裁切未应用”，保留现有人工调整与确认导出入口。
- [ ] 核对旧批次无报告的回退文案，以及人工保存后旧诊断失效行为；不增加修改类型选择或新的强制确认步骤。

## 任务 5：整批真实往返与交付证据

**文件：** `WorkflowResidueLiveTests.swift`、必要的 `WorkflowFinalPSDLiveTests.swift` 扩展、`docs/TESTING.md`、`docs/PHOTO-WORKFLOW.md`。

**接口：** 回放现有 Alpha 经过生产清理、PS 回写、裁切、保存读回与导出；不运行模型。每面生成可核对 JSON 与前后图，区分纯算法、Photoshop 往返、真实模型推理三个验证层次。

- [ ] 先运行全套常规测试，所有未跳过测试通过后再执行真实 Photoshop 验证。
- [ ] 在独立目录串行回放当前 10 只 / 20 面。每面记录原始及清理 Alpha 范围、删除区域与理由、裁切角度/尺寸/留白、保存后成品非零 Alpha 范围，以及原文件前后哈希。
- [ ] 核对四个异常面背景残留被移除、保护区像素不变；其余 16 面没有丢失细节。若没有真实有效背景不足，四面应可应用且留白回到约 10%；确有不足则正确警告，不硬凑通过。
- [ ] 从保存后的 PSD 直接读回默认选中透明成品的像素边界，与同一坐标系的预期非零 Alpha 范围一致；同时验证隐藏蒙版备份可恢复背景。
- [ ] 在副本上进行一次人工蒙版/像素/裁切修改并保存，再刷新及导出；证明没有自动覆盖人工结果，4K 为 4096 × 4096，堆栈原图仍来自「底图」。
- [ ] 人工查看全批删除区叠加图，逐项检查触角尖、细毛、白色翅缘与半透明区域。只看缩略图或绿色测试总数不能算质量验收。
- [ ] 更新现行文档和有日期的验证记录，写清失败/未覆盖项。既有 22_D / 33_V 成功记录仍为历史证据，不能替代本批次验收。

### 验证命令

常规测试（可用 `-only-testing` 缩小到任务相关测试；最终必须全量）：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -configuration Release -project 'Butterfly Toolkit.xcodeproj' \
  -scheme 'Butterfly Toolkit' -destination 'platform=macOS' \
  -derivedDataPath /tmp/toolkit-robust-matte-tests \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES
```

真实回放沿用 `WorkflowResidueLiveTests/testSavedMatteReplayThroughPhotoshopWhenRequested`。通过 `TEST_RUNNER_WORKFLOW_RESIDUE_BATCH`、`TEST_RUNNER_WORKFLOW_RESIDUE_EVIDENCE`、`TEST_RUNNER_WORKFLOW_RESIDUE_NAME`、`TEST_RUNNER_WORKFLOW_RESIDUE_SIDE=D/V` 指定样本；只运行该方法，并为每面使用新的证据目录。先按任务 1 扩展批量入口，再串行运行全部 20 面。完整环境说明见 [测试指南](../../TESTING.md)。

## 完成标准与停止条件

- 四个已知反例和细节保护反例都通过，同一清理规则覆盖全批；不添加按文件名识别的例外。
- 蒙版、成品、裁切和 4K 的实际 Alpha 范围一致；保留区域 Alpha 不变、可编辑 RGB 备份不损坏。
- 常规测试通过，20 面真实回放与人工细节检查有证据；跳过或未执行的验证明确列出。
- 确认会误删真实细节、需要切断不明弱桥、或需要绕过有效背景检查时停止扩大删除规则，将该区域归为不确定并报告。不能承诺所有输入全自动成功。
- 代码完成、测试完成、提交、推送、安装分别报告；本计划不自动授权最后三个动作。

## 设计参考

高低阈值结合连通性的思路参考 [scikit-image 迟滞阈值定义](https://scikit-image.org/docs/0.23.x/api/skimage.filters.html#skimage.filters.apply_hysteresis_threshold)。这里仅借用算法概念，在 Swift 内实现；不新增该依赖，也不把迟滞连通本身当作完整背景分类器。
