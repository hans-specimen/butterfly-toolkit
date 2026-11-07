# 照片工作流性能优化：任务 2

日期：2026-11-07。范围：[实施计划](../superpowers/plans/2026-11-07-photo-workflow-performance-implementation.md)任务 2；任务 1 已完成，任务 3–8 未实施。

## 实现与兼容边界

- Toolkit 基线 `5d4ee4b`，包含任务 1 和并行版本管理提交。AI 基线 `0d86a55`。保留版本配置和未跟踪的 `scripts/export_psd_sample.py`，不安装 App、不升版本、不推送远端。
- `exportStackPNG` 通过小型 `wfStackPNG` 路由：仅对标准 sRGB、8 位 RGB 副本指定标准 sRGB ICC，再复用现有快速无损 PNG helper；非 sRGB、其他模式及位深保持旧 Save for Web。角色图导出和任务 1 缓存不改。
- Python `save_prediction(..., *, compress_level=6)` 将明确的档位传给前景和 Alpha 两个 PNG。仅 `infer_file(workspace != None)` 传入 1；独立 AI 工作区保持 6。浮点 Alpha 保存、量化、白底合成、模型精度、模型 revision、输入身份与全部回读校验不变。

### 实测发现与处理

首次尝试对所有 8 位 RGB 输入直接快速保存，合成 Adobe RGB 夹具未通过：旧 Save for Web 会转换到 sRGB（ICC 3144 字节），快速保存保留 Adobe RGB（ICC 544 字节），RGB 数值也不同。这是本轮新增原始数据对照检出的实际差异，不能引用既有角色图的测试结果放行。

依据规范 §3 的像素／ICC 不变要求和 §5.6 的回退规则，**非 sRGB 输入保留旧 Save for Web 路径**。放弃这些输入的编码提速，不引入新的色彩转换算法。新增 sRGB 8 位、Adobe RGB 8 位、sRGB 16 位夹具验证实际编码器和结果；不得把所有模式均已加速作为交付结论。

进一步对照发现：相同 sRGB 名称的转换后 PSD 可能带不同的 ICC 渲染意图字节（偏移 67，旧导出 0、快速导出 1）。RGB 完全相同，且 Swift 的颜色配置归一化会掩盖这个字节差异。相同配置的 `convertProfile` 并未改变该字节，已撤销该尝试。最终在已是 sRGB 的临时副本上用带明确目标文档引用的 Assign Profile 指定标准 sRGB，再快速保存；没有将非 sRGB 图像重新解释成 sRGB。

`scripts/verify_workflow_png_pairs.py` 将原始 RGBA、ICC 字节、色彩块、尺寸、方向及位深比较直接接入 opt-in XCTest。修复前它对 ICC 差异退出 1；修复后 3 种合成夹具各 3 轮全部退出 0。它避免仅凭 Swift 预乘像素和归一化颜色信息宣称通过。动作描述器目标参考 [Adobe 社区记录的 ScriptListener 输出](https://community.adobe.com/questions-712/scripting-assign-profile-equivalent-1105083)；验收依据仍是本机实际输出。

## 现场保护和测量方法

- 开始时 App 空闲于已完成 22／33 批次的 4K 页面。源目录仍为 `/Users/hans/Developer/tmp/origin`。
- 输入测试采用四面的**未回写蒙版的堆栈不可变快照**，逐一复制到新临时目录，并为副本建立独立归属。不是回写后角色图，也不写原 PSD。
- 三种合成 PSD 包含 Alpha 0／1／64／128／255 和名为 `Background #74BFFF` 的蓝底层；导出时必须隐藏蓝底，保留软 Alpha。真实运行时计数验证 quick PNG 或 Save for Web 的实际执行，而非仅检索 helper 定义。
- Release、arm64；同一不可变快照的新旧输入导出各 3 次，交替次序。输入耗时为 `exportStackPNG` 完整调用，包含保存／身份检查、PS 导出编码与写盘、Swift 回读验证；另做原始 RGBA／ICC／色彩标记／方向／位深对照。
- AI 输出基准使用四面已保存的 RGB 和浮点 Alpha，在新目录调用旧提交的 `save_prediction` 与新版 level 1 各 3 次，交替次序。计时包含 Alpha 恢复、两个 PNG 和浮点文件写盘、全部回读校验；每次另行核对原始 RGBA、ICC、Alpha 和浮点数组。不会重复推理或改写已有结果。
- 原 AI 输入临时 PNG 已不存在；输出基准从保留的 predicted-foreground 提取同一 RGB／ICC、从 predicted-alpha.npy 取得同一浮点 Alpha。这是编码阶段测量，不是完整模型推理重跑。
- 全部产物只写 `/tmp/butterfly-perf-task2-20261107/`；保存原图、PSD、成品、AI 结果和清单的保护哈希，最终核对。

## 测试、耗时和空间代价

- Swift 新基线全量：168 项，165 通过、3 跳过、0 失败；构建＋测试墙钟 32.98 s。
- Python 红灯：原方法不支持 `compress_level`，工作流编码档位仍为默认 6；修改后全部 **36 项通过**，0.957 s。
- Swift 最终全量：169 项，**165 通过、4 项 opt-in 跳过、0 失败**；13.59 s。
- 最终真实输入 XCTest 另行启用并通过：**1 项通过、0 跳过、0 失败**，包含 7 个夹具 × 3 组新旧对照；墙钟 174.81 s。全部 **21 组原始 RGBA／ICC／色彩块／尺寸／方向／位深对照一致**。
- 原始核验脚本在未修正 ICC 的候选上实际失败（exit 1）；最终 XCTest 自动执行该脚本并通过。
- AI 输出：四面 × 三轮，新旧共 24 次保存；每次原始 RGBA、ICC、Alpha 和 float32 数组均与保存前数据一致。默认压缩与 level 1 的差异仅为编码体积。

每面 3 次中位数；时间包含写盘及回读，空间单位 MiB：

| 面 | 输入旧→新（秒） | 输入 PNG 旧→新 | AI 保存旧→新（秒） | 两个 AI PNG 旧→新 |
|---|---:|---:|---:|---:|
| 22_F | 10.82 → 3.60 | 21.66 → 22.33 | 1.49 → 0.70 | 23.58 → 37.51 |
| 22_U | 6.80 → 2.69 | 21.02 → 21.42 | 1.47 → 0.71 | 25.19 → 40.19 |
| 33_F | 8.56 → 2.95 | 16.90 → 17.36 | 1.40 → 0.66 | 20.59 → 34.46 |
| 33_U | 7.92 → 3.13 | 24.29 → 24.77 | 1.42 → 0.71 | 25.82 → 40.81 |

四面样本按重复编号求和，再取三轮中位数；不是用户操作到整批结束的墙钟：

| 阶段 | 旧版三轮（秒） | 新版三轮（秒） | 中位数及减少 |
|---|---|---|---|
| AI 输入导出 | 34.98, 34.19, 33.86 | 12.71, 12.06, 12.45 | 34.19 → 12.45，减少 21.74 s（63.6%） |
| AI 结果保存 | 5.84, 5.76, 5.73 | 2.79, 2.77, 2.78 | 5.76 → 2.78，减少 2.98 s（51.7%） |

- 四面输入 PNG 总计 **83.87 → 85.88 MiB**（+2.01 MiB）；八个 AI PNG 总计 **95.18 → 152.97 MiB**（+57.79 MiB）。合计多 **59.80 MiB／四面**。
- 四份浮点 Alpha 各 71,277,184 字节，未删除、未缩减精度。写盘和回读计入后，四面全尺寸实图仍有明确收益，因此启用上述快速路径。
- 三种 5×1 夹具用于颜色／透明度／回退验证；固定调用开销使 tiny sRGB 快速保存不更快，不把它外推成全尺寸收益。Adobe RGB 和 16 位只验收结果一致与旧路径保留，不宣称提速。
- **45 个**受保护文件全部哈希不变：12 张原 JPG、8 份原 PSD 快照（当前与未回写）、8 个已发布成品、原 batch.json，以及 16 份既有 AI 结果／记录。
- 第 2 项完成，下一项为任务 3：确认路径只做一次受保护的当前角色读取。

## 独立 review 与证据

配套 AI 仓库提交：`65695ee`（`perf: use fast lossless PNG compression for workflow inference`）。

同一独立审查者 `review_task2` 完成两仓库初审，并补充审查实测发现后新增的 ICC helper、原始 PNG 核验脚本及其 XCTest 接线；Critical／Important／Minor 均为 0。最终测试、实测和保护哈希均已通过，满足提交条件。

审查边界：标准 sRGB 与转换产生的 ICC intent 差异已测；没有覆盖人为构造的“名称为 sRGB、实际色彩定义不同”的自定义 ICC。未变化的 Python 实现沿用初审，其他性能任务不包含于本次提交。

临时证据目录：`/tmp/butterfly-perf-task2-20261107/`。包含测试日志／xcresult、input-verified 新旧 PNG 与逐轮 JSON、output 编码结果、保护哈希和对照脚本。`input/`、`input-final/`、`normalized-synthetic/` 是发现色彩／ICC 差异的被替代候选，不能当作最终通过证据。临时证据可能被系统清理；实测摘要保留于本文件。

Swift opt-in：`TEST_RUNNER_WORKFLOW_PNG_EVIDENCE` 指定一个新的空目录；`TEST_RUNNER_WORKFLOW_PNG_PYTHON` 指向 AI 仓库带 Pillow 的 Python；可通过 `TEST_RUNNER_WORKFLOW_STACK_FIXTURES` 传入包含 name/source 的 JSON 数组以加入只读实图快照。运行 `WorkflowBridgeTests/testRealStackInputFastPNGPreservesPixelsWhenRequested`；正常 suite 默认跳过真实 Photoshop 测试。

普通验证沿用计划的 Release `xcodebuild test` 和 `PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -B -m unittest discover -s scripts -p test_toolkit_bridge.py -v`。

本项不代表整批端到端提速或新模型质量验收；未测整批总耗时与峰值内存。
