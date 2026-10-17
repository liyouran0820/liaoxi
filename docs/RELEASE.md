# 发布流程

本文件维护发布步骤与验证标准；使用说明在 `README.md`，实际发布结果记录到 `log.md`。发布时不得将凭据、证书私钥或本地附件写入仓库。

1. 在 `main` 完成合并，运行 Swift 与 Windows 导出核心测试，检查版本号。
2. 推送版本标签（例如 `v0.2.0`），触发 `Release builds`。也可手动触发 `.github/workflows/windows.yml`。
3. 等待 Windows 原生 OCR / UIA 测试、PyInstaller 单文件打包以及实际 EXE 自检完成。下载 `ChatArchive-Windows` artifact。
4. macOS 本地设置 `CHATARCHIVE_SIGN_IDENTITY` 为现有 Developer ID Application 身份，运行 `zsh scripts/package-macos.sh`，生成 arm64 / x86_64 通用 DMG 与 ZIP。CI 的 macOS 包只用于构建检查；正式 Release 使用 Developer ID 签名产物。
5. 如具有可用的 Apple 公证凭据，用 `notarytool` 完成公证并装订票据后重新生成分发文件。未公证时，发布说明必须准确标明。
6. 手动运行 `.github/workflows/publish.yml`，指定成功的构建 run ID 和版本标签。流程会校验构建结论与 EXE 自检回执，并直接把 Windows 文件传至草稿 Release。标签指向实际被测试的构建提交。
7. 补充本地签名的 Mac DMG / ZIP，校验版本一致性并生成 `SHA256SUMS.txt`。
8. 确认两个平台资产齐全后发布，验证 README 的 `releases/latest/download/…` 固定下载链接。

签名只读取本机钥匙串中既有身份，不将签名私钥上传 CI。Windows 发布版若没有 Authenticode 签名，首次下载可能显示 SmartScreen 提示。
