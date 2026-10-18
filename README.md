# 聊析

聊析｜面向 LLM 的微信聊天记录整理工具，支持 macOS 与 Windows。将合并聊天记录导出为 Markdown，并将照片、视频和文档统一保存在同一文件夹中。

## 一键下载

- [macOS 通用版（DMG，Apple Silicon / Intel）](https://github.com/liyouran0820/liaoxi/releases/latest/download/ChatArchive-macOS-universal.dmg)
- [Windows x64 独立版（EXE，无需 Python）](https://github.com/liyouran0820/liaoxi/releases/latest/download/ChatArchive-Windows-x64.exe)
- [Windows ZIP 备用下载](https://github.com/liyouran0820/liaoxi/releases/latest/download/ChatArchive-Windows-x64.zip)
- [全部版本与校验文件](https://github.com/liyouran0820/liaoxi/releases)

macOS 打开 DMG，将“聊析”拖到 Applications。Windows 下载 EXE 后直接运行。系统 OCR 需已安装中文或英语语言功能。

## 使用

1. 在微信中多选消息，合并转发给文件传输助手。
2. 在电脑端微信（macOS 或 Windows）打开这条合并聊天记录，并保持窗口可见。
3. 打开对应系统的聊析：macOS 首次使用需授予“辅助功能”和“屏幕录制”权限；Windows 点击“刷新窗口”，选择对应的合并聊天记录窗口。
4. 选择导出位置。需要保留的本地照片、视频和文档可以通过“补充附件”多选加入。
5. 点击“开始提取”。程序逐屏读取，并尝试通过微信可见的“另存为”或“复制”菜单保存附件。

提取过程中可以随时点击“停止”；已保存的附件会保留在同名文件夹，Markdown 会标明提取未完成。

**macOS 权限：** 两个权限的“打开设置”会分别进入“隐私与安全性”中的对应页面。在列表中打开“聊析”开关后返回应用，状态会自动刷新。屏幕录制通常需要重新打开应用，请按系统提示操作。

建议使用安装在 `/Applications/聊析.app` 的固定版本。移动应用位置或更换签名会让 macOS 重新请求隐私权限。

**Windows 窗口选择：** 若没有找到记录，请先在微信打开合并记录卡片，再点“刷新窗口”。Windows 无需授予 macOS 的上述两项权限，但需安装中文或英语 OCR 语言功能；操作详情见 [Windows 说明](windows/README.md)。

输出目录包含：

```text
微信聊天记录-时间/
├── 微信聊天记录-时间.md
├── 照片.png
├── 视频.mp4
└── 教程.pdf
```

每次先创建与 Markdown 同名的总文件夹。附件从保存时就直接进入该文件夹，与 Markdown 平铺放置，不额外生成报告文件或附件子目录。Markdown 仅列出照片、视频、文档的类型、实际文件名及相对链接；媒体区域在文字 OCR 前排除，不将照片或视频内部文字转写为正文。复制的原文件进行 SHA-256 校验，缺失附件写入文末。

## Windows

Windows 10/11 x64，发布版独立 EXE 自带运行环境，无需安装 Python。源码启动包仍可通过 Python 3.12 x64 运行 `start.cmd`。详见 [Windows 使用与打包说明](windows/README.md)。

Windows 使用 UI Automation 与 Windows 本地 OCR；Mac 使用 Accessibility 与 Apple Vision。两版共用同样的输出规则与附件语义。原附件能否自动取得取决于微信版本提供的菜单；无法自动保存的附件需在微信另存后使用“补充附件”。

## 构建

### macOS

```bash
swift test
./scripts/build-app.sh
open "dist/聊析.app"
```

### Windows

在 Windows PowerShell 中运行：

```powershell
cd windows
./build.ps1
```

## 功能与边界

- 不读取微信数据库、登录信息、Token 或 Cookie。
- 不注入或 Hook 微信进程。
- macOS 使用 Accessibility 与 Apple Vision 本地 OCR；Windows 使用 UI Automation 与 Windows 本地 OCR。
- macOS 屏幕权限通过 ScreenCaptureKit 注册，用途仅限用户主动打开的微信记录窗口；Windows 从用户选择的记录窗口捕获内容。
- 自动保存仅操作已打开记录的可见附件菜单，不打开执行文档。微信隐藏菜单、过期或未下载的附件可能需要手动另存并补充。
- 优先另存原附件；图片复制路径保留微信放入剪贴板的图像像素，重新编码为 PNG，不保证与最初上传文件逐字节一致。
- 微信消息下方的灰色回复原文会输出为 Markdown `>` 引用块。
- 每个 Markdown 开头都会向 LLM 说明正文样式与引用样式，避免把被引用原消息理解为当前消息。
- Markdown 只为已经实际保存的文件生成链接，缺失附件会列明，不用截图冒充照片、视频或文档原文件。
- 自动滚动会把微信置于前台，并短暂移动鼠标指针。
- Mac 最多读取 120 屏，Windows 最多 100 屏；触及上限时在 Markdown 文末提示。

## 文档维护

本文件维护安装、操作与使用边界；Windows 的依赖和构建步骤维护在 `windows/README.md`，架构见 `PROJECT_INTRODUCTION.md`，验证记录按日期追加到 `log.md`。
