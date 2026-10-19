# 项目简介

## 产品目标

聊析将用户手动从微信复制的文字与自行保存的照片、视频和文档，整理为可提供给 LLM 的单个文件夹：Markdown 与附件平铺于同名目录。默认不截图、不使用 OCR、不定位或操作微信。

## 当前架构

- `MainView` / `ManualTextEditor`：Mac 纯文本编辑器与 UTF-16 光标绑定，关闭智能标点替换。
- `AppModel.start()`：无权限门槛的手动导出；文件操作在子任务执行。
- `ManualDraft`：Unicode 安全文字插入；添加附件不覆盖选中文字。
- `ManualAttachment`：文件与可移动标记，输出时替换为实际链接。
- `ManualMarkdownExporter`：原文保留、附件去重 / 校验、同名处理、相对链接及样式说明；先写文字快照，再复制附件。
- `ArchiveFiles` / `ArchiveWorkspace`：共用命名、摘要和同名目录规则。
- `windows/app.py`：Tk 手动编辑界面，后台线程导出，不导入历史捕获模块。
- `windows/manual_archive.py`：标准库导出实现，可跨平台测试。

历史 `ExtractionPipeline`、窗口 / OCR / 自动附件采集及测试保留供追溯，不属于当前默认链路。Mac 旧入口命名为 `startAutomaticExtraction()`，主界面不调用。Windows 历史依赖独立保留在 `requirements-legacy.txt`。

## 验证与分发边界

Mac 可以本机构建、签名、安装和验证；Windows 导出核心及自检可跨平台执行，Tk 界面和实际 EXE 需 Windows 实机 / CI 验证。`windows/build.ps1` 运行便携测试、打包，再启动实际 EXE 做手动文字 / 附件导出自检。旧原生测试仅在显式设置 `CHATARCHIVE_TEST_LEGACY_CAPTURE=1` 并安装历史依赖后执行。

公开 v0.2.0 仍是旧自动提取版；当前源代码修改不代表旧下载包已更新。实际验证和发布证据写入日志。

## 安全边界

本地处理，不读微信数据库或凭据，不上传内容。仅使用主动粘贴的文字和选定文件；不监听剪贴板。纯文本不能恢复灰色引用颜色，引用由用户以 `> ` 标记，附件位置由用户决定，不猜测缺失信息。

## 文档职责

- `PROJECT_INTRODUCTION.md`：稳定目标、架构与技术边界。
- `README.md`：使用、构建和版本状态。
- `windows/README.md`：Windows 启动、打包及平台限制。
- `log.md`：按日期追加实际结果，保留历史。
- `docs/releases/`：历史版本发布说明。
