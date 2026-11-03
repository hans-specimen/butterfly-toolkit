# 待抠原图导入实施计划

> 使用 superpowers:executing-plans；用户已明确纠正抠图与训练入口并要求 PNG、JPEG 支持，直接实施这一小步，不重做页面设计。

**Goal:** AI 抠图可直接添加单张／多张 PNG、JPEG，无需人工答案。
**Architecture:** 沿用现有 SwiftUI 工作区、后台 Process 和 Python CLI。新增 import-image 命令只负责复制和无损生成推理用 PNG；仍用既有 infer 命令。训练素材保持成对要求。
**Spec:** 当前用户两条补充要求：普通抠图只需原图；训练必须有人工答案；PNG 和 JPEG 都支持。

约束：保留原始文件与无关修改；不安装依赖、不下载模型、不训练、不提交推送。原图字节副本和派生 PNG 写入 data/processed/toolkit-imports/ 唯一目录。JPEG EXIF 方向应正确，未标记色彩按 sRGB 解释并明确显示；已有 RGB ICC 保留。高位深或不支持的色彩格式不能静默降精度。

实现选择：复用已安装 Pillow 做导入规范化，避免在 Swift 和 Python 各维护一套照片解码规则。PNG／JPEG 是待抠入口范围；本步不增加 PSD 图层选择界面，训练 PSD 仍需先导出配对图。

## 步骤

- [x] Python 测试先行：PNG 像素／Alpha／ICC 与源文件保持、JPEG 方向及无 ICC、损坏格式拒绝且无残留、无人工答案、空测试库可连接。
- [x] 实现 scripts/toolkit_bridge.py 的 import-image --input，返回 event=imported、sample，保存源文件副本和 import.json；runPath 为空时返回模型信息及空样本。
- [x] Swift 测试先行：无答案导入的持久化与校验、训练列表隔离、不可训练；AIModels 添加 sample 事件字段，AIFileValidation 支持只有原图的校验。
- [x] AIWorkspaceStore 多选导入、逐文件状态和失败汇总；AIWorkspaceView 分离入口；AIComparisonView 无答案时切换原图并禁用人工对比；AITrainingViews 仅展示配对训练素材。
- [x] 构建与测试；实际在 Toolkit 多选 PNG/JPEG，检查源文件未变、重新加载持久化、普通素材不进入训练；用导入图跑完整推理与另存。
- [x] 独立审查新增差异；更新交付说明与真实截图。

审查重点：错误文件不丢失已成功导入的文件；不因没有测试记录阻塞正常抠图；JPEG EXIF 不双重旋转；无 ICC 信息明确说明；RGBA 半透明保留；输出拒绝覆盖；所有导入异步。
