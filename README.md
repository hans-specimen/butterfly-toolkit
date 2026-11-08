# Butterfly Toolkit

本地自用的 macOS 原生 SwiftUI 应用，用于蝴蝶照片整理、景深合成、AI 抠图、人工检查与成品导出。本文按当前源码核对于 2026-11-09；实际安装的应用可能尚未包含当前工作目录中的修改。

## 当前功能

| 功能 | 当前范围 |
| --- | --- |
| 照片工作流 | 六张照片组成一只标本的正反面，依次完成景深合成、AI 抠图回写、几何构图、高清 JPEG、透明 PNG4K；支持四个检查点、暂停、失败重试、人工 PSD 编辑及清单恢复 |
| AI 抠图 | 导入 PNG／JPEG 待抠图片，逐张推理，对比原图、人工参考和透明度，安全另存结果 |
| 训练素材 | 导入成对 PNG，人工确认对齐与标本分组，按整组设置训练／验证／测试用途 |
| 模型训练与版本页 | 提供训练准备、素材选择和基础模型信息；真实训练任务创建、模型比较和选用按钮尚未接入 |
| 图片工具 | 批量重命名、图片压缩、批量旋转、智能裁剪、景深合成 PSD、闲鱼产品图、PSD 批量导出、透明 PNG 裁切 |

照片工作流当前止于 PNG4K；闲鱼产品图和透明裁切仍可从独立工具入口使用。代码中保留部分旧派生阶段和清单兼容逻辑，不代表当前界面仍有第六个阶段。

## 运行

1. 使用兼容当前工程设置的 Xcode，打开 `Butterfly Toolkit.xcodeproj`，选择 `Butterfly Toolkit` scheme 和本机 Mac。当前部署目标为 **macOS 26.5**。
2. 普通图片工具可直接运行。景深合成和照片工作流还需要本机 Adobe Photoshop；首次自动控制时按 macOS 提示授予相应权限。
3. AI 功能需选择独立 Python 引擎目录，其中应有 `.venv/bin/python`、`scripts/toolkit_bridge.py` 和可用模型。应用不负责安装依赖或下载模型；工作流还要求引擎支持 `--workspace` 和常驻 `serve` 协议。详见 [AI 工作区](docs/AI-WORKSPACE.md)。

首次测试请使用照片副本。重命名、覆盖旋转／裁剪、压缩输出清理和透明裁切目录同步会按各工具选项改变文件或目录；不要将重要原片目录作为无关实验输出。

命令行构建（输出到临时目录）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project 'Butterfly Toolkit.xcodeproj' -scheme 'Butterfly Toolkit' \
  -destination 'platform=macOS' -derivedDataPath /tmp/toolkit-docs-build \
  CODE_SIGNING_ALLOWED=NO build
```

以上用于编译验证，不会安装或替换 `/Applications` 中的应用。测试及真实 Photoshop／AI 验证入口见 [测试指南](docs/TESTING.md)。

## 源码目录

```text
Butterfly Toolkit/
├── App/                     应用入口、主窗口导航、关于页
├── Features/                按功能归类的界面与专属处理代码
│   ├── AI/                  AI 工作区、抠图、训练与模型管理
│   ├── PhotoWorkflow/       照片工作流、几何分析、缓存与输出
│   ├── Compress/            图片压缩
│   ├── Rotate/              批量旋转
│   ├── Rename/              批量重命名
│   ├── SmartCrop/           智能裁剪
│   ├── FocusStack/          景深合成界面
│   ├── PSDExport/           PSD 批量导出
│   ├── TransparentPNGTrim/  透明 PNG 裁切界面
│   └── XianyuProduct/       闲鱼产品图界面
├── Core/                    多个功能共用的处理能力
│   ├── ImageProcessing/     压缩、旋转、透明裁切、产品图合成
│   └── Photoshop/           景深合成执行与 Photoshop 任务协调
├── Assets.xcassets/         图标与颜色
└── Resources/               提示音与水印
```

新增代码优先放在所属的 `Features/<功能>` 中；只有被多个功能使用的处理能力才放进 `Core`。测试保留在 `Butterfly ToolkitTests`。

工程使用 Xcode 文件夹自动同步，磁盘目录就是工程导航中的目录；在源码根目录内移动 Swift 文件无需逐项修改 `project.pbxproj`。

## 版本管理

版本只维护在 `Config/Version.xcconfig`，Xcode 的 Debug、Release 和“关于”页共同使用。

```sh
python3 scripts/version.py show
python3 scripts/version.py bump patch
python3 scripts/version.py check
```

`bump patch` 用于修复更新；新增功能用 `minor`，不兼容变更用 `major`，同一版本的新本地构建用 `build`。每种升级都会让 Build 加一，普通编译不会改变版本。

详细操作见 [本地版本管理](docs/VERSIONING.md)，更新记录见 [CHANGELOG](CHANGELOG.md)。

## 文档与验证边界

- [文档索引](docs/README.md)：现行说明与历史证据的入口。
- [技术架构](docs/ARCHITECTURE.md)：模块职责、并发、图像坐标与数据存放位置。
- [照片工作流](docs/PHOTO-WORKFLOW.md)：操作流程、恢复规则、默认配置与待完成验证。
- [AI 工作区](docs/AI-WORKSPACE.md)：导入、推理、训练准备和引擎协议。
- [测试指南](docs/TESTING.md)、[历史验证记录](docs/validation/README.md)。
- [项目协作规范](AGENTS.md)：后续代码、文档和清理工作的约束。

真实 Photoshop／AI 局部链路和性能比较已有历史证据，但从新 JPG 开始的完整批次仍有已记录失败；候选优化未获默认启用放行。常规自动测试通过不代表整批稳定性、最终蒙版质量或屏幕交互性能已经验收。
