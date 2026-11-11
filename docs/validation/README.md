# 历史验证记录

本目录保留有独立价值的实测证据，不作为当前操作指南。各记录中的“本轮”“未实施”“尚未测试”、测试数量、分支、绝对路径均以记录日期和测量范围为限。当前功能与待办见 [照片工作流](../PHOTO-WORKFLOW.md)，运行方法见 [测试指南](../TESTING.md)。

## 基础与版本

- [批量 PSD 精修与首层输出](2026-11-12-batch-psd-review.md)：合成素材首层实际像素、真实只读文档查询和保存版本状态回归；范围与最终界面验收分别记录。

- [Photoshop 底层 BG](2026-11-11-photoshop-bg.md)：组外锁定可见背景、可编辑原生蒙版、两面副本导出隔离及常规测试间歇 ICC 失败记录。

- [Photoshop 智能识别](2026-11-11-photoshop-matte.md)：四面新合成副本的原生蒙版、自动裁切、直接改蒙版刷新与双输出，以及新 PSD 子目录和发布恢复。

- [蒙版残留与完整裁切](2026-11-10-robust-matte-cleanup.md)：实际轮廓距离、保守细节保护、自动保存诊断绑定、全批已有蒙版与 Photoshop 副本回放；区分 agent 视觉核对和用户画质验收。

- [微弱蒙版残留修复](2026-11-10-matte-residue.md)：有效背景残留清理、实际 PSD 蒙版回写与裁切、应用蒙版后的真实图层边界、sRGB ICC 保留，以及 22_D／33_V 后续复现与默认成品、可编辑备份验证。

- [人工定稿与统一导出](2026-11-10-manual-finalization.md)：真实 PSD 副本的保留／应用蒙版读取、双输出、保存版本保护及三张受影响蒙版分析。

- [照片工作流分阶段验收](2026-11-05-photo-workflow-acceptance.md)：含后续补充的真实 Photoshop 图像、ICC、角色提取与居中验证；不同日期结论不可混读。
- [版本管理验证](2026-11-07-version-management.md)：配置继承、版本工具和应用元数据检查。

## 第一轮性能优化

各项测量范围不同，收益不能直接相加；固定已保存 PSD 的比较也不等同于新 JPG 全链路。

| 记录 | 主要范围 |
| --- | --- |
| [任务 1](2026-11-07-photo-workflow-performance-task-1.md) | 发布后角色复用 |
| [任务 2](2026-11-07-photo-workflow-performance-task-2.md) | AI 输入与结果 PNG 编码、ICC 与像素等价 |
| [任务 3](2026-11-07-photo-workflow-performance-task-3.md) | 确认前受保护角色读取 |
| [任务 4](2026-11-07-photo-workflow-performance-task-4.md) | 有界几何缓存 |
| [任务 5](2026-11-07-photo-workflow-performance-task-5.md) | 移除未使用的预览位图 |
| [任务 6](2026-11-07-photo-workflow-performance-task-6.md) | 渲染与发布复用解码 |
| [任务 7](2026-11-07-photo-workflow-performance-task-7.md) | 两面交错、整段计时、暂停恢复及 UI 补充验证 |
| [任务 8](2026-11-07-photo-workflow-performance-task-8.md) | 单路常驻 AI worker 与模型复用 |

## 第二轮候选方案

| 记录 | 主要范围与限制 |
| --- | --- |
| [任务 1](2026-11-07-photo-workflow-batched-ps-task-1.md) | 细分观测及新 JPG 完整基线，包含失败，不能视为全绿 |
| [任务 2](2026-11-08-photo-workflow-batched-ps-task-2.md) | 合成时准备输入；透明像素不等价的回退约束 |
| [任务 3](2026-11-08-photo-workflow-batched-ps-task-3.md) | 单次 Photoshop 操作内文档复用、归属与恢复 |
| [任务 4](2026-11-08-photo-workflow-batched-ps-task-4.md) | 旧流程集中抠图调度，实测未证明更快 |

第二轮任务 5 未完成最终择优。其对照依赖旧照片工作流的 AI 推理与调度，已随该路径退役。原报告保留当时的测量、失败和限制。现行逐面流程的边界见 [照片工作流](../PHOTO-WORKFLOW.md)。

- [逐面 Photoshop 流程验证](2026-11-11-per-image-photoshop.md)：同工作文档、15/240 三层蒙版、人工恢复及新路径检查点；合成素材功能验证，不代表真实标本质量验收。
