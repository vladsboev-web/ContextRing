import ApplicationServices
import Cocoa
import Combine
import Darwin
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum PrefKeys {
        static let threshold = "contextThresholdTokens"
        static let ringBaseSize = "ringBaseSize"
        static let strokeBaseWidth = "strokeBaseWidth"
        static let fontSizeScale = "fontSizeScale"
        static let hoverFontScale = "hoverFontScale"
        static let detailFontScale = "detailFontScale"
        static let showPercentInside = "showPercentInside"
        static let ringStyle = "ringStyle"
        static let themePreference = "themePreference"
        static let scaleWithAntigravityZoom = "scaleWithAntigravityZoom"
        static let referenceZoomLevel = "referenceZoomLevel"
        static let positionMode = "positionMode"
        static let windowedEdgeAnchor = "windowedEdgeAnchorJSON"
        static let fullscreenEdgeAnchor = "fullscreenEdgeAnchorJSON"
        static let freeAbsoluteAnchor = "freeAbsoluteAnchorJSON"
        static let launchMode = "launchMode"
        static let languagePreference = "languagePreference"
        static let historyViewMode = "historyViewMode"
    }

    private let viewModel = RingViewModel()
    private let dataReader = AntigravityDataReader()
    private let windowTracker = AntigravityWindowTracker()

    private var ringPanel: RingPanel?
    private var hoverPanel: HoverTooltipPanel?
    private var detailPanel: DetailPopoverPanel?
    private var chatDropdownPanel: ChatDropdownPanel?
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?

    private var fileWatchers: [String: (fd: Int32, source: DispatchSourceFileSystemObject)] = [:]
    private var fileEventWorkItem: DispatchWorkItem?
    private var activeConversationId: String?

    private var hoverWorkItem: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var terminationObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?
    private var accessibilityPollTimer: Timer?

    private var lastSnapshot: WindowSnapshot?
    private var lastKnownAntigravitySnapshot: WindowSnapshot?
    private var lastAntigravityWindowTitle: String = ""
    private var isSettingsWindowOpen = false
    private var isUserInteractingWithRing = false
    private var cancellables = Set<AnyCancellable>()

    private var isMonitoringActive: Bool {
        (lastSnapshot?.isVisible == true) || isSettingsWindowOpen
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()
        loadSettings()
        viewModel.accessibilityGranted = AXIsProcessTrusted()
        reconcileLaunchAgentOnStartup()
        setupStatusItem()
        setupPanels()
        setupTerminationWatcher()
        setupAppActivationWatcher()
        refreshData(includeRecentList: true)
        setupTracker()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopFileWatchers()
        hoverWorkItem?.cancel()
        removeDetailMonitors()
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
            self.appActiveObserver = nil
        }
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        windowTracker.stop()
    }

    // MARK: - Settings Persistence

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKeys.threshold: 200_000,
            PrefKeys.ringBaseSize: 40.0,
            PrefKeys.strokeBaseWidth: 3.5,
            PrefKeys.fontSizeScale: 1.0,
            PrefKeys.hoverFontScale: 1.0,
            PrefKeys.detailFontScale: 1.0,
            PrefKeys.showPercentInside: true,
            PrefKeys.ringStyle: RingStyle.classic.rawValue,
            PrefKeys.themePreference: ThemePreference.auto.rawValue,
            PrefKeys.scaleWithAntigravityZoom: true,
            PrefKeys.positionMode: PositionMode.snapToEdges.rawValue,
            PrefKeys.launchMode: LaunchMode.withAntigravity.rawValue,
            PrefKeys.languagePreference: AppLanguagePreference.system.rawValue,
            PrefKeys.historyViewMode: HistoryViewMode.messages.rawValue,
        ])
    }

    private func loadSettings() {
        let d = UserDefaults.standard

        let savedThreshold = d.integer(forKey: PrefKeys.threshold)
        viewModel.threshold = savedThreshold >= 10_000 ? min(savedThreshold, 10_000_000) : 200_000

        viewModel.ringBaseSize = CGFloat(min(max(d.double(forKey: PrefKeys.ringBaseSize), 26), 64))
        viewModel.strokeBaseWidth = CGFloat(min(max(d.double(forKey: PrefKeys.strokeBaseWidth), 2.0), 6.0))
        viewModel.fontSizeScale = CGFloat(min(max(d.double(forKey: PrefKeys.fontSizeScale), 0.70), 1.60))
        viewModel.hoverFontScale = CGFloat(min(max(d.double(forKey: PrefKeys.hoverFontScale), 0.80), 1.80))
        viewModel.detailFontScale = CGFloat(min(max(d.double(forKey: PrefKeys.detailFontScale), 0.80), 1.80))
        viewModel.showPercentInside = d.bool(forKey: PrefKeys.showPercentInside)

        if let styleRaw = d.string(forKey: PrefKeys.ringStyle), let style = RingStyle(rawValue: styleRaw) {
            viewModel.ringStyle = style
        }
        if let themeRaw = d.string(forKey: PrefKeys.themePreference), let theme = ThemePreference(rawValue: themeRaw) {
            viewModel.themePreference = theme
        }
        if let langRaw = d.string(forKey: PrefKeys.languagePreference), let langPref = AppLanguagePreference(rawValue: langRaw) {
            viewModel.languagePreference = langPref
        }
        if let histRaw = d.string(forKey: PrefKeys.historyViewMode), let histMode = HistoryViewMode(rawValue: histRaw) {
            viewModel.historyViewMode = histMode
        }

        viewModel.scaleWithAntigravityZoom = d.bool(forKey: PrefKeys.scaleWithAntigravityZoom)

        let appState = dataReader.readAppState()
        viewModel.zoomLevel = appState.zoomLevel
        viewModel.isDarkTheme = appState.isDarkTheme

        if d.object(forKey: PrefKeys.referenceZoomLevel) != nil {
            viewModel.referenceZoomLevel = d.double(forKey: PrefKeys.referenceZoomLevel)
        } else {
            viewModel.referenceZoomLevel = appState.zoomLevel
            d.set(appState.zoomLevel, forKey: PrefKeys.referenceZoomLevel)
        }

        if let modeRaw = d.string(forKey: PrefKeys.positionMode), let mode = PositionMode(rawValue: modeRaw) {
            viewModel.positionMode = mode
        }

        if let anchor: EdgeAnchor = decodePref(EdgeAnchor.self, key: PrefKeys.windowedEdgeAnchor) {
            viewModel.windowedEdgeAnchor = anchor
        }
        if let anchor: EdgeAnchor = decodePref(EdgeAnchor.self, key: PrefKeys.fullscreenEdgeAnchor) {
            viewModel.fullscreenEdgeAnchor = anchor
        }
        if let absAnchor: AbsoluteAnchor = decodePref(AbsoluteAnchor.self, key: PrefKeys.freeAbsoluteAnchor) {
            viewModel.freeAbsoluteAnchor = absAnchor
        }

        if let launchRaw = d.string(forKey: PrefKeys.launchMode), let mode = LaunchMode(rawValue: launchRaw) {
            viewModel.launchMode = mode
        }
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            viewModel.launchMode = .withSystem
        }
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(viewModel.threshold, forKey: PrefKeys.threshold)
        d.set(Double(viewModel.ringBaseSize), forKey: PrefKeys.ringBaseSize)
        d.set(Double(viewModel.strokeBaseWidth), forKey: PrefKeys.strokeBaseWidth)
        d.set(Double(viewModel.fontSizeScale), forKey: PrefKeys.fontSizeScale)
        d.set(Double(viewModel.hoverFontScale), forKey: PrefKeys.hoverFontScale)
        d.set(Double(viewModel.detailFontScale), forKey: PrefKeys.detailFontScale)
        d.set(viewModel.showPercentInside, forKey: PrefKeys.showPercentInside)
        d.set(viewModel.ringStyle.rawValue, forKey: PrefKeys.ringStyle)
        d.set(viewModel.themePreference.rawValue, forKey: PrefKeys.themePreference)
        d.set(viewModel.scaleWithAntigravityZoom, forKey: PrefKeys.scaleWithAntigravityZoom)
        d.set(viewModel.referenceZoomLevel, forKey: PrefKeys.referenceZoomLevel)
        d.set(viewModel.positionMode.rawValue, forKey: PrefKeys.positionMode)
        d.set(viewModel.launchMode.rawValue, forKey: PrefKeys.launchMode)
        d.set(viewModel.languagePreference.rawValue, forKey: PrefKeys.languagePreference)
        d.set(viewModel.historyViewMode.rawValue, forKey: PrefKeys.historyViewMode)
        encodePref(viewModel.windowedEdgeAnchor, key: PrefKeys.windowedEdgeAnchor)
        encodePref(viewModel.fullscreenEdgeAnchor, key: PrefKeys.fullscreenEdgeAnchor)
        if let free = viewModel.freeAbsoluteAnchor {
            encodePref(free, key: PrefKeys.freeAbsoluteAnchor)
        } else {
            d.removeObject(forKey: PrefKeys.freeAbsoluteAnchor)
        }
    }

    private func reconcileLaunchAgentOnStartup() {
        if viewModel.launchMode == .withAntigravity {
            try? LaunchAgentManager.install(appBundlePath: Bundle.main.bundlePath, onlyIfChanged: true)
        } else {
            LaunchAgentManager.uninstall()
        }
    }

    private func decodePref<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encodePref<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "ContextRing")
            button.imagePosition = .imageLeading
            button.title = " —"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        viewModel.$hasTokenData
            .combineLatest(viewModel.$stats, viewModel.$threshold, viewModel.$selectedScope)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.updateStatusBarTitle()
            }
            .store(in: &cancellables)
    }

    private func setupPanels() {
        let ring = RingPanel(
            viewModel: viewModel,
            onMouseDown: { [weak self] in
                self?.isUserInteractingWithRing = true
                self?.cancelHoverTooltip()
            },
            onDragStarted: { [weak self] in
                self?.isUserInteractingWithRing = true
                self?.cancelHoverTooltip()
                self?.closeDetailPanel()
            },
            onDragFinished: { [weak self] newOrigin in
                guard let self else { return }
                self.isUserInteractingWithRing = false
                self.saveAnchor(for: newOrigin)
                if let snapshot = self.currentPositionSnapshot() {
                    self.positionRing(inside: snapshot)
                }
            },
            onClick: { [weak self] in
                guard let self else { return }
                self.isUserInteractingWithRing = false
                self.cancelHoverTooltip()
                self.toggleDetailPanel()
            },
            onHoverChanged: { [weak self] hovering in
                self?.handleHoverChanged(hovering)
            }
        )
        ring.orderOut(nil)
        ringPanel = ring

        let hover = HoverTooltipPanel(viewModel: viewModel)
        hover.orderOut(nil)
        hoverPanel = hover

        let detail = DetailPopoverPanel(
            viewModel: viewModel,
            onToggleChatDropdown: { [weak self] buttonRect in
                self?.toggleChatDropdown(below: buttonRect)
            },
            onSelectAutoMode: { [weak self] in
                self?.selectConversation(nil)
            },
            onCycleTheme: { [weak self] in
                self?.cycleThemePreference()
            },
            onSelectDetailTab: { [weak self] tab in
                self?.selectDetailTab(tab)
            },
            onSelectStatsPeriod: { [weak self] period in
                self?.selectStatsPeriod(period)
            },
            onSelectHistoryMode: { [weak self] mode in
                self?.selectHistoryMode(mode)
            },
            onSelectChatFromStats: { [weak self] convId in
                self?.selectConversationFromStats(convId)
            },
            onCopyHandoff: { [weak self] in
                self?.copyHandoffPrompt()
            },
            onClose: { [weak self] in
                self?.closeDetailPanel()
            }
        )
        detail.orderOut(nil)
        detailPanel = detail

        let dropdown = ChatDropdownPanel(viewModel: viewModel) { [weak self] convId in
            self?.closeChatDropdown()
            self?.selectConversation(convId)
        }
        dropdown.orderOut(nil)
        chatDropdownPanel = dropdown
    }

    private func setupTerminationWatcher() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self,
                  self.viewModel.launchMode != .withSystem,
                  let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AntigravityWindowTracker.targetBundleId else {
                return
            }
            NSApp.terminate(nil)
        }
    }

    private func setupAppActivationWatcher() {
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recheckAccessibilityTrust()
        }
    }

    private func recheckAccessibilityTrust() {
        let trusted = AXIsProcessTrusted()
        if viewModel.accessibilityGranted != trusted {
            viewModel.accessibilityGranted = trusted
            windowTracker.refresh(forceEmit: true)
        }
        if trusted {
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
        }
    }

    private func updateAccessibilityPollTimer() {
        guard isSettingsWindowOpen && !viewModel.accessibilityGranted else {
            accessibilityPollTimer?.invalidate()
            accessibilityPollTimer = nil
            return
        }
        guard accessibilityPollTimer == nil else { return }
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recheckAccessibilityTrust()
        }
    }

    private func setupTracker() {
        windowTracker.onUpdate = { [weak self] snapshot, trusted in
            self?.handleWindowUpdate(snapshot: snapshot, accessibilityTrusted: trusted)
        }
        windowTracker.start()
    }

    // MARK: - Event-Driven File Watchers

    private func syncFileWatchers() {
        guard isMonitoringActive else {
            stopFileWatchers()
            return
        }

        var desiredPaths = Set<String>()
        let fm = FileManager.default

        for path in [
            dataReader.dbFilePath,
            dataReader.dbWalFilePath,
            dataReader.appStorageFilePath,
            dataReader.userSettingsFilePath,
            dataReader.brainDirectoryPath,
        ] {
            if fm.fileExists(atPath: path) {
                desiredPaths.insert(path)
            }
        }
        if !fm.fileExists(atPath: dataReader.dbWalFilePath) {
            let dbDir = URL(fileURLWithPath: dataReader.dbFilePath).deletingLastPathComponent().path
            if fm.fileExists(atPath: dbDir) {
                desiredPaths.insert(dbDir)
            }
        }

        if let convId = activeConversationId {
            if let transcriptPath = dataReader.transcriptFilePath(forConversationId: convId) {
                desiredPaths.insert(transcriptPath)
            } else {
                let logsDir = URL(fileURLWithPath: dataReader.brainDirectoryPath)
                    .appendingPathComponent(convId)
                    .appendingPathComponent(".system_generated/logs").path
                if fm.fileExists(atPath: logsDir) {
                    desiredPaths.insert(logsDir)
                }
            }
        }

        for existingPath in Array(fileWatchers.keys) where !desiredPaths.contains(existingPath) {
            removeFileWatcher(forPath: existingPath)
        }

        for path in desiredPaths where fileWatchers[path] == nil {
            addFileWatcher(forPath: path)
        }
    }

    private func addFileWatcher(forPath path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        source.setCancelHandler {
            close(fd)
        }
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.removeFileWatcher(forPath: path)
            }
            self.scheduleFileEventRefresh()
        }
        fileWatchers[path] = (fd: fd, source: source)
        source.resume()
    }

    private func removeFileWatcher(forPath path: String) {
        guard let entry = fileWatchers.removeValue(forKey: path) else { return }
        entry.source.cancel()
    }

    private func stopFileWatchers() {
        fileEventWorkItem?.cancel()
        fileEventWorkItem = nil
        for (_, entry) in fileWatchers {
            entry.source.cancel()
        }
        fileWatchers.removeAll()
    }

    private func scheduleFileEventRefresh() {
        guard isMonitoringActive else { return }
        fileEventWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleFileSystemEvent()
        }
        fileEventWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func handleFileSystemEvent() {
        guard isMonitoringActive else { return }
        refreshData(includeRecentList: viewModel.isDetailOpen || viewModel.isChatDropdownOpen)
        if viewModel.isDetailOpen && viewModel.activeDetailTab == .stats {
            refreshPeriodStats()
        }
        syncFileWatchers()
    }

    // MARK: - Hover, Detail Popover & Chat Dropdown

    private func handleHoverChanged(_ hovering: Bool) {
        if isUserInteractingWithRing {
            if viewModel.isHoveringRing { viewModel.isHoveringRing = false }
            hoverPanel?.orderOut(nil)
            return
        }

        if viewModel.isHoveringRing != hovering {
            viewModel.isHoveringRing = hovering
        }
        hoverWorkItem?.cancel()
        hoverWorkItem = nil

        guard hovering, !viewModel.isDetailOpen else {
            hoverPanel?.orderOut(nil)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isUserInteractingWithRing,
                  self.viewModel.isHoveringRing,
                  !self.viewModel.isDetailOpen,
                  let ringFrame = self.ringPanel?.frame,
                  self.ringPanel?.isVisible == true else {
                return
            }
            self.refreshData(includeRecentList: false)
            self.hoverPanel?.show(near: ringFrame)
        }
        hoverWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func cancelHoverTooltip() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        if viewModel.isHoveringRing {
            viewModel.isHoveringRing = false
        }
        hoverPanel?.orderOut(nil)
    }

    private func toggleDetailPanel() {
        if viewModel.isDetailOpen {
            closeDetailPanel()
        } else {
            openDetailPanel()
        }
    }

    private func openDetailPanel() {
        guard let ringFrame = ringPanel?.frame, ringPanel?.isVisible == true else { return }
        refreshData(includeRecentList: true)
        if viewModel.activeDetailTab == .stats {
            refreshPeriodStats()
        }
        viewModel.isDetailOpen = true
        detailPanel?.show(near: ringFrame)
        installDetailMonitors()
    }

    private func closeDetailPanel() {
        closeChatDropdown()
        removeDetailMonitors()
        if viewModel.isDetailOpen {
            viewModel.isDetailOpen = false
        }
        detailPanel?.orderOut(nil)
    }

    private func toggleChatDropdown(below buttonScreenRect: CGRect) {
        if viewModel.isChatDropdownOpen {
            closeChatDropdown()
        } else {
            refreshData(includeRecentList: true)
            viewModel.isChatDropdownOpen = true
            chatDropdownPanel?.show(below: buttonScreenRect)
        }
    }

    private func closeChatDropdown() {
        if viewModel.isChatDropdownOpen {
            viewModel.isChatDropdownOpen = false
        }
        chatDropdownPanel?.orderOut(nil)
    }

    private func installDetailMonitors() {
        removeDetailMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.viewModel.isDetailOpen else { return }
            let loc = NSEvent.mouseLocation
            let inDetail = self.detailPanel?.frame.contains(loc) ?? false
            let inDropdown = (self.viewModel.isChatDropdownOpen && (self.chatDropdownPanel?.frame.contains(loc) ?? false))
            let inRing = self.ringPanel?.frame.contains(loc) ?? false

            if !inDetail && !inDropdown && !inRing {
                DispatchQueue.main.async {
                    self.closeDetailPanel()
                }
            } else if self.viewModel.isChatDropdownOpen && !inDropdown && inDetail {
                DispatchQueue.main.async {
                    self.closeChatDropdown()
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.viewModel.isDetailOpen else { return event }
            if event.keyCode == 53 {
                if self.viewModel.isChatDropdownOpen {
                    self.closeChatDropdown()
                } else {
                    self.closeDetailPanel()
                }
                return nil
            }
            return event
        }
    }

    private func removeDetailMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    // MARK: - Actions

    private func selectConversation(_ conversationId: String?) {
        viewModel.manualConversationId = conversationId
        refreshData(includeRecentList: true)
        syncFileWatchers()
    }

    private func selectConversationFromStats(_ conversationId: String) {
        viewModel.activeDetailTab = .context
        selectConversation(conversationId)
    }

    private func cycleThemePreference() {
        switch viewModel.themePreference {
        case .auto: viewModel.themePreference = .light
        case .light: viewModel.themePreference = .dark
        case .dark: viewModel.themePreference = .auto
        }
        applyAppearanceAndLayoutChange()
    }

    private func selectHistoryMode(_ mode: HistoryViewMode) {
        viewModel.historyViewMode = mode
        saveSettings()
    }

    private func selectDetailTab(_ tab: DetailTab) {
        viewModel.activeDetailTab = tab
        if tab == .stats {
            refreshPeriodStats()
        }
    }

    private func selectStatsPeriod(_ period: StatsPeriod) {
        viewModel.statsPeriod = period
        refreshPeriodStats()
    }

    private func refreshPeriodStats() {
        let periodStats = dataReader.readPeriodStats(hours: viewModel.statsPeriod.rawValue)
        if viewModel.periodStats != periodStats {
            viewModel.periodStats = periodStats
        }
    }

    private func copyHandoffPrompt() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(L10n.handoffPrompt(viewModel.resolvedLanguage), forType: .string)
    }

    private func applyAppearanceAndLayoutChange() {
        saveSettings()
        settingsController?.updateTitle(lang: viewModel.resolvedLanguage)
        settingsController?.updateAppearance(isDark: viewModel.effectiveIsDarkTheme)
        ringPanel?.updatePanelSize(viewModel.effectivePanelSize)
        if let snapshot = currentPositionSnapshot(), !isUserInteractingWithRing {
            positionRing(inside: snapshot)
        }
        if viewModel.isDetailOpen, let ringFrame = ringPanel?.frame {
            detailPanel?.reposition(near: ringFrame)
        }
    }

    private func captureReferenceZoom() {
        viewModel.referenceZoomLevel = viewModel.zoomLevel
        applyAppearanceAndLayoutChange()
    }

    private func locateSendButtonAndSnap() {
        let lang = viewModel.resolvedLanguage
        guard viewModel.accessibilityGranted else {
            viewModel.sendButtonLocateStatus = L10n.statusNeedAccessibility(lang)
            return
        }
        guard let snapshot = lastKnownAntigravitySnapshot ?? windowTracker.findAnyAntigravitySnapshot() else {
            viewModel.sendButtonLocateStatus = L10n.statusWindowNotFound(lang)
            return
        }

        if let sendRect = windowTracker.locateSendButton(in: snapshot) {
            let panelSize = viewModel.effectivePanelSize
            let targetOrigin = CGPoint(
                x: sendRect.midX - panelSize.width / 2.0,
                y: sendRect.maxY + 10
            )
            let anchor = computeNearestEdgeAnchor(
                panelFrame: CGRect(origin: targetOrigin, size: panelSize),
                windowFrame: snapshot.frame
            )
            if snapshot.isFullScreen {
                viewModel.fullscreenEdgeAnchor = anchor
            } else {
                viewModel.windowedEdgeAnchor = anchor
                viewModel.positionMode = .snapToEdges
            }
            viewModel.sendButtonLocateStatus = L10n.statusSendFound(L10n.edgeAnchorSummary(anchor, lang: lang), lang: lang)
            applyAppearanceAndLayoutChange()
        } else {
            viewModel.sendButtonLocateStatus = L10n.statusSendNotExposed(lang)
        }
    }

    private func changeLaunchMode(_ newMode: LaunchMode) {
        viewModel.launchAtLoginError = ""
        if newMode == .withSystem {
            LaunchAgentManager.uninstall()
            if #available(macOS 13.0, *) {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    viewModel.launchAtLoginError = L10n.statusLoginItemDenied(error.localizedDescription, lang: viewModel.resolvedLanguage)
                    viewModel.launchMode = .manual
                    saveSettings()
                    return
                }
            }
        } else {
            if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            if newMode == .withAntigravity {
                do {
                    try LaunchAgentManager.install(appBundlePath: Bundle.main.bundlePath, onlyIfChanged: false)
                } catch {
                    viewModel.launchAtLoginError = L10n.statusLaunchAgentError(error.localizedDescription, lang: viewModel.resolvedLanguage)
                    viewModel.launchMode = .manual
                    saveSettings()
                    return
                }
            } else {
                LaunchAgentManager.uninstall()
            }
        }
        viewModel.launchMode = newMode
        saveSettings()
    }

    // MARK: - Window & Data Sync

    private func handleWindowUpdate(snapshot: WindowSnapshot?, accessibilityTrusted: Bool) {
        if viewModel.accessibilityGranted != accessibilityTrusted {
            viewModel.accessibilityGranted = accessibilityTrusted
        }

        let previousSnapshot = lastSnapshot
        let wasRingVisible = ringPanel?.isVisible == true
        lastSnapshot = snapshot

        if let snapshot, snapshot.isVisible {
            let becameVisible = !(previousSnapshot?.isVisible == true) || !wasRingVisible
            lastKnownAntigravitySnapshot = snapshot

            if viewModel.activeWindowTitle != snapshot.title {
                viewModel.activeWindowTitle = snapshot.title
            }
            if viewModel.isFullScreen != snapshot.isFullScreen {
                viewModel.isFullScreen = snapshot.isFullScreen
            }

            if !snapshot.title.isEmpty && snapshot.title != lastAntigravityWindowTitle {
                lastAntigravityWindowTitle = snapshot.title
                if viewModel.manualConversationId != nil {
                    viewModel.manualConversationId = nil
                }
                refreshData(includeRecentList: viewModel.isDetailOpen || viewModel.isChatDropdownOpen)
            } else if becameVisible {
                refreshData(includeRecentList: viewModel.isDetailOpen || viewModel.isChatDropdownOpen)
                if viewModel.isDetailOpen && viewModel.activeDetailTab == .stats {
                    refreshPeriodStats()
                }
            }

            let targetSize = viewModel.effectivePanelSize
            let sizeChanged = ringPanel.map {
                abs($0.frame.width - targetSize.width) > 0.5 || abs($0.frame.height - targetSize.height) > 0.5
            } ?? false
            let geometryChanged = (previousSnapshot?.frame != snapshot.frame)
                || (previousSnapshot?.isFullScreen != snapshot.isFullScreen)
                || becameVisible
                || sizeChanged

            if sizeChanged {
                ringPanel?.updatePanelSize(targetSize)
            }
            if geometryChanged && !isUserInteractingWithRing {
                positionRing(inside: snapshot)
            }
            if becameVisible || geometryChanged {
                ringPanel?.orderFrontRegardless()
            }
            if geometryChanged && viewModel.isDetailOpen, let ringFrame = ringPanel?.frame {
                detailPanel?.reposition(near: ringFrame)
            }

            syncFileWatchers()
            return
        }

        if isSettingsWindowOpen,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
           let anchorSnapshot = lastKnownAntigravitySnapshot ?? windowTracker.findAnyAntigravitySnapshot() {
            ringPanel?.updatePanelSize(viewModel.effectivePanelSize)
            if !isUserInteractingWithRing {
                positionRing(inside: anchorSnapshot)
            }
            ringPanel?.orderFrontRegardless()
            syncFileWatchers()
            return
        }

        isUserInteractingWithRing = false
        if viewModel.isFullScreen {
            viewModel.isFullScreen = false
        }
        cancelHoverTooltip()
        closeDetailPanel()
        if wasRingVisible {
            ringPanel?.orderOut(nil)
        }
        stopFileWatchers()
    }

    private func currentPositionSnapshot() -> WindowSnapshot? {
        if let lastSnapshot, lastSnapshot.isVisible {
            return lastSnapshot
        }
        if isSettingsWindowOpen {
            return lastKnownAntigravitySnapshot ?? windowTracker.findAnyAntigravitySnapshot()
        }
        return nil
    }

    private func refreshData(includeRecentList: Bool) {
        let appState = dataReader.readAppState()
        if viewModel.isDarkTheme != appState.isDarkTheme {
            viewModel.isDarkTheme = appState.isDarkTheme
            settingsController?.updateAppearance(isDark: viewModel.effectiveIsDarkTheme)
        }
        if viewModel.zoomLevel != appState.zoomLevel {
            viewModel.zoomLevel = appState.zoomLevel
            ringPanel?.updatePanelSize(viewModel.effectivePanelSize)
            if let snapshot = currentPositionSnapshot(), !isUserInteractingWithRing {
                positionRing(inside: snapshot)
            }
            if viewModel.isDetailOpen, let ringFrame = ringPanel?.frame {
                detailPanel?.reposition(near: ringFrame)
            }
        }

        if includeRecentList || viewModel.recentConversations.isEmpty {
            let recent = dataReader.listRecentConversations(limit: 10)
            if viewModel.recentConversations != recent {
                viewModel.recentConversations = recent
            }
        }

        let previousConvId = activeConversationId

        if let manualId = viewModel.manualConversationId {
            activeConversationId = manualId
            let titleHint = viewModel.recentConversations.first(where: { $0.id == manualId })?.title ?? ""
            if let stats = dataReader.readTranscriptStats(conversationId: manualId, fallbackTitle: titleHint),
               stats.totalModelSteps > 0 {
                applyStatsToViewModel(stats: stats, activeTitle: stats.title, hasData: true)
            } else {
                let fallback = !titleHint.isEmpty ? titleHint : String(manualId.prefix(8))
                applyStatsToViewModel(stats: nil, activeTitle: fallback, hasData: false)
            }
        } else {
            let titleHint = !viewModel.activeWindowTitle.isEmpty
                ? viewModel.activeWindowTitle
                : (lastKnownAntigravitySnapshot?.title ?? "")

            if let resolved = dataReader.resolveConversationId(forWindowTitle: titleHint) {
                activeConversationId = resolved.id
                if let stats = dataReader.readTranscriptStats(conversationId: resolved.id, fallbackTitle: resolved.title),
                   stats.totalModelSteps > 0 {
                    applyStatsToViewModel(stats: stats, activeTitle: stats.title, hasData: true)
                } else {
                    let fallback = !resolved.title.isEmpty
                        ? resolved.title
                        : AntigravityDataReader.cleanWindowTitle(titleHint)
                    applyStatsToViewModel(stats: nil, activeTitle: fallback, hasData: false)
                }
            } else {
                activeConversationId = nil
                applyStatsToViewModel(
                    stats: nil,
                    activeTitle: AntigravityDataReader.cleanWindowTitle(titleHint),
                    hasData: false
                )
            }
        }

        if isMonitoringActive && previousConvId != activeConversationId {
            syncFileWatchers()
        }
    }

    private func applyStatsToViewModel(stats: TranscriptStats?, activeTitle: String, hasData: Bool) {
        let conversationChanged = viewModel.stats?.conversationId != stats?.conversationId
        if conversationChanged && viewModel.selectedScope != .allChat {
            viewModel.selectedScope = .allChat
        }
        if viewModel.stats != stats {
            viewModel.stats = stats
        }
        if viewModel.activeChatTitle != activeTitle {
            viewModel.activeChatTitle = activeTitle
        }
        if viewModel.hasTokenData != hasData {
            viewModel.hasTokenData = hasData
        }
    }

    // MARK: - 2-Nearest-Edge & Free Absolute Positioning

    private func positionRing(inside snapshot: WindowSnapshot) {
        guard let panel = ringPanel else { return }
        let panelSize = viewModel.effectivePanelSize

        var origin: CGPoint
        if !snapshot.isFullScreen && viewModel.positionMode == .freeAbsolute,
           let absAnchor = viewModel.freeAbsoluteAnchor {
            origin = CGPoint(x: absAnchor.x, y: absAnchor.y)
        } else {
            let anchor = snapshot.isFullScreen ? viewModel.fullscreenEdgeAnchor : viewModel.windowedEdgeAnchor
            origin = originFromEdgeAnchor(anchor, panelSize: panelSize, windowFrame: snapshot.frame)
        }

        origin = clampOrigin(origin, panelSize: panelSize, aroundWindow: snapshot.frame)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func saveAnchor(for panelOrigin: CGPoint) {
        guard let snapshot = currentPositionSnapshot() else { return }
        let panelSize = viewModel.effectivePanelSize
        let panelFrame = CGRect(origin: panelOrigin, size: panelSize)

        if !snapshot.isFullScreen && viewModel.positionMode == .freeAbsolute {
            viewModel.freeAbsoluteAnchor = AbsoluteAnchor(x: Double(panelOrigin.x), y: Double(panelOrigin.y))
        } else {
            let anchor = computeNearestEdgeAnchor(panelFrame: panelFrame, windowFrame: snapshot.frame)
            if snapshot.isFullScreen {
                viewModel.fullscreenEdgeAnchor = anchor
            } else {
                viewModel.windowedEdgeAnchor = anchor
            }
        }
        saveSettings()
    }

    private func computeNearestEdgeAnchor(panelFrame: CGRect, windowFrame: CGRect) -> EdgeAnchor {
        let distLeft = panelFrame.minX - windowFrame.minX
        let distRight = windowFrame.maxX - panelFrame.maxX
        let hEdge: HorizontalEdge = distLeft <= distRight ? .leading : .trailing
        let hOffset = max(0, Double(min(distLeft, distRight)))

        let distBottom = panelFrame.minY - windowFrame.minY
        let distTop = windowFrame.maxY - panelFrame.maxY
        let vEdge: VerticalEdge = distBottom <= distTop ? .bottom : .top
        let vOffset = max(0, Double(min(distBottom, distTop)))

        return EdgeAnchor(
            horizontalEdge: hEdge,
            horizontalOffset: hOffset,
            verticalEdge: vEdge,
            verticalOffset: vOffset
        )
    }

    private func originFromEdgeAnchor(_ anchor: EdgeAnchor, panelSize: CGSize, windowFrame: CGRect) -> CGPoint {
        let x: CGFloat
        switch anchor.horizontalEdge {
        case .leading:
            x = windowFrame.minX + CGFloat(anchor.horizontalOffset)
        case .trailing:
            x = windowFrame.maxX - CGFloat(anchor.horizontalOffset) - panelSize.width
        }

        let y: CGFloat
        switch anchor.verticalEdge {
        case .bottom:
            y = windowFrame.minY + CGFloat(anchor.verticalOffset)
        case .top:
            y = windowFrame.maxY - CGFloat(anchor.verticalOffset) - panelSize.height
        }

        return CGPoint(x: x, y: y)
    }

    private func clampOrigin(_ origin: CGPoint, panelSize: CGSize, aroundWindow windowFrame: CGRect) -> CGPoint {
        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main
        guard let bounds = targetScreen?.frame else { return origin }

        let clampedX = min(max(origin.x, bounds.minX + 4), bounds.maxX - panelSize.width - 4)
        let clampedY = min(max(origin.y, bounds.minY + 4), bounds.maxY - panelSize.height - 4)
        return CGPoint(x: clampedX, y: clampedY)
    }

    // MARK: - Status Bar Menu

    private func updateStatusBarTitle() {
        guard let button = statusItem?.button else { return }
        if !viewModel.hasTokenData {
            button.title = " —"
        } else {
            button.title = " \(viewModel.percent)%"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AXIsProcessTrusted()
        if viewModel.accessibilityGranted != trusted {
            viewModel.accessibilityGranted = trusted
        }
        refreshData(includeRecentList: false)

        let lang = viewModel.resolvedLanguage
        let chatTitle = !viewModel.activeChatTitle.isEmpty
            ? viewModel.activeChatTitle
            : (viewModel.activeWindowTitle.isEmpty ? L10n.menuNotDetected(lang) : viewModel.activeWindowTitle)
        let chatItem = NSMenuItem(title: L10n.menuChat(chatTitle, lang: lang), action: nil, keyEquivalent: "")
        chatItem.isEnabled = false
        menu.addItem(chatItem)

        let contextText = L10n.menuContext(
            viewModel.formattedTokens,
            limit: RingViewModel.formatNumber(viewModel.threshold),
            percent: viewModel.percent,
            hasData: viewModel.hasTokenData,
            lang: lang
        )
        let contextItem = NSMenuItem(title: contextText, action: nil, keyEquivalent: "")
        contextItem.isEnabled = false
        menu.addItem(contextItem)

        let zoomLabel = viewModel.zoomLevel.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(viewModel.zoomLevel))"
            : String(format: "%.1f", viewModel.zoomLevel)
        let windowItem = NSMenuItem(
            title: L10n.menuWindow(isFullScreen: viewModel.isFullScreen, zoom: zoomLabel, lang: lang),
            action: nil,
            keyEquivalent: ""
        )
        windowItem.isEnabled = false
        menu.addItem(windowItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: L10n.menuSettings(lang),
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let languageMenu = NSMenu()
        for pref in AppLanguagePreference.allCases {
            let langOption = NSMenuItem(
                title: L10n.languagePreferenceName(pref, lang: lang),
                action: #selector(selectLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            langOption.target = self
            langOption.representedObject = pref.rawValue
            langOption.state = (viewModel.languagePreference == pref) ? .on : .off
            languageMenu.addItem(langOption)
        }
        let languageItem = NSMenuItem(title: L10n.menuLanguage(lang), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        if !viewModel.accessibilityGranted {
            let axItem = NSMenuItem(
                title: L10n.menuGrantAccessibility(lang),
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            )
            axItem.target = self
            menu.addItem(axItem)
        }

        let resetItem = NSMenuItem(
            title: L10n.menuResetPosition(lang),
            action: #selector(resetRingPosition),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.menuQuit(lang),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func selectLanguageFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pref = AppLanguagePreference(rawValue: raw) else {
            return
        }
        viewModel.languagePreference = pref
        applyAppearanceAndLayoutChange()
    }

    @objc private func openSettingsWindow() {
        let trusted = AXIsProcessTrusted()
        if viewModel.accessibilityGranted != trusted {
            viewModel.accessibilityGranted = trusted
        }

        if settingsController == nil {
            let actions = SettingsActions(
                onSettingsChanged: { [weak self] in
                    self?.applyAppearanceAndLayoutChange()
                },
                onReferenceZoomCaptured: { [weak self] in
                    self?.captureReferenceZoom()
                },
                onLocateSendButton: { [weak self] in
                    self?.locateSendButtonAndSnap()
                },
                onResetPosition: { [weak self] in
                    self?.resetRingPosition()
                },
                onOpenAccessibility: { [weak self] in
                    self?.requestAccessibilityPermission()
                },
                onChangeLaunchMode: { [weak self] mode in
                    self?.changeLaunchMode(mode)
                },
                onWindowOpenChanged: { [weak self] isOpen in
                    guard let self else { return }
                    self.isSettingsWindowOpen = isOpen
                    if isOpen {
                        self.recheckAccessibilityTrust()
                        self.refreshData(includeRecentList: false)
                        self.syncFileWatchers()
                    } else {
                        self.windowTracker.refresh(forceEmit: true)
                    }
                    self.updateAccessibilityPollTimer()
                },
                onWindowFocused: { [weak self] in
                    self?.recheckAccessibilityTrust()
                }
            )
            settingsController = SettingsWindowController(viewModel: viewModel, actions: actions)
        }
        recheckAccessibilityTrust()
        updateAccessibilityPollTimer()
        settingsController?.updateTitle(lang: viewModel.resolvedLanguage)
        settingsController?.updateAppearance(isDark: viewModel.effectiveIsDarkTheme)
        settingsController?.showWindowAndActivate()
    }

    @objc private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetRingPosition() {
        viewModel.windowedEdgeAnchor = .defaultAnchor
        viewModel.fullscreenEdgeAnchor = .defaultAnchor
        viewModel.freeAbsoluteAnchor = nil
        viewModel.sendButtonLocateStatus = ""
        applyAppearanceAndLayoutChange()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
