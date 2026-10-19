# 聊析 Windows 手动版

本文件维护 Windows 启动、打包与平台限制；通用操作见上级 `README.md`，架构见 `PROJECT_INTRODUCTION.md`，验证写入 `log.md`。

## 使用

1. Windows 10/11 x64，源码启动需要含 Tcl/Tk 和 Python Launcher 的 Python 3.12 x64；双击 `start.cmd`。
2. 从微信复制文字，粘贴到“聊天内容”（Ctrl+V 或“粘贴”）。无需窗口选择和 OCR 语言包。
3. 自行保存照片、视频和文档；在对话对应位置放光标，点“补充附件”。可整体移动附件标记，不改内部字符。
4. 选择位置，点“导出 Markdown”，完成后“查看结果”。

文字原样保留，不猜发言者、不删除重复消息；引用请用 `> `。链接按手动位置插入，不识别图片文字、不操作微信。相同附件只存一份，源文件不删除。文件与 Markdown 平铺在一个同名文件夹中。草稿不持久化，关闭前请导出。

公开 v0.2.0 EXE 仍是旧自动提取版，不含本次修改；新版需要重新构建 / 发布，不能把源码测试当作已发布。

## 构建独立 EXE

在 Windows PowerShell 中执行：

```powershell
./build.ps1
```

脚本安装 PyInstaller、执行便携测试、打包单文件 EXE，再运行实际 EXE 的手动导出自检。报告必须为 `mode=manual`、`ocr=false`、`screen_capture=false`。成功后生成：

```text
dist/ChatArchive-Windows-x64.exe
dist/ChatArchive-Windows-x64.zip
dist/packaged-smoke.json
```

手动版只用 Python 标准库和 Tk，EXE 内含运行环境。历史 `windows_capture.py` 不由默认入口调用；旧依赖单列在 `requirements-legacy.txt`。历史原生测试需显式设置 `CHATARCHIVE_TEST_LEGACY_CAPTURE=1`，不属于手动版验收。

## 跨平台检查

```bash
python3 -m unittest discover -s windows/tests -v
python3 windows/app.py --self-test
```

可在 Mac 执行上述核心测试，但 Windows Tk 界面和实际 EXE 必须以 Windows 实机 / CI 结果为准。
