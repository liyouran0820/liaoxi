# 聊析 Windows 版 0.2.1

本文件负责 Windows 的安装、操作、构建与验证边界。总体产品范围见上级 `README.md`，每次发布更新本文件中的操作变更，并在上级 `log.md` 记录实际验证结果。

## 启动

1. 使用 Windows 10 1903 或更新版本 / Windows 11，x64 架构。
2. [下载独立 EXE](https://github.com/liyouran0820/liaoxi/releases/latest/download/ChatArchive-Windows-x64.exe)，直接运行，无需 Python。
3. 如下载的是源码包，则安装 [Python 3.12 x64](https://www.python.org/downloads/windows/)，保留 Tcl/Tk 和 Python Launcher；解压后双击 `start.cmd`，首次联网安装依赖。
4. 在微信打开“合并聊天记录”卡片，回到聊析点击“刷新窗口”，选择对应记录。
5. 选择导出位置；如有已从微信另存的照片、视频、文档，点击“补充附件”多选加入。
6. 点击“开始提取”。保持微信记录窗口可见，避免提取时移动窗口或操作微信。点击“停止”可以取消。
7. 完成后点“查看结果”。新生成的文件夹中只有 Markdown 及保存的附件。

发布版 EXE 自带 Python 运行环境。源码启动包与独立 EXE 都使用同一套程序。

## 已实现

- 从微信 / Weixin 进程中列出明确带“聊天记录”标题的窗口；不把普通主聊天窗口误当成目标。
- UI Automation 原文与 Windows 本地 OCR，自动滚动和跨屏去重，灰色回复引用输出为 Markdown 引用块。
- 在 Markdown 开头说明正文、引用、附件和缺失项的含义。
- 定位照片、视频、文档卡片，尝试微信可见的“另存为”；未提供另存时尝试“复制”所给的文件或图像。
- 手动补充任意实际附件，多选照片、视频和文档；原文件复制后做 SHA-256 校验。
- 输出平铺单文件夹，支持中文 / 空格 / 括号相对链接、同名自动编号与导入附件内容去重。
- 开始提取即创建与 Markdown 同名的文件夹，附件直接另存至其中；停止时保留已下载的文件，并标注记录未完成。
- 图片 / 视频区域在聊天文字 OCR 前遮罩排除，Markdown 只写附件类型、真实文件名和相对链接。

## 下载限制

微信各版本的自绘菜单与存储弹窗不同，自动另存尚需 Windows 微信实机验证。过期、被清理、未下载或菜单不可访问的文件不能凭 OCR 恢复；这类附件请先在微信下载并另存，再用“补充附件”。复制得到的图像会保存为 PNG，保证保留剪贴板像素，不保证与上传原文件的编码一致。

自动操作只使用已打开记录中的菜单与存储对话框，不读微信数据库，不执行文档，不上传聊天内容。最多扫描 100 屏，达到上限会写入文末提示。

## 构建独立 EXE

在 Windows PowerShell 中运行：

```powershell
./build.ps1
```

构建前先安装依赖并运行测试，包括一次本地 OCR 与 UIA 初始化测试。成功后得到：

```text
dist/ChatArchive-Windows-x64.exe
dist/ChatArchive-Windows-x64.zip
```

EXE 为单文件，可直接分发。打包脚本还会启动实际 EXE，用生成的测试图片检查内置 OCR 与 UIA 模块是否能加载，再生成 ZIP。`.github/workflows/windows.yml` 在版本标签推送或手动触发时完成 Windows 和 macOS 构建；正式发布会使用本地 Developer ID 签名的 macOS 包。

## 检查

导出核心测试在 Mac 也能执行：

```bash
python3 -m unittest discover -s windows/tests -v
```

Windows UIA / OCR 测试只在 Windows 执行。若缺少 OCR 语言，在 Windows“设置 → 时间和语言”中添加中文或英语语言功能。如果微信以管理员运行，建议关闭其管理员模式后重开，避免权限级别差异阻碍界面读取。
