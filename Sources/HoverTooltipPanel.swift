import Cocoa
import SwiftUI

final class HoverTooltipPanel: NSPanel {
    private let hostingView: NSHostingView<HoverTooltipView>

    init(viewModel: RingViewModel) {
        self.hostingView = NSHostingView(rootView: HoverTooltipView(viewModel: viewModel))
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 280, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovable = false

        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(near ringFrame: CGRect) {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let origin = calculateOrigin(for: size, near: ringFrame)
        setFrame(CGRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }

    private func calculateOrigin(for size: CGSize, near ringFrame: CGRect) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(ringFrame) }) ?? NSScreen.main
        let bounds = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 8
        let gap: CGFloat = 8

        var y = ringFrame.maxY + gap
        if y + size.height > bounds.maxY - inset {
            y = ringFrame.minY - size.height - gap
        }
        y = min(max(y, bounds.minY + inset), bounds.maxY - size.height - inset)

        let preferRightAlign = ringFrame.midX > bounds.midX
        var x = preferRightAlign ? (ringFrame.maxX - size.width) : ringFrame.minX
        x = min(max(x, bounds.minX + inset), bounds.maxX - size.width - inset)

        return CGPoint(x: x, y: y)
    }
}

struct HoverTooltipView: View {
    @ObservedObject var viewModel: RingViewModel

    private var s: CGFloat {
        viewModel.effectiveHoverScale
    }

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    private var darkTheme: Bool {
        viewModel.effectiveIsDarkTheme
    }

    private var surfaceBg: Color {
        darkTheme
            ? Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.96)
            : Color.white.opacity(0.97)
    }

    private var borderStroke: Color {
        darkTheme
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.11)
    }

    private var primaryText: Color {
        darkTheme ? Color(white: 0.94) : Color(white: 0.10)
    }

    private var secondaryText: Color {
        darkTheme ? Color(white: 0.64) : Color(white: 0.44)
    }

    private var chatTitle: String {
        if !viewModel.activeChatTitle.isEmpty {
            return viewModel.activeChatTitle
        }
        if let title = viewModel.stats?.title, !title.isEmpty {
            return title
        }
        return L10n.activeChatFallback(lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(spacing: 8 * s) {
                Text(chatTitle)
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundColor(primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6 * s)

                Text(viewModel.hasTokenData ? "\(viewModel.percent)%" : "—")
                    .font(.system(size: 12 * s, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(viewModel.hasTokenData ? viewModel.zone.accentColor : secondaryText)
                    .padding(.horizontal, 7 * s)
                    .padding(.vertical, 2.5 * s)
                    .background(viewModel.hasTokenData ? viewModel.zone.pillBackground : Color.gray.opacity(0.16))
                    .clipShape(Capsule())
            }

            HStack(spacing: 6 * s) {
                if viewModel.hasTokenData, let stats = viewModel.stats {
                    Text("\(RingViewModel.formatNumber(stats.contextTokens)) / \(RingViewModel.formatLimit(viewModel.threshold))")
                        .font(.system(size: 12.5 * s, weight: .medium, design: .monospaced))
                        .foregroundColor(primaryText)

                    if stats.totalModelSteps > 0 {
                        Text("(\(viewModel.formattedDelta))")
                            .font(.system(size: 11.5 * s, design: .monospaced))
                            .foregroundColor(secondaryText)
                    }

                    if stats.compactionEvents > 0 {
                        Text(L10n.compactionsBadge(stats.compactionEvents, lang: lang))
                            .font(.system(size: 11 * s, weight: .semibold))
                            .foregroundColor(ContextZone.amber.accentColor)
                            .padding(.horizontal, 5 * s)
                            .padding(.vertical, 1.5 * s)
                            .background(ContextZone.amber.pillBackground)
                            .cornerRadius(4 * s)
                    }
                } else {
                    Text(L10n.noTokenLogsShort(lang))
                        .font(.system(size: 12 * s))
                        .foregroundColor(secondaryText)
                }
            }
        }
        .padding(.horizontal, 12 * s)
        .padding(.vertical, 9 * s)
        .frame(maxWidth: 300 * s, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11 * s, style: .continuous)
                .fill(surfaceBg)
                .shadow(
                    color: Color.black.opacity(darkTheme ? 0.42 : 0.16),
                    radius: 8,
                    x: 0,
                    y: 3
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11 * s, style: .continuous)
                .stroke(borderStroke, lineWidth: 1)
        )
        .padding(6)
        .fixedSize()
    }
}
