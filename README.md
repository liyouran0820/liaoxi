# 聊析

面向 LLM 的微信聊天记录整理工具，支持 macOS 与 Windows。当前默认流程为**手动复制粘贴文字，再整理本地附件**，不使用 OCR，不读取微信窗口，不需要辅助功能或屏幕录制权限。

## 使用

1. 在微信复制需要的文字，在聊析“聊天内容”中粘贴（Mac ⌘V / Windows Ctrl+V，或点击“粘贴”）。
2. 自行从微信保存照片、视频和文档。在编辑区把光标放到对应的对话之间，点击“补充附件”多选加入。
3. 编辑区会出现 `[[照片 1：photo.jpg]]` 等标记。可整体剪切 / 粘贴标记到所需位置，不要改标记内部字符。导出时替换为实际文件名和相对链接。
4. 选择导出位置，点击“导出 Markdown”。每次新建同名文件夹，不覆盖旧记录。

```text
微信聊天记录-时间/
├── 微信聊天记录-时间.md
├── photo.jpg
├── video.mp4
└── 教程.pdf
```

正文按手动顺序输出，例如“A 的消息 → 照片链接 → B 的消息”。照片、视频不识别文字；附件与 Markdown 平铺于同一文件夹，可整体提供给支持相应格式的 LLM。

粘贴保留原文字、换行、Markdown 和重复消息，不猜测发言者、不自动去重。纯文本会丢失微信颜色：引用请自行在行首加 `> `。文档开头会向 LLM 说明正文、引用和附件样式。

附件按 SHA-256 内容去重，同一内容只保存一份，不同消息位置仍可重复引用。同名不同内容自动编号，复制后校验；源文件不删除。失败项标为“附件未保存”，不生成假链接。删除标记不会移除附件，文末仍标注“未插入正文”；“清空附件”清除本次附件和标记，不删除原文件。

编辑草稿仅在当前窗口内存中，关闭前请导出。开始导出后先保存文字快照；停止 / 失败时尽可能保留已写入的文字及附件。大文件复制时，停止可能要等当前文件操作完成。

## 下载与版本边界

- [已发布版本](https://github.com/liyouran0820/liaoxi/releases)
- [macOS 历史 v0.2.0 DMG](https://github.com/liyouran0820/liaoxi/releases/download/v0.2.0/ChatArchive-macOS-universal.dmg)
- [Windows 历史 v0.2.0 EXE](https://github.com/liyouran0820/liaoxi/releases/download/v0.2.0/ChatArchive-Windows-x64.exe)

上述 v0.2.0 仍为旧自动提取流程，不含本次手动粘贴修改。新版需重新构建并发布；本地构建 / 安装不等同于公开下载已更新。

## 构建与检查

macOS（默认 Apple Silicon）：

```bash
swift test
./scripts/build-app.sh
open "dist/聊析.app"
```

Windows 10/11 x64：安装含 Tcl/Tk 的 Python 3.12，双击 `windows/start.cmd` 从源码启动；在 Windows PowerShell 执行 `windows/build.ps1` 生成独立 EXE / ZIP。手动版无需 OCR 语言包或 UIA 依赖，详见 [Windows 说明](windows/README.md)。

跨平台导出检查：

```bash
python3 -m unittest discover -s windows/tests -v
python3 windows/app.py --self-test
```

## 安全与维护

- 仅在用户点击“粘贴”或系统粘贴时获取文字，不监听剪贴板。
- 只复制用户选择的本地文件，不执行附件，不上传内容。
- 不读取微信数据库、登录信息、Token 或 Cookie，不注入 / Hook 微信。
- 历史自动捕获源码保留供追溯，当前主界面不调用窗口 / OCR 流程。

本文件维护使用、构建和边界；架构见 `PROJECT_INTRODUCTION.md`，Windows 操作见 `windows/README.md`，验证按日期追加到 `log.md`。历史发布文档不视为当前使用说明。
