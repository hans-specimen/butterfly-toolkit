# 人工定稿与统一导出 Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans, inline execution; final independent review.

**Goal:** 自动处理停在人工检查，反复编辑 PSD 后统一导出底图 JPEG 与正方形 4K PNG。
**Architecture:** 保留旧清单语义；新批次使用 manualFinalization 标记，显式迁移旧批次。自动处理继续严格角色验证；最终保存快照使用独立图层选择和验证，复用现有安全发布。
**Tech Stack:** SwiftUI、Photoshop JSX、XCTest。
**Spec:** ../specs/2026-11-09-manual-finalization-workflow-design.md（用户已确认）

## Global Constraints
- 不修改本批次用户素材；真实验证使用临时副本；不提交、推送或安装。
- 4096 × 4096、居中加留白；输入目录内固定双输出子目录。
- 自动处理保持 ICC/Alpha/归属/保存版本校验；人工定稿允许图层替换和应用蒙版。
- 人工定稿后不得重跑 AI/自动几何；不得静默覆盖其他任务产物。

## Review Focus
- 保存后再次修改、旧异步结果、未保存 Photoshop 文档，不能导出旧版本。
- 顶层可见图层含蒙版、已经应用蒙版、图层重名或缺失，选择明确或明确报错。
- 旧批次当前面已人工改动，迁移不能自动重写 PSD。
- 双输出中途失败，恢复不重复变换或丢失成功产物。
- 不可见像素不能撑大主体；分离触角、缘毛继续保留。

### Task 1: 几何输入修复
- [x] 在 MaskGeometryProcessorTests 覆盖透明底图上的蒙版残留，观察失败。
- [x] MaskGeometryProcessor.prepare 使用蒙版与底图 Alpha 的乘积分析；原始像素不变。
- [x] 运行几何相关测试。

### Task 2: 最终 PSD 读取
- [x] 新增 WorkflowFinalizationTests：最终图层、已应用蒙版、版本/归属/未保存保护。
- [x] WorkflowModels 增加 FinalPSDIdentifiers、PSDSnapshot.finalRoles、RoleImages.isFinalized。
- [x] PhotoshopWorkflowBridge 增加 captureFinalPSD(document:owner:)，提取按 finalRoles 分支；复用不可变快照和缓存。
- [x] WorkflowAssetRenderer 对最终透明素材独立校验与渲染，不再要求与底图 RGB 对应。
- [x] 测试真实临时 PSD 副本最终读取与双输出。

### Task 3: 调度和恢复
- [x] 新增最终人工屏障、迁移、重开、刷新、双输出和失败恢复测试，观察失败。
- [x] WorkflowBatch.manualFinalization 可选标记；新草稿启用，旧批次显式 migrateToFinalization。
- [x] 执行器自动应用可用几何后进入 waitingReview；无解保留 PSD；新增 refreshFinalPSD、confirmFinalPSD。
- [x] 人工确认才进入导出；hd 延迟到 png4k 明确导出授权；同次点击生成两个产物。
- [x] 完整状态、执行器、输出和导入测试通过。

### Task 4: 界面和交付验证
- [x] 界面显示四阶段，人工检查去掉修改类型，重开同面不禁用；旧批次有显式迁移入口。
- [x] 隐藏新流程检查点开关和输出目录选择，仅显示固定目标；导出仅预览 4K。
- [x] 更新现行文档、完整常规测试、真实副本验证、独立代码审查。

## 执行记录
- 使用当前干净工作区的新功能分支；唯一既有未跟踪内容是本任务已确认方案。用户明确要求开始实施，不重复请求计划或目录审批。

- 验证完成：完整 Swift 套件 305 项、17 按需跳过、0 失败（含真实 PSD 定稿）；受影响三张蒙版副本分析单独通过；版本工具 14 项通过。
- 最后增加旧批次迁移前置条件后，执行器定稿及桥接相关测试再次通过。真实副本结果与边界见 ../../validation/2026-11-10-manual-finalization.md。
- 独立审查的四个问题均已关闭；仅本地代码完成，未提交、推送或安装。
