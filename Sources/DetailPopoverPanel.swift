import Cocoa
import SwiftUI

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class DetailLayoutState: ObservableObject {
    @Published var maxBodyHeight: CGFloat = 600
    @Published var measuredBodyHeight: CGFloat = 360
    @Published var measuredTopChromeHeight: CGFloat = 120
}

final class DetailPopoverPanel: NSPanel {
    static let baseCardWidth: CGFloat = 356

    private let viewModel: RingViewModel
    private let layoutState = DetailLayoutState()
    private let hostingView: FirstMouseHostingView<DetailCardView>
    private var lastAnchorRingFrame: CGRect?

    init(
        viewModel: RingViewModel,
        onToggleChatDropdown: @escaping (CGRect) -> Void,
        onSelectAutoMode: @escaping () -> Void,
        onSelectDetailTab: @escaping (DetailTab) -> Void,
        onSelectStatsPeriod: @escaping (StatsPeriod) -> Void,
        onSelectHistoryMode: @escaping (HistoryViewMode) -> Void,
        onCopyHandoff: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        weak var weakSelf: DetailPopoverPanel?
        let rootView = DetailCardView(
            viewModel: viewModel,
            layoutState: layoutState,
            onToggleChatDropdown: onToggleChatDropdown,
            onSelectAutoMode: onSelectAutoMode,
            onSelectDetailTab: onSelectDetailTab,
            onSelectStatsPeriod: onSelectStatsPeriod,
            onSelectHistoryMode: onSelectHistoryMode,
            onCopyHandoff: onCopyHandoff,
            onClose: onClose,
            onLayoutSizeMayChange: {
                DispatchQueue.main.async {
                    weakSelf?.resizeForCurrentAnchor()
                }
            }
        )
        self.hostingView = FirstMouseHostingView(rootView: rootView)

        super.init(
            contentRect: CGRect(x: 0, y: 0, width: Self.baseCardWidth + 16, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        weakSelf = self

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false

        contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(near ringFrame: CGRect) {
        lastAnchorRingFrame = ringFrame
        reposition(near: ringFrame)
        orderFrontRegardless()
    }

    func reposition(near ringFrame: CGRect) {
        lastAnchorRingFrame = ringFrame
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(ringFrame) }) ?? NSScreen.main
        let bounds = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 8
        let s = viewModel.effectiveDetailScale
        let maxPanelHeight = max(260, bounds.height - inset * 2)
        let chromeVerticalPadding = (24 * s) + 16 + (10 * s)
        let allowedBodyHeight = max(140, maxPanelHeight - layoutState.measuredTopChromeHeight - chromeVerticalPadding)

        if abs(layoutState.maxBodyHeight - allowedBodyHeight) > 0.5 {
            layoutState.maxBodyHeight = allowedBodyHeight
        }

        hostingView.layoutSubtreeIfNeeded()
        let targetWidth = (Self.baseCardWidth * s) + 16
        let measuredTotal = layoutState.measuredTopChromeHeight + min(layoutState.measuredBodyHeight, allowedBodyHeight) + chromeVerticalPadding
        let fittedHeight = hostingView.fittingSize.height
        let desiredHeight = min(maxPanelHeight, max(220, max(fittedHeight, measuredTotal)))
        let size = CGSize(width: targetWidth, height: desiredHeight)
        let origin = calculateOrigin(for: size, near: ringFrame, bounds: bounds, inset: inset)
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func resizeForCurrentAnchor() {
        guard isVisible, let ringFrame = lastAnchorRingFrame else { return }
        reposition(near: ringFrame)
    }

    private func calculateOrigin(for size: CGSize, near ringFrame: CGRect, bounds: CGRect, inset: CGFloat) -> CGPoint {
        let gap: CGFloat = 6

        var y = ringFrame.maxY + gap
        if y + size.height > bounds.maxY - inset {
            let belowY = ringFrame.minY - size.height - gap
            if belowY >= bounds.minY + inset {
                y = belowY
            }
        }
        y = min(max(y, bounds.minY + inset), bounds.maxY - size.height - inset)

        let preferRightAlign = ringFrame.midX > bounds.midX
        var x = preferRightAlign ? (ringFrame.maxX - size.width + 8) : (ringFrame.minX - 8)
        x = min(max(x, bounds.minX + inset), bounds.maxX - size.width - inset)

        return CGPoint(x: x, y: y)
    }
}

final class ChatDropdownPanel: NSPanel {
    private let viewModel: RingViewModel
    private let hostingView: FirstMouseHostingView<ChatDropdownView>

    init(viewModel: RingViewModel, onSelectConversation: @escaping (String?) -> Void) {
        self.viewModel = viewModel
        self.hostingView = FirstMouseHostingView(
            rootView: ChatDropdownView(viewModel: viewModel, onSelectConversation: onSelectConversation)
        )
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false

        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(below buttonScreenRect: CGRect) {
        let s = viewModel.effectiveDetailScale
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(buttonScreenRect) }) ?? NSScreen.main
        let bounds = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 8

        let rowCount = max(1, viewModel.recentConversations.count + 1)
        let estimatedListHeight = CGFloat(rowCount) * (31 * s) + (18 * s)
        let maxPanelHeight = max(140, min(280 * s, buttonScreenRect.minY - bounds.minY - inset - 4))
        let height = min(estimatedListHeight + 12, maxPanelHeight)
        let width = max(240, buttonScreenRect.width + 12)

        var x = buttonScreenRect.minX - 6
        x = min(max(x, bounds.minX + inset), bounds.maxX - width - inset)

        var y = buttonScreenRect.minY - height - 4
        if y < bounds.minY + inset {
            y = min(buttonScreenRect.maxY + 4, bounds.maxY - height - inset)
        }

        setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        orderFrontRegardless()
    }
}

private struct ChatDropdownView: View {
    @ObservedObject var viewModel: RingViewModel
    let onSelectConversation: (String?) -> Void

    private var s: CGFloat { viewModel.effectiveDetailScale }
    private var lang: ResolvedLanguage { viewModel.resolvedLanguage }
    private var darkTheme: Bool { viewModel.effectiveIsDarkTheme }

    private var cardBg: Color {
        darkTheme ? Color(red: 0.14, green: 0.15, blue: 0.18) : Color.white
    }

    private var mutedBg: Color {
        darkTheme ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var borderStroke: Color {
        darkTheme ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    private var primaryText: Color {
        darkTheme ? Color(white: 0.95) : Color(white: 0.10)
    }

    private var secondaryText: Color {
        darkTheme ? Color(white: 0.62) : Color(white: 0.44)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2 * s) {
                rowButton(
                    title: L10n.autoActiveWindowOption(lang),
                    subtitle: nil,
                    isSelected: viewModel.manualConversationId == nil
                ) {
                    onSelectConversation(nil)
                }

                if viewModel.recentConversations.isEmpty {
                    Text(L10n.chatHistoryEmpty(lang))
                        .font(.system(size: 12 * s))
                        .foregroundColor(secondaryText)
                        .padding(.horizontal, 8 * s)
                        .padding(.vertical, 6 * s)
                } else {
                    ForEach(viewModel.recentConversations) { item in
                        rowButton(
                            title: item.title,
                            subtitle: item.contextTokens > 0 ? RingViewModel.formatK(item.contextTokens) : "—",
                            isSelected: viewModel.manualConversationId == item.id
                                || (viewModel.manualConversationId == nil && viewModel.stats?.conversationId == item.id)
                        ) {
                            onSelectConversation(item.id)
                        }
                    }
                }
            }
            .padding(6 * s)
        }
        .background(
            RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                .fill(cardBg)
                .shadow(
                    color: Color.black.opacity(darkTheme ? 0.55 : 0.22),
                    radius: 12,
                    x: 0,
                    y: 6
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10 * s, style: .continuous)
                .stroke(borderStroke, lineWidth: 1)
        )
        .padding(6)
    }

    private func rowButton(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7 * s) {
                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.system(size: (isSelected ? 10.5 : 6) * s, weight: .bold))
                    .foregroundColor(isSelected ? Color(red: 0.24, green: 0.52, blue: 0.96) : secondaryText.opacity(0.6))
                    .frame(width: 14 * s)

                Text(title)
                    .font(.system(size: 12.5 * s, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6 * s)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5 * s, design: .monospaced))
                        .foregroundColor(secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8 * s)
            .padding(.vertical, 6 * s)
            .background(isSelected ? mutedBg : Color.clear)
            .cornerRadius(6 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SwitcherAnchorBridge: NSViewRepresentable {
    @Binding var viewRef: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { viewRef = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if viewRef !== nsView {
            DispatchQueue.main.async { viewRef = nsView }
        }
    }
}

struct DetailCardView: View {
    @ObservedObject var viewModel: RingViewModel
    @ObservedObject var layoutState: DetailLayoutState

    let onToggleChatDropdown: (CGRect) -> Void
    let onSelectAutoMode: () -> Void
    let onSelectDetailTab: (DetailTab) -> Void
    let onSelectStatsPeriod: (StatsPeriod) -> Void
    let onSelectHistoryMode: (HistoryViewMode) -> Void
    let onCopyHandoff: () -> Void
    let onClose: () -> Void
    let onLayoutSizeMayChange: () -> Void

    @State private var copiedFeedback = false
    @State private var switcherAnchorView: NSView?

    private var s: CGFloat {
        viewModel.effectiveDetailScale
    }

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    private var darkTheme: Bool {
        viewModel.effectiveIsDarkTheme
    }

    private var surfaceBg: Color {
        darkTheme
            ? Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.98)
            : Color(red: 0.98, green: 0.98, blue: 0.99).opacity(0.98)
    }

    private var cardBg: Color {
        darkTheme
            ? Color(red: 0.16, green: 0.17, blue: 0.20)
            : Color.white
    }

    private var mutedBg: Color {
        darkTheme
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.05)
    }

    private var borderStroke: Color {
        darkTheme
            ? Color.white.opacity(0.13)
            : Color.black.opacity(0.11)
    }

    private var primaryText: Color {
        darkTheme ? Color(white: 0.95) : Color(white: 0.10)
    }

    private var secondaryText: Color {
        darkTheme ? Color(white: 0.62) : Color(white: 0.44)
    }

    private var activeChatDisplayTitle: String {
        if let manualId = viewModel.manualConversationId,
           let item = viewModel.recentConversations.first(where: { $0.id == manualId }) {
            return item.title
        }
        if !viewModel.activeChatTitle.isEmpty {
            return viewModel.activeChatTitle
        }
        if let title = viewModel.stats?.title, !title.isEmpty {
            return title
        }
        return L10n.autoActiveWindowOption(lang)
    }

    private var alertMessage: String? {
        guard viewModel.hasTokenData, let stats = viewModel.stats else { return nil }
        var parts: [String] = []
        switch viewModel.zone {
        case .red:
            parts.append(L10n.alertRed(lang))
        case .amber:
            parts.append(L10n.alertAmber(lang))
        case .green:
            break
        }
        if stats.compactionEvents > 0 {
            parts.append(L10n.alertCompactions(stats.compactionEvents, lang: lang))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            VStack(alignment: .leading, spacing: 10 * s) {
                headerSection
                tabBarSection
                chatSwitcherSection
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { updateTopChromeHeight(geo.size.height) }
                        .onChange(of: geo.size.height) { newH in updateTopChromeHeight(newH) }
                }
            )

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10 * s) {
                    if viewModel.activeDetailTab == .context {
                        contextTabBody
                    } else {
                        statsTabBody
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { updateBodyHeight(geo.size.height) }
                            .onChange(of: geo.size.height) { newH in updateBodyHeight(newH) }
                    }
                )
            }
            .frame(height: min(layoutState.measuredBodyHeight, layoutState.maxBodyHeight))
        }
        .padding(12 * s)
        .frame(width: DetailPopoverPanel.baseCardWidth * s)
        .background(
            RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
                .fill(surfaceBg)
                .shadow(
                    color: Color.black.opacity(darkTheme ? 0.50 : 0.20),
                    radius: 14,
                    x: 0,
                    y: 6
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12 * s, style: .continuous)
                .stroke(borderStroke, lineWidth: 1)
        )
        .padding(8)
        .onChange(of: viewModel.stats?.conversationId) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.hasTokenData) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.stats?.compactionEvents) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.stats?.recentSteps.count) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.stats?.recentMessages.count) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.activeDetailTab) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.statsPeriod) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.periodStats) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.historyViewMode) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.languagePreference) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.threshold) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.zoomLevel) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.detailFontScale) { _ in onLayoutSizeMayChange() }
        .onChange(of: viewModel.scaleWithAntigravityZoom) { _ in onLayoutSizeMayChange() }
    }

    private func updateTopChromeHeight(_ newHeight: CGFloat) {
        guard newHeight > 10, abs(layoutState.measuredTopChromeHeight - newHeight) > 0.5 else { return }
        DispatchQueue.main.async {
            layoutState.measuredTopChromeHeight = newHeight
            onLayoutSizeMayChange()
        }
    }

    private func updateBodyHeight(_ newHeight: CGFloat) {
        guard newHeight > 10, abs(layoutState.measuredBodyHeight - newHeight) > 0.5 else { return }
        DispatchQueue.main.async {
            layoutState.measuredBodyHeight = newHeight
            onLayoutSizeMayChange()
        }
    }

    @ViewBuilder
    private var contextTabBody: some View {
        progressSection

        if !viewModel.hasTokenData {
            noDataBanner
        } else if let alert = alertMessage {
            alertBanner(alert)
        }

        breakdownSection
        metricsGrid
        handoffButton
        recentStepsSection
    }

    @ViewBuilder
    private var statsTabBody: some View {
        currentChatStatsCard
        allChatsPeriodStatsCard
    }

    private var headerSection: some View {
        HStack(spacing: 8 * s) {
            Text("Context Monitor")
                .font(.system(size: 14.5 * s, weight: .semibold))
                .foregroundColor(primaryText)

            if viewModel.manualConversationId == nil {
                Text(L10n.autoBadge(lang))
                    .font(.system(size: 11 * s, weight: .semibold))
                    .foregroundColor(ContextZone.green.accentColor)
                    .padding(.horizontal, 7 * s)
                    .padding(.vertical, 2.5 * s)
                    .background(ContextZone.green.pillBackground)
                    .clipShape(Capsule())
            } else {
                Button(action: onSelectAutoMode) {
                    Text(L10n.manualToAutoBadge(lang))
                        .font(.system(size: 11 * s, weight: .semibold))
                        .foregroundColor(Color(red: 0.24, green: 0.52, blue: 0.96))
                        .padding(.horizontal, 7 * s)
                        .padding(.vertical, 2.5 * s)
                        .background(Color(red: 0.24, green: 0.52, blue: 0.96).opacity(0.15))
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5 * s, weight: .semibold))
                    .foregroundColor(secondaryText)
                    .frame(width: 24 * s, height: 24 * s)
                    .background(mutedBg)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var tabBarSection: some View {
        HStack(spacing: 4 * s) {
            ForEach(DetailTab.allCases) { tab in
                let selected = viewModel.activeDetailTab == tab
                Button {
                    onSelectDetailTab(tab)
                } label: {
                    Text(L10n.detailTabName(tab, lang: lang))
                        .font(.system(size: 12 * s, weight: selected ? .semibold : .medium))
                        .foregroundColor(selected ? primaryText : secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5 * s)
                        .background(selected ? cardBg : Color.clear)
                        .cornerRadius(6 * s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3 * s)
        .background(mutedBg)
        .cornerRadius(8 * s)
    }

    private var chatSwitcherSection: some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            Text(L10n.recentChatsCount(viewModel.recentConversations.count, lang: lang))
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundColor(secondaryText)

            Button {
                if let view = switcherAnchorView, let win = view.window {
                    let rectInWin = view.convert(view.bounds, to: nil)
                    let screenRect = win.convertToScreen(rectInWin)
                    onToggleChatDropdown(screenRect)
                }
            } label: {
                HStack(spacing: 6 * s) {
                    Text(activeChatDisplayTitle)
                        .font(.system(size: 12.5 * s, weight: .medium))
                        .foregroundColor(primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: viewModel.isChatDropdownOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11 * s, weight: .semibold))
                        .foregroundColor(secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10 * s)
                .padding(.vertical, 8 * s)
                .background(cardBg)
                .cornerRadius(8 * s)
                .overlay(
                    RoundedRectangle(cornerRadius: 8 * s)
                        .stroke(borderStroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(SwitcherAnchorBridge(viewRef: $switcherAnchorView))
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                Text(viewModel.hasTokenData ? viewModel.formattedTokens : "—")
                    .font(.system(size: 23 * s, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.hasTokenData ? primaryText : secondaryText)

                Text("/ \(RingViewModel.formatLimit(viewModel.threshold)) \(L10n.tokensSuffix(lang))")
                    .font(.system(size: 12.5 * s))
                    .foregroundColor(secondaryText)

                Spacer()

                Text(viewModel.hasTokenData ? "\(viewModel.percent)%" : "—")
                    .font(.system(size: 12 * s, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(viewModel.hasTokenData ? viewModel.zone.accentColor : secondaryText)
                    .padding(.horizontal, 8 * s)
                    .padding(.vertical, 3 * s)
                    .background(viewModel.hasTokenData ? viewModel.zone.pillBackground : Color.gray.opacity(0.16))
                    .clipShape(Capsule())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(mutedBg)
                    Capsule()
                        .fill(viewModel.hasTokenData ? viewModel.zone.accentColor : Color.gray.opacity(0.4))
                        .frame(width: max(0, geo.size.width * CGFloat(viewModel.progress)))
                        .animation(.easeOut(duration: 0.22), value: viewModel.progress)
                }
            }
            .frame(height: 8 * s)
        }
        .padding(10 * s)
        .background(cardBg)
        .cornerRadius(10 * s)
        .overlay(
            RoundedRectangle(cornerRadius: 10 * s)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private var noDataBanner: some View {
        Text(L10n.noTokenLogsBanner(lang))
            .font(.system(size: 12 * s))
            .foregroundColor(secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9 * s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mutedBg)
            .cornerRadius(8 * s)
            .overlay(
                RoundedRectangle(cornerRadius: 8 * s)
                    .stroke(borderStroke, lineWidth: 1)
            )
    }

    private func alertBanner(_ message: String) -> some View {
        let color = viewModel.zone == .red
            ? ContextZone.red.accentColor
            : ContextZone.amber.accentColor

        return Text(message)
            .font(.system(size: 12 * s))
            .foregroundColor(primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9 * s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.14))
            .cornerRadius(8 * s)
            .overlay(
                RoundedRectangle(cornerRadius: 8 * s)
                    .stroke(color.opacity(0.35), lineWidth: 1)
            )
    }

    private var breakdownSection: some View {
        let b = viewModel.hasTokenData ? (viewModel.stats?.breakdown ?? .empty) : .empty
        let denom = max(1, max(viewModel.threshold, viewModel.contextTokens))

        let sysColor = Color(red: 0.56, green: 0.42, blue: 0.96)
        let toolsColor = Color(red: 0.20, green: 0.55, blue: 0.96)
        let assistantColor = Color(red: 0.14, green: 0.72, blue: 0.56)
        let userColor = Color(red: 0.95, green: 0.56, blue: 0.18)

        let segments: [(label: String, tokens: Int, color: Color)] = [
            (L10n.segmentSystem(lang), b.systemTokens, sysColor),
            (L10n.segmentTools(lang), b.toolsTokens, toolsColor),
            (L10n.segmentAssistant(lang), b.assistantTokens, assistantColor),
            (L10n.segmentUser(lang), b.userTokens, userColor),
        ]

        return VStack(alignment: .leading, spacing: 7 * s) {
            HStack {
                Text(L10n.breakdownTitle(lang))
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundColor(secondaryText)
                Spacer()
                Text(L10n.estimateTag(lang))
                    .font(.system(size: 10.5 * s))
                    .foregroundColor(secondaryText.opacity(0.85))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(mutedBg)
                    HStack(spacing: 1) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            let ratio = CGFloat(seg.tokens) / CGFloat(denom)
                            if seg.tokens > 0 {
                                Rectangle()
                                    .fill(seg.color)
                                    .frame(width: max(2 * s, geo.size.width * ratio))
                            }
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 9 * s)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8 * s),
                    GridItem(.flexible(), spacing: 8 * s),
                ],
                spacing: 5 * s
            ) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    let pctOfLimit = viewModel.threshold > 0
                        ? Int((Double(seg.tokens) / Double(viewModel.threshold) * 100.0).rounded())
                        : 0
                    HStack(spacing: 5 * s) {
                        Circle()
                            .fill(seg.color)
                            .frame(width: 8 * s, height: 8 * s)
                        Text(seg.label)
                            .font(.system(size: 11.5 * s))
                            .foregroundColor(secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2 * s)
                        Text(viewModel.hasTokenData ? "\(RingViewModel.formatK(seg.tokens)) (\(pctOfLimit)%)" : "—")
                            .font(.system(size: 11.5 * s, weight: .medium, design: .monospaced))
                            .foregroundColor(primaryText)
                    }
                }
            }

            if viewModel.hasTokenData && (b.totalOutputTokens > 0 || b.toolCallsCount > 0) {
                let toolsTail = b.topTools.isEmpty
                    ? ""
                    : " (" + b.topTools.map { "\($0.name)×\($0.count)" }.joined(separator: ", ") + ")"
                Text(L10n.outputAndToolsFooter(
                    outputK: RingViewModel.formatK(b.totalOutputTokens),
                    toolCalls: b.toolCallsCount,
                    toolsTail: toolsTail,
                    lang: lang
                ))
                .font(.system(size: 10.5 * s, design: .monospaced))
                .foregroundColor(secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(10 * s)
        .background(cardBg)
        .cornerRadius(9 * s)
        .overlay(
            RoundedRectangle(cornerRadius: 9 * s)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private var metricsGrid: some View {
        let stats = viewModel.hasTokenData ? viewModel.stats : nil
        let session = stats?.sessionStats ?? .empty
        let mode = viewModel.historyViewMode

        let modelValue: String
        if let stats {
            let base = !session.primaryModel.isEmpty ? session.primaryModel : stats.model
            if base.isEmpty {
                modelValue = "—"
            } else if session.otherModelsCount > 0 {
                modelValue = "\(base) (+\(session.otherModelsCount))"
            } else {
                modelValue = base
            }
        } else {
            modelValue = "—"
        }

        let cacheValue: String
        if let stats {
            if mode == .messages, let turn = stats.recentMessages.first {
                cacheValue = "\(RingViewModel.formatK(turn.cacheReadTokens)) (\(turn.cacheHitPercent)%)"
            } else {
                cacheValue = "\(RingViewModel.formatK(stats.lastCacheReadTokens)) (\(stats.cacheHitPercent)%)"
            }
        } else {
            cacheValue = "—"
        }

        let countPeakValue: String
        if let stats {
            let countVal = mode == .messages ? session.userMessageCount : stats.totalModelSteps
            countPeakValue = "\(countVal) / \(RingViewModel.formatK(stats.peakTokens))"
        } else {
            countPeakValue = "—"
        }

        return VStack(spacing: 6 * s) {
            HStack(spacing: 6 * s) {
                metricCell(label: L10n.metricPrimaryModel(lang), value: modelValue)
                metricCell(label: L10n.metricLastDelta(mode, lang: lang), value: viewModel.formattedDelta)
            }
            HStack(spacing: 6 * s) {
                metricCell(label: L10n.metricCache(mode, lang: lang), value: cacheValue)
                metricCell(label: L10n.metricCountPeak(mode, lang: lang), value: countPeakValue)
            }
        }
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            Text(label)
                .font(.system(size: 11 * s))
                .foregroundColor(secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 12.5 * s, weight: .semibold, design: .monospaced))
                .foregroundColor(primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9 * s)
        .padding(.vertical, 7 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBg)
        .cornerRadius(8 * s)
        .overlay(
            RoundedRectangle(cornerRadius: 8 * s)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private var handoffButton: some View {
        Button {
            onCopyHandoff()
            copiedFeedback = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                copiedFeedback = false
            }
        } label: {
            Text(L10n.copyHandoffButton(copiedFeedback, lang: lang))
                .font(.system(size: 13 * s, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8 * s)
                .background(
                    copiedFeedback
                        ? ContextZone.green.accentColor
                        : Color(red: 0.20, green: 0.45, blue: 0.92)
                )
                .cornerRadius(8 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentStepsSection: some View {
        let mode = viewModel.historyViewMode
        let messages = viewModel.hasTokenData ? Array((viewModel.stats?.recentMessages ?? []).prefix(5)) : []
        let steps = viewModel.hasTokenData ? Array((viewModel.stats?.recentSteps ?? []).prefix(5)) : []
        let isEmpty = mode == .messages ? messages.isEmpty : steps.isEmpty

        return VStack(alignment: .leading, spacing: 6 * s) {
            HStack(spacing: 6 * s) {
                Text(L10n.recentActivityTitle(lang))
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundColor(secondaryText)

                Spacer()

                HStack(spacing: 2 * s) {
                    ForEach(HistoryViewMode.allCases) { itemMode in
                        let selected = mode == itemMode
                        Button {
                            onSelectHistoryMode(itemMode)
                        } label: {
                            Text(L10n.historyModeName(itemMode, lang: lang))
                                .font(.system(size: 10.5 * s, weight: selected ? .semibold : .medium))
                                .foregroundColor(selected ? primaryText : secondaryText)
                                .padding(.horizontal, 7 * s)
                                .padding(.vertical, 3 * s)
                                .background(selected ? cardBg : Color.clear)
                                .cornerRadius(5 * s)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2 * s)
                .background(mutedBg)
                .cornerRadius(7 * s)
            }

            if isEmpty {
                Text(L10n.noModelStepsYet(lang))
                    .font(.system(size: 12 * s))
                    .foregroundColor(secondaryText)
                    .padding(.vertical, 2 * s)
            } else {
                HStack(spacing: 8 * s) {
                    Text(L10n.columnIndex(mode, lang: lang))
                        .frame(width: 44 * s, alignment: .leading)
                    Text(L10n.columnContext(lang))
                    Spacer()
                    Text(L10n.columnDelta(lang))
                }
                .font(.system(size: 10 * s, weight: .medium))
                .foregroundColor(secondaryText.opacity(0.85))
                .padding(.top, 2 * s)

                VStack(spacing: 4 * s) {
                    if mode == .messages {
                        ForEach(messages) { turn in
                            historyRow(
                                indexText: "#\(turn.turnIndex)",
                                totalTokens: turn.contextTokens,
                                delta: turn.delta,
                                compacted: turn.hadCompaction
                            )
                        }
                    } else {
                        ForEach(steps) { step in
                            historyRow(
                                indexText: "#\(step.stepIndex)",
                                totalTokens: step.contextTokens,
                                delta: step.delta,
                                compacted: step.isCompaction
                            )
                        }
                    }
                }
            }
        }
        .padding(10 * s)
        .background(cardBg)
        .cornerRadius(9 * s)
        .overlay(
            RoundedRectangle(cornerRadius: 9 * s)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private func historyRow(indexText: String, totalTokens: Int, delta: Int, compacted: Bool) -> some View {
        HStack(spacing: 6 * s) {
            Text(indexText)
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(secondaryText)
                .frame(width: 44 * s, alignment: .leading)

            Text(RingViewModel.formatNumber(totalTokens))
                .font(.system(size: 12 * s, weight: .medium, design: .monospaced))
                .foregroundColor(primaryText)

            if compacted {
                Text(L10n.compactedPill(lang))
                    .font(.system(size: 10 * s, weight: .semibold))
                    .foregroundColor(ContextZone.amber.accentColor)
                    .padding(.horizontal, 5 * s)
                    .padding(.vertical, 1.5 * s)
                    .background(ContextZone.amber.pillBackground)
                    .cornerRadius(4 * s)
            }

            Spacer()

            Text(RingViewModel.formatSignedNumber(delta))
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(delta < 0 ? ContextZone.amber.accentColor : secondaryText)
        }
        .padding(.vertical, compacted ? 2 * s : 0)
        .padding(.horizontal, compacted ? 4 * s : 0)
        .background(compacted ? ContextZone.amber.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(5 * s)
    }

    // MARK: - Stats Tab Cards

    private var currentChatStatsCard: some View {
        let stats = viewModel.hasTokenData ? viewModel.stats : nil
        let ss = stats?.sessionStats ?? .empty
        let b = stats?.breakdown ?? .empty

        return VStack(alignment: .leading, spacing: 8 * s) {
            Text(L10n.statsCurrentChatTitle(lang))
                .font(.system(size: 12 * s, weight: .semibold))
                .foregroundColor(secondaryText)

            if stats == nil {
                Text(L10n.noTokenLogsBanner(lang))
                    .font(.system(size: 12 * s))
                    .foregroundColor(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6 * s) {
                    HStack(spacing: 6 * s) {
                        metricCell(label: L10n.statsFreshInput(lang), value: RingViewModel.formatCompactTokens(ss.totalInputTokens))
                        metricCell(label: L10n.statsFromCache(lang), value: RingViewModel.formatCompactTokens(ss.totalCacheReadTokens))
                    }
                    HStack(spacing: 6 * s) {
                        metricCell(label: L10n.statsOutput(lang), value: RingViewModel.formatCompactTokens(ss.totalOutputTokens))
                        metricCell(label: L10n.statsAvgCache(lang), value: "\(ss.avgCacheHitPercent)%")
                    }
                    HStack(spacing: 6 * s) {
                        metricCell(label: L10n.statsDuration(lang), value: L10n.formatDuration(seconds: ss.durationSeconds, lang: lang))
                        metricCell(label: "\(L10n.statsMedia(lang)) / \(L10n.statsErrors(lang))", value: "\(ss.mediaCount) / \(ss.errorCount)")
                    }
                }

                if b.toolCallsCount > 0 {
                    let topNames = b.topTools.map { "\($0.name)×\($0.count)" }.joined(separator: ", ")
                    let text = topNames.isEmpty ? "\(b.toolCallsCount)" : "\(b.toolCallsCount) (\(topNames))"
                    HStack(spacing: 6 * s) {
                        Text(L10n.statsTools(lang))
                            .font(.system(size: 11 * s))
                            .foregroundColor(secondaryText)
                        Spacer()
                        Text(text)
                            .font(.system(size: 11 * s, design: .monospaced))
                            .foregroundColor(primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.top, 2 * s)
                }

                if !ss.modelUsage.isEmpty {
                    Divider()
                    Text(L10n.statsModelsInChat(lang))
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundColor(secondaryText)

                    VStack(spacing: 4 * s) {
                        ForEach(ss.modelUsage.prefix(4)) { item in
                            modelUsageRow(item)
                        }
                    }
                }
            }
        }
        .padding(10 * s)
        .background(cardBg)
        .cornerRadius(9 * s)
        .overlay(
            RoundedRectangle(cornerRadius: 9 * s)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private var allChatsPeriodStatsCard: some View {
        let ps = viewModel.periodStats
        return VStack(alignment: .leading, spacing: 8 * s) {
            HStack(spacing: 6 * s) {
                Text(L10n.statsAllChatsTitle(lang))
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundColor(secondaryText)

                Spacer()

                HStack(spacing: 2 * s) {
                    ForEach(StatsPeriod.allCases) { period in
                        let selected = viewModel.statsPeriod == period
                        Button {
                            onSelectStatsPeriod(period)
                        } label: {
                            Text(L10n.statsPeriodName(period, lang: lang))
                                .font(.system(size: 10.5 * s, weight: selected ? .semibold : .medium))
                                .foregroundColor(selected ? primaryText : secondaryText)
                                .padding(.horizontal, 8 * s)
                                .padding(.vertical, 3 * s)
                                .background(selected ? cardBg : Color.clear)
                                .cornerRadius(5 * s)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2 * s)
                .background(mutedBg)
                .cornerRadius(7 * s)
            }

            if ps.modelSteps == 0 {
                Text(L10n.statsNoPeriodActivity(lang))
                    .font(.system(size: 12 * s))
                    .foregroundColor(secondaryText)
                    .padding(.vertical, 2 * s)
            } else {
                VStack(spacing: 6 * s) {
                    HStack(spacing: 6 * s) {
                        metricCell(label: L10n.statsActiveChats(lang), value: "\(ps.activeChats)")
                        metricCell(label: L10n.statsModelCalls(lang), value: "\(ps.modelSteps)")
                    }
                    HStack(spacing: 6 * s) {
                        metricCell(
                            label: L10n.statsInputPlusOutput(lang),
                            value: "\(RingViewModel.formatCompactTokens(ps.totalInputTokens)) + \(RingViewModel.formatCompactTokens(ps.totalOutputTokens))"
                        )
                        metricCell(
                            label: L10n.statsFromCache(lang),
                            value: "\(RingViewModel.formatCompactTokens(ps.totalCacheReadTokens)) (\(ps.avgCacheHitPercent)%)"
                        )
                    }
                }

                if !ps.modelUsage.isEmpty {
                    VStack(spacing: 4 * s) {
                        ForEach(ps.modelUsage.prefix(4)) { item in
                            modelUsageRow(item)
                        }
                    }
                    .padding(.top, 2 * s)
                }
            }
        }
        .padding(10 * s)
        .background(cardBg)
        .cornerRadius(9 * s)
        .overlay(
            RoundedRectangle(cornerRadius: 9 * s)
                .stroke(borderStroke, lineWidth: 1)
        )
    }

    private func modelUsageRow(_ item: ModelUsageCount) -> some View {
        HStack(spacing: 6 * s) {
            Text(item.name)
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(L10n.statsStepsShort(item.steps, lang: lang))
                .font(.system(size: 11.5 * s, weight: .semibold, design: .monospaced))
                .foregroundColor(secondaryText)
        }
        .padding(.horizontal, 8 * s)
        .padding(.vertical, 4 * s)
        .background(mutedBg)
        .cornerRadius(6 * s)
    }
}
