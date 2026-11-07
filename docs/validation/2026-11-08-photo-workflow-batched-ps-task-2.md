# Batched Photoshop Task 2：合成保存后准备输入 PNG

日期：2026-11-08。基线 `07b89e7`。仅实施 Task 2，候选默认关闭；用户明确要求减少全流程重复测试。状态：实现与恢复修复完成；直接融合的透明像素等价失败，候选已收窄为全不透明输入，原失败样本回退验证通过，独立 review 通过受限候选的代码与证据。

## 实现与边界

- `FocusStackProcessor.process/jsx` 接受默认 nil 的内部可信导出钩子：分层 PSD `saveAs(copy)` 成功后、原堆栈关闭前执行。独立景深工具与默认工作流不传钩子。PSD 保存错误仍失败；可选 PNG 错误不撤销成功 PSD。
- `stackWithInput` 复用原独占租约及合成／归属／正式发布／capture 流程；只在已验证的正式 PSD 版本等于初始发布版本时，将有效候选 PNG 移入现有 `data/processed/<owner>/` 路径并绑定版本。未发布、坏图、错误尺寸／方向／缺 ICC 都不能登记成功输入。
- 关闭前导出与旧重新打开导出共用相同 duplicate→隐藏蓝底／选择角色→PNG 编码→关闭副本逻辑。sRGB8 快速路径及广色域／16 位原路径不变。原堆栈图层、蒙版和画布外像素不作额外变换。
- 全不透明限制：复用已经解码的 RGBA，任一 Alpha 不等于 255 即放弃候选并保留旧的重新打开导出；不抹掉透明 RGB、不改变 Alpha、不放宽相等标准。透明场景仍付出一次尝试导出的成本，当前不声称有收益。
- executor 在原版本栅栏后同时保存 snapshot 与可选 stackPNG，保留全批 stack／matte 边界、四检查点和原持久化格式。已有 PSD 的重试仍走归属恢复，不再合成；旧清单缺 PNG 时只补导出。
- `Services.live(...prepareStackInput: false)` 默认保持旧路径，仅内部显式开启候选。候选复用 PNG 前保留原本重新导出所做的 PSD 检查；PNG 丢失／损坏补导出，PSD 改动或 dirty 文档拒绝。已持久化同输入 MatteArtifact 的安装恢复仍走原 refresh／validateInstalledMatte 分支，不能被新验证提前拦住。

## 独立 review

独立 reviewer `review_task2` 发现：新增 PNG 验证若在已有同输入 MatteArtifact 时先核对旧 PSD，会挡住“安装已发布、清单仍旧”的原恢复路径。新增候选恢复用例先复现失败，再将新验证限定到需要新推理的分支；不吞验证错误、不改变已安装结果验证。恢复修复、全不透明限制、原失败样本回退、最后回归的失败／复跑记录及保护哈希均经独立复核通过；允许作为默认关闭的受限候选提交，不代表通用融合或整批性能门禁通过。

## 验证范围与实际耗时

按用户最新指令，不做 Task 1 的三轮矩阵、不跑 AI／几何／成品完整实图链。普通测试覆盖保存顺序、主保存错误、PNG 可选失败、发布冲突、检查点、编辑失效、候选安装恢复及默认关闭。真实检查只做一次 4 面新合成，以及 sRGB8／AdobeRGB8／sRGB16 三个软 Alpha 夹具；每份保存内容分别导出关闭前与重新打开后的 PNG，复用原始 RGBA／ICC／色彩标记／方向／位深比较脚本。

| 验证 | 结果 | 命令墙钟 |
|---|---|---:|
| 新行为 RED | 4 用例、8 条预期断言失败 | 44.381 s |
| 桥接／执行器／新类聚焦 | 70 通过、4 跳过、0 失败 | 45.439 s |
| 首次完整回归 | 222 通过、13 跳过、0 失败 | 45.585 s |
| review 恢复问题 RED | 1 条预期断言失败 | 21.270 s |
| 恢复修复后全套（透明限制前） | 224 通过、13 跳过、0 失败 | 52.996 s |
| Python 回归（AI 未改） | 43 通过、0 失败 | 1.398 s |
| 透明候选限制 RED | 1 条预期断言失败 | 25.889 s |
| 加入透明限制后的全套 | 223 通过、14 跳过、1 失败 | 71.361 s |
| 失败旧用例及透明回退定向复跑 | 2 通过、0 失败 | 16.706 s |

两次测试编译问题分别为 XCTest 同步断言闭包内使用 await（2.343 s）和新用例引用另一文件的 private 计数器（2.547 s）；已修正，不计作行为 RED。首次全套后，独立 review 发现新的恢复问题，因此才追加修复后的最终全套。没有重复实图全流程矩阵。

首次真实检查命令 62.557 s，测试体 53.004 s，**7 对直接融合输出中 6 对精确相等，22_U 的 RGBA 失败**。这份失败日志／xcresult 保留，不以修改比较器或删掉样本取得全绿。

22_U 共有 2394 个 Alpha=0 像素的 RGB 不同（最大通道差 76，位置 x=5176…5178、y=602…3447）；Alpha、ICC、尺寸、方向和位深相同。例如融合输出 `[187,197,199,0]`，重开 PSD 后为 `[255,255,255,0]`。两路径使用相同编码 helper；保存前后内存与磁盘的透明 RGB 表示差异是目前证据支持的风险，未证明 Photoshop 所有可能差异都仅限透明像素。

独立 reviewer 同意采用全不透明限制，作为保守支持范围，透明输入回退原路径。原 7 对的严格直接融合门禁仍为 6/7；不能改称“融合全通过”。本次 22_F、33_F 为全不透明且精确相等；22_U 有 118999 个非不透明像素、33_U 有 1 个、三个软 Alpha 夹具各有 4 个，均由新限制回退。含透明内容的通用融合仍未获质量放行。

以下为加入全不透明限制**之前**的单次诊断秒数，仅用于观测组成。`fusedExportInsidePS` 是 PS 内部导出；`reopenedExportIncludingValidation` 包含 Swift 往返、verify、解码和哈希；`stackWithInput` 包含合成、预备 PNG 读取／哈希、正式发布和 capture。加入限制后另有一次对已解码 Alpha 的扫描。不能直接相减得到 A/B 端到端收益。

| 样本 | 合成+预备服务 | PS 内部融合导出 | 预备输入复核 | 重开导出服务 | 最终支持 |
|---|---:|---:|---:|---:|---|
| 22_F | 7.228 | 1.299 | 0.763 | 2.487 | 全不透明候选 |
| 22_U | 7.809 | 1.655 | 0.848 | 2.884 | 旧导出回退 |
| 33_F | 6.352 | 1.265 | 0.740 | 2.483 | 全不透明候选 |
| 33_U | 6.779 | 1.617 | 0.827 | 2.819 | 旧导出回退 |
| soft-alpha-adobe-8 | — | 0.118 | — | 0.373 | 旧导出回退 |
| soft-alpha-srgb-16 | — | 0.085 | — | 0.352 | 旧导出回退 |
| soft-alpha-srgb-8 | — | 0.321 | — | 0.596 | 旧导出回退 |

真实四面诊断的 bridge 日志确认：单次 validateStackInput 有 1 次 PS open／close、3 次 hash；旧 exportStackPNG 有验证与快照导出各 1 次 open，共 2 次 open、3 次 close（其中 1 次关闭导出副本）、3 次 hash。融合钩子仍 duplicate 并关闭副本，因此接纳候选时净省的是 1 次快照 open／close，而非省去验证或副本。每次合成仍保存分层 PSD 1 次；观测到 stack 服务包含 15 次 hash（含新 PNG）、4 次 copy、一次 capture。合成处理器内部操作未计入 bridge 计数，不能将局部次数称作完整 PS 总数。

加入透明限制后的全套有一次旧用例 `WorkflowBridgeTests.testCachedExtractionInspectsOnceAndRejectsDeletedRolesOrSavingSource` 失败：其 2×2 AdobeRGB 角色夹具在原 WorkflowRaster.validateMatte 抛 invalidStructure。该用例不走新合成／透明限制路径；角色提取及像素验证代码未改。仅定向复跑此用例与透明回退用例，两者通过，未复现失败；不据此断言根因已修复，也不将该次全套改写成全绿。独立 reviewer 已核对调用路径及复跑策略。

保留的 22_U 实际 PSD／PNG 回放通过：命令 7.075 s、测试体 5.407 s。候选被拒绝（input=nil），只补导出 PNG，没有再次合成；补出的 PNG 与首次重开基准原始 RGBA／ICC／色彩标记／方向／位深精确相等。证据为 `replay.log`、`replay.xcresult`、`replay-equivalence/raw-pixel-comparison.json`（passed=true，differences=[]）。原失败诊断仍保留在 `real.log`／`real.xcresult`、`pixel-difference.json`。

后续 opt-in 入口遇到被拒候选会验证旧路径回退，并在记录中用 comparisonPath 区分 accepted-prepared-input／reopened-fallback／direct-export-diagnostic；不会把两次重新打开导出称作融合通过。本次没有再运行四面合成。

原始证据根 `/tmp/butterfly-batched-ps-task2-20261108/`，DerivedData `/tmp/butterfly-next-perf-build`；测试素材、PSD、PNG、清单和构建产物均隔离。本报告区分 PS 内部导出时间、Swift 服务完整耗时，不把二者直接相减当端到端优化收益。

## 保护与交付

最终 SHA-256 复核：87 个受保护文件、30 个并行文件均无变化，核对耗时 2.371 s。保留 `project.pbxproj`、`output/`、AI `scripts/export_psd_sample.py` 的并行修改，不将它们提交。Task 1 已有的完整 JPG 间歇性像素校验失败未在本项修复或放宽；本项不宣称解决它。默认是否启用、稳定整批收益留在后续验收。本项独立 review 后单独提交并停止，不进入 Task 3，不推送、不安装。

首次 7 组实图诊断与一次保留样本回放合计命令墙钟 69.632 s，未运行 AI 或成品全流程。大图与xcresult留在临时目录，可能被系统清理；关键失败与数据保存在此报告。
