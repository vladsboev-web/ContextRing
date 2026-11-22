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
        onCycleTheme: @escaping () -> Void,
        onSelectDetailTab: @escaping (DetailTab) -> Void,
        onSelectStatsPeriod: @escaping (StatsPeriod) -> Void,
        onSelectHistoryMode: @escaping (HistoryViewMode) -> Void,
        onSelectChatFromStats: @escaping (String) -> Void,
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
            onCycleTheme: onCycleTheme,
            onSelectDetailTab: onSelectDetailTab,
            onSelectStatsPeriod: onSelectStatsPeriod,
            onSelectHistoryMode: onSelectHistoryMode,
            onSelectChatFromStats: onSelectChatFromStats,
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
        let bounds = OverlayPositioning.screenBounds(near: ringFrame)
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
        let origin = OverlayPositioning.popupOrigin(
            for: size,
            near: ringFrame,
            bounds: bounds,
            gap: 6,
            horizontalOverlap: 8,
            inset: inset
        )
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func resizeForCurrentAnchor() {
        guard isVisible, let ringFrame = lastAnchorRingFrame else { return }
        reposition(near: ringFrame)
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
        let bounds = OverlayPositioning.screenBounds(near: buttonScreenRect)
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

    @State private var hoveredRowId: String?

    private var s: CGFloat { viewModel.effectiveDetailScale }
    private var lang: ResolvedLanguage { viewModel.resolvedLanguage }
    private var darkTheme: Bool { viewModel.effectiveIsDarkTheme }
    private var palette: OverlayPalette { viewModel.palette }

    private var cardBg: Color { palette.dropdownCardBg }
    private var mutedBg: Color { palette.mutedBg }
    private var borderStroke: Color { palette.borderStroke }
    private var primaryText: Color { palette.primaryText }
    private var secondaryText: Color { palette.secondaryText }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2 * s) {
                rowButton(
                    rowId: "__auto__",
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
                            rowId: item.id,
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
        rowId: String,
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRowId == rowId
        let rowBg: Color
        if isSelected {
            rowBg = mutedBg
        } else if isHovered {
            rowBg = darkTheme ? Color.white.opacity(0.11) : Color.black.opacity(0.07)
        } else {
            rowBg = Color.clear
        }

        return Button(action: action) {
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
            .background(rowBg)
            .cornerRadius(6 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRowId = rowId
            } else if hoveredRowId == rowId {
                hoveredRowId = nil
            }
        }
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
    let onCycleTheme: () -> Void
    let onSelectDetailTab: (DetailTab) -> Void
    let onSelectStatsPeriod: (StatsPeriod) -> Void
    let onSelectHistoryMode: (HistoryViewMode) -> Void
    let onSelectChatFromStats: (String) -> Void
    let onCopyHandoff: () -> Void
    let onClose: () -> Void
    let onLayoutSizeMayChange: () -> Void

    @State private var copiedFeedback = false
    @State private var isSystemExpanded = false
    @State private var isFilesExpanded = false
    @State private var isToolsExpanded = false
    @State private var isPeriodModelsExpanded = true
    @State private var isPeriodFilesExpanded = false
    @State private var isPeriodToolsExpanded = false
    @State private var isPeriodChatsExpanded = false
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

    private var palette: OverlayPalette {
        viewModel.palette
    }

    private var surfaceBg: Color { palette.surfaceBg }
    private var cardBg: Color { palette.cardBg }
    private var mutedBg: Color { palette.mutedBg }
    private var borderStroke: Color { palette.borderStroke }
    private var primaryText: Color { palette.primaryText }
    private var secondaryText: Color { palette.secondaryText }

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
        guard viewModel.hasTokenData, let scoped = viewModel.activeScopedSnapshot else { return nil }
        var parts: [String] = []
        switch viewModel.zone {
        case .red:
            parts.append(L10n.alertRed(lang))
        case .amber:
            parts.append(L10n.alertAmber(lang))
        case .green:
            break
        }
        if scoped.compactionEvents > 0 {
            parts.append(L10n.alertCompactions(scoped.compactionEvents, lang: lang))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            VStack(alignment: .leading, spacing: 10 * s) {
                headerSection
                tabBarSection
                if viewModel.activeDetailTab == .context {
                    chatSwitcherSection
                    scopeSelectorSection
                } else {
                    periodHeaderSection
                }
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
        periodSummaryGrid
        periodActivityCard
    }

    private var themeIconName: String {
        switch viewModel.themePreference {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
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

            Button(action: onCycleTheme) {
                Image(systemName: themeIconName)
                    .font(.system(size: 11.5 * s, weight: .semibold))
                    .foregroundColor(secondaryText)
                    .frame(width: 24 * s, height: 24 * s)
                    .background(mutedBg)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.themeName(viewModel.themePreference, lang: lang))

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

    private var periodHeaderSection: some View {
        HStack(spacing: 6 * s) {
            Text(L10n.statsPeriodHeader(lang))
                .font(.system(size: 11.5 * s, weight: .medium))
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
                            .padding(.horizontal, 10 * s)
                            .padding(.vertical, 4 * s)
                            .background(selected ? cardBg : Color.clear)
                            .cornerRadius(5.5 * s)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2 * s)
            .background(mutedBg)
            .cornerRadius(7 * s)
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

    @ViewBuilder
    private var scopeSelectorSection: some View {
        if viewModel.hasTokenData, let stats = viewModel.stats {
            let showBothGroups = stats.hasManualMode && stats.hasOrchestratorMode
            let showManualSubtabs = stats.hasManualMode && stats.manualModels.count > 1
            let hasPlanner = stats.scopedSnapshots[.orchestratorPlanner] != nil
            let hasExecutor = stats.scopedSnapshots[.orchestratorExecutor] != nil
            let showOrchSubtabs = stats.hasOrchestratorMode && (hasPlanner || hasExecutor)

            if showBothGroups || showManualSubtabs || showOrchSubtabs {
                let effective = viewModel.effectiveScope
                VStack(alignment: .leading, spacing: 5 * s) {
                    if showBothGroups {
                        HStack(spacing: 3 * s) {
                            scopeSegmentButton(
                                title: L10n.scopeAllChat(lang),
                                selected: effective == .allChat
                            ) {
                                viewModel.selectedScope = .allChat
                            }
                            scopeSegmentButton(
                                title: L10n.scopeGroupManual(lang),
                                selected: effective.group == .manual
                            ) {
                                viewModel.selectedScope = .manualAll
                            }
                            scopeSegmentButton(
                                title: L10n.scopeGroupOrchestrator(lang),
                                selected: effective.group == .orchestrator
                            ) {
                                viewModel.selectedScope = .orchestratorAll
                            }
                        }
                        .padding(2.5 * s)
                        .background(mutedBg)
                        .cornerRadius(7 * s)

                        if effective.group == .manual && showManualSubtabs {
                            manualSubtabsBar(stats: stats, singleModeRoot: false, effective: effective)
                        } else if effective.group == .orchestrator && showOrchSubtabs {
                            orchestratorSubtabsBar(hasPlanner: hasPlanner, hasExecutor: hasExecutor, singleModeRoot: false, effective: effective)
                        }
                    } else if showOrchSubtabs {
                        VStack(alignment: .leading, spacing: 4 * s) {
                            Text(L10n.scopeGroupOrchestrator(lang))
                                .font(.system(size: 10.5 * s, weight: .medium))
                                .foregroundColor(secondaryText)
                            orchestratorSubtabsBar(hasPlanner: hasPlanner, hasExecutor: hasExecutor, singleModeRoot: true, effective: effective)
                        }
                    } else if showManualSubtabs {
                        VStack(alignment: .leading, spacing: 4 * s) {
                            Text(L10n.scopeGroupManual(lang))
                                .font(.system(size: 10.5 * s, weight: .medium))
                                .foregroundColor(secondaryText)
                            manualSubtabsBar(stats: stats, singleModeRoot: true, effective: effective)
                        }
                    }
                }
            }
        }
    }

    private func manualSubtabsBar(stats: TranscriptStats, singleModeRoot: Bool, effective: ChatStatsScope) -> some View {
        let isAllSelected = singleModeRoot
            ? (effective == .allChat || effective == .manualAll)
            : (effective == .manualAll)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3 * s) {
                scopeSegmentButton(
                    title: L10n.scopeAllInGroup(lang),
                    selected: isAllSelected,
                    compact: true
                ) {
                    viewModel.selectedScope = singleModeRoot ? .allChat : .manualAll
                }
                ForEach(stats.manualModels) { item in
                    let targetScope = ChatStatsScope.manualModel(item.id)
                    scopeSegmentButton(
                        title: item.shortName,
                        selected: effective == targetScope,
                        compact: true
                    ) {
                        viewModel.selectedScope = targetScope
                    }
                }
            }
        }
        .padding(2.5 * s)
        .background(mutedBg)
        .cornerRadius(7 * s)
    }

    private func orchestratorSubtabsBar(hasPlanner: Bool, hasExecutor: Bool, singleModeRoot: Bool, effective: ChatStatsScope) -> some View {
        let isAllSelected = singleModeRoot
            ? (effective == .allChat || effective == .orchestratorAll)
            : (effective == .orchestratorAll)
        return HStack(spacing: 3 * s) {
            scopeSegmentButton(
                title: L10n.scopeAllInGroup(lang),
                selected: isAllSelected,
                compact: true
            ) {
                viewModel.selectedScope = singleModeRoot ? .allChat : .orchestratorAll
            }
            if hasPlanner {
                scopeSegmentButton(
                    title: L10n.scopeOrchestratorPlanner(lang),
                    selected: effective == .orchestratorPlanner,
                    compact: true
                ) {
                    viewModel.selectedScope = .orchestratorPlanner
                }
            }
            if hasExecutor {
                scopeSegmentButton(
                    title: L10n.scopeOrchestratorExecutor(lang),
                    selected: effective == .orchestratorExecutor,
                    compact: true
                ) {
                    viewModel.selectedScope = .orchestratorExecutor
                }
            }
        }
        .padding(2.5 * s)
        .background(mutedBg)
        .cornerRadius(7 * s)
    }

    private func scopeSegmentButton(
        title: String,
        selected: Bool,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: (compact ? 11 : 11.5) * s, weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? primaryText : secondaryText)
                .lineLimit(1)
                .frame(maxWidth: compact ? nil : .infinity)
                .padding(.horizontal, compact ? 9 * s : 6 * s)
                .padding(.vertical, (compact ? 3.5 : 4) * s)
                .background(selected ? cardBg : Color.clear)
                .cornerRadius(5.5 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let b = viewModel.activeScopedSnapshot?.breakdown ?? .empty
        let denom = max(1, max(viewModel.threshold, viewModel.contextTokens))

        let sysColor = Color(red: 0.56, green: 0.42, blue: 0.96)
        let filesColor = Color(red: 0.20, green: 0.55, blue: 0.96)
        let toolsColor = Color(red: 0.10, green: 0.72, blue: 0.84)
        let assistantColor = Color(red: 0.14, green: 0.72, blue: 0.56)
        let thinkingColor = Color(red: 0.20, green: 0.78, blue: 0.70)
        let userColor = Color(red: 0.95, green: 0.56, blue: 0.18)

        let barSegments: [(tokens: Int, color: Color)] = [
            (b.systemTokens, sysColor),
            (b.filesTokens, filesColor),
            (b.toolsTokens, toolsColor),
            (b.assistantTokens, assistantColor),
            (b.thinkingTokens, thinkingColor),
            (b.userTokens, userColor),
        ]

        let sysSubItems: [(label: String, tokens: Int)] = [
            (L10n.subBasePrompt(lang), b.basePromptTokens),
            (L10n.subSystemMessages(lang), b.systemMessageTokens),
            (L10n.subConversationHistory(lang), b.historyTokens),
            (L10n.subCheckpointSummary(lang), b.checkpointSummaryTokens),
        ].filter { $0.tokens > 0 }

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
                        ForEach(Array(barSegments.enumerated()), id: \.offset) { _, seg in
                            if seg.tokens > 0 {
                                let ratio = CGFloat(seg.tokens) / CGFloat(denom)
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

            if !viewModel.hasTokenData {
                Text("—")
                    .font(.system(size: 11.5 * s, design: .monospaced))
                    .foregroundColor(secondaryText)
            } else {
                VStack(spacing: 2 * s) {
                    if b.systemTokens > 0 {
                        let canExpandSys = sysSubItems.count > 1
                        breakdownRow(
                            color: sysColor,
                            title: L10n.segmentSystem(lang),
                            tokens: b.systemTokens,
                            denom: viewModel.threshold,
                            expandable: canExpandSys,
                            expanded: isSystemExpanded
                        ) {
                            isSystemExpanded.toggle()
                        }

                        if canExpandSys && isSystemExpanded {
                            VStack(spacing: 2 * s) {
                                ForEach(Array(sysSubItems.enumerated()), id: \.offset) { _, sub in
                                    let subPct = viewModel.threshold > 0
                                        ? Int((Double(sub.tokens) / Double(viewModel.threshold) * 100.0).rounded())
                                        : 0
                                    HStack(spacing: 6 * s) {
                                        Text(sub.label)
                                            .font(.system(size: 11 * s))
                                            .foregroundColor(secondaryText)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 4 * s)
                                        Text(RingViewModel.formatK(sub.tokens))
                                            .font(.system(size: 11 * s, design: .monospaced))
                                            .foregroundColor(secondaryText)
                                            .frame(width: 40 * s, alignment: .trailing)
                                        Text("\(subPct)%")
                                            .font(.system(size: 11 * s, design: .monospaced))
                                            .foregroundColor(secondaryText)
                                            .frame(width: 34 * s, alignment: .trailing)
                                    }
                                    .padding(.leading, 18 * s)
                                    .padding(.trailing, 4 * s)
                                    .padding(.vertical, 1.5 * s)
                                }
                            }
                            .padding(.vertical, 3 * s)
                            .background(mutedBg.opacity(0.6))
                            .cornerRadius(6 * s)
                        }
                    }

                    if b.filesTokens > 0 {
                        breakdownRow(
                            color: filesColor,
                            title: L10n.segmentFiles(b.topFiles.count, lang: lang),
                            tokens: b.filesTokens,
                            denom: viewModel.threshold,
                            expandable: !b.topFiles.isEmpty,
                            expanded: isFilesExpanded
                        ) {
                            isFilesExpanded.toggle()
                        }

                        if isFilesExpanded && !b.topFiles.isEmpty {
                            countListBox(items: b.topFiles.map { ($0.name, "\($0.count)×") })
                        }
                    }

                    if b.toolsTokens > 0 {
                        breakdownRow(
                            color: toolsColor,
                            title: L10n.segmentToolsWithCount(b.toolCallsCount, lang: lang),
                            tokens: b.toolsTokens,
                            denom: viewModel.threshold,
                            expandable: !b.topTools.isEmpty,
                            expanded: isToolsExpanded
                        ) {
                            isToolsExpanded.toggle()
                        }

                        if isToolsExpanded && !b.topTools.isEmpty {
                            countListBox(items: b.topTools.map { ($0.name, "\($0.count)×") })
                        }
                    }

                    if b.assistantTokens > 0 {
                        breakdownRow(
                            color: assistantColor,
                            title: L10n.segmentAssistant(lang),
                            tokens: b.assistantTokens,
                            denom: viewModel.threshold
                        )
                    }

                    if b.thinkingTokens > 0 {
                        breakdownRow(
                            color: thinkingColor,
                            title: L10n.segmentThinking(lang),
                            tokens: b.thinkingTokens,
                            denom: viewModel.threshold
                        )
                    }

                    if b.userTokens > 0 {
                        breakdownRow(
                            color: userColor,
                            title: L10n.segmentUserWithMedia(b.mediaCount, lang: lang),
                            tokens: b.userTokens,
                            denom: viewModel.threshold
                        )
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

    @ViewBuilder
    private func breakdownRow(
        color: Color,
        title: String,
        tokens: Int,
        denom: Int,
        expandable: Bool = false,
        expanded: Bool = false,
        onTap: (() -> Void)? = nil
    ) -> some View {
        let pct = denom > 0 ? Int((Double(tokens) / Double(denom) * 100.0).rounded()) : 0
        let content = HStack(spacing: 6 * s) {
            Circle()
                .fill(color)
                .frame(width: 7.5 * s, height: 7.5 * s)
            Text(title)
                .font(.system(size: 11.5 * s, weight: .medium))
                .foregroundColor(primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if expandable {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * s, weight: .semibold))
                    .foregroundColor(secondaryText)
            }
            Spacer(minLength: 4 * s)
            Text(RingViewModel.formatK(tokens))
                .font(.system(size: 11.5 * s, weight: .semibold, design: .monospaced))
                .foregroundColor(primaryText)
                .frame(width: 40 * s, alignment: .trailing)
            Text("\(pct)%")
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(secondaryText)
                .frame(width: 34 * s, alignment: .trailing)
        }
        .padding(.horizontal, 4 * s)
        .padding(.vertical, 3 * s)
        .contentShape(Rectangle())

        if expandable, let onTap {
            Button(action: onTap) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func countListBox(items: [(name: String, countText: String)]) -> some View {
        VStack(spacing: 2.5 * s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6 * s) {
                    Text(item.name)
                        .font(.system(size: 11 * s, design: .monospaced))
                        .foregroundColor(primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6 * s)
                    Text(item.countText)
                        .font(.system(size: 11 * s, weight: .semibold, design: .monospaced))
                        .foregroundColor(secondaryText)
                }
                .padding(.horizontal, 8 * s)
                .padding(.vertical, 2 * s)
            }
        }
        .padding(.vertical, 4 * s)
        .padding(.leading, 10 * s)
        .background(mutedBg.opacity(0.65))
        .cornerRadius(6 * s)
    }

    private var metricsGrid: some View {
        let scoped = viewModel.activeScopedSnapshot
        let session = scoped?.sessionStats ?? .empty
        let mode = viewModel.historyViewMode
        let scope = viewModel.effectiveScope

        let modelTitle = scope.isAggregateScope
            ? L10n.metricPrimaryModel(lang)
            : L10n.metricModelSingle(lang)

        let modelValue: String
        let modelEffort: String?
        if let scoped {
            let rawModel: String
            if scope.isAggregateScope {
                rawModel = !session.primaryModel.isEmpty ? session.primaryModel : scoped.model
            } else {
                rawModel = !scoped.model.isEmpty ? scoped.model : session.primaryModel
            }
            let formatted = RingViewModel.formatModelDisplay(rawModel)
            modelEffort = formatted.effort
            if formatted.name.isEmpty {
                modelValue = "—"
            } else if scope.isAggregateScope && session.otherModelsCount > 0 {
                modelValue = "\(formatted.name) (+\(session.otherModelsCount))"
            } else {
                modelValue = formatted.name
            }
        } else {
            modelValue = "—"
            modelEffort = nil
        }

        let cacheValue: String
        if let scoped {
            let stepCacheK: String
            let stepCachePct: Int
            if mode == .messages, let turn = scoped.recentMessages.first {
                stepCacheK = RingViewModel.formatK(turn.cacheReadTokens)
                stepCachePct = turn.cacheHitPercent
            } else {
                stepCacheK = RingViewModel.formatK(scoped.lastCacheReadTokens)
                stepCachePct = scoped.cacheHitPercent
            }
            cacheValue = "\(stepCacheK) (\(stepCachePct)% · \(session.avgCacheHitPercent)%)"
        } else {
            cacheValue = "—"
        }

        let countPeakValue: String
        if let scoped {
            let countVal = mode == .messages ? session.userMessageCount : scoped.totalModelSteps
            countPeakValue = "\(countVal) / \(RingViewModel.formatK(scoped.peakTokens))"
        } else {
            countPeakValue = "—"
        }

        let ioValue: String
        let durationValue: String
        if scoped != nil {
            ioValue = "\(RingViewModel.formatCompactTokens(session.totalInputTokens)) + \(RingViewModel.formatCompactTokens(session.totalOutputTokens))"
            durationValue = L10n.formatDuration(seconds: session.durationSeconds, lang: lang)
        } else {
            ioValue = "—"
            durationValue = "—"
        }

        return VStack(spacing: 6 * s) {
            HStack(spacing: 6 * s) {
                metricCell(label: modelTitle, badge: modelEffort, value: modelValue)
                metricCell(label: L10n.metricLastDelta(mode, lang: lang), value: viewModel.formattedDelta)
            }
            HStack(spacing: 6 * s) {
                metricCell(label: L10n.metricCacheCombined(lang), value: cacheValue)
                metricCell(label: L10n.metricCountPeak(mode, lang: lang), value: countPeakValue)
            }
            HStack(spacing: 6 * s) {
                metricCell(label: L10n.metricInputOutput(lang), value: ioValue)
                metricCell(label: L10n.statsDuration(lang), value: durationValue)
            }
        }
    }

    private func metricCell(label: String, badge: String? = nil, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * s) {
            HStack(spacing: 4 * s) {
                Text(label)
                    .font(.system(size: 11 * s))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)
                if let badge, !badge.isEmpty {
                    Spacer(minLength: 2 * s)
                    Text(badge)
                        .font(.system(size: 9.5 * s, weight: .semibold))
                        .foregroundColor(Color(red: 0.24, green: 0.52, blue: 0.96))
                        .padding(.horizontal, 5 * s)
                        .padding(.vertical, 1 * s)
                        .background(Color(red: 0.24, green: 0.52, blue: 0.96).opacity(0.14))
                        .cornerRadius(4 * s)
                }
            }
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
        let scoped = viewModel.activeScopedSnapshot
        let messages = Array((scoped?.recentMessages ?? []).prefix(5))
        let steps = Array((scoped?.recentSteps ?? []).prefix(5))
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
                                compacted: turn.hadCompaction,
                                modelSwitched: turn.hadModelSwitch,
                                effortSwitched: turn.hadEffortSwitch
                            )
                        }
                    } else {
                        ForEach(steps) { step in
                            historyRow(
                                indexText: "#\(step.stepIndex)",
                                totalTokens: step.contextTokens,
                                delta: step.delta,
                                compacted: step.isCompaction,
                                modelSwitched: step.isModelSwitch,
                                effortSwitched: step.isEffortSwitch
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

    private func historyRow(
        indexText: String,
        totalTokens: Int,
        delta: Int,
        compacted: Bool,
        modelSwitched: Bool,
        effortSwitched: Bool
    ) -> some View {
        let hasEventBadge = compacted || modelSwitched || effortSwitched
        let rowBg: Color
        if compacted {
            rowBg = ContextZone.amber.accentColor.opacity(0.08)
        } else if modelSwitched {
            rowBg = Color(red: 0.24, green: 0.52, blue: 0.96).opacity(0.08)
        } else if effortSwitched {
            rowBg = Color(red: 0.56, green: 0.42, blue: 0.96).opacity(0.08)
        } else {
            rowBg = Color.clear
        }

        return HStack(spacing: 6 * s) {
            Text(indexText)
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(secondaryText)
                .frame(width: 44 * s, alignment: .leading)

            Text(RingViewModel.formatNumber(totalTokens))
                .font(.system(size: 12 * s, weight: .medium, design: .monospaced))
                .foregroundColor(primaryText)

            if compacted {
                historyEventBadge(
                    text: L10n.compactedPill(lang),
                    color: ContextZone.amber.accentColor
                )
            }
            if modelSwitched {
                historyEventBadge(
                    text: L10n.modelSwitchPill(lang),
                    color: Color(red: 0.24, green: 0.52, blue: 0.96)
                )
            }
            if effortSwitched {
                historyEventBadge(
                    text: L10n.effortSwitchPill(lang),
                    color: Color(red: 0.56, green: 0.42, blue: 0.96)
                )
            }

            Spacer()

            Text(RingViewModel.formatSignedNumber(delta))
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(delta < 0 ? ContextZone.amber.accentColor : secondaryText)
        }
        .padding(.vertical, hasEventBadge ? 2 * s : 0)
        .padding(.horizontal, hasEventBadge ? 4 * s : 0)
        .background(rowBg)
        .cornerRadius(5 * s)
    }

    private func historyEventBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10 * s, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5 * s)
            .padding(.vertical, 1.5 * s)
            .background(color.opacity(0.16))
            .cornerRadius(4 * s)
    }

    // MARK: - Stats Tab Cards (Global 24h / 7d Analytics)

    private var periodSummaryGrid: some View {
        let ps = viewModel.periodStats
        if ps.modelSteps == 0 {
            return AnyView(
                Text(L10n.statsNoPeriodActivity(lang))
                    .font(.system(size: 12 * s))
                    .foregroundColor(secondaryText)
                    .padding(10 * s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBg)
                    .cornerRadius(9 * s)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9 * s)
                            .stroke(borderStroke, lineWidth: 1)
                    )
            )
        }

        let requestsText = ps.compactionEvents > 0
            ? "\(ps.modelSteps) · ⚡ \(ps.compactionEvents)"
            : "\(ps.modelSteps)"

        return AnyView(
            VStack(spacing: 6 * s) {
                HStack(spacing: 6 * s) {
                    metricCell(label: L10n.statsChatsAndMessages(lang), value: "\(ps.activeChats) / \(ps.userMessages)")
                    metricCell(label: L10n.statsModelCalls(lang), value: requestsText)
                }
                HStack(spacing: 6 * s) {
                    metricCell(label: L10n.statsFreshInput(lang), value: RingViewModel.formatCompactTokens(ps.totalInputTokens))
                    metricCell(
                        label: L10n.statsFromCache(lang),
                        value: "\(RingViewModel.formatCompactTokens(ps.totalCacheReadTokens)) (\(ps.avgCacheHitPercent)%)"
                    )
                }
                HStack(spacing: 6 * s) {
                    metricCell(label: L10n.statsOutput(lang), value: RingViewModel.formatCompactTokens(ps.totalOutputTokens))
                    metricCell(label: L10n.statsActiveTime(lang), value: L10n.formatDuration(seconds: ps.totalDurationSeconds, lang: lang))
                }
            }
        )
    }

    @ViewBuilder
    private var periodActivityCard: some View {
        let ps = viewModel.periodStats
        if ps.modelSteps > 0 {
            let sysColor = Color(red: 0.56, green: 0.42, blue: 0.96)
            let filesColor = Color(red: 0.20, green: 0.55, blue: 0.96)
            let toolsColor = Color(red: 0.10, green: 0.72, blue: 0.84)
            let chatsColor = Color(red: 0.14, green: 0.72, blue: 0.56)

            VStack(alignment: .leading, spacing: 6 * s) {
                Text(L10n.statsPeriodActivityTitle(lang))
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundColor(secondaryText)

                if !ps.modelUsage.isEmpty {
                    periodSectionHeader(
                        color: sysColor,
                        title: L10n.statsPeriodModels(ps.modelUsage.count, lang: lang),
                        trailing: L10n.statsStepsShort(ps.modelSteps, lang: lang),
                        expanded: isPeriodModelsExpanded
                    ) {
                        isPeriodModelsExpanded.toggle()
                    }

                    if isPeriodModelsExpanded {
                        VStack(spacing: 4 * s) {
                            ForEach(ps.modelUsage) { item in
                                modelUsageRow(item)
                            }
                        }
                        .padding(.leading, 10 * s)
                    }
                }

                if !ps.topFiles.isEmpty {
                    periodSectionHeader(
                        color: filesColor,
                        title: L10n.statsPeriodFiles(ps.topFiles.count, lang: lang),
                        trailing: L10n.statsTouchesShort(ps.totalFileTouches, lang: lang),
                        expanded: isPeriodFilesExpanded
                    ) {
                        isPeriodFilesExpanded.toggle()
                    }

                    if isPeriodFilesExpanded {
                        countListBox(items: ps.topFiles.map { ($0.name, "\($0.count)×") })
                    }
                }

                if !ps.topTools.isEmpty {
                    periodSectionHeader(
                        color: toolsColor,
                        title: L10n.statsPeriodTools(ps.topTools.count, lang: lang),
                        trailing: L10n.statsCallsShort(ps.totalToolCalls, lang: lang),
                        expanded: isPeriodToolsExpanded
                    ) {
                        isPeriodToolsExpanded.toggle()
                    }

                    if isPeriodToolsExpanded {
                        countListBox(items: ps.topTools.map { ($0.name, "\($0.count)×") })
                    }
                }

                if !ps.activeChatItems.isEmpty {
                    periodSectionHeader(
                        color: chatsColor,
                        title: L10n.statsPeriodChats(ps.activeChatItems.count, lang: lang),
                        trailing: L10n.statsPeakShort(RingViewModel.formatK(ps.peakTokens), lang: lang),
                        expanded: isPeriodChatsExpanded
                    ) {
                        isPeriodChatsExpanded.toggle()
                    }

                    if isPeriodChatsExpanded {
                        VStack(spacing: 3 * s) {
                            ForEach(ps.activeChatItems) { chat in
                                Button {
                                    onSelectChatFromStats(chat.id)
                                } label: {
                                    HStack(spacing: 6 * s) {
                                        Text(chat.title)
                                            .font(.system(size: 11 * s))
                                            .foregroundColor(primaryText)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 6 * s)
                                        Text(chat.peakTokens > 0 ? RingViewModel.formatK(chat.peakTokens) : "—")
                                            .font(.system(size: 11 * s, weight: .semibold, design: .monospaced))
                                            .foregroundColor(secondaryText)
                                    }
                                    .padding(.horizontal, 8 * s)
                                    .padding(.vertical, 4 * s)
                                    .background(mutedBg)
                                    .cornerRadius(6 * s)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 10 * s)
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
    }

    private func periodSectionHeader(
        color: Color,
        title: String,
        trailing: String,
        expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6 * s) {
                Circle()
                    .fill(color)
                    .frame(width: 7.5 * s, height: 7.5 * s)
                Text(title)
                    .font(.system(size: 11.5 * s, weight: .medium))
                    .foregroundColor(primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * s, weight: .semibold))
                    .foregroundColor(secondaryText)
                Spacer(minLength: 4 * s)
                Text(trailing)
                    .font(.system(size: 11.5 * s, weight: .semibold, design: .monospaced))
                    .foregroundColor(secondaryText)
            }
            .padding(.horizontal, 4 * s)
            .padding(.vertical, 3.5 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelUsageRow(_ item: ModelUsageCount) -> some View {
        let display = RingViewModel.formatModelDisplay(item.name)
        let stepsPart = L10n.statsStepsShort(item.steps, lang: lang)
        let outPart = item.outputTokens > 0 ? " · \(RingViewModel.formatCompactTokens(item.outputTokens))" : ""
        return HStack(spacing: 6 * s) {
            Text(display.name.isEmpty ? item.name : display.name)
                .font(.system(size: 11.5 * s, design: .monospaced))
                .foregroundColor(primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let effort = display.effort {
                Text(effort)
                    .font(.system(size: 9.5 * s, weight: .semibold))
                    .foregroundColor(Color(red: 0.24, green: 0.52, blue: 0.96))
                    .padding(.horizontal, 5 * s)
                    .padding(.vertical, 1 * s)
                    .background(Color(red: 0.24, green: 0.52, blue: 0.96).opacity(0.14))
                    .cornerRadius(4 * s)
            }
            Spacer()
            Text(stepsPart + outPart)
                .font(.system(size: 11.5 * s, weight: .semibold, design: .monospaced))
                .foregroundColor(secondaryText)
        }
        .padding(.horizontal, 8 * s)
        .padding(.vertical, 4 * s)
        .background(mutedBg)
        .cornerRadius(6 * s)
    }
}
