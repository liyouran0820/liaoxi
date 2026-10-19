import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.96, green: 0.98, blue: 0.96), .white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    inputSection
                    exportSection
                    actionSection
                }
                .padding(30)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("聊析")
                .font(.system(size: 54, weight: .black, design: .rounded))
                .tracking(-2)
            Text("手动粘贴 · Markdown")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionLabel("01  聊天内容")
                Spacer()
                Button("粘贴", action: model.pasteFromClipboard).buttonStyle(OutlineButtonStyle())
                Button("补充附件", action: model.chooseAttachments).buttonStyle(OutlineButtonStyle())
            }
            .disabled(model.isWorking)
            ManualTextEditor(text: $model.draftText, selection: $model.draftSelection, editable: !model.isWorking)
                .frame(height: 260)
                .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.10)))
            if !model.manualAttachments.isEmpty {
                HStack {
                    Text("\(model.manualAttachments.count) 个附件").foregroundStyle(.secondary)
                    Spacer()
                    Button("清空附件", action: model.clearManualAttachments).disabled(model.isWorking)
                }
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("02  导出")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.outputDirectory?.lastPathComponent ?? "尚未选择位置")
                        .font(.system(size: 17, weight: .semibold))
                    Text(model.outputDirectory?.path(percentEncoded: false) ?? "MD 与同名文件夹中的照片、视频、文档一起保存")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("选择位置", action: model.chooseOutputDirectory)
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.isWorking)
            }
            .padding(20)
            .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.07)))
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("03  保存")

            HStack(spacing: 16) {
                Button(model.isWorking ? "保存中" : "导出 Markdown", action: model.start)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isWorking)

                if model.isWorking {
                    Button("停止", action: model.cancel)
                        .buttonStyle(OutlineButtonStyle())
                }

                if case .finished = model.runState {
                    Button("在访达中查看", action: model.revealResult)
                        .buttonStyle(OutlineButtonStyle())
                }
            }

            statusView
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.runState {
        case .idle:
            EmptyView()
        case let .working(message):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            .foregroundStyle(.secondary)
        case let .finished(report):
            Text("已保存：\(report.textLineCount) 行文字，\(report.imageCount) 张照片、\(report.videoCount) 个视频、\(report.fileCount) 个文件\(report.missingAttachmentCount > 0 ? "；请查看文末附件提示" : "")")
                .foregroundStyle(Color(red: 0.08, green: 0.45, blue: 0.25))
                .fontWeight(.semibold)
        case let .failed(message):
            Text(message)
                .foregroundStyle(Color(red: 0.72, green: 0.15, blue: 0.12))
                .fontWeight(.semibold)
        }
    }

    private func permissionCard(
        title: String,
        granted: Bool,
        waitingText: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(granted ? Color(red: 0.13, green: 0.66, blue: 0.36) : Color.orange)
                .frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(granted ? "已允许" : waitingText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(actionTitle, action: action).buttonStyle(.plain).fontWeight(.bold)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.07)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .black))
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .frame(height: 48)
            .background(Color(red: 0.04, green: 0.16, blue: 0.11).opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(Capsule())
    }
}

private struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(height: 42)
            .background(.white.opacity(configuration.isPressed ? 0.45 : 0.82))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.black.opacity(0.12)))
    }
}
