# Photoshop 底层 BG 与可编辑蒙版验证

日期：2026-11-11。范围：1.4.1（10）的新生成 PSD，不迁移既有 PSD。

## 实机副本

使用 SC10140 正反面共六张照片的全新副本，执行景深合成、Photoshop 选择主体及蒙版、自动裁切、人工蒙版修改后的保存刷新和双输出。原照片与原批次哈希未变。

- 景深合成保存后、抠图之前：最底层为可见且锁定的 BG。
- 自动裁切后：顶层为两个工作组与底层 BG；BG 位于所有组外，可见且锁定。
- 共同调整组仅有底图与带蒙版的抠图层，抠图可见，没有应用蒙版的透明成品层。
- 修改蒙版一个像素后保存、刷新，角色 Alpha 正确变为零。
- 两面均完成堆栈原图 JPEG 与 4096×4096 PNG 导出；透明 PNG 角落 Alpha 为零，BG 未混入导出。
- 该实机测试通过，不代表全部素材画质已获用户验收。

证据目录：`/tmp/toolkit-bg-green-20261111/`，含 processed.json、finished.json、validation.json、工作 PSD 和最终图片。实机日志：`/tmp/toolkit-bg-green.log`。修改前同一两面流程在 BG 状态断言处失败，证据位于 `/tmp/toolkit-bg-red-20261111/`；不是成功验收。

## 常规回归及边界

最终完整常规复跑 327 项通过、20 项按需测试跳过、0 失败；版本工具 14 项通过，Release 构建通过。JavaScript 行为测试覆盖旧双组结构、新底层纯色 BG、拒绝任意额外图层，以及导入 PSD 中普通像素层恰好命名 BG 时仍保留其内容。

中间一次完整回归中，以下两个既有 AI 测试报告“透明结果的 ICC 与输入不同”：

- WorkflowBridgeTests.testInferenceClearsRemoteFaintAlphaAndCutoutBeforeWriteback
- WorkflowBridgeTests.testMatteAcceptsWhiteCompositedEdgesButRejectsChangedPixels

不改变代码及构建后完整复跑，两项均通过。该间歇不一致的根因尚未确认，本次未改 AI 像素或 ICC 校验，也不把复跑通过描述为已修复 ICC 问题。失败日志 `/tmp/toolkit-bg-final-full.log`，复跑日志 `/tmp/toolkit-bg-full-repeat.log`。
