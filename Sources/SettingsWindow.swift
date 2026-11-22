import Cocoa
import SwiftUI

struct SettingsActions {
    let onSettingsChanged: () -> Void
    let onReferenceZoomCaptured: () -> Void
    let onLocateSendButton: () -> Void
    let onResetPosition: () -> Void
    let onOpenAccessibility: () -> Void
    let onChangeLaunchMode: (LaunchMode) -> Void
    let onWindowOpenChanged: (Bool) -> Void
    let onWindowFocused: () -> Void
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onWindowOpenChanged: (Bool) -> Void
    private let onWindowFocused: () -> Void

    init(viewModel: RingViewModel, actions: SettingsActions) {
        self.onWindowOpenChanged = actions.onWindowOpenChanged
        self.onWindowFocused = actions.onWindowFocused
        let hosting = NSHostingView(rootView: SettingsView(viewModel: viewModel, actions: actions))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settingsWindowTitle(viewModel.resolvedLanguage)
        window.minSize = NSSize(width: 530, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        onWindowOpenChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func updateTitle(lang: ResolvedLanguage) {
        window?.title = L10n.settingsWindowTitle(lang)
    }

    func updateAppearance(isDark: Bool) {
        window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onWindowFocused()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowOpenChanged(false)
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: RingViewModel
    let actions: SettingsActions

    @State private var customThresholdInput: String = ""
    @State private var customThresholdError: String = ""

    private let labelWidth: CGFloat = 186

    private var lang: ResolvedLanguage {
        viewModel.resolvedLanguage
    }

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    thresholdCard
                    sizesAndFontsCard
                    positionCard
                    launchAndSystemCard
                }
                .padding(18)
            }
        }
        .frame(minWidth: 530, minHeight: 620)
        .onAppear {
            syncThresholdInputFromModel()
        }
        .onChange(of: viewModel.threshold) { _ in
            syncThresholdInputFromModel()
        }
    }

    private var previewHeader: some View {
        let dark = viewModel.effectiveIsDarkTheme
        return HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dark ? Color(red: 0.14, green: 0.15, blue: 0.18) : Color(red: 0.92, green: 0.93, blue: 0.95))
                    .frame(width: 124, height: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                RingView(viewModel: viewModel, interactive: false)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.settingsPreviewTitle(lang))
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.settingsPreviewStats(size: Int(viewModel.effectiveRingSize), scale: viewModel.uiScale, lang: lang))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text(L10n.settingsPreviewHint(lang))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var thresholdCard: some View {
        settingsCard(title: L10n.settingsThresholdSection(lang)) {
            HStack(spacing: 6) {
                ForEach(RingViewModel.thresholdPresets, id: \.self) { preset in
                    let isSelected = viewModel.threshold == preset
                    Button {
                        viewModel.threshold = preset
                        customThresholdError = ""
                        actions.onSettingsChanged()
                    } label: {
                        Text(RingViewModel.formatLimit(preset))
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                isSelected
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.08)
                            )
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Text(L10n.settingsCustomNumberLabel(lang))
                    .font(.system(size: 13))
                    .frame(width: 96, alignment: .leading)

                TextField(L10n.settingsCustomThresholdPlaceholder(lang), text: $customThresholdInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { applyCustomThreshold() }

                Button(L10n.settingsApplyButton(lang)) {
                    applyCustomThreshold()
                }
                .controlSize(.regular)
            }

            HStack {
                Text(L10n.settingsActiveThreshold(RingViewModel.formatNumber(viewModel.threshold), lang: lang))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                if !customThresholdError.isEmpty {
                    Text(customThresholdError)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var sizesAndFontsCard: some View {
        settingsCard(title: L10n.settingsAppearanceSection(lang)) {
            zoomLinkingGroup
            Divider()
            slidersGroup
            Divider()
            styleAndThemeGroup
        }
    }

    @ViewBuilder
    private var zoomLinkingGroup: some View {
        Toggle(isOn: binding(
            get: { viewModel.scaleWithAntigravityZoom },
            set: { newVal in
                viewModel.scaleWithAntigravityZoom = newVal
                if newVal {
                    actions.onReferenceZoomCaptured()
                } else {
                    actions.onSettingsChanged()
                }
            }
        )) {
            Text(L10n.settingsLinkZoomToggle(lang))
                .font(.system(size: 13))
        }

        HStack {
            Text(L10n.settingsZoomSummary(current: formatZoom(viewModel.zoomLevel), base: formatZoom(viewModel.referenceZoomLevel), lang: lang))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Button(L10n.settingsCaptureZoomButton(lang)) {
                actions.onReferenceZoomCaptured()
            }
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var slidersGroup: some View {
        sliderRow(
            label: L10n.settingsRingSize(lang),
            valueText: "\(Int(viewModel.ringBaseSize)) pt",
            value: binding(
                get: { Double(viewModel.ringBaseSize) },
                set: { newVal in
                    viewModel.ringBaseSize = CGFloat(newVal.rounded())
                    if viewModel.scaleWithAntigravityZoom {
                        viewModel.referenceZoomLevel = viewModel.zoomLevel
                    }
                    actions.onSettingsChanged()
                }
            ),
            range: 26...64,
            step: 1
        )

        sliderRow(
            label: L10n.settingsStrokeWidth(lang),
            valueText: String(format: "%.1f pt", Double(viewModel.strokeBaseWidth)),
            value: binding(
                get: { Double(viewModel.strokeBaseWidth) },
                set: { newVal in
                    viewModel.strokeBaseWidth = CGFloat((newVal * 2).rounded() / 2)
                    actions.onSettingsChanged()
                }
            ),
            range: 2.0...6.0,
            step: 0.5
        )

        Toggle(isOn: binding(
            get: { viewModel.showPercentInside },
            set: {
                viewModel.showPercentInside = $0
                actions.onSettingsChanged()
            }
        )) {
            Text(L10n.settingsShowPercentToggle(lang))
                .font(.system(size: 13))
        }

        sliderRow(
            label: L10n.settingsRingFontSize(lang),
            valueText: "\(Int((viewModel.fontSizeScale * 100).rounded()))%",
            value: binding(
                get: { Double(viewModel.fontSizeScale) },
                set: {
                    viewModel.fontSizeScale = CGFloat($0)
                    actions.onSettingsChanged()
                }
            ),
            range: 0.70...1.60,
            step: 0.05
        )
        .disabled(!viewModel.showPercentInside)

        sliderRow(
            label: L10n.settingsHoverFontSize(lang),
            valueText: "\(Int((viewModel.hoverFontScale * 100).rounded()))%",
            value: binding(
                get: { Double(viewModel.hoverFontScale) },
                set: {
                    viewModel.hoverFontScale = CGFloat($0)
                    actions.onSettingsChanged()
                }
            ),
            range: 0.80...1.80,
            step: 0.05
        )

        sliderRow(
            label: L10n.settingsDetailFontSize(lang),
            valueText: "\(Int((viewModel.detailFontScale * 100).rounded()))%",
            value: binding(
                get: { Double(viewModel.detailFontScale) },
                set: {
                    viewModel.detailFontScale = CGFloat($0)
                    actions.onSettingsChanged()
                }
            ),
            range: 0.80...1.80,
            step: 0.05
        )
    }

    @ViewBuilder
    private var styleAndThemeGroup: some View {
        HStack(spacing: 12) {
            Text(L10n.settingsStyleLabel(lang))
                .font(.system(size: 13))
                .frame(width: 64, alignment: .leading)
            Picker("", selection: binding(
                get: { viewModel.ringStyle },
                set: {
                    viewModel.ringStyle = $0
                    actions.onSettingsChanged()
                }
            )) {
                ForEach(RingStyle.allCases) { style in
                    Text(L10n.ringStyleName(style, lang: lang)).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
        }

        HStack(spacing: 12) {
            Text(L10n.settingsThemeLabel(lang))
                .font(.system(size: 13))
                .frame(width: 64, alignment: .leading)
            Picker("", selection: binding(
                get: { viewModel.themePreference },
                set: {
                    viewModel.themePreference = $0
                    actions.onSettingsChanged()
                }
            )) {
                ForEach(ThemePreference.allCases) { theme in
                    Text(L10n.themeName(theme, lang: lang)).tag(theme)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
        }
    }

    private var positionCard: some View {
        settingsCard(title: L10n.settingsPositionSection(lang)) {
            Picker("", selection: binding(
                get: { viewModel.positionMode },
                set: {
                    viewModel.positionMode = $0
                    actions.onSettingsChanged()
                }
            )) {
                ForEach(PositionMode.allCases) { mode in
                    Text(L10n.positionModeName(mode, lang: lang)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)

            VStack(alignment: .leading, spacing: 3) {
                if viewModel.positionMode == .snapToEdges {
                    Text(L10n.settingsWindowedAnchor(L10n.edgeAnchorSummary(viewModel.windowedEdgeAnchor, lang: lang), lang: lang))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else if let absPos = viewModel.freeAbsoluteAnchor {
                    Text(L10n.settingsFreeAnchorCoords(x: Int(absPos.x.rounded()), y: Int(absPos.y.rounded()), lang: lang))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Text(L10n.settingsFreeAnchorHint(lang))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text(L10n.settingsFullscreenAnchor(L10n.edgeAnchorSummary(viewModel.fullscreenEdgeAnchor, lang: lang), lang: lang))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button(L10n.settingsSnapToSendButton(lang)) {
                    actions.onLocateSendButton()
                }
                .controlSize(.regular)

                Button(L10n.settingsResetPosButton(lang)) {
                    actions.onResetPosition()
                }
                .controlSize(.regular)

                Spacer()
            }

            if !viewModel.sendButtonLocateStatus.isEmpty {
                Text(viewModel.sendButtonLocateStatus)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchAndSystemCard: some View {
        settingsCard(title: L10n.settingsSystemSection(lang)) {
            HStack(spacing: 12) {
                Text(L10n.settingsLanguageLabel(lang))
                    .font(.system(size: 13))
                    .frame(width: 78, alignment: .leading)
                Picker("", selection: binding(
                    get: { viewModel.languagePreference },
                    set: { newPref in
                        viewModel.languagePreference = newPref
                        actions.onSettingsChanged()
                    }
                )) {
                    ForEach(AppLanguagePreference.allCases) { pref in
                        Text(L10n.languagePreferenceName(pref, lang: lang)).tag(pref)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.settingsLaunchModeLabel(lang))
                    .font(.system(size: 13))
                Picker("", selection: binding(
                    get: { viewModel.launchMode },
                    set: { newMode in
                        actions.onChangeLaunchMode(newMode)
                    }
                )) {
                    ForEach(LaunchMode.allCases) { mode in
                        Text(L10n.launchModeName(mode, lang: lang)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)
            }

            Text(L10n.settingsLaunchModeNote(viewModel.launchMode, lang: lang))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !viewModel.launchAtLoginError.isEmpty {
                Text(viewModel.launchAtLoginError)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.accessibilityGranted {
                Divider()

                HStack {
                    Text(L10n.settingsAccessibilityMissing(lang))
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                    Spacer()
                    Button(L10n.settingsOpenAccessibilityButton(lang)) {
                        actions.onOpenAccessibility()
                    }
                    .controlSize(.regular)
                }
            }
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private func sliderRow(
        label: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(valueText)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func syncThresholdInputFromModel() {
        customThresholdInput = "\(viewModel.threshold)"
    }

    private func applyCustomThreshold() {
        guard let parsed = RingViewModel.parseThresholdInput(customThresholdInput) else {
            customThresholdError = L10n.settingsCustomThresholdError(lang)
            return
        }
        customThresholdError = ""
        viewModel.threshold = parsed
        customThresholdInput = "\(parsed)"
        actions.onSettingsChanged()
    }

    private func binding<T>(get: @escaping () -> T, set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: set)
    }

    private func formatZoom(_ z: Double) -> String {
        z.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(z))" : String(format: "%.1f", z)
    }
}
