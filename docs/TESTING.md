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

| 分组 | 文件与主要范围 |
| --- | --- |
| 逐面处理 | [WorkflowPerImageTests](<../Butterfly ToolkitTests/WorkflowPerImageTests.swift>) 覆盖逐面顺序、失败隔离、安全暂停、人工接管、单面确认、重跑和独立导出。 |
| 批量精修与定稿 | [WorkflowFinalizationTests](<../Butterfly ToolkitTests/WorkflowFinalizationTests.swift>) 覆盖多文档分别保存关闭、打开观察与重启恢复、接收凭据、延后角色准备、导出版本冻结和已确认面重新处理。 |
| 状态和文件 | [WorkflowStateTests](<../Butterfly ToolkitTests/WorkflowStateTests.swift>)、[WorkflowOutputTests](<../Butterfly ToolkitTests/WorkflowOutputTests.swift>)、[WorkflowPSDImportTests](<../Butterfly ToolkitTests/WorkflowPSDImportTests.swift>) 覆盖状态、清单、输出目录、PSD 配对及保护。 |
| Photoshop 桥接 | [WorkflowBridgeTests](<../Butterfly ToolkitTests/WorkflowBridgeTests.swift>) 与 [WorkflowDocumentSessionTests](<../Butterfly ToolkitTests/WorkflowDocumentSessionTests.swift>) 覆盖角色、同一工作文档、独立快照读回、归属、未保存保护和写入恢复。 |
| 预览与几何 | [WorkflowPreviewTests](<../Butterfly ToolkitTests/WorkflowPreviewTests.swift>)、[WorkflowGeometryCacheTests](<../Butterfly ToolkitTests/WorkflowGeometryCacheTests.swift>)、[MaskGeometryProcessorTests](<../Butterfly ToolkitTests/MaskGeometryProcessorTests.swift>) 覆盖确认门槛、缓存、翅顶、主体和坐标。 |
| 渲染与发布 | [WorkflowAssetRendererTests](<../Butterfly ToolkitTests/WorkflowAssetRendererTests.swift>) 覆盖 ICC、Alpha、布局、归属凭据、原子发布与历史版本。 |
| 独立 AI 与裁剪 | [AIWorkspaceTests](<../Butterfly ToolkitTests/AIWorkspaceTests.swift>)、[AIInferenceWorkerTests](<../Butterfly ToolkitTests/AIInferenceWorkerTests.swift>)、[SmartCropNativeTests](<../Butterfly ToolkitTests/SmartCropNativeTests.swift>)、[SmartCropStoreTests](<../Butterfly ToolkitTests/SmartCropStoreTests.swift>)。独立裁剪另行验证 JPEG、预览会话和源文件保护。 |

修改跨阶段调度、持久化、发布或共享组件时运行完整常规测试。拆分测试前检查跨文件夹具。`ExecutorFixture`、`WorkflowPipelineProbe` 和 `WorkflowPipelinePerformanceTests` 中的 `copyFixture`、`isolatedEvidenceRoot` 仍供其他测试使用。

## 按需真实环境测试

Xcode 运行测试时用 `TEST_RUNNER_` 前缀传递变量，并用 `-only-testing` 限定测试类。下表列的是测试内部读取的变量名，缩写的 `BATCH/EVIDENCE` 表示两个完整变量名。素材与路径约束以各测试方法为准。

| 测试入口 | 变量与范围 |
| --- | --- |
| Photoshop 文档与首层输出 | `WORKFLOW_SESSION_SYNTHETIC=1` 启用 [WorkflowDocumentSessionLiveTests](<../Butterfly ToolkitTests/WorkflowDocumentSessionLiveTests.swift>)。素材由测试生成，检查合成、主体识别、矫正使用同一工作文档，验证保存凭据重用和文档释放。另验证改名且隐藏的精修首层实际像素，以及只读查询的路径、文档 ID、保存和关闭状态。首层用例发现已有打开文档时跳过；整个类运行前须确认 Photoshop 空闲。临时证据位置见 `SESSION_EVIDENCE`、`FIRST_LAYER_EVIDENCE` 输出。 |
| 新照片逐面工作流 | `WORKFLOW_PS_BATCH/EVIDENCE`，可选 `WORKFLOW_PS_NAMES` 指定逗号分隔的标本编号前缀。[WorkflowPhotoshopMatteLiveTests](<../Butterfly ToolkitTests/WorkflowPhotoshopMatteLiveTests.swift>) 从指定清单复制原照到新目录，检查自动处理、图层、人工保存刷新与双输出。 |
| 已有 PSD 原生处理 | `WORKFLOW_IMPORT_REAL_SOURCE/EVIDENCE`，选用合成 PSD 并在独立副本验证 PS 选择主体、角色提取与几何。`WORKFLOW_IMPORT_FLATTEN=1` 额外验证单层背景 PSD。 |
| 人工定稿 | `WORKFLOW_FINAL_SOURCE/EVIDENCE` 需符合当前三层角色的 PSD，验证保存版本、人工编辑、角色隔离及双输出。`WORKFLOW_FINAL_GEOMETRY_BATCH/EVIDENCE` 用于从指定清单读取并分析蒙版。 |
| 既有蒙版回放与分析 | `WORKFLOW_RESIDUE_BATCH/EVIDENCE` 回放已保存的蒙版，可用 `WORKFLOW_RESIDUE_NAME` 与 `WORKFLOW_RESIDUE_SIDE=D/V` 缩小范围。`TASK3_EVIDENCE_DIR` 依赖历史 `/tmp/butterfly-task2-real/` 夹具。 |
| 独立 AI worker 协议 | `WORKFLOW_WORKER_REAL_INPUT/EVIDENCE/ENGINE`，使用已配置引擎验证真实推理。 |

合成素材测试可单独启动：

```sh
TEST_RUNNER_WORKFLOW_SESSION_SYNTHETIC=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test -project 'Butterfly Toolkit.xcodeproj' \
  -scheme 'Butterfly Toolkit' -destination 'platform=macOS' \
  -derivedDataPath /tmp/toolkit-docs-build CODE_SIGNING_ALLOWED=NO \
  '-only-testing:Butterfly ToolkitTests/WorkflowDocumentSessionLiveTests'
```

保留的局部观测入口包含 `WORKFLOW_RENDER_BATCH/EVIDENCE`、`WORKFLOW_GEOMETRY_BATCH/EVIDENCE`、`WORKFLOW_PREVIEW_BATCH/EVIDENCE`、`WORKFLOW_EXPORT_BATCH/EVIDENCE`、`WORKFLOW_ROLE_PUBLICATION_BATCH/EVIDENCE` 和 `WORKFLOW_CONFIRMATION_BATCH/EVIDENCE`。PNG 编码、单次服务内文档复用、合成顺带 PNG 的夹具入口见对应测试文件。`WORKFLOW_COLOR_EVIDENCE` 为常规颜色测试附加证据输出。

旧全链路 `WORKFLOW_NEXT_*`、`WORKFLOW_PIPELINE_*` 入口已退役，A/B/C/D 测量留在[历史记录](validation/README.md)。局部入口所得计时按各自测量范围解读。

## 素材、输出与验收边界

- 真实 Photoshop 测试应串行执行，使用明确选定的素材和新的独立证据目录。采用 `isolatedEvidenceRoot` 的入口仅接受系统临时目录下的路径，并检查符号链接。
- 记录实际命令、失败与跳过原因以及证据位置。构建、常规测试、合成素材 Photoshop 测试、真实标本和用户画质验收分别记录。
- 常规测试可以使用替身。合成素材的 Photoshop 测试验证文档生命周期与重复写入保护，真实标本的边缘质量、构图和整批表现须另行验收。
- 涉及独立 AI 引擎协议的修改，还应在所选引擎环境运行其桥接测试，具体入口以引擎文档为准。
