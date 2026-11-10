import BridgeplayUI
import SwiftUI

// Loading placeholders in the shape of the content on its way, instead of a spinner: quiet
// bars that a soft highlight crosses, still when Reduce Motion is on.

struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

// Sweeps a highlight across whatever it modifies, masked to its shapes.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.06), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

// The Status page while its first check runs: the hero, then two cards of rows.
struct SkeletonPage: View {
    let label: String
    var hero = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if hero {
                    RoundedRectangle(cornerRadius: BP.radius, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 148)
                }
                ForEach(0..<2, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBar(width: 90, height: 9)
                            .padding(.leading, 20)
                        VStack(spacing: 0) {
                            ForEach(0..<(section == 0 ? 4 : 3), id: \.self) { row in
                                SkeletonRow(titleWidth: [150, 190, 120, 170][row % 4])
                                if row < (section == 0 ? 3 : 2) {
                                    Rectangle().fill(BP.line).frame(height: 1).padding(.horizontal, 20)
                                }
                            }
                        }
                        .background(BP.raise, in: RoundedRectangle(cornerRadius: BP.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: BP.radius, style: .continuous).strokeBorder(BP.line, lineWidth: 1))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .shimmer()
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct SkeletonRow: View {
    var titleWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(width: titleWidth, height: 11)
                SkeletonBar(width: titleWidth * 1.6, height: 9)
            }
            Spacer(minLength: 12)
            SkeletonBar(width: 38, height: 20)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// A table on its way (Prefixes, Prefix Backups): a header and rows of columns.
struct SkeletonTable: View {
    let label: String
    var columns: [CGFloat] = [0.38, 0.22, 0.2, 0.2]
    var rows = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - 32
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, share in
                        SkeletonBar(width: width * share * 0.4, height: 8)
                            .frame(width: width * share - 16, alignment: .leading)
                    }
                }
                .padding(.vertical, 10)
                Rectangle().fill(BP.line).frame(height: 1)
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 16) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { column, share in
                            SkeletonBar(width: width * share * (column == 0 ? [0.8, 0.6, 0.7][row % 3] : 0.5), height: 10)
                                .frame(width: width * share - 16, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 11)
                }
            }
            .padding(.horizontal, 16)
            .shimmer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
