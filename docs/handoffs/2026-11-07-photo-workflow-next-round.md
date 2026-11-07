# 照片工作流性能优化交接

## 接手任务

上一轮 1–8 **全部实施、实测、独立 review 并提交**，Release 副本 UI 也已验收。不要重做。下一轮仅完成了规范和计划，**尚未改产品代码、尚无新收益实测**。用户要求下一位 agent 按确认后的任务逐项实施，每项测试、计时、独立 review、单独提交后停止。

先读[下一轮规范](../superpowers/specs/2026-11-07-photo-workflow-batched-ps-design.md)，再读[五项实施计划](../superpowers/plans/2026-11-07-photo-workflow-batched-ps-implementation.md)。收到用户开始指令后，从新计划 **Task 1：完整基线及细分观测**开始；不要立即改调度或跳到 Task 4。

## 已完成及提交

Toolkit：`/Users/hans/Developer/butterfly-toolkit`，分支 `codex/photo-workflow-perf-1`，已推送 [GitHub](https://github.com/hans-specimen/butterfly-toolkit/tree/codex/photo-workflow-perf-1)。AI：`/Users/hans/Developer/butterfly-ai`，分支 `codex/photo-workflow-perf-2`，已推送 [GitHub](https://github.com/hans-specimen/butterfly-ai/tree/codex/photo-workflow-perf-2)。未合并 main，未正式安装新版；本次文档也提交并推送同一 Toolkit 分支，接手时读实际 HEAD。

| 原编号 | 已实现／四面三轮中位数收益 | Toolkit 提交 |
|---|---|---|
| 1 | 发布后角色复用：37.40→11.39 s | `ecd023c` |
| 2 | AI 输入 PNG：34.19→12.45 s；AI 保存：5.76→2.78 s；非 sRGB／非8位保留旧路径 | `8a3a8c4`；AI `65695ee` |
| 3 | 确认前单次受保护角色读取：10.78→3.52 s | `b506b6c` |
| 4 | 共享有界几何缓存：三次几何调用合计7.016→2.583 s | `65916ac` |
| 5 | 删除丢弃位图：缓存预览合计66.38→24.05 ms，首次无明显收益 | `9eba0cc` |
| 6 | 渲染／首次发布复用解码：11.011→7.235 s | `4aa99e4` |
| 7 | 两面交错：已保存堆栈到8份成品237.161→215.044 s（9.3%） | `f446b46`；UI `fd94f22` |
| 8 | 同批单路模型复用：连续AI106.559→92.176 s（13.5%） | `349048e`；AI `43f0e46` |

实际顺序为 1→2→3→5→4→6→8→7。各项范围不同，**收益不能相加**。详情在 `docs/validation/2026-11-07-photo-workflow-performance-task-1.md` 至 `task-8.md`。最新最终回归：Swift210通过／10默认跳过／0失败，27.29s；Python43通过，1.55s；正式Release构建26.82s。真实AI／PS专项另行执行通过，真实暂停恢复额外推理0次／安装共2次；49个保护文件哈希最终不变。

Toolkit 性能基线 `fd94f22` 后另有已提交图标更新 `3938dea`，不回退它。未提交的 `Butterfly Toolkit.xcodeproj/project.pbxproj`、未跟踪 `output/` 和 AI 的 `scripts/export_psd_sample.py` 属并行工作，原样保留，不纳入性能提交；接手时重新核对新增修改。

## 下一轮待实现

1. **测量先行**：分开 PS 打开／保存／快照／哈希／角色导出、排队与AI计算；补从新 JPG 开始的完整批次基线。
2. **合成顺带输入**：保存分层 PSD 后，在同一次打开期间从副本导出 AI PNG；PNG 失败只补 PNG，不重做有效 PSD；合成检查仍可阻止 AI。
3. **PS 操作内复用**：仅在单个现有独占租约内复用打开文档；正式 PSD 原子替换仍关闭旧文档并验证新版，不跨人工检查点常驻。
4. **集中 matte 候选**：全批补齐输入→单路 AI→等待worker退出→串行安装；每面结果立即持久化，全部 matte 完成后才几何；保留原交错模式作为默认／对照。
5. **A/B/C/D 实测择优**：原流程、输入融合、再加PS复用、再加集中调度；同堆栈精确比较与新JPG完整批次分开计时。集中方式不一定更快，不达门槛保留已通过旧路径。

新计划的状态明确：输入／AI 子阶段 running→缓存落盘→pending（revision递增），只有安装验证完成才 matte completed；不得提前清理、不在安装段偷偷推理、不跨整批边界逐面一路输出。四个检查开关全部16组合、双面选择、失效／暂停／手工优先／重启必须保留。

现有证据提示资源竞争：任务7同输入AI内部段串行65.305s、交错85.188s，但整批仍更快；不是已证明的因果关系，也不是能直接追回20s的承诺。完整原JPG新旧总收益、真实统一内存峰值、任意大批次及长期混合负载仍未验证。

## 保护与实测入口

- 测试源：`/Users/hans/Developer/tmp/origin`；原清单：`/Users/hans/Library/Application Support/Butterfly Toolkit/PhotoWorkflow/5FF0CED2-FA21-4D17-8DA4-2F8D8B62BCE2/batch.json`，只读。
- 新建临时根并重定向所有源／PSD／workspace／输出路径；原批次22／33成品不可确认重导、覆盖或用作写实验。
- 固定模型、FP32、2048输入、JPEG0.82、4096画布、默认256边距、原始Alpha／ICC／居中／分层及恢复协议不变。禁止为提速删检查、降精度或删浮点Alpha。
- 历史证据 `/tmp/butterfly-perf-task1-20261107/` 至 `task8-20261107/` 可能被清理；关键数值已入仓库，缺少原始证据时重建安全夹具，不能补造结果。
- 单项完成后记录实际耗时、测试和限制，经独立review再提交并停止；推送／安装按当时用户指令，不从本次推送授权推断以后可自动发布。
