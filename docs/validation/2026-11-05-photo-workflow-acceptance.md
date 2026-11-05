# 照片工作流验收记录与恢复说明

日期：2026-11-05。范围：`codex/photo-workflow` 的收藏照片六步流程；保留旧工具与销售入口。第 1～6 步代码已实现，第 7 步补集成回归和交付记录。**工程实现与自动化通过，不等于真实六图全流程、用户蒙版质量或性能验收通过。**

用户最新指示为“ps暂时没有可用订阅。。可以跳过ps测试”。本轮跳过所有实际 Photoshop 调用、界面操作和新的合成／AI／PSD 往返；这些项目记为本轮豁免、质量结论仍待验证，不记为通过。没有修改账号或订阅。

## 1. 当前结论与证据范围

| 层次 | 本轮结论 | 证据／限制 |
|---|---|---|
| 执行器集成 | 修正后 7 项用例全部通过；归属冲突测试能检出隔离错误变异 | 公开命令注册、处理、继续、双面确认、重试、排除、刷新与恢复；未直接写“完成”字段。PS／AI 为注入服务，不能替代真实 PSD 验收 |
| 全量回归 | 合并前对修正后的代码重新全量运行：`TEST SUCCEEDED`，148 通过／1 跳过／0 失败 | 保留已有 AI、旧工具、状态／桥接／几何／渲染／预览测试；唯一全量命令见第 5 节 |
| 真实文件分组 | 12 张真实 JPG 的复制品已核对自然排序、名称与 F/U 三张映射，源文件前后 SHA256 一致 | 第一组 `test/DSC00001.JPG…DSC00006.JPG`；第二组 `260709_黛安娜闪蝶/DSC00048.JPG…DSC00053.JPG`。名称仅为记录标签，未经用户确认物种／样本真值；不是两只实拍全流程验收 |
| 真实 SwiftUI | 已有实际页面观察，覆盖可行的构图、独立 4K 与生命周期操作 | 根代理实测，见下节。加载的是已保存角色的种子批次，不能冒充新流水线 |
| 真实 Photoshop 往返 | **本轮按用户指示跳过／豁免** | 之前已留桥接小样记录；本轮无新的编辑、保存、刷新、应用构图或导出证据 |
| AI／蒙版质量 | **未通过最终用户实图验收** | 正面浅色翅缘有保留证据；反面存在微弱残留与不确定碎片，仍需检查。没有以人工修正冒充自动一次成功 |
| 实际输出像素 | 本轮已从既有保存角色离线重新导出并记录尺寸／边界／哈希 | 使用之前保存的角色 PNG，不启动 PS／AI，不声称新鲜端到端流程；未应用正面建议角度，反面不确定性保留 |
| 真实交互性能 | **未测得 warm p95** | 机器上原生拖动有观察，无计时序列；CUA 在尝试启用可选指标时拒绝 Terminal 访问。没有绕过限制，不宣称 p95≤100 ms |
| 20 只／40 面比较集 | **未完成，保留质量门槛** | 尚无可追溯的每面人工角度／截断／调整原因真值；不能填写自动成功率或形态校准结论 |
| 提交／安装／推送／合并 | 由根代理在独立审查后按授权另行处理 | 本第 7 步执行者未提交、暂存、安装、推送或合并 |

所有 `/tmp` 路径均为本机临时证据，当前保留，不保证跨机器或长期存在。此报告保留结论和限制；交付时如需长期归档，应另存这些图片、清单、日志和 xcresult，不能只保留路径。

## 2. 实际原生界面观察（根代理记录）

- 真实 SwiftUI 中可见六阶段、输入／批次／引擎入口，正反面角色图可载入。
- 正面自适应建议为 −0.794272°、4002×3283，约四边 10%；5:4 为 4105×3284；5%／1°时为 3745×2996；11:8.5 同参数为 3894×3009（22:17）。正面 1:1 因有效背景不足显示非对称留白与警告。
- 反面有不确定蒙版碎片时保留 5168×3448 当前视口、显示无效区域并禁止双面确认；这不是已经接受的裁切或蒙版质量。
- 两点扶正计数、位置拖动、查看倍率 100%→150%、恢复居中均有真实观察。倍率变更不改输出尺寸；未录制足够的逐帧时序，不能作为性能证明。
- 独立 4K 页显示透明抠图与默认 256 px 安全框；正面改 384，切反面仍为 256，再切正面恢复 384；黑／棋盘预览可切换。高清构图未确认时，4K 导出按钮保持禁用。
- 重选引擎目录后持久暂停并要求明确继续；关闭批次返回设置页，无自动重新处理。

截图：`/tmp/butterfly-task6-real/ui-evidence/01-reverse-full-detail.png`；`/tmp/butterfly-task6-resume/ui-evidence/02-4k-default.png`、`03-4k-384-black.png`。完整观察记录见本机 scratch `task-6-native-partial-report.md`。

保存现场：旧批次 `0FBD5B15-8BB5-421C-AB70-F74A9FDF7F23` 在 `/tmp/butterfly-task6-real`，revision 9、暂停、用户明确排除；**保留原状，不恢复它来跑批**。新种子批次 `18232CFF-866A-43AD-8F7F-A0D54C255EAE` 在 `/tmp/butterfly-task6-resume`，revision 2、暂停；工作 PSD 仍与不可变种子哈希相同。`/tmp/butterfly-task6-resume/ui-evidence/final-source-integrity.json` 记录六张原始 JPG 指纹一致；这些种子批次均不代表新合成。

## 3. 自动化覆盖和输出约定

`WorkflowIntegrationTests.swift` 新增以下联动检查；除实际渲染／发布用例外，文件编码与 PS／AI 操作由测试服务替代：

1. 两只／四面遍历两个检查开关的四种组合；开启时等整批阶段到齐，不能部分继续；第 3、5 步拒绝只确认一面，选中一只不会批准另一只。
2. 一面合成失败阻断自动跨步；重新打开清单后只重试失败面，不重做三个成功面。
3. 明确排除整只后成功项可继续，原名称不顺移；两面均显示排除，不能宣称整批全部成功。
4. 模拟 PS 未保存时，保存刷新与继续均拒绝；即使刷新成功仍保持暂停，必须明确继续才释放手工编辑控制。此为注入错误测试，不是真实 PS 操作。
5. 4K 待确认处重新加载清单，不重复早期工作；只变更 4K 预设，仅重做 4K 与派生，AI、几何应用、高清记录及文件指纹不变。
6. 实际产物存储器拒绝没有归属凭据的有效同名 JPEG，待发布候选也使用真实 JPEG 渲染；要求准确归属冲突错误、不创建归属收据、原字节保留且不认领，另一面仍可成功。
7. 实际渲染器与实际发布器串入执行器，双面确认后得到 4096 透明 PNG（最窄 256）、1000 纯白 PNG（重新构图最窄 10）；派生来源指纹绑定本次 4K。紧裁素材逐行字节等于同一 4K 裁出区域，无额外缩放；没有水印只让闲鱼失败，1K／素材仍发布且可凭收据恢复。

固定参数保持：六 JPG、自然名顺序、每名一行、F/U 各三图；高清自适应／5:4／22:17／1:1，默认最窄相对留白 10%，高清不额外缩放；使用当前保存 PSD 的蒙版，不重跑 Vision，不覆盖人工蒙版，不补背景或裁主体；4K 4096 透明／256；1K 1000 纯白／10；闲鱼 2000、RGB 238、15% 黑阴影、24 px 偏移、49 px 模糊及既有水印样式；紧裁 PNG 直接来自已确认 4K。源图只读，仅更新任务自己拥有的输出，所有阶段遵守源版本／预设／当前文件指纹一致性。

## 4. 真实角色离线导出与尚缺的质量验收

既有证据在 `/tmp/butterfly-task4-real` 与 `/tmp/butterfly-task4-hd-refusal`：高清 F/U 为底图 5168×3448；真实几何视口可导出 3000×2300；恢复到含透明空角的完整视口时必须拒绝高清输出，早期诊断文件 `geometry-restored-hd-INVALID-FLATTENED.jpg` 已标为无效，不能作为成功样例。

真实角色的正面 4K 最窄 256；1K 最窄 10；反面不确定碎片影响主体支持范围而保留，不能根据“方图生成了”判 AI 质量合格。参考图仅用于构图规范，未修改或冒充自动扶正样本。本轮离线验证成功，证据在 `/tmp/butterfly-task7-real/grouping-evidence.json`、`render-evidence.json`，复现脚本／编译日志／执行日志在同目录。分组调用从当前 `PhotoWorkflowStore.swift` 原样抽取的 `WorkflowBatchDraft` 定义（在 `@MainActor PhotoWorkflowStore` 前截取，未重写分组算法），对 12 张真实文件的复制品扫描并冻结；源图前后 SHA256 相同，冻结后新增的试验文件未进入现有映射。此证据只证明排序／冻结，不证明两个样本的拍摄面或物种标签正确。

| 本轮重新导出 | 实测 |
|---|---|
| F／U 高清 | 5168×3448；读取底图，未应用正面建议角度 |
| F 透明 4K | 4096×4096；raw alpha>0 边界 `[256,561,3840,3534)`；角落 RGBA 0／0／0／0 |
| F 白底 1K | 1000×1000；角落 RGB 255；RGB<254 估计边界 `[11,94,989,906)`。实际构图预设为 10 px，极淡边缘与阈值带来 1 px 估计差异；合成夹具验证每边误差≤1 px |
| F 紧裁素材 | 3584×2973，透明；来自同一 F 4K，无额外缩放 |
| F 闲鱼 | 2000×2000；角落 RGB 238，使用现有项目水印和既有样式 |
| U 透明 4K | 4096×4096；raw alpha>0 边界 `[256,909,3840,3187)`；有明显背景残留，质量未认可 |
| 空背景高清 | 恢复视口中有空角时正确拒绝，未创建 `invalid-restored-hd.jpg` |

F／U 输入角色 PNG 前后哈希一致；目检了本次 `F-white1k.png` 和 `U-4k.png`，前者完整、白底，后者仍有背景残留。**没有清洗反面蒙版或修改源角色来做出“成功样例”。** 这些 PNG 角色来自先前保存结果，未在本轮通过 PS 重新验证当前 PSD 与角色提取的一致性。

仍需在 PS 可用且用户愿意继续时验证：真实两只／12 张从合成到派生的全链路、当前 PSD 保存与角色对齐、人工精修后的保存读回／显式继续、确认几何的 PSD 写入与预览一致、真实交互 warm p95、至少 20 只／40 面的扶正／裁切比较集。建议每面记录原输入、自动角度、人工确认角度、截断与否、调整次数／原因、批次耗时，另记自动初稿与人工修正结果。当前没有这些实测数据，留空而不推算。

## 5. 验证命令和结果

全部在隔离 worktree 使用完整 Xcode，日志在 `/tmp`。集成测试是在已经实现的代码上补回归；没有新增生产修复，**没有声称先观察到缺失行为的 TDD RED**。首轮遇到测试辅助参数 CGFloat／Int 编译错误并修正，此为测试编译错误，不是产品行为 RED。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowIntegrationTests' CODE_SIGNING_ALLOWED=NO > /tmp/butterfly-task7-focused.log 2>&1
```

首轮可运行结果：`TEST SUCCEEDED`，7 通过／0 失败；之后仅收窄同名文件夹具，单独验证 `testForeignSameNamedHDIsNeverOverwrittenOrAdopted`：`TEST SUCCEEDED`，1 通过／0 失败，日志 `/tmp/butterfly-task7-foreign.log`。真实像素联动用例约 119.763 秒，非 UI p95。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build CODE_SIGNING_ALLOWED=NO > /tmp/butterfly-task7-full.log 2>&1
```

修正前的最终全量在当时代码冻结后仅运行一次：退出码 0，`TEST SUCCEEDED`；149 项总计、148 通过、0 失败、1 跳过，`runtimeWarnings=[]`、`testFailures=[]`。唯一跳过项为 `MaskGeometryProcessorTests.testRealSavedMaskEvidenceWhenRequested`，因未设置 opt-in 环境变量 `TASK3_EVIDENCE_DIR`（`Real-image evidence is opt-in`），不是新增失败或删掉的测试。原有 AI 与旧工具回归保留。

结果包：`/tmp/butterfly-workflow-build/Logs/Test/Test-Butterfly Toolkit-2026.11.05_22-51-39-+0800.xcresult`；结构化摘要：`/tmp/butterfly-task7-full-summary.json`。运行设备为 Mac Studio、arm64、macOS 27.0.1；macOS 26.5 仅为 deployment target，不代表机器版本。修正前 7 项新集成用例在该次全量中全部通过，实际像素用例 122.310 秒同样不代表 UI p95。

### 独立审查后测试补强（fix1）

审查发现原同名文件测试仍可能因候选内容是文本而失败，掩盖归属检查回退；此外，即便使用有效 JPEG，也可能仅因最后移动同名文件失败而误通过。本轮仅修正该测试：外来图及候选都使用真实渲染器生成的有效 JPEG；保留前面失败／反面成功／外来字节不变，并要求阶段错误恰为 `ownershipConflict`、不创建归属收据。未改产品代码或共享测试辅助代码。

修正后覆盖命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' -destination 'platform=macOS' -derivedDataPath /tmp/butterfly-workflow-build -only-testing:'Butterfly ToolkitTests/WorkflowIntegrationTests/testForeignSameNamedHDIsNeverOverwrittenOrAdopted' CODE_SIGNING_ALLOWED=NO > /tmp/butterfly-task7-fix1-green.log 2>&1
```

结果 `TEST SUCCEEDED`，1 通过／0 失败／0 跳过；`/tmp/butterfly-task7-fix1-green-summary.json` 无运行时警告。之后只在 `/tmp/butterfly-task7-fix1-mutation` 的完整项目副本里，将“存在文件但无匹配归属收据时抛冲突”故意改成返回 nil；同一条测试 `TEST FAILED`，1 失败，因阶段错误成为移动文件重名而非归属冲突。证据 `/tmp/butterfly-task7-fix1-mutation-summary.json`；原工作区产品文件 SHA256 前后不变，隔离副本未提交。

本轮是测试补强，没有生产修复；没有把变异检查称为产品缺陷的 TDD RED。**上面的 149 项全量结果发生在此次单项测试修正前；修正后仅运行上述覆盖测试，没有重新运行全量。**

### 合并前最终验证（2026-11-05）

用户已追加授权合并 main、提交并推送 GitHub。对测试补强后的最终代码重新执行第 5 节完整测试命令，日志改为 `/tmp/butterfly-main-merge-tests.log`：退出码 0、`TEST SUCCEEDED`，148 通过／1 原有 opt-in 跳过／0 失败，7 项集成测试均通过。结果包为 `/tmp/butterfly-workflow-build/Logs/Test/Test-Butterfly Toolkit-2026.11.05_23-25-04-+0800.xcresult`。本次结果更新上文历史记录中的“补强后未再次全量”状态。

已复核同名 JPEG 测试与实际发布器：候选和已有文件都是有效 JPEG，并断言明确的归属冲突、原字节保留以及无归属收据，原审查缺口已补齐。最终差异格式检查通过。产品代码未在本次收尾中修改；Photoshop、蒙版质量、性能和比较集的未验证范围保持不变。

## 6. 操作和恢复说明

- **首次建批次**：选 JPG 输入与新的空输出目录；逐组核对六图缩略图、F/U 三图映射和名称。试拍、补拍在开始前明确调整／排除。开始后新增源文件不会自动加入已冻结批次；源 JPG 不改名、不覆盖。
- **整批检查／双面确认**：第 1、2 步开关仅控制检查，不跳过处理；失败须重试或明确排除整只。第 3、5 步始终确认所选整只两面，不会默许未选项。
- **异常、靠边或不确定蒙版**：停留检查页，查看完整主体与警告，必要时人工调整。不能靠缩小高清主体、补背景、切掉触角／尾突来凑比例；修改前保留可恢复工作版本。
- **人工 PSD 编辑**：PS 可用时才使用“打开 PSD”；等待自动操作结束并暂停。编辑后在 PS 保存，返回刷新保存结果；未保存、保存中、角色被改或版本落后时不要强行确认。刷新后仍须明确继续。当前无订阅，本轮不执行这一段。
- **只改蒙版／姿态**：蒙版变更需重查完整范围并刷新 4K／派生；姿态或画布变更返回第 3 步确认。不要把旧 AI alpha 或已裁高清 JPG 当作当前可编辑母图，不自动再跑 AI。
- **只改 4K**：使用独立 4K 安全框和位置；不重做 AI、高清裁切或已验证高清。派生必须绑定本次确认保存的 4K，不读同名旧文件。1K 会重新适配 10 px，而不是将整张 4K 简单缩小。
- **缺水印／部分失败**：补充可读水印后仅重试闲鱼资产；已有成功 1K／素材不需重做前面阶段。保留失败和排除摘要，不能把“部分完成”改成“全部成功”。
- **同名冲突**：外来同名图不能直接覆盖或当作成功。先把外来文件另存并由操作者明确处理冲突，再重试；不要手动删除归属收据、修改 batch.json 的完成字段或清空 `.workflow-history`。
- **暂停、退出、重启**：等待当前不可中断操作结束；重新打开该批次 `batch.json`，按清单恢复未完成／失效项。保留 `.work`、PSD 保存版本、归属收据和历史产物；文件存在不表示有效。手工编辑控制未释放时核对保存／刷新后再明确继续，不能自动抢回 PS。
- **保护当前测试现场**：不要继续旧的用户排除批次；新的种子批次也保持暂停。需要新的全流程验收时另建输出目录，不复用现场去覆盖已有工作 PSD。
