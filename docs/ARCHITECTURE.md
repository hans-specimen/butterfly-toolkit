# 技术架构与代码导航

依据当前工作目录核对：2026-11-09。应用是一个 macOS SwiftUI target，测试为独立 XCTest target；没有拆分 Swift Package 或第三方 Swift 依赖。部署目标为 macOS 26.5，Swift 语言模式为 5，应用默认 actor 隔离为 MainActor；这些设置以 `project.pbxproj` 为准。

## 职责结构

| 位置 | 职责与主要入口 |
| --- | --- |
| `App` | `Butterfly_ToolkitApp` 创建窗口；`ContentView` 定义工具路由并持有 AI、工作流状态；`AboutView` 读取构建版本 |
| `Features/AI` | `AIWorkspaceStore` 管理独立 AI 页面；`AIProcessRunner` 运行单次桥接命令；`AIInferenceWorker` 为照片工作流复用推理会话 |
| `Features/PhotoWorkflow` | `PhotoWorkflowStore/View` 负责交互；`WorkflowExecutor` 调度；`WorkflowStateMachine` 校验状态转换；模型、预览、几何、持久化、发布各有专属文件 |
| 其他 `Features` | 按工具保存界面及专用处理器，如智能裁剪、PSD 导出；没有为了层级统一强行拆出每个工具的模型或服务 |
| `Core/ImageProcessing` | 压缩／旋转、透明 PNG 裁切、闲鱼产品图合成等共用能力 |
| `Core/Photoshop` | 景深合成计划与脚本生成、应用查找，以及跨工具共享的 Photoshop 执行协调 |
| `Resources`、`Assets.xcassets` | 水印、完成提示音、图标与颜色 |
| `Butterfly ToolkitTests`、`scripts/tests` | Swift 行为回归与 Python 版本工具测试 |

同一功能的代码放在一起；只有多个功能都使用的处理能力进入 `Core`。Xcode 的 `PBXFileSystemSynchronizedRootGroup` 同步磁盘目录，新增／移动 Swift 文件通常无需手写源文件引用。

## 照片工作流的数据流

```text
PhotoWorkflowView / PhotoWorkflowStore
                ↓
        WorkflowExecutor
          ├─ WorkflowStateMachine → WorkflowBatchStore → batch.json
          ├─ PhotoshopWorkflowBridge → PhotoshopExecutionCoordinator → Photoshop
          ├─ WorkflowMatteService → AIInferenceWorker → Python 引擎
          ├─ WorkflowGeometryCache → MaskGeometryProcessor
          └─ WorkflowAssetRenderer → WorkflowArtifactStore → 导出文件与归属凭据
```

- `WorkflowBatchDraft` 在输入阶段固定六张源图的位置与名称，建批次时记录源哈希。排除标本不会把后续图片重新挤入空槽。
- `WorkflowStateMachine.reduce` 在批次副本上执行版本和状态校验；不写文件或调用处理服务，但路径校验会读取文件系统。
- `WorkflowExecutor` 持有运行状态，注入可替换服务以供测试。异步操作前后核对修订与快照；最后一次校验到文件发布在同一 actor 内同步完成。
- `WorkflowBatchStore` 保存和恢复清单；`WorkflowArtifactStore` 维护发布意图、已提交归属、指纹与历史记录，防止仅凭同名路径覆盖他人文件。
- `WorkflowGeometryCache` 以内容和坐标相关身份缓存几何准备结果，默认最多 4 项、512 MiB 保留量；该上限不是整个应用或 GPU 的内存峰值。

具体阶段、输出目录、检查点和候选开关见 [照片工作流](PHOTO-WORKFLOW.md)。

## 并发与外部进程

UI 状态由 MainActor 管理；重图像处理、哈希及阻塞进程交互放在后台。Swift actor 会在 `await` 时允许重入，因此 Photoshop 采用显式占用与等待队列，AI worker 采用显式先进先出请求队列。

照片工作流默认最多两个抠图面任务在途、两个本地导出任务并发，但 Photoshop 和 AI 各自仍是单路。暂停先撤销后续执行资格，已进入不可中断 Photoshop 调用的操作必须安全收尾后释放占用。

Python 引擎是外部项目，通过所选目录下的 `.venv/bin/python` 与 `scripts/toolkit_bridge.py` 调用；应用不携带模型或 Python 环境。独立 AI 命令与工作流常驻协议见 [AI 工作区](AI-WORKSPACE.md)。

## 图像与坐标约定

- 保存 PSD 的工作流坐标使用 x 向右、y 向下，正角度绕指定中心顺时针旋转；转换到 Core Graphics 时显式处理纵轴。
- `RoleImages` 分别记录完整可编辑像素范围、像素原点与可见裁切框，不能把画布尺寸当成全部可恢复内容。
- 角色图、快照版本、尺寸、方向、ICC 和蒙版／抠图 Alpha 必须相互匹配；预览可确认状态也必须对应当前版本。
- 几何修改仅作用于指定快照的增量，恢复不能再次叠加已经写入 PSD 的旋转或裁切。
- 高清 JPEG 使用确认裁切框内的底图，质量参数 0.82；透明输出默认 4096 × 4096、256 像素安全边距，保留主体边界内细微 Alpha。

## 磁盘数据与清理边界

| 位置 | 含义 |
| --- | --- |
| 用户输入目录 | 原图；照片工作流的 `<名称>_F.psd`、`<名称>_U.psd` 也保存在原图旁 |
| `~/Library/Application Support/Butterfly Toolkit/PhotoWorkflow/<UUID>/` | `batch.json`、`.work` 中的可恢复中间数据；不是构建缓存 |
| 用户选择的高清与 PNG4K 目录 | 成品及发布归属记录；旧批次可能使用内部子目录，保留兼容读取 |
| 所选 AI 项目的数据／输出目录 | 独立导入副本、人工答案、推理记录与工作区设置，具体由引擎和 UI 契约管理 |
| `/tmp`、本地 `build/`、`staging/` | 本次构建、测试及临时证据；只有确认可再生成或已备份的部分才清理 |
| `output/app-icon-liquid-glass/` | 当前图标的原始设计图与生成说明；正式各尺寸图标在 `Assets.xcassets`，重复导出包与旧方案已清理 |

不会为了目录清爽自动删除用户批次、图片或 AI 模型。历史验证与当前自动化测试的关系见 [测试指南](TESTING.md) 和 [验证记录索引](validation/README.md)。
