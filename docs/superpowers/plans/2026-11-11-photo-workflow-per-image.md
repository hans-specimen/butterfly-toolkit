# 照片工作流逐张处理实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 实施已批准的逐张 PS 合成、抠图、矫正、人工检查与独立导出流程。

**Architecture:** 沿用单面状态、保存版本、PS 独占协调和输出凭据。移除照片工作流的外部推理服务与整批屏障；PS 文档在单面自动步骤之间保持打开。共享图像处理与独立 AI 功能保留。

**Tech Stack:** Swift、SwiftUI、XCTest、Photoshop ExtendScript。

**Spec:** ../specs/2026-11-11-photo-workflow-per-image-design.md

## Global Constraints

- 组内从上到下 `Keying_Level` 红色、`Keying_Origin` 绿色、`Stack` 蓝色；默认仅显示 `Keying_Level`。
- 副本蒙版输入色阶 15 / 1.00 / 240、输出 0 / 255；原始蒙版保留，不重复应用。
- 高清 JPEG 读取 `Stack`；透明 PNG 和几何读取 `Keying_Level`，不按组可见图层合成。
- 无旧批次迁移；旧文件不得覆盖或删除。独立训练与对比保留。
- 保存版本、任务归属、源哈希、阶段修订、ICC、Alpha 和原子输出保护不可删除。
- 人工 PS 编辑独占，未经保存核验不关闭、保存或丢弃人工修改。
- 开发阶段保留本地改动；用户后续已授权提交 main、推送并安装。保留启动时已有未提交内容。

## Review Focus

- 旧图层名称仍残留在定稿导出校验中，导致改名后 JPEG 失败：任务 1 覆盖。
- 两个带蒙版层同时参与透明输出，抵消色阶效果：任务 1 覆盖。
- 保存已完成但清单未完成，重试重复调整蒙版或旋转：任务 2、3 覆盖。
- 另一面失败阻塞当前面确认／导出，或自动进度抢走当前选择：任务 3、4 覆盖。
- 排队导出期间 PSD 改变、同名外来文件、单类型部分成功：任务 3、4 覆盖。

## Task 1: PS 图层角色与导出名称

**Files:** `PhotoshopWorkflowBridge.swift`、`WorkflowModels.swift`（若角色结构需要）、桥接与定稿测试，均在现有 PhotoWorkflow 目录下。

**Interfaces:** 保持 `captureFinalPSD(document:owner:)`、`extractRoles(snapshot:)`、`applyGeometry(snapshot:solution:createFinishedLayer:)` 的调用协议；内部角色改为新三层。

- [x] 新增桥接测试，证明只有 `Stack` 能充当底图、`Keying_Level` 是透明结果、原始蒙版层不参与导出。
- [x] 先运行新增测试确认失败。
- [x] 更新共同调整组的创建、识别、最终定稿验证和几何变换，不生成第四个已应用蒙版层。
- [x] 更新新结构测试夹具，保留未保存文档保护与几何校验测试，运行相关测试。

## Task 2: PS 抠图与单面文档生命周期

**Files:** `PhotoshopWorkflowBridge.swift`、`FocusStackProcessor.swift`、新的 PS 抠图测试；必要的共用图像类型从 `WorkflowMatteService.swift` 分离。

**Interfaces:** 复用 `selectSubject(snapshot:) async throws -> PSDSnapshot` 和单面 PS 文档作用域；原有服务在作用域内复用租约和文档，作用域外保持正常独占与释放。

- [x] 核对用户实际使用的 PS 抠图方式：已有 ba193b3 原生选择主体入口。
- [x] 测试原始蒙版生成、复制、15/240 色阶仅执行一次、色标／可见性及错误恢复。
- [x] 实现已确认的 PS 命令与可恢复保存，保证从合成到几何之间不关闭工作 PSD。
- [x] 在独立临时素材上验证 PS 实际调用；不得使用历史路径作为素材写入授权。

## Task 3: 单面调度、恢复与导出

**Files:** `WorkflowExecutor.swift`、`WorkflowStateMachine.swift`、`WorkflowModels.swift`、`WorkflowBatchStore.swift`、相关执行器／状态／输出测试。

**Interfaces:** 单面确认与重试使用 task ID 集合；显式导出请求携带 task IDs、输出类型、跳过／覆盖策略及冻结版本。`runPending(batchID:)` 只推进自动阶段和已明确请求的导出。

- [x] 添加四面交错成功／失败测试，要求实际调用顺序逐面 stack → matte → geometry，不受整批屏障影响。
- [x] 新流程采用新清单标识并拒绝旧清单；工作 PSD 写入新批次专属目录，避免覆盖旧 PSD。
- [x] 删除外部 AI 推理调度与依赖，接入 PS 抠图。暂停在安全步骤边界收尾并保留成功记录。
- [x] 实现单面确认、重试、人工完成与编辑结束；最终确认不自动导出。
- [x] 实现按类型排队导出、有效版本跳过／旧版待更新／显式覆盖及外来文件保护。
- [x] 运行相关测试，覆盖中断保存、版本变化、部分成功和独立正反面。

## Task 4: 单张交互与移除引擎界面

**Files:** `PhotoWorkflowStore.swift`、`PhotoWorkflowView.swift`、预览／Store 测试。

**Interfaces:** Store 调用任务 3 的单面操作，保留当前选择并分别展示正在处理任务；可选择单面输出范围及输出类型。

- [x] 添加单面确认与自动更新不抢选择的行为测试。
- [x] 删除引擎目录、worker 与外部推理文案；批次统计与单面五步流程分离。
- [x] 实现失败步骤操作、人工接管／刷新／结束编辑以及导出面板和结果汇总。
- [x] 验证无引擎配置能创建批次，独立训练／对比的调用与设置未变。

## Task 5: 整体验证与说明

**Files:** 当前照片工作流与测试说明；新增验收记录仅在存在真实证据时写入。

- [x] 完整常规测试：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/toolkit-per-image-build CODE_SIGNING_ALLOWED=NO`。
- [x] 版本工具测试与配置检查：`python3 -m unittest discover -s scripts/tests -p 'test_*.py'`、`python3 scripts/version.py check`。
- [x] 真实 PS 验证同文档连续步骤与保存恢复，三层像素及几何探针；未保存保护、逐张失败和双输出由常规测试覆盖。真实标本整批和画质未验收，见验证记录。
- [x] 独立审阅完整改动，修复实际功能缺口后交付本地变更，不宣称已安装。

## 执行记录

- 用户明确在 main 工作；实现位于 main 已有工作树（起点 01de979），从干净状态开始。原目录 codex/matte-edge-regression 的用户改动未动。
- 已复用 ba193b3 的原生 Select Subject 入口，并保留后续 BG 修复。
- 三角色、15/240、同文档自动处理、幂等凭据、人工接纳、新路径检查点重跑均已实现并在合成 Photoshop 素材验证。
- 单面流程、确认与独立导出、暂停与版本边界已接入。独立 AI 功能保留，旧照片 AI 调度及相关专用测试退役。
- 首轮逐面回归 13 项通过；最终独立审阅又补充导出缓存、人工检查点、接管互斥和发布时跳过边界，已加回归并经独立复核，最终新增边界经独立复核通过，最终相关回归覆盖 77 项。
- 七组主题文档、界面实际渲染检查、14 项 Python 版本工具测试及版本检查完成。发布前完整 Swift 常规套件 346 项（328 通过／18 按需跳过）零失败，最后的最终源码相关回归 77 项全部通过。
- 用户后续授权发布：版本按清单不兼容升级为 2.0.0（11），使用 Release 构建；提交、远端同步与安装状态以实际完成结果为准。
