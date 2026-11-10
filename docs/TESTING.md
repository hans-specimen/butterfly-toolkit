# 测试指南

本文说明当前测试入口、覆盖范围与运行条件。测试方法数仅用于整理覆盖范围，不代表实际执行或通过数；运行结果以当次 Xcode 测试报告和 Python 输出为准。

## 常规检查

在仓库根目录运行。以下命令使用完整 Xcode、macOS 目标和临时构建目录，不要求代码签名。

构建应用与测试目标，但不执行测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build-for-testing \
  -project 'Butterfly Toolkit.xcodeproj' \
  -scheme 'Butterfly Toolkit' -destination 'platform=macOS' \
  -derivedDataPath /tmp/toolkit-docs-build CODE_SIGNING_ALLOWED=NO
```

执行常规 Swift 测试：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project 'Butterfly Toolkit.xcodeproj' \
  -scheme 'Butterfly Toolkit' -destination 'platform=macOS' \
  -derivedDataPath /tmp/toolkit-docs-build CODE_SIGNING_ALLOWED=NO
```

未设置真实环境变量时，对应按需测试会跳过。`build-for-testing` 成功只证明编译通过；`test` 的执行、失败和跳过数量应分别记录。

版本工具独立使用 Python 标准库测试，并检查当前版本配置：

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/version.py check
```

[版本工具测试](../scripts/tests/test_version.py) 在临时 Git 仓库验证版本递增、发布说明、标签与应用元数据，不给当前项目创建标签。日常检查使用 `check`；里程碑发布的额外约束见[版本管理](VERSIONING.md)。

## Swift 测试分组

按修改涉及的行为选择局部测试，涉及共享状态、路径或发布机制时再运行相关集成测试。

| 分组 | 文件与主要范围 |
|---|---|
| AI 工作区 | [AIWorkspaceTests](<../Butterfly ToolkitTests/AIWorkspaceTests.swift>)：分组资格、素材导入、结果校验、安全导出和单次子进程 |
| 常驻推理 | [AIInferenceWorkerTests](<../Butterfly ToolkitTests/AIInferenceWorkerTests.swift>)：会话复用、串行队列、协议错误、取消和退出清理 |
| 独立智能裁剪 | [ButterflyCropProcessorTests](<../Butterfly ToolkitTests/ButterflyCropProcessorTests.swift>)：固定留白、整数尺寸、完整主体与人工范围；[SmartCropNativeTests](<../Butterfly ToolkitTests/SmartCropNativeTests.swift>)：蒙版格式、方向、灰度 JPEG、真实渲染导出和源文件保护；[SmartCropStoreTests](<../Butterfly ToolkitTests/SmartCropStoreTests.swift>)：旧预览隔离、离页取消、原图与缩略图独立加载、切图与批次结果复用、磁盘缓存恢复、构图／源版本失效，以及重新载入与取消覆盖后的刷新 |
| 工作流几何 | [MaskGeometryProcessorTests](<../Butterfly ToolkitTests/MaskGeometryProcessorTests.swift>)：主体细节、翅顶、真实背景、坐标与裁切约束 |
| 几何缓存 | [WorkflowGeometryCacheTests](<../Butterfly ToolkitTests/WorkflowGeometryCacheTests.swift>)：并发合并、串行准备、容量、取消和清空 |
| 状态与清单 | [WorkflowStateTests](<../Butterfly ToolkitTests/WorkflowStateTests.swift>)：阶段屏障、版本失效、双面确认、保存与恢复 |
| 执行调度 | [WorkflowExecutorTests](<../Butterfly ToolkitTests/WorkflowExecutorTests.swift>)：暂停、重试、人工编辑、异步结果和两种抠图调度 |
| 操作链集成 | [WorkflowIntegrationTests](<../Butterfly ToolkitTests/WorkflowIntegrationTests.swift>)：逐标本推进、双面确认、故障恢复、源文件保护与持久化 |
| 输出规则 | [WorkflowOutputTests](<../Butterfly ToolkitTests/WorkflowOutputTests.swift>)：PSD 位置、独立输出目录、四个检查点组合、PNG4K 结束及发布保护 |
| 图片与发布 | [WorkflowAssetRendererTests](<../Butterfly ToolkitTests/WorkflowAssetRendererTests.swift>)：ICC、透明度、布局、归属凭据、原子发布和旧版本保留 |
| Photoshop 桥接 | [WorkflowBridgeTests](<../Butterfly ToolkitTests/WorkflowBridgeTests.swift>)：文档归属、租约、快照、角色提取、蒙版事务与中断恢复 |
| 人工定稿 | [WorkflowFinalizationTests](<../Butterfly ToolkitTests/WorkflowFinalizationTests.swift>)：强制人工检查、旧批次迁移、重复打开与刷新、最终图层身份、双输出和恢复 |
| 已有 PSD 入口 | [WorkflowPSDImportTests](<../Butterfly ToolkitTests/WorkflowPSDImportTests.swift>)：D/V 配对、未配对排除、重复面、模式切换、单文件来源、接管保护、跳过堆栈与清单恢复 |
| 预览与交互 | [WorkflowPreviewTests](<../Butterfly ToolkitTests/WorkflowPreviewTests.swift>)：异步预览、确认门槛、坐标、批次切换和细节图持有范围 |
| 堆栈输入准备 | [WorkflowStackPreparationTests](<../Butterfly ToolkitTests/WorkflowStackPreparationTests.swift>)：可选预备 PNG、回退、保存顺序和恢复 |
| 真实流水线测量 | [WorkflowPipelinePerformanceTests](<../Butterfly ToolkitTests/WorkflowPipelinePerformanceTests.swift>)：按需性能比较，以及默认执行的素材复制与证据目录保护 |

状态、执行器、集成和输出测试的名称可能相近，但验证层次不同。独立智能裁剪与照片流共用几何核心，独立测试另行覆盖 JPEG 识别适配、交互状态和导出边界，不按名称判定重复。

四个检查点的完整组合由输出测试覆盖；集成测试另行检查逐标本确认、持久化和原图不变。旧派生阶段的兼容数据与仍存在的渲染能力继续保留相关测试。

## 共享测试辅助代码

删除或拆分文件前检查跨文件引用，不能只看该文件自身的测试方法。

| 定义文件 | 被复用的辅助代码 |
|---|---|
| `WorkflowExecutorTests.swift` | `ExecutorFixture`、`WorkflowPipelineProbe`，供输出、集成、堆栈准备、流水线等测试使用 |
| `WorkflowAssetRendererTests.swift` | 图像 `Fixture`，供输出发布和集成测试使用 |
| `AIInferenceWorkerTests.swift` | 假 worker `Fixture`，供预览生命周期测试使用 |
| `WorkflowPipelinePerformanceTests.swift` | `copyFixture`、`isolatedEvidenceRoot`，供文档复用和堆栈准备测试使用 |

## 按需真实环境测试

仅在准备好素材、外部引擎与独立输出位置后启用。具体必需变量、素材格式及前置状态，以对应测试方法的 `guard`、`XCTUnwrap` 和后续校验为准。

通过 `xcodebuild` 启动测试时，使用 `TEST_RUNNER_` 前缀传递变量。例如测试读取 `WORKFLOW_RENDER_BATCH`，命令环境中设置 `TEST_RUNNER_WORKFLOW_RENDER_BATCH`。同时使用 `'-only-testing:Butterfly ToolkitTests/类名/方法名'`，避免同组环境变量意外启用其他真实测试。

下表列出测试内部读取的变量名；前缀相同的 `BATCH/EVIDENCE` 表示两个完整变量名。

| 测试入口 | 变量与关键条件 |
|---|---|
| AI worker 真实推理 | `WORKFLOW_WORKER_REAL_INPUT/EVIDENCE/ENGINE`；需要已配置好的 AI 引擎 |
| 已有 PSD 真实流程 | `WORKFLOW_IMPORT_REAL_SOURCE/EVIDENCE/ENGINE`；仅复制输入到新证据目录，验证接管、自动 PNG、AI、回写、恢复校验和裁切；`WORKFLOW_IMPORT_FLATTEN=1` 额外验证单层 Background PSD |
| 人工定稿真实 PSD | `WORKFLOW_FINAL_SOURCE/EVIDENCE`，使用 WorkflowFinalPSDLiveTests 验证独立副本的保留／应用蒙版、4K 像素一致、人工像素擦除与裁切保存后刷新／双输出，以及未保存／旧版本保护。`WORKFLOW_FINAL_GEOMETRY_BATCH/EVIDENCE` 只读指定旧批次并复制受影响蒙版分析；新证据目录必须不存在 |
| 微弱残留回写与裁切 | `WORKFLOW_RESIDUE_BATCH/EVIDENCE`，WorkflowResidueLiveTests 只读批次的蒙版与底图（默认串行枚举整批两面，可用 `WORKFLOW_RESIDUE_NAME`（完整名称或编号前缀）和 `WORKFLOW_RESIDUE_SIDE=D/V` 缩小范围），在新目录建立 PSD 副本，回放已有蒙版经过生产清理、回写、裁切，直接核对默认选中成品的已保存图层边界、可恢复的蒙版备份及最终导出像素；不运行模型或修改原批次 |
| 蒙版真实素材分析 | `TASK3_EVIDENCE_DIR`；还依赖 `/tmp/butterfly-task2-real/` 下的 `F/U-roles.json`、`F/U-saved.json` 及其引用文件 |
| 渲染与发布计时 | `WORKFLOW_RENDER_BATCH/EVIDENCE`；批次须包含有效角色图像 |
| 几何缓存计时 | `WORKFLOW_GEOMETRY_BATCH/EVIDENCE`；批次须包含角色图像与已保存几何方案 |
| 界面存储预览计时 | `WORKFLOW_PREVIEW_BATCH/EVIDENCE` |
| Photoshop 4K 导出 | `WORKFLOW_EXPORT_BATCH/EVIDENCE` |
| Photoshop 角色发布复用 | `WORKFLOW_ROLE_PUBLICATION_BATCH/EVIDENCE` |
| Photoshop 确认读取 | `WORKFLOW_CONFIRMATION_BATCH/EVIDENCE` |
| Photoshop PNG 编码比较 | `WORKFLOW_PNG_EVIDENCE`、`WORKFLOW_PNG_PYTHON`；可选 `WORKFLOW_STACK_FIXTURES`；Python 需具备 Pillow |
| Photoshop 文档复用比较 | `WORKFLOW_REUSE_EVIDENCE`、`WORKFLOW_REUSE_FIXTURE`、`WORKFLOW_PNG_PYTHON`；可选 `WORKFLOW_REUSE_BASELINE`；已有结果复查使用 `WORKFLOW_REUSE_COMPARE` |
| 堆栈预备 PNG 比较 | `WORKFLOW_STACK_PREP_EVIDENCE/BATCH`、`WORKFLOW_PNG_PYTHON` |
| 已保留透明输入重放 | `WORKFLOW_STACK_PREP_REPLAY/EVIDENCE`、`WORKFLOW_PNG_PYTHON` |
| 真实流水线 | `WORKFLOW_PIPELINE_BATCH/STACKS/EVIDENCE/ENGINE`；`COUNT` 为 1/2/4，`LIMIT` 为 1/2；`PAUSE=1` 仅支持 COUNT=2、LIMIT=2 |
| 下一轮流水线比较 | `WORKFLOW_NEXT_MODE=A/C/D` 及 `WORKFLOW_NEXT_BATCH/STACKS/EVIDENCE/ENGINE`；可选 `COUNT`、`OBSERVE=1`；完整重做堆栈仅支持 A 且 COUNT 为 2/4，完整批次不需要 STACKS |

下一轮比较中，C/D 启用操作内文档复用，D 使用分阶段抠图；A 是对照路径。这些测试入口不能据以推断应用已默认启用候选优化。

`WORKFLOW_COLOR_EVIDENCE` 仅为常规颜色测试附加证据输出，不是跳过条件。

## 素材、输出与验收边界

- 真实测试可能打开 Photoshop、运行 AI 并写入 PSD、图片与测量报告。使用明确选定的测试素材及新的独立证据目录，避免输出到工作素材目录。
- 多个入口要求证据目录尚不存在。使用 `isolatedEvidenceRoot` 的入口仅接受 `/tmp` 或系统临时目录内的位置，并校验符号链接；其他入口不应被假定具有相同保护。
- 不要为复跑而直接清空旧证据目录。选择新的目录，确认不再需要后再清理旧结果。
- 常规测试中的 Photoshop/AI 多通过替身注入。集成测试名称中的真实渲染与发布，表示使用实际图像处理和文件发布，不代表实际运行了 Photoshop 与 AI 整批流程。
- 真实素材几何、预览、渲染计时各自测量不同范围；它们不等于整批耗时、屏幕呈现延迟或人工画质验收。
- 记录实际执行命令、选择的测试、失败和跳过原因，以及证据目录。构建、自动测试、真实环境运行和人工画质确认应分别报告。
- 影响 AI 协议或进行候选择优交付时，还须在所选外部引擎环境运行 `scripts/test_toolkit_bridge.py` 全套回归；本仓库的版本工具测试不能替代引擎测试，具体入口以该引擎当前文档为准。

### 残留清理回归

`MaskResidueCleanupTests` 覆盖大淡斑、夹杂亮点的边带、实际轮廓距离、多主体、贴边与分离触角、半透明翅片、弱连接、取消和幂等性。`WorkflowCleanupReportTests` 覆盖旧记录解码、报告哈希、保存版本及首次自动裁切的位置变换；人工保存与 4K 输出同时由 Finalization、Geometry 和 AssetRenderer 测试验证。

`WorkflowResidueLiveTests` 对每面单独建立证据子目录，保存清理报告、源文件哈希、裁切角度与留白、已保存透明成品边界、背景可恢复性及 4096 方形输出。`fixture-index.json` 记录原始和清理蒙版供逐项视觉核对。自动断言通过不等于细节质量已获用户认可。不要并行执行多个 Photoshop 真实入口。
