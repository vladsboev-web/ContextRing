import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case ru
    case en

    var id: String { rawValue }
}

enum ResolvedLanguage: String {
    case ru
    case en

    static func systemDefault() -> ResolvedLanguage {
        if let preferred = Locale.preferredLanguages.first?.lowercased(), !preferred.isEmpty {
            return preferred.hasPrefix("ru") ? .ru : .en
        }
        if let appleLangs = UserDefaults.standard.stringArray(forKey: "AppleLanguages"),
           let first = appleLangs.first?.lowercased(), !first.isEmpty {
            return first.hasPrefix("ru") ? .ru : .en
        }
        return .en
    }
}

enum HistoryViewMode: String, CaseIterable, Identifiable {
    case messages
    case steps

    var id: String { rawValue }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case context
    case stats

    var id: String { rawValue }
}

enum StatsPeriod: Int, CaseIterable, Identifiable {
    case day = 24
    case week = 168

    var id: Int { rawValue }
}

enum L10n {
    // MARK: - Option Enums

    static func languagePreferenceName(_ pref: AppLanguagePreference, lang: ResolvedLanguage) -> String {
        switch pref {
        case .system: return lang == .ru ? "Авто (система)" : "Auto (System)"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    static func historyModeName(_ mode: HistoryViewMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .messages: return lang == .ru ? "Сообщения" : "Messages"
        case .steps: return lang == .ru ? "Шаги" : "Steps"
        }
    }

    static func detailTabName(_ tab: DetailTab, lang: ResolvedLanguage) -> String {
        switch tab {
        case .context: return lang == .ru ? "Контекст" : "Context"
        case .stats: return lang == .ru ? "Статистика" : "Stats"
        }
    }

    static func statsPeriodName(_ period: StatsPeriod, lang: ResolvedLanguage) -> String {
        switch period {
        case .day: return lang == .ru ? "24ч" : "24h"
        case .week: return lang == .ru ? "7дн" : "7d"
        }
    }

    static func ringStyleName(_ style: RingStyle, lang: ResolvedLanguage) -> String {
        switch style {
        case .classic: return lang == .ru ? "Классика" : "Classic"
        case .minimal: return lang == .ru ? "Минимал" : "Minimal"
        case .codex: return "Codex"
        }
    }

    static func themeName(_ theme: ThemePreference, lang: ResolvedLanguage) -> String {
        switch theme {
        case .auto: return lang == .ru ? "Авто" : "Auto"
        case .light: return lang == .ru ? "Светлая" : "Light"
        case .dark: return lang == .ru ? "Тёмная" : "Dark"
        }
    }

    static func positionModeName(_ mode: PositionMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .snapToEdges: return lang == .ru ? "К 2 краям окна" : "2 nearest edges"
        case .freeAbsolute: return lang == .ru ? "Свободно на экране" : "Free on screen"
        }
    }

    static func launchModeName(_ mode: LaunchMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .withAntigravity: return lang == .ru ? "С Antigravity" : "With Antigravity"
        case .withSystem: return lang == .ru ? "С системой" : "With macOS"
        case .manual: return lang == .ru ? "Вручную" : "Manual"
        }
    }

    static func edgeAnchorSummary(_ anchor: EdgeAnchor, lang: ResolvedLanguage) -> String {
        let hLabel: String
        let vLabel: String
        if lang == .ru {
            hLabel = anchor.horizontalEdge == .leading ? "слева" : "справа"
            vLabel = anchor.verticalEdge == .bottom ? "снизу" : "сверху"
        } else {
            hLabel = anchor.horizontalEdge == .leading ? "left" : "right"
            vLabel = anchor.verticalEdge == .bottom ? "bottom" : "top"
        }
        return "\(hLabel) \(Int(anchor.horizontalOffset.rounded())) pt, \(vLabel) \(Int(anchor.verticalOffset.rounded())) pt"
    }

    static func formatDuration(seconds: Int, lang: ResolvedLanguage) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 60 {
            return lang == .ru ? "<1м" : "<1m"
        }
        let totalMinutes = seconds / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let mins = totalMinutes % 60
        if days > 0 {
            return lang == .ru ? "\(days)д \(hours)ч" : "\(days)d \(hours)h"
        }
        if hours > 0 {
            return lang == .ru ? "\(hours)ч \(mins)м" : "\(hours)h \(mins)m"
        }
        return lang == .ru ? "\(mins)м" : "\(mins)m"
    }

    // MARK: - Handoff Prompt

    static func handoffPrompt(_ lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return "Мы приближаемся к порогу контекстного окна. Сохрани файл HANDOFF.md в корне проекта (или в артефакт) со строгой структурой:\n" +
                "1. Изменённые и ключевые файлы (точные пути и что сделано).\n" +
                "2. Что уже решено и проверено (точные команды и результаты).\n" +
                "3. Строгие ограничения и неудачные попытки (чего НЕ делать и что не сработало).\n" +
                "4. Конкретные следующие шаги для продолжения в новом чистом чате."
        }
        return "We are approaching the context window threshold. Save a HANDOFF.md file in the project root (or as an artifact) with this strict structure:\n" +
            "1. Modified and key files (exact paths and what changed).\n" +
            "2. What has been resolved and verified (exact commands and results).\n" +
            "3. Strict constraints and failed attempts (what NOT to do and what did not work).\n" +
            "4. Concrete next steps to continue cleanly in a fresh chat."
    }

    // MARK: - Hover Tooltip

    static func activeChatFallback(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Активный чат" : "Active chat"
    }

    static func compactionsBadge(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "сжатий: \(count)×" : "compactions: \(count)×"
    }

    static func noTokenLogsShort(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Нет логов токенов для этого чата" : "No token logs for this chat"
    }

    // MARK: - Detail Card & Dropdown

    static func autoBadge(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Авто" : "Auto"
    }

    static func manualToAutoBadge(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Ручной ↺ Авто" : "Manual ↺ Auto"
    }

    static func autoActiveWindowOption(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Авто (активное окно)" : "Auto (active window)"
    }

    static func chatHistoryEmpty(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "История чатов пуста" : "No recent chats"
    }

    static func recentChatsCount(_ count: Int, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return count > 0 ? "Последние \(count) чатов" : "Последние чаты"
        }
        return count > 0 ? "Last \(count) chats" : "Recent chats"
    }

    static func tokensSuffix(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "токенов" : "tokens"
    }

    static func noTokenLogsBanner(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Нет логов токенов для этого чата (старый или пустой чат)."
            : "No token logs for this chat (old or empty conversation)."
    }

    static func alertRed(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Близко к авто-сжатию: рекомендуется сохранить HANDOFF.md и открыть новый чат."
            : "Near auto-compaction: save HANDOFF.md and continue in a fresh chat."
    }

    static func alertAmber(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Контекст заполняется: лучше завершить текущую подзадачу и не смешивать темы."
            : "Context filling up: finish the current subtask without mixing topics."
    }

    static func alertCompactions(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "В этом чате уже было авто-сжатие (\(count)×)."
            : "Auto-compaction occurred in this chat (\(count)×)."
    }

    static func breakdownTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Структура контекста" : "Context breakdown"
    }

    static func estimateTag(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "оценка" : "estimate"
    }

    static func segmentSystem(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Система и правила" : "System & rules"
    }

    static func subBasePrompt(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Базовый промпт и правила" : "Base prompt & rules"
    }

    static func subSystemMessages(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Системные сообщения" : "System messages"
    }

    static func subConversationHistory(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Память прошлых чатов" : "Conversation history"
    }

    static func subCheckpointSummary(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Сводка после сжатия" : "Compaction summary"
    }

    static func segmentFiles(_ count: Int, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return count > 0 ? "Файлы в контексте (\(count))" : "Файлы в контексте"
        }
        return count > 0 ? "Files in context (\(count))" : "Files in context"
    }

    static func segmentToolsWithCount(_ count: Int, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return count > 0 ? "Инструменты и команды (\(count))" : "Инструменты и команды"
        }
        return count > 0 ? "Tools & commands (\(count))" : "Tools & commands"
    }

    static func segmentAssistant(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Ответы модели" : "Model responses"
    }

    static func segmentThinking(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Рассуждения (Thinking)" : "Thinking"
    }

    static func segmentUserWithMedia(_ mediaCount: Int, lang: ResolvedLanguage) -> String {
        if mediaCount > 0 {
            return lang == .ru ? "Сообщения (\(mediaCount) влож.)" : "User messages (\(mediaCount) media)"
        }
        return lang == .ru ? "Сообщения" : "User messages"
    }

    static func outputAndToolsFooter(outputK: String, toolCalls: Int, toolsTail: String, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return "Вывод: \(outputK) · Инструментов: \(toolCalls)\(toolsTail)"
        }
        return "Output: \(outputK) · Tools: \(toolCalls)\(toolsTail)"
    }

    static func metricPrimaryModel(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Основная модель" : "Primary model"
    }

    static func metricModelSingle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Модель" : "Model"
    }

    static func scopeAllChat(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Весь чат" : "All chat"
    }

    static func scopeGroupManual(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Ручной режим" : "Manual"
    }

    static func scopeGroupOrchestrator(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Оркестратор" : "Orchestrator"
    }

    static func scopeAllInGroup(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Общее" : "All"
    }

    static func scopeOrchestratorPlanner(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Оркестр" : "Planner"
    }

    static func scopeOrchestratorExecutor(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Исполнитель" : "Executor"
    }

    static func hoverScopeBadge(scope: ChatStatsScope, stats: TranscriptStats?, lang: ResolvedLanguage) -> String {
        guard let stats else { return "" }
        let scoped = stats.snapshot(for: scope)
        let modelName = !scoped.model.isEmpty ? scoped.model : scoped.sessionStats.primaryModel
        let short = RingViewModel.shortModelName(modelName)

        switch scope {
        case .allChat:
            if stats.hasOrchestratorMode && !stats.hasManualMode {
                return short.isEmpty
                    ? "\(scopeGroupOrchestrator(lang)) · \(scopeAllInGroup(lang))"
                    : "\(scopeGroupOrchestrator(lang)) · \(scopeAllInGroup(lang)) (\(short))"
            }
            if stats.hasManualMode && !stats.hasOrchestratorMode {
                if short.isEmpty {
                    return scopeGroupManual(lang)
                }
                if scoped.sessionStats.otherModelsCount > 0 {
                    return "\(scopeGroupManual(lang)) · \(short) (+\(scoped.sessionStats.otherModelsCount))"
                }
                return "\(scopeGroupManual(lang)) · \(short)"
            }
            if short.isEmpty {
                return scopeAllChat(lang)
            }
            if scoped.sessionStats.otherModelsCount > 0 {
                return "\(scopeAllChat(lang)) · \(short) (+\(scoped.sessionStats.otherModelsCount))"
            }
            return "\(scopeAllChat(lang)) · \(short)"
        case .manualAll:
            if short.isEmpty {
                return "\(scopeGroupManual(lang)) · \(scopeAllInGroup(lang))"
            }
            return "\(scopeGroupManual(lang)) · \(scopeAllInGroup(lang)) (\(short))"
        case .manualModel(let key):
            let itemShort = stats.manualModels.first(where: { $0.id == key })?.shortName ?? short
            let label = !itemShort.isEmpty ? itemShort : short
            return label.isEmpty ? scopeGroupManual(lang) : "\(scopeGroupManual(lang)) · \(label)"
        case .orchestratorAll:
            return "\(scopeGroupOrchestrator(lang)) · \(scopeAllInGroup(lang))"
        case .orchestratorPlanner:
            return short.isEmpty
                ? "\(scopeGroupOrchestrator(lang)) · \(scopeOrchestratorPlanner(lang))"
                : "\(scopeGroupOrchestrator(lang)) · \(scopeOrchestratorPlanner(lang)) (\(short))"
        case .orchestratorExecutor:
            return short.isEmpty
                ? "\(scopeGroupOrchestrator(lang)) · \(scopeOrchestratorExecutor(lang))"
                : "\(scopeGroupOrchestrator(lang)) · \(scopeOrchestratorExecutor(lang)) (\(short))"
        }
    }

    static func metricLastDelta(_ mode: HistoryViewMode, lang: ResolvedLanguage) -> String {
        switch (mode, lang) {
        case (.messages, .ru): return "Последнее сообщение"
        case (.messages, .en): return "Last message"
        case (.steps, .ru): return "Последний шаг"
        case (.steps, .en): return "Last step"
        }
    }

    static func metricCache(_ mode: HistoryViewMode, lang: ResolvedLanguage) -> String {
        switch (mode, lang) {
        case (.messages, .ru): return "Кэш (посл. сообщ.)"
        case (.messages, .en): return "Cache (last msg)"
        case (.steps, .ru): return "Кэш (посл. шаг)"
        case (.steps, .en): return "Cache (last step)"
        }
    }

    static func metricCacheCombined(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Кэш (посл. / ср.)" : "Cache (last / avg)"
    }

    static func metricInputOutput(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Вход + Вывод" : "Input + Output"
    }

    static func metricCountPeak(_ mode: HistoryViewMode, lang: ResolvedLanguage) -> String {
        switch (mode, lang) {
        case (.messages, .ru): return "Сообщений / Пик"
        case (.messages, .en): return "Messages / Peak"
        case (.steps, .ru): return "Шагов / Пик"
        case (.steps, .en): return "Steps / Peak"
        }
    }

    static func copyHandoffButton(_ copied: Bool, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return copied ? "Скопировано в буфер ✓" : "Скопировать промпт для HANDOFF"
        }
        return copied ? "Copied to clipboard ✓" : "Copy HANDOFF prompt"
    }

    static func recentActivityTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Последние ходы" : "Recent activity"
    }

    static func columnIndex(_ mode: HistoryViewMode, lang: ResolvedLanguage) -> String {
        switch (mode, lang) {
        case (.messages, .ru): return "Сообщ."
        case (.messages, .en): return "Msg"
        case (.steps, .ru): return "Шаг"
        case (.steps, .en): return "Step"
        }
    }

    static func columnContext(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Контекст" : "Context"
    }

    static func columnDelta(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Прирост" : "Delta"
    }

    static func compactedPill(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "⚡ сжатие" : "⚡ compacted"
    }

    static func modelSwitchPill(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "⇄ модель" : "⇄ model"
    }

    static func effortSwitchPill(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "⇄ уровень" : "⇄ effort"
    }

    static func noModelStepsYet(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Пока нет шагов модели" : "No model steps yet"
    }

    // MARK: - Stats Tab

    static func statsCurrentChatTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Текущий чат" : "Current chat"
    }

    static func statsFreshInput(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Свежий вход" : "Fresh input"
    }

    static func statsFromCache(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Из кэша" : "From cache"
    }

    static func statsOutput(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Вывод (ответы)" : "Output"
    }

    static func statsAvgCache(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Средний кэш" : "Avg cache"
    }

    static func statsDuration(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Длительность" : "Duration"
    }

    static func statsMedia(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Вложения" : "Media"
    }

    static func statsErrors(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Ошибки" : "Errors"
    }

    static func statsTools(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Инструменты" : "Tools"
    }

    static func statsModelsInChat(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Модели в чате" : "Models in chat"
    }

    static func statsStepsShort(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "\(count) шаг." : "\(count) steps"
    }

    static func statsAllChatsTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Все чаты" : "All chats"
    }

    static func statsPeriodHeader(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Все чаты за период" : "All chats in period"
    }

    static func statsChatsAndMessages(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Чатов / Сообщений" : "Chats / Messages"
    }

    static func statsActiveTime(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Активное время" : "Active time"
    }

    static func statsPeriodActivityTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Активность за период" : "Period activity"
    }

    static func statsPeriodModels(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Модели за период (\(count))" : "Models in period (\(count))"
    }

    static func statsPeriodFiles(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Файлы за период (\(count))" : "Files in period (\(count))"
    }

    static func statsPeriodTools(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Инструменты за период (\(count))" : "Tools in period (\(count))"
    }

    static func statsPeriodChats(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Активные чаты (\(count))" : "Active chats (\(count))"
    }

    static func statsTouchesShort(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "\(count) обр." : "\(count) refs"
    }

    static func statsCallsShort(_ count: Int, lang: ResolvedLanguage) -> String {
        lang == .ru ? "\(count) выз." : "\(count) calls"
    }

    static func statsPeakShort(_ peakK: String, lang: ResolvedLanguage) -> String {
        lang == .ru ? "пик \(peakK)" : "peak \(peakK)"
    }

    static func statsActiveChats(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Активных чатов" : "Active chats"
    }

    static func statsModelCalls(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Запросов к моделям" : "Model calls"
    }

    static func statsInputPlusOutput(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Вход + вывод" : "Input + output"
    }

    static func statsNoPeriodActivity(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Нет активности за выбранный период" : "No activity in this period"
    }

    // MARK: - Menu Bar

    static func menuChat(_ title: String, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Чат: \(title)" : "Chat: \(title)"
    }

    static func menuNotDetected(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "не определён" : "not detected"
    }

    static func menuContext(_ formattedUsed: String, limit: String, percent: Int, hasData: Bool, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            return hasData
                ? "Контекст: \(formattedUsed) / \(limit) (\(percent)%)"
                : "Контекст: нет данных"
        }
        return hasData
            ? "Context: \(formattedUsed) / \(limit) (\(percent)%)"
            : "Context: no data"
    }

    static func menuWindow(isFullScreen: Bool, zoom: String, lang: ResolvedLanguage) -> String {
        if lang == .ru {
            let mode = isFullScreen ? "Полный экран" : "Обычное"
            return "Окно: \(mode) · Zoom: \(zoom)"
        }
        let mode = isFullScreen ? "Fullscreen" : "Windowed"
        return "Window: \(mode) · Zoom: \(zoom)"
    }

    static func menuLanguage(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Язык" : "Language"
    }

    static func menuSettings(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Настройки…" : "Settings…"
    }

    static func menuGrantAccessibility(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Выдать доступ Accessibility…" : "Grant Accessibility Access…"
    }

    static func menuResetPosition(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Сбросить позицию кольца" : "Reset ring position"
    }

    static func menuQuit(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Выход" : "Quit"
    }

    // MARK: - Settings Window

    static func settingsWindowTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Настройки ContextRing" : "ContextRing Settings"
    }

    static func settingsPreviewTitle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Предпросмотр кольца" : "Ring Preview"
    }

    static func settingsPreviewStats(size: Int, scale: CGFloat, lang: ResolvedLanguage) -> String {
        let s = String(format: "%.2f", Double(scale))
        return lang == .ru
            ? "Итоговый размер: \(size) pt · масштаб ×\(s)"
            : "Effective size: \(size) pt · scale ×\(s)"
    }

    static func settingsPreviewHint(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Кольцо остаётся видимым поверх Antigravity, пока открыто это окно — можно настраивать вживую."
            : "The ring stays visible over Antigravity while this window is open so you can tune it live."
    }

    static func settingsThresholdSection(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Порог контекста" : "Context Threshold"
    }

    static func settingsCustomNumberLabel(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Своё число:" : "Custom:"
    }

    static func settingsCustomThresholdPlaceholder(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Напр. 300k, 500000 или 1.5M" : "e.g. 300k, 500000 or 1.5M"
    }

    static func settingsApplyButton(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Применить" : "Apply"
    }

    static func settingsActiveThreshold(_ formatted: String, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Активный порог: \(formatted) токенов"
            : "Active threshold: \(formatted) tokens"
    }

    static func settingsCustomThresholdError(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Введи число, напр. 300k, 500000 или 1.5M"
            : "Enter a number, e.g. 300k, 500000 or 1.5M"
    }

    static func settingsAppearanceSection(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Размеры, шрифты и стиль" : "Size, Fonts & Style"
    }

    static func settingsLinkZoomToggle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Привязывать размеры к масштабу Antigravity" : "Scale sizes with Antigravity zoom"
    }

    static func settingsZoomSummary(current: String, base: String, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Zoom Antigravity: \(current) · базовый: \(base)"
            : "Antigravity Zoom: \(current) · base: \(base)"
    }

    static func settingsCaptureZoomButton(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Зафиксировать текущий" : "Set current as base"
    }

    static func settingsRingSize(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Размер кольца" : "Ring size"
    }

    static func settingsStrokeWidth(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Толщина дуги" : "Stroke width"
    }

    static func settingsShowPercentToggle(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Показывать % внутри кольца" : "Show % inside ring"
    }

    static func settingsRingFontSize(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Шрифт внутри кольца" : "Ring % font size"
    }

    static func settingsHoverFontSize(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Шрифт подсказки (hover)" : "Hover tooltip font"
    }

    static func settingsDetailFontSize(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Шрифт окна по клику" : "Detail card font"
    }

    static func settingsStyleLabel(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Стиль" : "Style"
    }

    static func settingsThemeLabel(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Тема" : "Theme"
    }

    static func settingsPositionSection(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Позиция и привязка" : "Position & Snapping"
    }

    static func settingsWindowedAnchor(_ summary: String, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Обычное окно: \(summary)" : "Windowed: \(summary)"
    }

    static func settingsFreeAnchorCoords(x: Int, y: Int, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Свободно на экране: x=\(x), y=\(y)"
            : "Free on screen: x=\(x), y=\(y)"
    }

    static func settingsFreeAnchorHint(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Свободно: перетащи кольцо, чтобы зафиксировать точку на экране"
            : "Free: drag the ring to pin an absolute screen position"
    }

    static func settingsFullscreenAnchor(_ summary: String, lang: ResolvedLanguage) -> String {
        lang == .ru ? "Полный экран: \(summary)" : "Fullscreen: \(summary)"
    }

    static func settingsSnapToSendButton(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Над кнопкой «Отправить» (AX)" : "Above Send button (AX)"
    }

    static func settingsResetPosButton(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Сбросить позицию" : "Reset position"
    }

    static func settingsSystemSection(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Язык, запуск и система" : "Language, Launch & System"
    }

    static func settingsLanguageLabel(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Язык" : "Language"
    }

    static func settingsLaunchModeLabel(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Автозапуск" : "Launch at"
    }

    static func settingsLaunchModeNote(_ mode: LaunchMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .withAntigravity:
            return lang == .ru
                ? "Запускается через macOS LaunchAgent только при старте Antigravity и полностью закрывается при выходе (не висит в фоне)."
                : "Launches via macOS LaunchAgent only when Antigravity starts and quits completely on exit (zero background process)."
        case .withSystem:
            return lang == .ru
                ? "Запускается при входе в macOS и тихо ждёт в меню-баре, показывая кольцо при открытии Antigravity."
                : "Starts at macOS login and waits quietly in the menu bar, showing the ring whenever Antigravity opens."
        case .manual:
            return lang == .ru
                ? "Автозапуск отключён. Программа запускается вручную и закрывается при выходе из Antigravity."
                : "Auto-launch disabled. Start the app manually; it exits when Antigravity quits."
        }
    }

    static func statusLaunchAgentError(_ errorDesc: String, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Не удалось настроить LaunchAgent (\(errorDesc))."
            : "Failed to configure LaunchAgent (\(errorDesc))."
    }

    static func settingsAccessibilityMissing(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Accessibility: нет доступа" : "Accessibility: permission required"
    }

    static func settingsOpenAccessibilityButton(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Универсальный доступ…" : "Open Accessibility…"
    }

    // MARK: - Runtime Status Messages

    static func statusNeedAccessibility(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Сначала выдай доступ Accessibility." : "Grant Accessibility permission first."
    }

    static func statusWindowNotFound(_ lang: ResolvedLanguage) -> String {
        lang == .ru ? "Окно Antigravity не найдено." : "Antigravity window not found."
    }

    static func statusSendFound(_ summary: String, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Кнопка «Отправить» найдена: \(summary)."
            : "Send button located: \(summary)."
    }

    static func statusSendNotExposed(_ lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "Antigravity (Electron) не отдаёт кнопку «Отправить» через Accessibility. Перетащи кольцо вручную — позиция привяжется к 2 ближайшим краям."
            : "Antigravity (Electron) does not expose the Send button via Accessibility. Drag the ring manually to snap to the 2 nearest edges."
    }

    static func statusLoginItemDenied(_ errorDesc: String, lang: ResolvedLanguage) -> String {
        lang == .ru
            ? "macOS отклонила автозапуск из текущей папки (\(errorDesc)). Для режима «С системой» перенеси ContextRing.app в /Applications."
            : "macOS denied login item from this folder (\(errorDesc)). Move ContextRing.app to /Applications to use \"With macOS\"."
    }
}
