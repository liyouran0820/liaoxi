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
                VStack(alignment: .leading, spacing: 30) {
                    header
                    permissionSection
                    exportSection
                    actionSection
                }
                .padding(44)
            }
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("聊析")
                .font(.system(size: 54, weight: .black, design: .rounded))
                .tracking(-2)
            Text("微信合并记录 · Markdown")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("01  权限")
            HStack(spacing: 14) {
                permissionCard(
                    title: "辅助功能",
                    granted: model.accessibilityGranted,
                    waitingText: "点击后打开系统设置",
                    actionTitle: "打开设置",
                    action: model.requestAccessibility
                )
                permissionCard(
                    title: "屏幕录制",
                    granted: model.screenCaptureGranted,
                    waitingText: "等待授权",
                    actionTitle: "授权",
                    action: model.requestScreenCapture
                )
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
                    Text(model.outputDirectory?.path(percentEncoded: false) ?? "conversation.md 与 attachments 将保存在这里")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("选择位置", action: model.chooseOutputDirectory)
                    .buttonStyle(OutlineButtonStyle())
            }
            .padding(20)
            .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.07)))
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("03  提取")
            Text("在微信中打开合并聊天记录，并让窗口保持可见。")
                .font(.system(size: 20, weight: .bold))

            HStack(spacing: 16) {
                Button(model.isWorking ? "提取中" : "开始提取", action: model.start)
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
            Text("已完成：\(report.textLineCount) 行文字，\(report.imageCount) 张图片")
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
