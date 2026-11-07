# Toolkit 本地版本管理实施计划

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 建立适合本地自用的统一版本、升级检查与稳定版本留档机制。

**Architecture:** Xcode 原生 xcconfig 为唯一来源，Python 标准库脚本只做显式升级和校验；Git 标签与 Markdown 记录由操作者确认。

**Tech Stack:** Xcode、Git、Python 3 标准库、macOS plutil。

**Spec:** `docs/superpowers/specs/2026-11-07-version-management-design.md`

## Global Constraints

- 初始版本 `1.0.0 (1)`，不自动标记发布，不改动照片工作流工作区文件。
- 无第三方依赖、无编译时递增、无网络或自动提交/标签副作用。
- 保留当前分支；测试 Git 操作在临时仓库中执行。

## Review Focus

- Xcode 配置覆盖单一来源：检查所有 buildSettings 和项目配置引用。
- 非法/重复配置：升级拒绝，原文件不变。
- 已有标签、倒退版本或 Build：留档检查拒绝错误状态。
- 未提交/未跟踪文件及浅克隆：留档检查拒绝不完整代码状态。
- 错误安装产物：校验 Bundle ID 和两种版本字段。

## Task 1: 配置、脚本与回归

- [x] 先编写并运行 `scripts/tests/test_version.py`，确认当前缺少管理入口。
- [x] 增加 `Config/Version.xcconfig`，接入项目 Debug/Release 并移除原重复值。
- [x] 实现 `scripts/version.py` 的 show、bump、check、--milestone、--app；在临时仓库中验证实际命令行为。
- [x] 关于页缺失版本时显示“未知”，避免误报 1.0/1；忽略 Python 缓存。

## Task 2: 使用说明与验证

- [x] 增加根目录 README、CHANGELOG 和 `docs/VERSIONING.md`，说明本地升级、稳定版本留档、回退与边界。
- [x] 运行脚本回归、Xcode Debug/Release 设置和构建，读回产物版本。此项不涉及业务逻辑，未运行现有业务测试全量。
- [x] 独立审查未发现重要问题；验证结果见 `docs/validation/2026-11-07-version-management.md`。本轮不自动提交或创建稳定标签。
