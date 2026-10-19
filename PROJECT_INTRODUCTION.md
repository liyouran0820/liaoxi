# 项目简介

## 当前版本基线

2026-10-20 按用户要求恢复 GitHub 发布标签 `v0.2.0`（`31a0f77`）的程序源码、测试与 Windows 依赖。后续实验保存在 `codex/before-release-rollback-20261020`，不进入当前应用。保留历史日志、发布说明与发布工作流用于追溯；回滚与签名 / 启动检查不等同于已重新验收微信识别。

## 产品目标

聊析服务于“手动合并转发、自动结构化整理”的工作流。用户主动在微信内筛选内容，应用读取已打开的合并记录，每次导出一个文件夹，里面平铺放置 `conversation.md` 及实际保存的照片、视频、文档，便于整体移动和交给 LLM。

## 技术路径

- `WindowCaptureService`：用 ScreenCaptureKit 定位和捕获微信可见窗口，驱动滚动。
- `AccessibilityTextService`：读取微信窗口暴露的辅助功能文本。
- `OCRService`：以 Apple Vision 在本机识别中英文。
- `ContentProcessor`：跨屏去重、文字源选择、灰色回复引用识别、图片候选裁切和文件名识别。
- `AttachmentCollector`：逐屏定位候选附件，通过微信可见的另存或复制菜单收集附件。
- `ArchiveFiles`：跨平台文件名兼容、同名编号、SHA-256 校验和相对链接。
- `MarkdownExporter`：暂存、校验并原子提交单个导出文件夹；提示与统计内嵌 Markdown，不另写 JSON。
- `windows/archive_core.py`：Windows 的导出格式、内容去重、引用标注与附件复制，纯标准库，支持在 Mac 运行导出测试。
- `windows/windows_capture.py`：Windows UI Automation、WinRT OCR、窗口捕获、滚动与附件另存。
- `windows/app.py`：Windows Tk 桌面界面，提取与停止在后台线程执行。

## 验证边界

Mac 可在本机构建、签名、安装并验证。Windows 的导出核心可跨平台测试，原生 UIA / WinRT 与微信实机流程必须在 Windows 验证。`windows/build.ps1` 会先执行含 Windows OCR 的测试，再打包 EXE；仓库中的 Windows CI 仅在关联远端并运行后才产生已构建产物。

## 文档职责

- `PROJECT_INTRODUCTION.md`：维护稳定的产品范围、架构和关键技术决策。
- `README.md`：维护面向使用者与开发者的安装、使用和构建说明。
- `log.md`：按日期追加已完成事项、验证结果和已知问题，不在这里重复产品介绍。
- `windows/README.md`：Windows 安装、启动、EXE 构建与系统限制，不重复 Mac 授权步骤。

## 安全边界

应用不接触微信数据库和私有协议，不读取凭据，不修改微信文件，不上传提取内容。授权范围仅为用户明确触发的辅助功能与窗口捕获。
