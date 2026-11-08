# 照片工作流性能优化：任务 3

> 历史实测记录：结论、测试数量和未完成事项以文内日期及范围为限。当前行为与待办见 [照片工作流](../PHOTO-WORKFLOW.md)，分类见 [验证索引](README.md)；原始日志和临时路径不保证仍存在。

日期：2026-11-07。范围：[第一轮性能记录](README.md)任务 3。Toolkit 基线 `8a3a8c4`；AI 保持 `65695ee`，未修改。

## 实现与保护边界

- `WorkflowExecutor.readCurrentRoles` 直接调用 `services.extract(snapshot)`，去掉此前的 refresh、重复身份比较和额外 inspect。签名、服务接口与清单格式不变。
- 真实 `extractRoles` 继续在 Photoshop 保存读取租约内检查保存状态、角色结构、尺寸、结构摘要、归属、工作文件及不可变快照的哈希；命中缓存仍检查三张 PNG 的哈希。
- 保留读取后的 `check`、角色版本校验、角色图写回，以及上层双面确认的全部 `checkSelection`。手工刷新、堆栈恢复、安装事务恢复不变。
- 首次几何确认仍需在应用几何并保存之后读取新版本。本项只消除确认前同版本的重复检查，不删除必要的保存后读回；画质、透明度、居中裁切及恢复机制未改。
- 版本配置、关于页、项目配置和版本管理脚本均未改；CHANGELOG 仅添加本项记录。AI 原有未跟踪脚本保持原样。未安装 App、升版本或推送远端。

## 测试与独立 review

- 基线 Release 全量：165 通过、4 项 opt-in 跳过、0 失败；墙钟 10.76 秒。
- RED：指定 executor／bridge／integration 三类共 57 通过、1 失败、3 跳过；24.62 秒。新测试检出旧实现每次双面确认出现 2 次 refresh，而预期为 0。此前新增测试有一次 `await` 放在 XCTest 自动闭包中的编译错误，修正后才取得上述有效 RED。
- GREEN 指定三类：58 通过、4 项 opt-in 跳过、0 失败；36.72 秒。
- 扩充首次几何确认覆盖后的最终 Release 全量：**167 通过、5 项 opt-in 跳过、0 失败**，共 172 项；墙钟 **22.33 秒**。上述实图专项另行启用通过，不以默认跳过代替实测。
- 计数测试覆盖首次几何确认、已完成几何的再次确认和 4K：每面当前版本仅 extract 一次；首次几何另有一次应用后的新版本读回。检查角色图写回对应任务、未选中标本不变。外部保存和双面失效注入转移到 extract 边界，原拒绝断言保留。
- 真实 bridge + fake runner 验证缓存读取仅一次 inspect、无额外角色导出，删角色或 inspect 期间保存仍拒绝。原未保存、归属改变、不可变快照损坏、图片／收据损坏和恢复用例继续执行。
- 实图专项：1 通过、0 跳过、0 失败；墙钟 84.99 秒，内含四面各三轮的新旧路径对照。
- 独立审查 `review_task3` 检查实际调用方、bridge 验证／缓存、租约、双面栅栏及手工刷新／恢复。审查提出补足首次几何确认计数覆盖，已扩充同一测试并由审查者确认；最终无 Critical／Important／Minor 待办。

## 实图测量

使用源目录 `/Users/hans/Developer/tmp/origin` 对应既有 22／33 批次的四份当前不可变 PSD，各自复制到新临时目录并写入独立归属记录。未在原批次执行确认、重新保存或重新导出。开始时 App 空闲于 AI 抠图页，已有结果可用。

每面先建立角色缓存，再交替运行旧路径 refresh＋extract 和新路径单次 extract，共三轮。计时含 Photoshop 调用、PSD 与缓存哈希检查和缓存收据读取，不含最初复制 fixture。旧 opt-in 的 refresh＋extract 测量仍保留，新用例明确记录 `confirmationSingleExtractSeconds`。

每面三轮中位数（秒）；首次列是该面仅一次的冷缓存建立，不作为前后收益依据：

| 面 | 首次刷新＋提取 | 缓存 refresh＋extract | 确认单次 extract |
|---|---:|---:|---:|
| 22_F | 10.10 | 2.66 | 0.89 |
| 22_U | 9.26 | 2.64 | 0.85 |
| 33_F | 9.42 | 2.91 | 0.94 |
| 33_U | 8.78 | 2.57 | 0.85 |

四面每轮合计：旧路径 **10.91、10.78、10.65 秒**；新路径 **3.61、3.52、3.51 秒**。中位数 **10.78 → 3.52 秒**，减少 **7.26 秒（67.3%）**。

- 12/12 对照均为每面 **3 → 1 次 inspect**；缓存有效时角色 PNG 导出均为 **0**。生产执行器的对应服务调用由普通测试单独验证，实图专项测量的是确认前的受保护读取阶段。
- 每轮返回的角色路径、版本、负坐标起点、完整范围和裁切视口完全相同；三张缓存 PNG 的完整文件哈希逐轮一致，涵盖所有原始像素、透明 RGB 和色彩元数据。
- 另以 Pillow 对四面三角色共 **12 组**新提取图与批次原角色图比较：原始 RGBA、ICC／sRGB／gAMA／cHRM、方向、尺寸及坐标范围全部一致。
- **45 个**受保护文件哈希全部不变：12 张源 JPG、8 份原 PSD 快照、8 个已导出成品、原 batch.json 和 16 份既有 AI 结果／记录。
- **整批端到端耗时、完整几何确认或完整 4K 导出耗时、峰值内存未测。** 不将该读取阶段的节省比例外推到整批，也不改变既有检查点和最终输出参数。

## 复现与证据

证据目录：`/tmp/butterfly-perf-task3-20261107/`。包含 baseline／red-tests／green／real／final 的测试日志和 xcresult、结构化结果、逐面 `confirmation/*/timings.json`、角色 JSON／PNG、原始像素对照、保护哈希和 `measurement-summary.json`。临时证据可能被系统清理，本记录保存实测摘要。

普通验证沿用计划的 Release `xcodebuild test`；聚焦测试指定 `WorkflowExecutorTests`、`WorkflowBridgeTests`、`WorkflowIntegrationTests`。实图验证指定 `TEST_RUNNER_WORKFLOW_CONFIRMATION_BATCH` 为含角色快照的 batch.json，`TEST_RUNNER_WORKFLOW_CONFIRMATION_EVIDENCE` 为尚不存在的新目录，仅运行 `WorkflowBridgeTests/testRealConfirmationRoleReadWhenRequested`。

第 3 项之后按计划顺序执行第 5 项：删除生成后丢弃的裁切预览。本次不实施后续任务。
