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
        let origin = OverlayPositioning.popupOrigin(for: size, near: ringFrame, gap: 8, horizontalOverlap: 0, inset: 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
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

    private var palette: OverlayPalette {
        viewModel.palette
    }

    private var surfaceBg: Color { palette.tooltipSurfaceBg }
    private var borderStroke: Color { palette.borderStroke }
    private var primaryText: Color { palette.primaryText }
    private var secondaryText: Color { palette.secondaryText }

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

            if viewModel.hasTokenData {
                let scopeLabel = L10n.hoverScopeBadge(scope: viewModel.effectiveScope, stats: viewModel.stats, lang: lang)
                if !scopeLabel.isEmpty {
                    Text(scopeLabel)
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 6 * s) {
                if viewModel.hasTokenData, let scoped = viewModel.activeScopedSnapshot {
                    Text("\(RingViewModel.formatNumber(scoped.contextTokens)) / \(RingViewModel.formatLimit(viewModel.threshold))")
                        .font(.system(size: 12.5 * s, weight: .medium, design: .monospaced))
                        .foregroundColor(primaryText)

                    if scoped.totalModelSteps > 0 {
                        Text("(\(viewModel.formattedDelta))")
                            .font(.system(size: 11.5 * s, design: .monospaced))
                            .foregroundColor(secondaryText)
                    }

                    if scoped.compactionEvents > 0 {
                        Text(L10n.compactionsBadge(scoped.compactionEvents, lang: lang))
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
