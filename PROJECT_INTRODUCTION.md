# 项目简介

## 产品目标

聊析服务于“手动合并转发、自动结构化整理”的工作流。用户主动在微信内筛选内容，本应用只读取屏幕上已经打开的合并记录，生成 `conversation.md + attachments/`，方便交给支持文件与图片的大语言模型。

## 技术路径

- `WindowCaptureService`：用 ScreenCaptureKit 定位和捕获微信可见窗口，驱动滚动。
- `AccessibilityTextService`：读取微信窗口暴露的辅助功能文本。
- `OCRService`：以 Apple Vision 在本机识别中英文。
- `ContentProcessor`：跨屏去重、文字源选择、灰色回复引用识别、图片候选裁切和文件名识别。
- `MarkdownExporter`：输出 Markdown、PNG 附件与机器可读提取报告。

## 文档职责

- `PROJECT_INTRODUCTION.md`：维护稳定的产品范围、架构和关键技术决策。
- `README.md`：维护面向使用者与开发者的安装、使用和构建说明。
- `log.md`：按日期追加已完成事项、验证结果和已知问题，不在这里重复产品介绍。

## 安全边界

应用不接触微信数据库和私有协议，不读取凭据，不修改微信文件，不上传提取内容。授权范围仅为用户明确触发的辅助功能与窗口捕获。
