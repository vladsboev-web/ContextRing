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
}

struct ToolUsageCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
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
    let modelSteps: Int
    let totalInputTokens: Int
    let totalCacheReadTokens: Int
    let totalOutputTokens: Int
    let avgCacheHitPercent: Int
    let modelUsage: [ModelUsageCount]

    static func empty(hours: Int) -> PeriodUsageStats {
        PeriodUsageStats(
            windowHours: hours,
            activeChats: 0,
            modelSteps: 0,
            totalInputTokens: 0,
            totalCacheReadTokens: 0,
            totalOutputTokens: 0,
            avgCacheHitPercent: 0,
            modelUsage: []
        )
    }
}

struct ContextBreakdown: Equatable {
    let systemTokens: Int
    let toolsTokens: Int
    let assistantTokens: Int
    let userTokens: Int
    let totalOutputTokens: Int
    let userTurns: Int
    let toolCallsCount: Int
    let topTools: [ToolUsageCount]

    static let empty = ContextBreakdown(
        systemTokens: 0,
        toolsTokens: 0,
        assistantTokens: 0,
        userTokens: 0,
        totalOutputTokens: 0,
        userTurns: 0,
        toolCallsCount: 0,
        topTools: []
    )
}

struct TranscriptStats {
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
    let updatedAt: Date?
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

struct AntigravityAppState {
    let zoomLevel: Double
    let isDarkTheme: Bool
}

struct WindowSnapshot {
    let frame: CGRect
    let title: String
    let isFullScreen: Bool
    let isVisible: Bool
    let pid: pid_t
}

final class RingViewModel: ObservableObject {
    static let thresholdPresets = [128_000, 160_000, 200_000, 256_000, 1_000_000]

    @Published var stats: TranscriptStats?
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

    var contextTokens: Int {
        hasTokenData ? (stats?.contextTokens ?? 0) : 0
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
        guard hasTokenData, let stats, stats.totalModelSteps > 0 else { return "—" }
        let val: Int
        if historyViewMode == .messages, let lastTurn = stats.recentMessages.first {
            val = lastTurn.delta
        } else {
            val = stats.lastDelta
        }
        return Self.formatSignedNumber(val)
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
