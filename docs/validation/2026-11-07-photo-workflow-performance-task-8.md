# 照片工作流性能优化：任务 8 验证记录

日期：2026-11-07。实施基线：Toolkit `4aa99e4`、AI `65695ee`。本项跨两个仓库，各自独立提交；保留现有功能分支和并行版本管理改动。只完成任务 8，不开始任务 7，不安装、不推送。

配套 AI 实现提交：`43f0e46`（`perf: reuse fixed inference model within workflow sessions`）。

## 实施内容

- Python 增加固定 workspace／device／revision 的 `InferenceSession` 和逐行 JSON `serve` 命令，模型惰性加载且同会话只加载一次。保留独立 `catalog`、`import-image`、`infer` 命令。
- Swift `AIInferenceWorker` 使用明确 FIFO 队列和单个活动请求，逐条验证 ready 协议、requestID、输入身份和输出路径。stderr 写临时日志，避免管道写满；协议损坏、错序、错 ID、错误输入、进程退出均不能完成别的请求。
- 排队取消仅移除自己；活动取消终止进程、等待退出并清理队列。shutdown 幂等，并发调用都等待真正退出。无法响应正常终止的子进程在 1 秒后强制结束。
- 致命错误锁存到会话结束，执行器不能为下一面自动重启；用户重试可以建立新会话。普通请求错误保留 requestID，允许会话处理后续请求。
- WorkflowMatteService 改为结构化请求注入；同一批连续面共享 worker。matte 阶段结束、进入检查／后续阶段、暂停、关闭／切换批次、切换引擎都关闭会话。独立 AIWorkspace／AIProcessRunner 不变。
- PhotoWorkflowStore 异步读取返回后检查取消、重置状态、执行器身份和批次 ID，错误分支也做相同检查，防止旧读取恢复已关闭／替换的批次、缓存或错误提示。
- 实测 24 GiB 机器保留完整 MPS 分配池会严重拖慢后续面，因此 worker 每次保存验证后释放**未使用的分配池**，保留模型张量；失败请求在异常处理结束、回收 traceback 引用后也释放未使用分配池。
- 模型 revision 仍为 `5d6b6f8adcb5b417c871b1d84ceaae9871355b7f`，FP32、2048 输入、原预／后处理与 `engine.infer` 不变；没有训练、下载模型、新增依赖或改精度。裁切、JPEG 质量、PNG 像素和恢复／发布机制不变。

## 测试与独立 review

Swift 使用 Release、`ENABLE_TESTABILITY=YES`、`platform=macOS`；derived data 为 `/tmp/butterfly-workflow-perf-build`。Python 使用 AI 仓库现有虚拟环境，普通测试使用 fake load／infer，不加载真实模型。

| 验证 | 通过 | 跳过 | 失败 | 命令墙钟耗时 |
|---|---:|---:|---:|---:|
| 最终 Python 全量 | 43 | 0 | 0 | 1.25 s |
| 指定 Swift worker／AIWorkspace／bridge／executor／preview 类 | 91 | 6 | 0 | 37.78 s |
| 最终 Swift 完整回归（含最终关闭路径修复） | **201** | **9** | **0** | **36.66 s** |
| 真实 Swift service opt-in 专项 | 1 | 0 | 0 | 27.23 s |

9 项默认跳过均为显式环境变量启用的实图／集成专项；本项新真实 service 测试另行运行，确认没有跳过。使用任务 2 已验证的 22_F 堆栈 PNG，只读复制至新的 `swift-real/data/processed/input.png`，真实 service 推理、回读像素／ICC／输入身份校验和 shutdown 共 **24.425404 s**。源输入及临时副本的 SHA-256 均为 `f9fb2687e3f9d5b19bd517feab6255cb4879106e7f4073841740ad0a8464927d`，前后不变。

有效 RED 证据：

- Python 两请求模型加载次数：改动前 37 项中 1 项预期失败，墙钟 1.30 s。
- Swift 临时单次进程实现：有效 fake worker 下两请求进程数 `2 != 1`，墙钟 40.03 s，之后恢复完整 worker。更早的 fake 可执行文件／脚本夹具故障不作为 RED 证据。
- Review 发现并发空闲 shutdown 提前返回：进程仍存活的断言失败，40.47 s；改为共享 shutdown task。末轮复核进一步统一崩溃清理期间的关闭路径，避免晚恢复的旧等待者清除新会话状态；两个并发关闭后显式重试的用例随最终全套通过。
- Review 发现失败请求缺少释放分配池：43 项中 1 项失败，1.50 s；修复后全部通过，1.25 s。
- Review 发现旧异步读取回写和自动下一面重启：3 项中 1 通过、2 预期失败，43.95 s；分别观察到切换后旧 batchID 恢复和崩溃后进程数 `2 != 1`。增加读取归属检查和会话失败锁存。

初始完整基线为 **186 通过、8 跳过、1 失败，18.07 s**，不是全绿：`testBatchSwitchAndCloseClearSharedGeometryCache` 观察到缓存 4 项而非 2 项。独立 review 确认旧 `sync` 具备可复现的过期回写路径；不能仅凭相似症状断言它就是初始偶发失败的唯一原因。新增 gated-read 测试覆盖切换、关闭、同批切换引擎及迟到错误；最终完整回归重新运行。

生命周期测试还覆盖并发请求最多活动 1 个、启动中取消、重复关闭、忽略 SIGTERM 的子进程、崩溃清理期间关闭后重试、真实执行器暂停、matte 结束先关闭再分析、正常 Store 关闭／切换引擎／批次。现有独立 AI 工作区、bridge、恢复及发布测试随回归执行。实图 Swift service 另行 opt-in 验证。

独立 reviewer `review_task8` 只读检查跨仓库实现、相关调用、新增回归测试和实测报告，并复核上述修复，最终结论：**代码 review 通过，无剩余阻塞性发现**。Reviewer 未重复执行测试／模型；最终全套与真实 service 验证由实施方完成。

## 三轮实际耗时

相同输入来自 `/Users/hans/Developer/tmp/origin` 对应既有批次 `5FF0CED2-FA21-4D17-8DA4-2F8D8B62BCE2` 的 22_F、22_U、33_F、33_U 角色 PNG。只读复制到新临时 workspace，保留完整尺寸和 ICC；透明输入沿用已有 `white_rgb` 规则。每组使用新进程／会话，1、2、4 面分别三轮，第二轮交换 single／worker 次序。共 18 组、42 次真实 MPS 推理、21 对结果。

计时从进程启动到组内全部结果完成及进程退出，包含 imports、模型加载、预处理、推理、保存验证与清理；排除测试输入复制。测试期间未并行运行其他本任务的编译或 GPU 测试，没有清空操作系统文件缓存。

| 面数 | 单次进程三轮（秒） | worker 三轮（秒） | 中位数（单次 → worker） | 减少 |
|---|---|---|---|---|
| 1 | 27.204380 / 30.458315 / 23.156408 | 26.230101 / 34.855366 / 26.895523 | 27.204380 → 26.895523 s | 0.309 s，1.1% |
| 2 | 55.685920 / 63.289528 / 45.738856 | 50.201669 / 57.570140 / 43.210987 | 55.685920 → 50.201669 s | 5.484 s，9.8% |
| 4 | 106.559230 / 106.942842 / 100.974388 | 92.176284 / 107.079420 / 87.188585 | **106.559230 → 92.176284 s** | **14.383 s，13.5%** |

每轮 worker 进程数和真实 model load 数都为 1；单次模式均为面数 1／2／4。单面收益很小，第二轮四面 worker 略慢于对照，不宣称每次均提速；三轮中位数表明多面连续推理有收益，因此接入默认工作流。

下表为每组各阶段合计的三轮中位数，单位秒。各列分别取中位数，不能相加还原总中位数。

| 面数／模式 | 启动至首事件 | import | prepare | load | 首面 infer 调用 | 后续 infer 调用合计 | 保存验证 | 释放未用 MPS 池 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 single | 0.0523 | 0.6241 | 0.2956 | 1.7595 | 22.1907 | 0 | 1.2280 | 0 |
| 1 worker | 0.0566 | 0.6483 | 0.3059 | 1.7320 | 21.7053 | 0 | 1.2390 | 0.6650 |
| 2 single | 0.1143 | 1.4066 | 0.6175 | 3.3275 | 24.9564 | 18.9077 | 2.7006 | 0 |
| 2 worker | 0.0621 | 0.6656 | 0.9796 | 1.6358 | 21.7117 | 18.7652 | 3.0713 | 1.3605 |
| 4 single | 0.2149 | 2.7005 | 1.2325 | 6.7463 | 21.8454 | 60.0705 | 4.8725 | 0 |
| 4 worker | 0.0793 | 0.6281 | 2.0408 | 1.6660 | 17.7963 | 64.3584 | 4.6541 | 1.8505 |

`infer` 调用包括原函数内设备传输、forward／finite／sigmoid／同步及回读。未改原函数来拆分计时；另记录其已有内部推理时间和外层调用差值。四面 single／worker 内部段合计中位数为 80.7872／78.8516 s，外层差值为 0.8842／0.3753 s；后者包含传输、回读和其他调用开销，**不是纯传输时间**。不宣称后续每面 forward 更快。完整每轮数据保存在 `summary.json`。

## 内存与结果一致性

- 24 GiB 物理内存。各进程 `ru_maxrss` 记录 CPU 进程峰值 RSS；单次模式每组取子进程峰值最大者，未相加：1 面三轮 1.876／1.877／1.876 GiB，2 面 1.883／1.883／1.883 GiB，4 面 1.905／1.904／1.905 GiB；worker 约 1.876–1.877 GiB。
- 原 infer 返回时的 GPU driver 分配记录：single 16.064–29.736 GiB，worker 14.611–29.877 GiB；worker 每次释放未使用池后为 **1.563–2.102 GiB**，仍存活张量为 **0.832 GiB**。它们是阶段端点，不是 GPU 峰值，也不能与 RSS 相加当作整机峰值。会话结束等待进程退出。
- 探索轮在尚未释放 unused pool 时，第二面曾耗时约 131 s，驱动分配接近 30 GiB；主动停止仅本任务子进程，保留 `real/` 诊断。修复后重新完整跑三轮，以上表格只用 `real-final/`，未混入探索轮。
- **21 对浮点 Alpha 数组逐元素精确一致**；保存 Alpha PNG 和前景 PNG 的原始像素、mode、尺寸、完整解码元数据（含 ICC）全部一致，没有放宽任何阈值，也没有用预乘 sRGB 比较替代原 RGBA。
- **49 个受保护文件 SHA-256 不变**：既有 45 个源图／PSD 快照／导出成品／清单／AI 结果，以及本次只读使用的 4 张角色 PNG。所有新结果写入新的临时目录，未覆盖原件或成品。
- 保留 `Butterfly Toolkit.xcodeproj/project.pbxproj` 的并行版本配置改动，以及 AI 仓库既有未跟踪 `scripts/export_psd_sample.py`，均不纳入本项提交。

## 证据与边界

证据目录 `/tmp/butterfly-perf-task8-20261107/` 包含测试日志和 xcresult、`real-final.log`、18 组计时、21 对原始结果、汇总脚本、前后保护哈希和真实 Swift service 输出；临时文件可能被系统清理，关键结果保留于本文。

Python 全量为 AI 仓库虚拟环境执行 `scripts/test_toolkit_bridge.py`。Swift 真实专项为 `AIInferenceWorkerTests/testRealMatteWorkerWhenRequested`，通过 `TEST_RUNNER_WORKFLOW_WORKER_REAL_INPUT`、尚不存在的 `TEST_RUNNER_WORKFLOW_WORKER_REAL_EVIDENCE`、`TEST_RUNNER_WORKFLOW_WORKER_REAL_ENGINE` 指定输入、新 workspace 和 AI 仓库。基准脚本 `benchmark-final.py` 使用同一 bridge 的 single／serve 命令，`summarize.py` 汇总阶段、内存、加载次数并重新检查保护哈希。

这是连续 AI 阶段的进程／模型复用测量，**不是包含 Photoshop、人工确认、几何和导出的整批端到端测量**。本项未测整机／GPU 峰值、长时间混合负载或任意规模批次；不将这次结果外推为完整流程 13.5% 提速。按计划下一项是任务 7，本次独立提交后停止。
