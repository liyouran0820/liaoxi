# 开发日志

本文件按日期倒序记录实现、验证和已知问题。每次发布或关键行为变化时追加一节，并保留历史记录。

## 2026-10-18 双平台使用说明补全

- 将使用流程中的“Mac 微信”改为“电脑端微信（macOS 或 Windows）”，补充 Windows 刷新并选择合并记录窗口的步骤。
- 将 Mac 专属权限说明明确标注为 macOS，并补充 Windows OCR 语言要求与构建命令。
- 本次仅修改文档，检查 Markdown 与 Git 差异后推送 `main`；发行程序无需重新构建。

## 2026-10-18 v0.2.0 正式发布

- `main` 已保留双方历史完成合并；`v0.2.0` 指向实际通过双平台构建的提交 `31a0f77`。
- GitHub Actions `39053722042` 的 macOS 与 Windows 均通过。Windows 原生 OCR / UIA 测试、单文件 EXE 打包、实际 EXE 自检成功；macOS 云端测试与通用包构建成功。
- 正式 Release：https://github.com/liyouran0820/liaoxi/releases/tag/v0.2.0 ，已发布为非草稿、非预发布版本。
- 已上传 macOS 通用 DMG / ZIP、Windows x64 EXE / ZIP、SHA-256 校验清单及 Windows 自检回执。正式 Mac 包由本机 Developer ID 签名；未上传签名私钥至 GitHub。
- macOS 未完成 Apple 公证，Windows 无 Authenticode 签名，发布说明已列明。微信真实附件菜单兼容性仍与实际微信版本有关。

## 2026-10-18 GitHub 发布

- 保留远端简介及本地开发历史，将完整项目合并并推送至 `liyouran0820/liaoxi` 的 `main`。
- 增加 Windows 单文件 EXE、打包后 OCR / UIA 自检、macOS arm64 / x86_64 通用 DMG / ZIP 和直接下载入口。
- 首次 GitHub Actions 中 Windows 原生测试、EXE 打包和实际 EXE 自检通过；Mac 检出进度回调的并发捕获兼容错误，改为明确的主线程回调。
- 本地 macOS 通用包完成 Developer ID 签名与 DMG 校验；当前未配置 Apple 公证凭据，发布说明明确标注签名 / 公证状态。

## 2026-10-18

- 0.2.0：统一为单文件夹平铺导出，Markdown 与照片、视频、文档位于同层，提取报告内嵌文末。
- 增加原附件另存 / 复制收集、多选补充附件、SHA-256 校验、同名编号与相同内容去重；缺失项明确列出。
- 限定合并聊天记录窗口，按窗口高度滚动，逐屏收集附件，避免只靠旧版缩略哈希提前停止与长记录截图内存累积。
- 新增 Windows 桌面应用源码、启动脚本、Windows OCR / UIA 后端、打包脚本与 Windows CI 配置。
- 验证：10 项 Swift 测试通过；Windows 导出核心 5 项测试通过，原生 OCR / UIA 测试在 Mac 明确跳过；Python 语法与 ZIP 完整性检查通过。
- Mac Release 构建、签名校验、`/Applications/聊析.app` 安装与主窗口检查通过，两项系统权限仍为已允许；补充附件选择窗口可打开。检查工具在取消窗口时超时，重启应用后主窗口正常。
- Windows 原生 OCR / UIA 测试需 Windows 主机；当前 Mac 无 Windows VM。两版微信附件菜单的真实下载尚未完成端到端验证，未宣称 Windows EXE 构建或真实微信下载通过。

## 2026-08-28

- 识别微信消息下方的灰色回复原文，并在 Markdown 中保留为引用块。
- 引用判断结合文字灰度、发送者冒号结构和连续行位置，避免把昵称与时间误判为引用。
- 在 Markdown 开头写入正文样式与引用样式说明，明确供 LLM 解析的语义边界。

## 2026-08-27

- 修复辅助功能按钮在系统不再重复显示授权弹窗时看似无响应的问题。
- 授权按钮现在直接打开“隐私与安全性 → 辅助功能”，并提供新旧系统设置地址回退。
- 屏幕录制按钮同样直接打开对应系统设置页面。
- 补充 `NSScreenCaptureUsageDescription`，并以 `SCShareableContent` 正式触发屏幕录制注册。
- 应用固定安装到 `/Applications/聊析.app`，清理本应用失效的旧权限记录后重新授权。
- 本机构建优先使用 Apple Development 身份签名，减少重新构建后权限身份变化。

## 2026-08-26

- 初始化原生 SwiftUI macOS 应用“聊析”。
- 完成权限检测、微信窗口定位、自动滚动、Accessibility 文本读取、Vision OCR、跨屏去重、图片候选裁切和 Markdown 导出闭环。
- 仅保留与当前截图匹配的 Accessibility 文本，减少微信侧栏内容混入；支持中途停止提取。
- 增加 Swift 单元测试、应用打包脚本和 V1 边界文档。
- 待实机验证：不同微信版本的合并聊天记录窗口结构、滚动方向和图片裁切准确率。
