# 图鉴卡片验证（2026-11-13）

本记录仅描述本轮独立工作目录中的源码和临时测试，未安装、提交、推送或发布；不代表用户最终画质确认。

## 新功能与真实 Photoshop

- 输入为用户明确指定的 `260701_栎蛱蝶_4K_PNG` 文件夹，共 20 张 4096 × 4096 透明 PNG，识别为 10 组 D/V。
- 从素材副本和模板副本生成 10 张 4000 × 2250 PNG；使用 Photoshop `exportDocumentAsFileTypePressed` 快速导出事件，没有改用 Save for Web。
- 当次 Photoshop 设置只读核对：PNG、透明开启、转换 sRGB 开启、元数据 0。自动调用沿用这些颜色和元数据选项，不修改全局设置。
- 采集文字留空，不把对话中的地点/日期样例当作真实采集记录。SC10129 在测试中采用用户指定的「赭色栎蛱蝶」名称，其他名称沿用解析值。
- 源素材及模板哈希在整批处理前后相同；成功发布后，批次工作目录内 `card.psd` 为 0 份。
- agent 目视核对 SC10129、SC10137、SC10140：左右构图、性别、文字、背景、组投影正常，无辅助框；用户尚未作最终画质确认。
- 合成透明图另测长形框高限制、人工移动 30 像素后刷新及修改文字保留位置、未保存修改拒绝刷新、重复渲染复用角色。

批次证据：`/tmp/toolkit-card-batch-24C70A1C-41A0-4A14-A43C-876F4455A2E5/`。`output/` 为 10 张 PNG，`work/` 留有轻量清单和预览；`inputs/` 是隔离副本。`interface-1000.png`、`interface-1400.png` 是最终界面截图。临时目录不保证长期保存。

## 自动验证

- 最终批次验收与解析/状态回归：13 项通过、0 失败，日志 `/tmp/toolkit-cards-batch-final.log`。
- 真实人工编辑测试在 `/tmp/toolkit-cards-batch.log` 中通过；该次批次清理曾因 URL 目录标志比较误判而失败，后来改为规范路径比较并在最终 10 只批次通过。早期日志不能视为全绿。
- 最终界面快照单独通过，日志 `/tmp/toolkit-cards-ui-final.log`；两种宽度均已目视检查，独立界面审阅原唯一问题（未显示实际输出名）已修正并获 resolved / ship。
- 版本检查通过，Python 版本工具测试 14 项通过。未准备安装，因此不升号。
- 完整常规测试完成：352 项中 331 通过、21 项按需跳过、0 失败，`TEST SUCCEEDED`；日志 `/tmp/toolkit-cards-full.log`，结果 `/tmp/toolkit-cards-regression/Logs/Test/Test-Butterfly Toolkit-2026.11.13_03-51-08-+0800.xcresult`。最后补充的底栏文件名展示另经最新构建和两种宽度截图验证通过。

改动前基线：316 项通过、19 项跳过、2 项失败，失败均为原有 ICC 校验：

- `WorkflowBridgeTests.testCleanupUsesEffectiveVisibilityWithoutMultiplyingRetainedMaskTwice`
- `WorkflowBridgeTests.testMatteAcceptsWhiteCompositedEdgesButRejectsChangedPixels`

错误均为透明结果 ICC 与输入不同。本轮未修改这些旧流程或降低其校验要求；最终完整回归两项均通过，基线与最终结果不一致的原因尚未定位，不能宣称本轮修复了 ICC 问题。

## 审阅与修复

独立代码审阅发现并修复：清理前重新校验工作 PSD 哈希；准备阶段即持久化角色及版本，防止快速导出失败后重置图片；导出修订独立于预览修订；识别不透明/全透明/损坏素材并显示实际尺寸。相应回归已加入解析、状态和真实批次测试。

当前使用方法见 [图鉴卡片](../IDENTIFICATION-CARDS.md)，测试条件见 [测试指南](../TESTING.md)。原工作区已有文档保持不动，应用改动位于本聊天附属独立工作目录。
