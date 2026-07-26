// 이 파일은 네 가지 V4 도트 오피스 테마와 명령 입력창을 네이티브 macOS 창에 표시한다.

import OfficeCore
import SwiftUI

@main
struct OfficeGameApp: App {
    var body: some Scene {
        WindowGroup("사무실") {
            OfficeGameView()
        }
        .defaultSize(width: 1_200, height: 800)
        .windowResizability(.contentMinSize)
    }
}

private struct OfficeGameView: View {
    @State private var command = ""
    @State private var bossActivity = BossActivity.working
    @State private var bossSpeechTask: Task<Void, Never>?
    @AppStorage("officeTheme") private var selectedThemeRawValue =
        OfficeTheme.modernDay.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            letterboxColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.18), value: theme)

            OfficeRealtimeView(
                theme: theme,
                isActive: scenePhase == .active,
                reduceMotion: reduceMotion,
                bossActivity: bossActivity
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack {
                Spacer()
                commandBar
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(alignment: .topTrailing) {
            themeToggle
                .padding(.top, 12)
                .padding(.trailing, 14)
                .zIndex(100)
        }
        .onDisappear {
            bossSpeechTask?.cancel()
            bossActivity = .working
        }
    }

    private var theme: OfficeTheme {
        OfficeTheme(rawValue: selectedThemeRawValue) ?? .modernDay
    }

    private var letterboxColor: Color {
        switch theme {
        case .modernDay, .woodDay:
            Color(red: 0.965, green: 0.925, blue: 0.895)
        case .modernNight:
            Color(red: 0.095, green: 0.135, blue: 0.205)
        case .woodNight:
            Color(red: 0.11, green: 0.12, blue: 0.17)
        }
    }

    private var themeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedThemeRawValue = theme.isNight
                    ? OfficeTheme.modernDay.rawValue
                    : OfficeTheme.modernNight.rawValue
            }
        } label: {
            Image(
                systemName: theme.isNight
                    ? "moon.stars.fill"
                    : "sun.max.fill"
            )
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, theme.isNight ? .dark : .light)
        .foregroundStyle(theme.isNight ? Color.white : Color.black.opacity(0.72))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            theme.isNight
                ? Color.black.opacity(0.72)
                : Color.white.opacity(0.92),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    theme.isNight
                        ? Color.white.opacity(0.25)
                        : Color.black.opacity(0.08)
                )
        }
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
        .fixedSize()
        .accessibilityLabel("오피스 테마")
        .accessibilityValue(theme.title)
        .accessibilityIdentifier("officeThemeMenu")
        .help(theme.isNight ? "낮 테마로 전환" : "밤 테마로 전환")
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0.46, green: 0.40, blue: 0.34))

            TextField("팀에게 무엇을 시킬까요?", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .onSubmit(submitCommand)

            Button {
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color(red: 0.44, green: 0.39, blue: 0.34))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("파일 첨부")

            Button(action: submitCommand) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Color(red: 0.18, green: 0.58, blue: 0.53),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("보내기")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.94))
                .shadow(color: .black.opacity(0.15), radius: 18, y: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.90), lineWidth: 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private func submitCommand() {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        command = ""
        bossSpeechTask?.cancel()
        bossActivity = .speaking
        bossSpeechTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else {
                return
            }
            bossActivity = .working
        }
    }
}
