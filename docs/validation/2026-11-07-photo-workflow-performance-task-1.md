# 照片工作流性能优化：任务 1

> 历史实测记录：结论、测试数量和未完成事项以文内日期及范围为限。当前行为与待办见 [照片工作流](../PHOTO-WORKFLOW.md)，分类见 [验证索引](README.md)；原始日志和临时路径不保证仍存在。

日期：2026-11-07。范围：[第一轮性能记录](README.md)任务 1；任务 2–8 未实施。

## 修改与边界

角色缓存仅在比较提取来源时忽略 `workingURL`，仍要求 taskID、contentVersion、snapshotURL、pixelSize、roles、structureSummary 全部一致。全局 `PSDSnapshot.Equatable`、收据格式及旧缓存兼容性不变。

`capture`、`verify`、`recoverInstall` 的保存、结构、归属、工作文件／不可变快照哈希检查保留；缓存命中仍核对三张 PNG 哈希；发布前后的蒙版等价检查保留。没有修改编码、AI、画质、Alpha、几何裁切、透明背景或恢复协议。

## 现场保护和测量方法

- Toolkit 基线 `bd5e631`（包含 `615fa09`）；AI 基线 `0d86a55`。AI 仓库及其未跟踪的 `scripts/export_psd_sample.py` 未修改。
- 验证收尾时工作区出现另一组版本管理修改（项目配置、About、README、Config 等）；没有覆盖或纳入本项提交。本项两个 Swift 文件的最终 diff 与独立审查包逐字相同；上述测试不作为另一组并行修改的验收。
- App 开始时停在已完成的 22／33 批次、33 正面、4K／天蓝预览，没有执行新处理。
- 用户测试目录 `/Users/hans/Developer/tmp/origin` 的 12 张 JPG 内容哈希全部与已有批次源记录一致。
- 采用该批次四面的已保存不可变 PSD；每次先复制到全新 `/tmp` 目录，再模拟同 owner、同内容的 staged → published 路径切换。所有 Photoshop 测试均只打开这些临时副本，不写原 PSD。
- Release，arm64，每面 3 次；每次使用新 workspace。分别计时首次 refresh＋extract、发布后 refresh＋extract，包含保存状态检查、文件哈希、角色提取及回读。提取次数由真实 ScriptRunner 调用计数。
- 使用相同测试二进制接口先测旧生产实现，再测新实现。旧实现的复用断言预期失败，仍写出全部测量数据；不把旧版失败称为通过。
- 对照使用 Pillow 原始 RGBA（包括 Alpha=0 的 RGB）和 ICC／sRGB／gAMA／cHRM／方向，同时核对尺寸、coordinateOrigin、editableExtent 和 cropViewport。未用 Swift 预乘像素替代原始 RGBA。
- 这不是重新运行景深合成、AI、几何与最终导出的全流程。整批端到端耗时和峰值内存未测；该阶段结果不能直接外推整批提速比例。

## 测量与验证结果

- Swift 基线全量：165 项，163 通过、2 项 opt-in 跳过、0 失败；构建＋测试墙钟 48.32 s。
- RED：bridge 聚焦 23 项，19 通过、2 失败、2 跳过；20.17 s。失败正是发布后角色文件不复用和恢复导出计数 `[1, 1]`，不是构建错误。
- GREEN：Swift 全量 168 项，165 通过、3 项 opt-in 跳过、0 失败；构建＋测试墙钟 39.20 s。两个新增普通回归及扩充恢复用例均通过。
- Python 基线：36 项通过，1.122 s；本项不修改 AI 代码。
- 初次 Swift 运行因受限环境无法启动宏插件而失败，紧接的重试遇到旧构建尚未结束的数据库锁；旧进程结束后在正常本机环境重跑基线通过。以上 48.32 s 指有效基线，未把环境失败当产品回归。

每面 3 次中位数（秒）：

| 面 | 首次：旧版 | 首次：新版 | 发布后：旧版 | 发布后：新版 | 发布后减少 |
|---|---:|---:|---:|---:|---:|
| 22_F | 9.67 | 9.88 | 9.49 | 2.85 | 6.64 |
| 22_U | 9.45 | 9.35 | 9.46 | 2.73 | 6.73 |
| 33_F | 10.15 | 9.65 | 9.65 | 3.08 | 6.57 |
| 33_U | 9.12 | 9.10 | 8.80 | 2.71 | 6.10 |

四面每轮合计：

| 测量范围 | 旧版三轮（秒） | 新版三轮（秒） | 中位数变化 |
|---|---|---|---|
| 发布后 refresh＋extract | 37.40, 37.37, 37.53 | 11.02, 11.39, 11.99 | 37.40 → 11.39，减少 26.01 s（69.5%） |
| 首次＋发布后 refresh＋extract | 76.34, 75.66, 75.95 | 48.78, 49.91, 49.48 | 75.95 → 49.48，减少 26.46 s（34.8%） |

- 每面 staged→published 导出次数：旧版全部为 **2**，新版全部为 **1**；12/12 新版样本通过。首次成本基本保留，收益来自去掉发布后的重复导出。
- 新版实图 XCTest：1 项通过、0 跳过、0 失败（内含 4 面 × 3 轮）；总运行墙钟 154.91 s。旧版 242.65 s 含预期断言失败的报告开销，不用这两个墙钟数值计算工作流收益。
- **108 组**原始 RGBA、ICC／sRGB／gAMA／cHRM／方向及坐标范围对照一致；包括旧版 staged→published 和旧版→新版角色图。
- **25 个**受保护文件哈希全部不变：12 张源 JPG、4 份原不可变 PSD、8 个已发布 JPG／PNG 和原 batch.json。原 App 页面亦未改变。
- 本项完成。后续按计划执行任务 2；不包含任务 2–8、不重跑 AI 全流程、不替换当前已运行 App、不推送远端。

## 独立 review

独立审查者 `review_task1` 已只读检查当前改动及关联调用，结论：通过；Critical／Important／Minor 均为 0，无搁置判断。本轮 GREEN、全量回归、实图对照随后全部通过，满足提交条件。

## 证据与复现

证据目录：`/tmp/butterfly-perf-task1-20261107/`。包含各轮 `before/`、`after/`、PNG 及角色 JSON、`timings.json`、Xcode `.xcresult`／日志、测试摘要、源文件保护哈希及对照脚本。临时目录不是永久存档；本文的实测摘要随本提交保留。

普通验证：

```sh
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/butterfly-workflow-perf-build ENABLE_TESTABILITY=YES test
```

实图用例默认跳过；启用时，使用新的空证据目录，指定 `TEST_RUNNER_WORKFLOW_ROLE_PUBLICATION_BATCH` 和 `TEST_RUNNER_WORKFLOW_ROLE_PUBLICATION_EVIDENCE`，仅运行 `Butterfly ToolkitTests/WorkflowBridgeTests/testRealPublishedCopyRoleReuseWhenRequested`。输入 batch 需含有效不可变快照；不要求原 workingURL 文件仍在。

计划技能的 `task-start` 脚本仅识别英文 Task 标题，不能解析本计划的中文“任务 1”；本轮直接提取对应原文作为任务清单，没有改变需求。遵循用户“review 后再提交”的要求，以未提交完整 diff 进行审查。
