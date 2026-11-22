import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

struct ModelStepSample: Identifiable, Equatable {
    var id: Int { stepIndex }
    let stepIndex: Int
    let contextTokens: Int
    let delta: Int
    let isCompaction: Bool
    let isModelSwitch: Bool
    let isEffortSwitch: Bool
}

struct MessageTurnSample: Identifiable, Equatable {
    var id: Int { turnIndex }
    let turnIndex: Int
    let contextTokens: Int
    let delta: Int
    let modelStepsInTurn: Int
    let cacheReadTokens: Int
    let cacheHitPercent: Int
    let hadCompaction: Bool
    let hadModelSwitch: Bool
    let hadEffortSwitch: Bool
}

struct ToolUsageCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

struct FileUsageCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

struct PeriodChatItem: Identifiable, Equatable {
    let id: String
    let title: String
    let peakTokens: Int
    let steps: Int
}

struct ModelUsageCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let steps: Int
    let outputTokens: Int
}

struct ChatSessionStats: Equatable {
    let primaryModel: String
    let otherModelsCount: Int
    let modelUsage: [ModelUsageCount]
    let totalInputTokens: Int
    let totalCacheReadTokens: Int
    let totalOutputTokens: Int
    let avgCacheHitPercent: Int
    let durationSeconds: Int
    let mediaCount: Int
    let errorCount: Int
    let userMessageCount: Int

    static let empty = ChatSessionStats(
        primaryModel: "",
        otherModelsCount: 0,
        modelUsage: [],
        totalInputTokens: 0,
        totalCacheReadTokens: 0,
        totalOutputTokens: 0,
        avgCacheHitPercent: 0,
        durationSeconds: 0,
        mediaCount: 0,
        errorCount: 0,
        userMessageCount: 0
    )
}

struct PeriodUsageStats: Equatable {
    let windowHours: Int
    let activeChats: Int
    let userMessages: Int
    let modelSteps: Int
    let compactionEvents: Int
    let totalInputTokens: Int
    let totalCacheReadTokens: Int
    let totalOutputTokens: Int
    let avgCacheHitPercent: Int
    let totalDurationSeconds: Int
    let totalToolCalls: Int
    let totalFileTouches: Int
    let peakTokens: Int
    let modelUsage: [ModelUsageCount]
    let topTools: [ToolUsageCount]
    let topFiles: [FileUsageCount]
    let activeChatItems: [PeriodChatItem]

    static func empty(hours: Int) -> PeriodUsageStats {
        PeriodUsageStats(
            windowHours: hours,
            activeChats: 0,
            userMessages: 0,
            modelSteps: 0,
            compactionEvents: 0,
            totalInputTokens: 0,
            totalCacheReadTokens: 0,
            totalOutputTokens: 0,
            avgCacheHitPercent: 0,
            totalDurationSeconds: 0,
            totalToolCalls: 0,
            totalFileTouches: 0,
            peakTokens: 0,
            modelUsage: [],
            topTools: [],
            topFiles: [],
            activeChatItems: []
        )
    }
}

struct ContextBreakdown: Equatable {
    let systemTokens: Int
    let basePromptTokens: Int
    let systemMessageTokens: Int
    let historyTokens: Int
    let checkpointSummaryTokens: Int
    let filesTokens: Int
    let toolsTokens: Int
    let assistantTokens: Int
    let thinkingTokens: Int
    let userTokens: Int
    let totalOutputTokens: Int
    let userTurns: Int
    let mediaCount: Int
    let toolCallsCount: Int
    let fileTouchesCount: Int
    let topTools: [ToolUsageCount]
    let topFiles: [FileUsageCount]

    static let empty = ContextBreakdown(
        systemTokens: 0,
        basePromptTokens: 0,
        systemMessageTokens: 0,
        historyTokens: 0,
        checkpointSummaryTokens: 0,
        filesTokens: 0,
        toolsTokens: 0,
        assistantTokens: 0,
        thinkingTokens: 0,
        userTokens: 0,
        totalOutputTokens: 0,
        userTurns: 0,
        mediaCount: 0,
        toolCallsCount: 0,
        fileTouchesCount: 0,
        topTools: [],
        topFiles: []
    )
}

enum ChatScopeGroup: String, Equatable, Identifiable {
    case allChat
    case manual
    case orchestrator

    var id: String { rawValue }
}

enum ChatStatsScope: Equatable, Hashable {
    case allChat
    case manualAll
    case manualModel(String)
    case orchestratorAll
    case orchestratorPlanner
    case orchestratorExecutor

    var group: ChatScopeGroup {
        switch self {
        case .allChat: return .allChat
        case .manualAll, .manualModel: return .manual
        case .orchestratorAll, .orchestratorPlanner, .orchestratorExecutor: return .orchestrator
        }
    }

    var isAggregateScope: Bool {
        switch self {
        case .allChat, .manualAll, .orchestratorAll:
            return true
        case .manualModel, .orchestratorPlanner, .orchestratorExecutor:
            return false
        }
    }
}

struct ManualModelScopeItem: Identifiable, Equatable {
    let id: String
    let shortName: String
    let fullName: String
    let steps: Int
}

struct ScopedStatsSnapshot: Equatable {
    let contextTokens: Int
    let lastInputTokens: Int
    let lastCacheReadTokens: Int
    let lastOutputTokens: Int
    let lastDelta: Int
    let cacheHitPercent: Int
    let model: String
    let totalModelSteps: Int
    let peakTokens: Int
    let compactionEvents: Int
    let recentSteps: [ModelStepSample]
    let recentMessages: [MessageTurnSample]
    let breakdown: ContextBreakdown
    let sessionStats: ChatSessionStats
}

struct TranscriptStats: Equatable {
    let conversationId: String
    let title: String
    let contextTokens: Int
    let lastInputTokens: Int
    let lastCacheReadTokens: Int
    let lastOutputTokens: Int
    let lastDelta: Int
    let cacheHitPercent: Int
    let model: String
    let totalModelSteps: Int
    let peakTokens: Int
    let compactionEvents: Int
    let recentSteps: [ModelStepSample]
    let recentMessages: [MessageTurnSample]
    let breakdown: ContextBreakdown
    let sessionStats: ChatSessionStats
    let hasManualMode: Bool
    let hasOrchestratorMode: Bool
    let manualModels: [ManualModelScopeItem]
    let scopedSnapshots: [ChatStatsScope: ScopedStatsSnapshot]
    let updatedAt: Date?

    func snapshot(for scope: ChatStatsScope) -> ScopedStatsSnapshot {
        if let hit = scopedSnapshots[scope] {
            return hit
        }
        return ScopedStatsSnapshot(
            contextTokens: contextTokens,
            lastInputTokens: lastInputTokens,
            lastCacheReadTokens: lastCacheReadTokens,
            lastOutputTokens: lastOutputTokens,
            lastDelta: lastDelta,
            cacheHitPercent: cacheHitPercent,
            model: model,
            totalModelSteps: totalModelSteps,
            peakTokens: peakTokens,
            compactionEvents: compactionEvents,
            recentSteps: recentSteps,
            recentMessages: recentMessages,
            breakdown: breakdown,
            sessionStats: sessionStats
        )
    }
}

struct RecentConversationItem: Identifiable, Equatable {
    let id: String
    let title: String
    let contextTokens: Int
    let model: String
}

enum ContextZone {
    case green
    case amber
    case red

    var accentColor: Color {
        switch self {
        case .green:
            return Color(red: 0.16, green: 0.72, blue: 0.40)
        case .amber:
            return Color(red: 0.92, green: 0.58, blue: 0.12)
        case .red:
            return Color(red: 0.90, green: 0.24, blue: 0.24)
        }
    }

    var pillBackground: Color {
        accentColor.opacity(0.16)
    }
}

enum RingStyle: String, CaseIterable, Identifiable {
    case classic
    case minimal
    case codex

    var id: String { rawValue }
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }
}

enum PositionMode: String, CaseIterable, Identifiable {
    case snapToEdges
    case freeAbsolute

    var id: String { rawValue }
}

enum LaunchMode: String, CaseIterable, Identifiable {
    case withAntigravity
    case withSystem
    case manual

    var id: String { rawValue }
}

enum HorizontalEdge: String, Codable {
    case leading
    case trailing
}

enum VerticalEdge: String, Codable {
    case bottom
    case top
}

struct EdgeAnchor: Codable, Equatable {
    var horizontalEdge: HorizontalEdge
    var horizontalOffset: Double
    var verticalEdge: VerticalEdge
    var verticalOffset: Double

    static let defaultAnchor = EdgeAnchor(
        horizontalEdge: .trailing,
        horizontalOffset: 36,
        verticalEdge: .bottom,
        verticalOffset: 78
    )
}

struct AbsoluteAnchor: Codable, Equatable {
    var x: Double
    var y: Double
}

struct AntigravityAppState: Equatable {
    let zoomLevel: Double
    let isDarkTheme: Bool
}

struct WindowSnapshot: Equatable {
    let frame: CGRect
    let title: String
    let isFullScreen: Bool
    let isVisible: Bool
    let pid: pid_t
}

final class RingViewModel: ObservableObject {
    static let thresholdPresets = [128_000, 160_000, 200_000, 256_000, 1_000_000]

    @Published var stats: TranscriptStats?
    @Published var selectedScope: ChatStatsScope = .allChat
    @Published var activeChatTitle: String = ""
    @Published var hasTokenData: Bool = false
    @Published var threshold: Int = 200_000
    @Published var isDarkTheme: Bool = false
    @Published var zoomLevel: Double = 0
    @Published var accessibilityGranted: Bool = false
    @Published var activeWindowTitle: String = ""
    @Published var isFullScreen: Bool = false
    @Published var recentConversations: [RecentConversationItem] = []
    @Published var manualConversationId: String? = nil
    @Published var isHoveringRing: Bool = false
    @Published var isDetailOpen: Bool = false
    @Published var isChatDropdownOpen: Bool = false

    @Published var languagePreference: AppLanguagePreference = .system
    @Published var historyViewMode: HistoryViewMode = .messages
    @Published var activeDetailTab: DetailTab = .context
    @Published var statsPeriod: StatsPeriod = .day
    @Published var periodStats: PeriodUsageStats = .empty(hours: 24)

    // Appearance, zoom-linked scaling, fonts, positioning, launch
    @Published var ringBaseSize: CGFloat = 40
    @Published var strokeBaseWidth: CGFloat = 3.5
    @Published var fontSizeScale: CGFloat = 1.0
    @Published var hoverFontScale: CGFloat = 1.0
    @Published var detailFontScale: CGFloat = 1.0
    @Published var showPercentInside: Bool = true
    @Published var ringStyle: RingStyle = .classic
    @Published var themePreference: ThemePreference = .auto
    @Published var scaleWithAntigravityZoom: Bool = true
    @Published var referenceZoomLevel: Double = 0
    @Published var positionMode: PositionMode = .snapToEdges
    @Published var windowedEdgeAnchor: EdgeAnchor = .defaultAnchor
    @Published var fullscreenEdgeAnchor: EdgeAnchor = .defaultAnchor
    @Published var freeAbsoluteAnchor: AbsoluteAnchor? = nil
    @Published var launchMode: LaunchMode = .withAntigravity
    @Published var launchAtLoginError: String = ""
    @Published var sendButtonLocateStatus: String = ""

    private static let numberFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = " "
        return fmt
    }()

    var resolvedLanguage: ResolvedLanguage {
        switch languagePreference {
        case .system: return ResolvedLanguage.systemDefault()
        case .ru: return .ru
        case .en: return .en
        }
    }

    var effectiveIsDarkTheme: Bool {
        switch themePreference {
        case .auto: return isDarkTheme
        case .light: return false
        case .dark: return true
        }
    }

    var palette: OverlayPalette {
        OverlayPalette(isDark: effectiveIsDarkTheme)
    }

    var uiScale: CGFloat {
        guard scaleWithAntigravityZoom else { return 1.0 }
        let factor = pow(1.2, zoomLevel - referenceZoomLevel)
        return CGFloat(min(max(factor, 0.55), 2.2))
    }

    var effectiveRingSize: CGFloat {
        let raw = (ringBaseSize * uiScale).rounded()
        return min(max(raw, 22), 110)
    }

    var effectivePanelSize: CGSize {
        let side = effectiveRingSize + 6
        return CGSize(width: side, height: side)
    }

    var effectiveStrokeWidth: CGFloat {
        let scaled = strokeBaseWidth * uiScale
        return min(max(scaled, 1.5), 11.0)
    }

    var effectiveHoverScale: CGFloat {
        min(max(hoverFontScale * uiScale, 0.75), 2.2)
    }

    var effectiveDetailScale: CGFloat {
        min(max(detailFontScale * uiScale, 0.75), 2.1)
    }

    var effectiveScope: ChatStatsScope {
        guard let stats else { return .allChat }
        if stats.scopedSnapshots[selectedScope] != nil {
            return selectedScope
        }
        return .allChat
    }

    var activeScopedSnapshot: ScopedStatsSnapshot? {
        guard hasTokenData, let stats else { return nil }
        return stats.snapshot(for: effectiveScope)
    }

    var contextTokens: Int {
        activeScopedSnapshot?.contextTokens ?? 0
    }

    var progress: Double {
        guard hasTokenData, threshold > 0 else { return 0 }
        let ratio = Double(contextTokens) / Double(threshold)
        return min(max(ratio, 0), 1)
    }

    var percent: Int {
        guard hasTokenData, threshold > 0 else { return 0 }
        let raw = Int(((Double(contextTokens) / Double(threshold)) * 100.0).rounded())
        return min(max(raw, 0), 999)
    }

    var zone: ContextZone {
        let pct = percent
        if pct >= 85 { return .red }
        if pct >= 65 { return .amber }
        return .green
    }

    var formattedTokens: String {
        Self.formatNumber(contextTokens)
    }

    var formattedDelta: String {
        guard hasTokenData, let scoped = activeScopedSnapshot, scoped.totalModelSteps > 0 else { return "—" }
        let val: Int
        if historyViewMode == .messages, let lastTurn = scoped.recentMessages.first {
            val = lastTurn.delta
        } else {
            val = scoped.lastDelta
        }
        return Self.formatSignedNumber(val)
    }

    static func formatModelDisplay(_ raw: String) -> (name: String, effort: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        var work = trimmed
        var effort: String? = nil

        let effortPatterns = [
            #"\s*\((x?high|medium|low)\)\s*$"#,
            #"-(x?high|medium|low)$"#,
            #"\s+(x?high|medium|low)$"#,
        ]
        for pattern in effortPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let nsRange = NSRange(location: 0, length: work.utf16.count)
                if let match = regex.firstMatch(in: work, options: [], range: nsRange),
                   match.numberOfRanges >= 2,
                   let tokenRange = Range(match.range(at: 1), in: work),
                   let fullRange = Range(match.range(at: 0), in: work) {
                    let rawEffort = work[tokenRange].lowercased()
                    switch rawEffort {
                    case "xhigh": effort = "XHigh"
                    case "high": effort = "High"
                    case "medium": effort = "Medium"
                    case "low": effort = "Low"
                    default: break
                    }
                    work.removeSubrange(fullRange)
                    work = work.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        if let orchRegex = try? NSRegularExpression(pattern: #"^orchestrator\s*\(([^)]+)\)$"#, options: [.caseInsensitive]) {
            let nsRange = NSRange(location: 0, length: work.utf16.count)
            if let match = orchRegex.firstMatch(in: work, options: [], range: nsRange),
               match.numberOfRanges >= 2,
               let innerRange = Range(match.range(at: 1), in: work) {
                work = String(work[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        work = work
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")

        while let range = work.range(of: #"(?<=\d)-(?=\d)"#, options: .regularExpression) {
            work.replaceSubrange(range, with: ".")
        }

        let rawTokens = work
            .components(separatedBy: CharacterSet(charactersIn: "-_ \t\n"))
            .filter { !$0.isEmpty }

        let dropTokens: Set<String> = ["gemini", "claude", "anthropic", "google", "agy", "orchestrator", "worker"]
        let filtered = rawTokens.filter { !dropTokens.contains($0.lowercased()) }
        let chosen = filtered.isEmpty ? rawTokens : filtered

        let formattedTokens = chosen.map { tok -> String in
            if tok == tok.lowercased(), tok.rangeOfCharacter(from: .letters) != nil {
                return tok.prefix(1).uppercased() + tok.dropFirst()
            }
            return tok
        }

        let cleanName = formattedTokens.joined(separator: " ")
        return (cleanName.isEmpty ? trimmed : cleanName, effort)
    }

    static func shortModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()

        let known: [(token: String, label: String)] = [
            ("opus", "Opus"),
            ("sonnet", "Sonnet"),
            ("haiku", "Haiku"),
            ("argon", "Argon"),
            ("hydrogen", "Hydrogen"),
            ("neon", "Neon"),
            ("flash", "Flash"),
            ("pro", "Pro"),
        ]
        for entry in known where lower.contains(entry.token) {
            return entry.label
        }

        return formatModelDisplay(trimmed).name
    }

    static func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func formatSignedNumber(_ value: Int) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(formatNumber(value))"
    }

    static func formatK(_ value: Int) -> String {
        let k = Int((Double(value) / 1000.0).rounded())
        return "\(k)k"
    }

    static func formatCompactTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000.0
            if value % 1_000_000 == 0 {
                return "\(value / 1_000_000)M"
            }
            return String(format: "%.1fM", m)
        }
        if value >= 1_000 {
            return formatK(value)
        }
        return "\(value)"
    }

    static func formatLimit(_ value: Int) -> String {
        formatCompactTokens(value)
    }

    static func parseThresholdInput(_ raw: String) -> Int? {
        var cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }

        var multiplier: Double = 1
        if cleaned.hasSuffix("m") || cleaned.hasSuffix("м") {
            multiplier = 1_000_000
            cleaned.removeLast()
        } else if cleaned.hasSuffix("k") || cleaned.hasSuffix("к") {
            multiplier = 1_000
            cleaned.removeLast()
        }

        guard let num = Double(cleaned), num.isFinite, num > 0 else {
            return nil
        }
        let tokens = Int((num * multiplier).rounded())
        return min(max(tokens, 10_000), 10_000_000)
    }
}

struct OverlayPalette {
    let isDark: Bool

    var surfaceBg: Color {
        isDark
            ? Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.98)
            : Color(red: 0.98, green: 0.98, blue: 0.99).opacity(0.98)
    }

    var tooltipSurfaceBg: Color {
        isDark
            ? Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.96)
            : Color.white.opacity(0.97)
    }

    var cardBg: Color {
        isDark
            ? Color(red: 0.16, green: 0.17, blue: 0.20)
            : Color.white
    }

    var dropdownCardBg: Color {
        isDark
            ? Color(red: 0.14, green: 0.15, blue: 0.18)
            : Color.white
    }

    var mutedBg: Color {
        isDark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.05)
    }

    var borderStroke: Color {
        isDark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.11)
    }

    var primaryText: Color {
        isDark ? Color(white: 0.95) : Color(white: 0.10)
    }

    var secondaryText: Color {
        isDark ? Color(white: 0.62) : Color(white: 0.44)
    }
}

enum OverlayPositioning {
    static func screenBounds(near anchorRect: CGRect) -> CGRect {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main
        return screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    static func popupOrigin(
        for size: CGSize,
        near ringFrame: CGRect,
        bounds: CGRect? = nil,
        gap: CGFloat = 8,
        horizontalOverlap: CGFloat = 0,
        inset: CGFloat = 8
    ) -> CGPoint {
        let b = bounds ?? screenBounds(near: ringFrame)
        var y = ringFrame.maxY + gap
        if y + size.height > b.maxY - inset {
            let belowY = ringFrame.minY - size.height - gap
            if belowY >= b.minY + inset || gap >= 8 {
                y = belowY
            }
        }
        y = min(max(y, b.minY + inset), b.maxY - size.height - inset)

        let preferRightAlign = ringFrame.midX > b.midX
        var x = preferRightAlign
            ? (ringFrame.maxX - size.width + horizontalOverlap)
            : (ringFrame.minX - horizontalOverlap)
        x = min(max(x, b.minX + inset), b.maxX - size.width - inset)
        return CGPoint(x: x, y: y)
    }
}
