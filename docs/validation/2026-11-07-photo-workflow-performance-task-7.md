# 照片工作流性能优化：任务 7 验证记录

日期：2026-11-07。实施基线：Toolkit `349048e`、AI `43f0e46`。仅实施第 7 项；沿用现有分支。状态：7a／7b 实施、实图三轮对照、完整回归、真实暂停恢复与独立代码 review 均通过；无阶段回退。仅现场 UI 验收因 Mac 锁屏未验证，不记为完整现场验收通过。

## 实施和保护边界

- 现有 WorkflowExecutor 内增加 `runStageTasks`，不建立通用调度框架。高清／4K 导出及蒙版阶段最多两面在途，stack／geometry 仍串行。
- 每次补充任务都重新读取当前 activeTasks、pending 和 eligible；实际任务进入时再检查一次。不能把初始任务列表当作持续授权。
- 全部状态修改、manifest 保存队列、发布前版本栅栏和同步发布仍在执行器 actor 内。没有在最后检查与 publish 之间新增 await；所有在途任务收尾后才推进阶段或完成双面 4K 确认。
- 蒙版阶段复用已有单路 AI worker 与 Photoshop 独占租约，允许 A 推理时 B 导出输入、B 推理时 A 回写。每面的输入、推理结果和安装事务仍分别持久化，失败面不撤销成功面，也不自动排除标本。
- 暂停先失效当前授权、取消运行句柄并持久化，停止新派发。已经开始的不可中断 Photoshop 操作继续持有租约直至结束；手工编辑等待租约释放。显式暂停收尾后正常返回，外部父 Task.cancel 仍抛取消错误。
- 旧运行未排空时 `continueAutomatic` 拒绝改变暂停状态，与界面的 busy 门禁一致，避免恢复请求被旧运行吞掉。
- 内部 `exportLimit`／`matteLimit` 参数限制为 1...2，供同一二进制串行对照和阶段级资源回退使用；没有新增用户性能设置。
- 模型、FP32、2048 输入、PNG 压缩、浮点 Alpha、JPEG 0.82、4096 画布、256 默认边距、居中规则及恢复／归属检查不变。AI 仓库无实现改动。

## 自动测试及 review 修复

Swift 均使用 Release、`ENABLE_TESTABILITY=YES`、macOS，derived data 为 `/tmp/butterfly-workflow-perf-build`。

| 验证 | 通过 | 跳过 | 失败 | 墙钟耗时 |
|---|---:|---:|---:|---:|
| 改动前完整基线 | 201 | 9 | 0 | 12.17 s |
| 导出并发 RED | 1 | 0 | 2（预期） | 27.53 s |
| 蒙版仍为单路的 RED，含 executor／integration／output | 54 | 0 | 2（预期） | 64.04 s |
| review 两项竞争窗口 RED | 0 | 0 | 2（预期） | 21.91 s |
| 最终完整回归 | **210** | **10** | **0** | **27.29 s** |
| Python 全量 | 43 | 0 | 0 | 1.55 s |

指定 executor、integration、output 与 worker 类全部包含在最终全套中。默认跳过项均为显式环境变量启用的真实 Photoshop／模型／性能专项，本项真实用例另行执行。

最终完整回归还覆盖四个检查开关的全部 **16 种组合**，每组四面；打开的 stack／matte 检查点分别阻止 AI／构图继续，geometry／4K 保留原确认逻辑。

新增普通测试覆盖：

- `testExportsOverlapWithMaximumTwoActiveRenders`：高清和 4K 各四面；两个 render 被门控同时阻塞，峰值恰为 2，在途时不显示整批完成，磁盘清单与内存状态一致。
- `testParallelExportPausePreventsLatePublication`：两面阻塞时暂停，另外两面不派发，迟到结果不发布，显式继续可完成。
- `testParallelExportFailureKeepsSuccessfulSide`：一面失败、三面成功；重启只渲染失败面，成功产物记录不变。
- `testMattePipelineOverlapsPSAndAIWithoutParallelAI`：真实 coordinator、真实 worker 加临时 fake Python，证明 PS／AI 工作重叠；PS 峰值 1，AI 仍单进程逐请求，面任务为 2。
- `testPipelinePauseAndManualLeaseDrainSafely`：暂停不提前释放阻塞的 PS 租约，人工编辑在 PS 操作结束后才获准，不再派发其余面。
- `testPipelineRestartReusesCompletedInference`：两个推理结果已持久化、A 的 PSD 已保存但执行器未收尾时暂停；重启复用两份推理结果并验证已写入的 A，不重复推理或回写。
- review 用例：AI 致命错误清理期间第二面仍收到故障而非 CancellationError，批次不会被伪装成暂停，两面记录 failed；旧运行未排空时恢复请求被明确拒绝。

Review 发现 worker 在 fatal cleanup 窗口先检查 stopping，第二面可能收到取消并触发整批暂停；现改为优先返回已有 sessionFailure。新执行器测试在旧实现中实际失败后修复。暂停回归曾有一项旧测试仅要求外层抛错（66 通过、1 跳过、1 失败，49.75 s）；改为检查推理没有完成、进程已退出、状态没有误记失败，保留父任务取消异常测试。

一次完整回归在既有 `testCancellationDuringStartupAndRepeatedShutdown` 停滞，采样证明子进程已退出而 detached cleanup 卡在 Foundation `waitUntilExit()` 的 RunLoop。该轮在 259.68 s 被主动终止，不记为通过。改用启动前登记的 terminationHandler／DispatchGroup 等待真实退出；启动失败与正常退出分别释放一次，不持锁等待、不捕获 self。新增 10 次启动中并发关闭的有界 expectation 回归，随最终全套通过。只终止本任务的测试／构建进程，没有结束用户运行的应用。

早期一次编译因 throwing `||` 右操作数失败（4.36 s），修正表达式后重跑；编译失败不作为 RED 证据。既有单续体 render 测试夹具改为保存并释放全部续体，避免双路测试丢失等待者。

独立 reviewer `review_task7` 只读检查相关执行器、worker、状态机、Store 和 coordinator，复核了上述修复及真实夹具边界；依据实测支持保留双路上限。最终代码／规范／证据 review 通过，无阻塞发现；reviewer 未重复运行重测试。代码 review 通过不等于锁屏期间无法完成的现场 UI 验收通过。

## 真实测量方法

- 原批次只读：`5FF0CED2-FA21-4D17-8DA4-2F8D8B62BCE2`，对应 `/Users/hans/Developer/tmp/origin` 的 22／33 正反面。测试前现场确认 Toolkit 原批次停在已完成的 4K 页面，Photoshop 无进行中的自动操作。
- 每组复制源 JPG 及相同不可变原堆栈 PSD 到新的 `/tmp/butterfly-perf-task7-20261107/` 子目录，创建新的 owner、workspace、manifest 和输出路径。所有 install／apply／publish 只写副本及新文件。
- 2／4 面从相同已保存堆栈恢复，实际执行输入导出、真实 MPS 推理、蒙版安装验证、角色读取、自动构图与应用、高清和 4K 发布，结束时断言 allSucceeded。不是只测服务 mock。
- 1 面模拟双面标本中只剩一面需要推理，另一面使用已完成蒙版的独立 PSD 副本；保持整批蒙版检查点，结束时两面均 waitingReview。此项不包含后续导出，不把它写作单面全流程完成。
- 每种规模各三轮，串行／双路均使用相同二进制与服务，仅执行器上限不同；第二轮交换次序。首先完成的两面试跑使用相同版本及方法，作为两面第一轮，不重复计入。
- 总时长是实际 `runPending` 调用，包含阶段收尾和 worker 退出。准备、复制、初始 capture／hash、register 另记 setupSeconds，排除于总时长；已有 stack 不重做。**不代表从新 JPG 景深合成开始的整批耗时。**
- 阶段计时包裹真实 Services 调用；exportStack／infer／install 等包含等待 PS／AI 队列，不能直接相加当作总时长或纯设备时间。同步 publish 原地计时，没有插入 await。capture／hash 包含在相应 bridge 服务中，没有单独拆出其纯耗时。
- 每秒采样本次测试 App、其子进程与 Photoshop 的 RSS，并记录系统压力原始级别、vm_stat 和 swap 前后值。App 的 ru_maxrss 只表示测试进程峰值（含 setup），不含 PS／Python／MPS；采样 RSS 和设备端点也不是统一内存峰值，不能直接相加。
- 未清空 OS 文件缓存／swap，测试初始系统已经使用约 16 GiB swap；压力变化不能全归因于本项。实图计时期间不并行编译或运行其他本任务重负载测试。
- 输出按原堆栈内容版本及标本面配对；新导出 PNG 的单请求字节哈希不是跨运行的配对键。比较保存浮点 Alpha 精确数组、Alpha／前景 PNG 完整非预乘像素和色彩信息，以及最终 JPG／PNG 的解码像素、色彩标记、尺寸和方向，不放宽任何 Alpha 阈值。

## 三轮实际结果

| 规模／终点 | 串行三轮（秒） | 双路三轮（秒） | 中位数：串行 → 双路 | 减少 |
|---|---|---|---|---|
| 1 面／蒙版检查点 | 47.327 / 43.567 / 47.844 | 45.605 / 48.441 / 45.275 | 47.327 → 45.605 s | 1.722 s，3.6% |
| 2 面／高清及4K完成 | 128.580 / 120.520 / 116.615 | 122.674 / 109.735 / 111.298 | 120.520 → 111.298 s | 9.222 s，7.7% |
| 4 面／高清及4K完成 | 246.925 / 236.496 / 237.161 | 215.044 / 206.735 / 216.973 | 237.161 → 215.044 s | 22.117 s，9.3% |

每组只有一个 worker／一次模型加载，首面包含模型准备、后续面复用；串行对照也享有任务 8 的模型复用。单面没有可重叠的第二面，其差值属于本次测量波动，不能归因为双路收益。

以下为服务覆盖窗口的三轮中位数（秒）：从该阶段第一项服务开始到最后一项服务结束，包含中间排队和持久化，但不包括窗口外的阶段收尾。各列分别取中位数，不能相加还原总中位数。

| 面数／上限 | 蒙版服务窗口 | 几何服务窗口 | 高清 render 窗口 | 4K render 窗口 | 同步 publish 合计 |
|---|---:|---:|---:|---:|---:|
| 2 / 1 | 87.043 | 30.881 | 0.713 | 2.420 | 0.537 |
| 2 / 2 | 78.630 | 31.158 | 0.488 | 1.350 | 0.549 |
| 4 / 1 | 168.951 | 62.906 | 1.522 | 5.034 | 1.031 |
| 4 / 2 | 148.243 | 62.577 | 0.974 | 3.036 | 1.134 |

四面各服务累计调用耗时中位数（串行 → 双路，秒）：exportStack 10.689 → 32.275、infer 78.391 → 135.966、install 80.956 → 113.132、extract 13.582 → 13.973、analyze 1.785 → 1.814、validateGeometry 3.095 → 3.160、apply 42.464 → 42.750、高清 render 1.360 → 1.544、4K render 4.337 → 5.128。前几项包含同时在途任务各自的排队时间，累计值上升不等于批次变慢；上表覆盖窗口反映重叠后的墙钟变化。

准备耗时：1 面每组 8.806–9.486 s；2 面 2.357–5.723 s；4 面 4.619–5.070 s，单独记录而不混入运行时间。未测新 JPG 景深合成、人工操作时间或任意更大批次。

共 **21 对浮点 Alpha 数组**逐元素精确一致；Alpha／前景 PNG 42 对及最终 JPG／PNG 36 对，共 **78 对图片**原始像素、色彩信息、尺寸、方向一致。高清仍为 JPEG 0.82，4K 仍为 4096×4096／默认边距 256；没有放宽透明度或裁切检查。

## 内存与默认上限决定

现场物理内存为 24 GiB。下表是每组测试 App、Python 子进程及 Photoshop 的**合并采样 RSS 最大值**（GiB），不是整机／GPU 峰值。

| 面数 | 串行三轮 | 双路三轮 |
|---|---|---|
| 1 | 4.930 / 5.092 / 5.457 | 5.520 / 4.851 / 5.680 |
| 2 | 6.261 / 6.898 / 7.014 | 6.307 / 6.343 / 7.359 |
| 4 | 6.492 / 7.333 / 7.027 | 6.467 / 7.449 / 6.878 |

- 2／4 面的系统压力原始级别 4 采样占比：串行 6.2–11.1%，双路 8.5–10.1%；双路级别 2 的占比有所增加，未隐去此现象。四面双路三轮 swap 净变化为 −478.00／−562.19／−943.50 MiB；系统起始已有约 16 GiB swap，不能据此宣称没有内存压力。
- GPU driver 推理结束端点：本次串行 14.611–17.611 GiB，双路 15.072–29.795 GiB；双路有三次达到约 29 GiB。此前任务 8 的单次和串行 worker 也出现过 29.736／29.877 GiB。该指标包含缓存与框架分配，不能当作物理驻留量或 GPU 峰值（[PyTorch 指标定义](https://docs.pytorch.org/docs/2.15/generated/torch.mps.driver_allocated_memory.html)）。
- 本次每面释放未使用池后，driver 均回到 1.563–2.102 GiB，存活张量约 0.832 GiB；会话结束等待进程退出。没有观察到逐面累积或相对串行的明确持续内存恶化。
- 保留 `matteLimit=2` 与 `exportLimit=2`；stack／geometry、PS、AI 各自仍为 1。蒙版和两个 render 窗口均缩短，所有对照输出一致，现有证据未触发阶段回退条件。**实际 GPU／统一内存峰值、长时间混合负载未测**，不将本机样本外推为所有规模和负载均安全。

## 真实暂停恢复与发布验证

额外一次真实 Photoshop／MPS 暂停专项通过（1 通过、0 跳过、0 失败，命令墙钟 112.76 s，不计入 18 组性能中位数）。在真实安装事务 `.prepared` 处持有 PS 租约，暂停后申请手工编辑，再允许不可中断安装收尾：

- `pause()` 返回 0.032105 s，手工编辑等待 3.554732 s；事件顺序实际为 prepared → install-published → manual-granted，租约未提前授予。
- 暂停时两份推理结果已经持久化，无 running 蒙版或已发布导出。重新打开清单继续，额外成功推理次数为 **0**；全程成功安装共 **2** 次，没有重复安装已保存的一面。
- 缓存 Alpha／前景文件哈希仍相同，最后双面高清及 4K 全部成功。此次运行含暂停与恢复 108.107374 s，准备 2.544221 s；不是不暂停模式的速度样本。两份推理已经完成，不能将它描述为真实 forward 中途取消；活动推理取消由普通 worker／执行器测试验证。

不带测试环境变量的正式 Release build 通过，26.82 s。另复制为独立 bundle ID 的临时验证应用，并将原清单引用的 36 个文件复制、重定向到全新 UI 夹具；未替换已安装应用。现场 Mac 锁屏，启动和预览验证等待解锁，尚未记为通过。

## 文件保护与交付

18 组实图及真实暂停恢复结束后，49 个受保护文件 SHA-256 再次复核全部不变。原应用的批次／预览选择未主动修改；因锁屏不能进行结束时的视觉确认。后续解锁补做 UI 时需再次复核。未覆盖原始 JPG、用户 PSD、已有成品或原批次清单。

保留 `Butterfly Toolkit.xcodeproj/project.pbxproj` 的并行版本配置改动，以及 AI 既有未跟踪 `scripts/export_psd_sample.py`，均不纳入本项提交。验证产物、日志、xcresult、逐组计时及内存采样位于 `/tmp/butterfly-perf-task7-20261107/`，临时目录可能被系统清理，关键结果将保留于本文。

真实专项为 `WorkflowPipelinePerformanceTests/testRealPipelineFromSavedStacksWhenRequested`，通过 `TEST_RUNNER_WORKFLOW_PIPELINE_BATCH`、`STACKS`、`EVIDENCE`、`ENGINE`、`COUNT`、`LIMIT`（后五项共享 `TEST_RUNNER_WORKFLOW_PIPELINE_` 前缀）启用。`TEST_RUNNER_WORKFLOW_PIPELINE_PAUSE=1` 启用额外暂停恢复专项，仅允许 COUNT=2／LIMIT=2。EVIDENCE 必须不存在；普通 suite 默认跳过。外部 `benchmark.py` 串行驱动各组、采样内存并比对结果。
