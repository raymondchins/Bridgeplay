import BridgeplayUI
import SwiftUI

// A small card floating over the bottom corner of the window, never a sheet or alert.
struct StarPromptCard: View {
    private var prompt: StarPrompt { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "star.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BP.iridescentDiagonal)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(BP.raise2))
                    .overlay(Circle().strokeBorder(BP.line, lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enjoying Bridgeplay?")
                        .font(BP.sans(13, .semibold))
                        .foregroundStyle(BP.fg)
                    Text("A star on GitHub helps other people find it.")
                        .font(BP.sans(12))
                        .foregroundStyle(BP.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(String(localized: "Close"), systemImage: "xmark", action: prompt.later)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BP.fg3)
                    .help("Later")
            }
            // Longer translations put Don't Show Again on a line of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    answers
                    Spacer(minLength: 8)
                    never
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { answers }
                    never
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(BP.raise, in: RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enjoying Bridgeplay?")
        // Behind a sheet or alert it is not seen yet, so it counts once that closes.
        .onAppear { if !NSApp.windows.contains(where: { $0.attachedSheet != nil }) { prompt.appeared() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in prompt.appeared() }
    }

    @ViewBuilder private var answers: some View {
        Button("Star on GitHub", action: prompt.star)
            .buttonStyle(.pill)
            .fixedSize()
        Button("Later", action: prompt.later)
            .buttonStyle(.pillSecondary)
            .fixedSize()
    }

    private var never: some View {
        Button(action: prompt.never) {
            Text("Don't show again")
                .font(BP.sans(12))
                .foregroundStyle(BP.fg3)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
