import AppKit
import Foundation
import SQLite3

/// Read-only local reader for Antigravity conversation metadata, transcripts, and app state.
final class AntigravityDataReader {
    private struct FileStamp: Equatable {
        let modificationDate: Date?
        let fileSize: UInt64
    }

    private struct CachedTranscript {
        let path: String
        let stamp: FileStamp
        let stats: TranscriptStats
    }

    private struct CachedAppState {
        let stamp: FileStamp
        let state: AntigravityAppState
    }

    private struct StepRecord {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
    }

    private struct CachedStepLog {
        let path: String
        let stamp: FileStamp
        let records: [StepRecord]
    }

    private let homeDir: URL
    private let dbPath: String
    private let brainDir: URL
    private let appStoragePath: String

    private var transcriptCache: [String: CachedTranscript] = [:]
    private var stepLogCache: [String: CachedStepLog] = [:]
    private var appStateCache: CachedAppState?

    private static let uuidRegex = try? NSRegularExpression(pattern: "^[0-9a-f-]{8,}$", options: [.caseInsensitive])
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.homeDir = home
        self.dbPath = home.appendingPathComponent(".gemini/antigravity/conversation_summaries.db").path
        self.brainDir = home.appendingPathComponent(".gemini/antigravity/brain")
        self.appStoragePath = home.appendingPathComponent("Library/Application Support/Antigravity/app_storage.json").path
    }

    func resolveConversationId(forWindowTitle rawTitle: String) -> (id: String, title: String)? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGenericTitle = trimmed.isEmpty || trimmed.caseInsensitiveCompare("Antigravity") == .orderedSame
        let candidates = isGenericTitle ? [] : buildTitleCandidates(from: trimmed)

        if let dbMatch = queryConversationSummaries(candidates: candidates, allowLatestFallback: isGenericTitle) {
            return dbMatch
        }
        if isGenericTitle, let latestId = findNewestTranscriptInBrain() {
            return (latestId, String(latestId.prefix(8)))
        }
        return nil
    }

    static func cleanWindowTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let lastDash = trimmed.range(of: " - ", options: .backwards) {
            let prefix = String(trimmed[..<lastDash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }
        return trimmed
    }

    func listRecentConversations(limit: Int = 10) -> [RecentConversationItem] {
        var entries = queryRecentSummariesFromDB(limit: limit)
        if entries.isEmpty {
            entries = scanRecentInBrain(limit: limit)
        }

        return entries.map { item in
            let stats = readTranscriptStats(conversationId: item.id, fallbackTitle: item.title)
            let resolvedTitle = !item.title.isEmpty
                ? item.title
                : (stats?.title ?? String(item.id.prefix(8)))
            return RecentConversationItem(
                id: item.id,
                title: resolvedTitle,
                contextTokens: stats?.contextTokens ?? 0,
                model: stats?.model ?? ""
            )
        }
    }

    func readTranscriptStats(conversationId: String, fallbackTitle: String) -> TranscriptStats? {
        guard let transcriptPath = resolveTranscriptPath(conversationId: conversationId) else {
            return nil
        }

        let currentStamp = fileStamp(atPath: transcriptPath)
        if let cached = transcriptCache[conversationId],
           cached.path == transcriptPath,
           let currentStamp,
           cached.stamp == currentStamp {
            return cached.stats
        }

        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let rawText = String(data: data, encoding: .utf8) else {
            return nil
        }

        var extractedTitle = ""
        var totalSteps = 0
        var modelStepsCount = 0
        var modelSamples: [ModelStepSample] = []
        var messageTurns: [MessageTurnSample] = []
        var lastInput = 0
        var lastCache = 0
        var lastOutput = 0
        var lastTotal = 0
        var prevTotal = 0
        var lastModel = ""
        var lastCreatedAt: Date?
        var allTimePeak = 0
        var segmentPeak = 0
        var pendingCompaction = false
        var compactionEvents = 0

        var firstModelTotal: Int?
        var firstUserChars = 0
        var totalInputTokens = 0
        var totalCacheReadTokens = 0
        var totalOutputTokens = 0
        var userTurns = 0
        var toolCallsCount = 0
        var toolNameCounts: [String: Int] = [:]
        var modelStepCounts: [String: Int] = [:]
        var modelOutputCounts: [String: Int] = [:]
        var modelLastSeenIndex: [String: Int] = [:]
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var mediaCount = 0
        var errorCount = 0

        var userChars = 0
        var assistantChars = 0
        var toolsChars = 0
        var systemMsgChars = 0

        var currentTurnIndex = 0
        var currentTurnSteps = 0
        var currentTurnEndTokens = 0
        var currentTurnSumInput = 0
        var currentTurnSumCache = 0
        var currentTurnLastCache = 0
        var currentTurnHadCompaction = false
        var previousTurnEndTokens = 0

        func finalizeCurrentTurn() {
            guard currentTurnSteps > 0 else { return }
            let turnDelta = currentTurnEndTokens - previousTurnEndTokens
            let turnDenom = currentTurnSumInput + currentTurnSumCache
            let turnCachePct = turnDenom > 0
                ? Int((Double(currentTurnSumCache) / Double(turnDenom) * 100.0).rounded())
                : 0
            messageTurns.append(
                MessageTurnSample(
                    turnIndex: max(1, currentTurnIndex),
                    contextTokens: currentTurnEndTokens,
                    delta: turnDelta,
                    modelStepsInTurn: currentTurnSteps,
                    cacheReadTokens: currentTurnLastCache,
                    cacheHitPercent: turnCachePct,
                    hadCompaction: currentTurnHadCompaction
                )
            )
            previousTurnEndTokens = currentTurnEndTokens
            currentTurnSteps = 0
            currentTurnSumInput = 0
            currentTurnSumCache = 0
            currentTurnLastCache = 0
            currentTurnHadCompaction = false
        }

        rawText.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                return
            }

            totalSteps += 1
            let stepType = (obj["type"] as? String) ?? ""
            let contentStr = (obj["content"] as? String) ?? ""

            if let createdStr = obj["created_at"] as? String,
               let parsedDate = Self.parseDate(createdStr) {
                if firstTimestamp == nil {
                    firstTimestamp = parsedDate
                }
                lastTimestamp = parsedDate
            }

            if let mediaArr = obj["media"] as? [Any] {
                mediaCount += mediaArr.count
            }
            if let errStr = obj["error"] as? String, !errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorCount += 1
            }

            switch stepType {
            case "CHECKPOINT":
                compactionEvents += 1
                pendingCompaction = true
                segmentPeak = 0
                userChars = 0
                assistantChars = 0
                toolsChars = 0
                systemMsgChars = 0
                if currentTurnSteps > 0 {
                    currentTurnHadCompaction = true
                }
            case "USER_INPUT":
                finalizeCurrentTurn()
                userTurns += 1
                currentTurnIndex = userTurns
                currentTurnSteps = 0
                currentTurnEndTokens = 0
                currentTurnSumInput = 0
                currentTurnSumCache = 0
                currentTurnLastCache = 0
                currentTurnHadCompaction = false
                userChars += contentStr.count
                if firstModelTotal == nil {
                    firstUserChars += contentStr.count
                }
                if extractedTitle.isEmpty && !contentStr.isEmpty {
                    extractedTitle = Self.cleanTitle(contentStr)
                }
            case "PLANNER_RESPONSE":
                assistantChars += contentStr.count
                if let thinkingStr = obj["thinking"] as? String {
                    assistantChars += thinkingStr.count
                }
                if let toolCalls = obj["tool_calls"] as? [[String: Any]] {
                    toolCallsCount += toolCalls.count
                    for call in toolCalls {
                        if let name = call["name"] as? String, !name.isEmpty {
                            toolNameCounts[name, default: 0] += 1
                        }
                    }
                    if let tcData = try? JSONSerialization.data(withJSONObject: toolCalls) {
                        toolsChars += tcData.count
                    }
                }
            case "SYSTEM_MESSAGE":
                systemMsgChars += contentStr.count
            case "GENERIC":
                toolsChars += contentStr.count
            default:
                break
            }

            if let inVal = Self.intValue(obj["input_tokens"]) {
                let cacheVal = Self.intValue(obj["cache_read_tokens"]) ?? 0
                let outVal = Self.intValue(obj["output_tokens"]) ?? 0
                let total = inVal + cacheVal
                let stepIdx = Self.intValue(obj["step_index"]) ?? totalSteps
                let modelName = (obj["model"] as? String) ?? ""

                if firstModelTotal == nil {
                    firstModelTotal = total
                }
                totalInputTokens += inVal
                totalCacheReadTokens += cacheVal
                totalOutputTokens += outVal

                if !modelName.isEmpty {
                    modelStepCounts[modelName, default: 0] += 1
                    modelOutputCounts[modelName, default: 0] += outVal
                    modelLastSeenIndex[modelName] = modelStepsCount
                }

                var stepCompacted = false
                if pendingCompaction {
                    stepCompacted = true
                    pendingCompaction = false
                    segmentPeak = total
                } else if segmentPeak > 0 {
                    let drop = segmentPeak - total
                    if drop > 25_000 && (Double(drop) / Double(segmentPeak)) > 0.30 {
                        compactionEvents += 1
                        stepCompacted = true
                        segmentPeak = total
                        userChars = 0
                        assistantChars = 0
                        toolsChars = 0
                        systemMsgChars = 0
                    } else {
                        segmentPeak = max(segmentPeak, total)
                    }
                } else {
                    segmentPeak = total
                }

                if total > allTimePeak {
                    allTimePeak = total
                }

                let stepDelta = modelStepsCount > 0 ? (total - lastTotal) : total
                modelSamples.append(
                    ModelStepSample(
                        stepIndex: stepIdx,
                        contextTokens: total,
                        delta: stepDelta,
                        isCompaction: stepCompacted
                    )
                )

                if currentTurnIndex == 0 {
                    currentTurnIndex = 1
                }
                currentTurnSteps += 1
                currentTurnEndTokens = total
                currentTurnSumInput += inVal
                currentTurnSumCache += cacheVal
                currentTurnLastCache = cacheVal
                if stepCompacted {
                    currentTurnHadCompaction = true
                }

                prevTotal = lastTotal
                lastTotal = total
                lastInput = inVal
                lastCache = cacheVal
                lastOutput = outVal
                lastModel = modelName
                if let created = obj["created_at"] as? String {
                    lastCreatedAt = Self.parseDate(created)
                }
                modelStepsCount += 1
            }
        }

        finalizeCurrentTurn()

        let sortedModels = modelStepCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsLast = modelLastSeenIndex[lhs.key] ?? -1
                let rhsLast = modelLastSeenIndex[rhs.key] ?? -1
                return lhsLast > rhsLast
            }
            .map { ModelUsageCount(name: $0.key, steps: $0.value, outputTokens: modelOutputCounts[$0.key] ?? 0) }

        let primaryModel = sortedModels.first?.name ?? lastModel
        let otherModelsCount = max(0, sortedModels.count - 1)
        let sessionDenom = totalInputTokens + totalCacheReadTokens
        let avgCacheHitPercent = sessionDenom > 0
            ? Int((Double(totalCacheReadTokens) / Double(sessionDenom) * 100.0).rounded())
            : 0
        let durationSeconds: Int
        if let firstTimestamp, let lastTimestamp, lastTimestamp >= firstTimestamp {
            durationSeconds = Int(lastTimestamp.timeIntervalSince(firstTimestamp).rounded())
        } else {
            durationSeconds = 0
        }

        let sessionStats = ChatSessionStats(
            primaryModel: primaryModel,
            otherModelsCount: otherModelsCount,
            modelUsage: sortedModels,
            totalInputTokens: totalInputTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalOutputTokens: totalOutputTokens,
            avgCacheHitPercent: avgCacheHitPercent,
            durationSeconds: durationSeconds,
            mediaCount: mediaCount,
            errorCount: errorCount,
            userMessageCount: max(userTurns, messageTurns.count)
        )

        let breakdown = Self.buildBreakdown(
            lastTotal: lastTotal,
            firstModelTotal: firstModelTotal,
            firstUserChars: firstUserChars,
            systemMsgChars: systemMsgChars,
            toolsChars: toolsChars,
            assistantChars: assistantChars,
            userChars: userChars,
            totalOutputTokens: totalOutputTokens,
            userTurns: userTurns,
            toolCallsCount: toolCallsCount,
            toolNameCounts: toolNameCounts
        )

        let delta = modelStepsCount > 1 ? (lastTotal - prevTotal) : lastTotal
        let cacheHitPercent = lastTotal > 0 ? Int((Double(lastCache) / Double(lastTotal) * 100.0).rounded()) : 0
        let displayTitle = !fallbackTitle.isEmpty
            ? fallbackTitle
            : (!extractedTitle.isEmpty ? extractedTitle : String(conversationId.prefix(8)))

        let stats = TranscriptStats(
            conversationId: conversationId,
            title: displayTitle,
            contextTokens: lastTotal,
            lastInputTokens: lastInput,
            lastCacheReadTokens: lastCache,
            lastOutputTokens: lastOutput,
            lastDelta: delta,
            cacheHitPercent: cacheHitPercent,
            model: lastModel,
            totalModelSteps: modelStepsCount,
            peakTokens: allTimePeak,
            compactionEvents: compactionEvents,
            recentSteps: Array(modelSamples.suffix(6).reversed()),
            recentMessages: Array(messageTurns.suffix(6).reversed()),
            breakdown: breakdown,
            sessionStats: sessionStats,
            updatedAt: lastCreatedAt ?? currentStamp?.modificationDate
        )

        if let currentStamp {
            transcriptCache[conversationId] = CachedTranscript(
                path: transcriptPath,
                stamp: currentStamp,
                stats: stats
            )
        }
        return stats
    }

    func readAppState() -> AntigravityAppState {
        let currentStamp = fileStamp(atPath: appStoragePath)
        if let cached = appStateCache, let currentStamp, cached.stamp == currentStamp {
            return cached.state
        }

        let fallbackDark = Self.isSystemAppearanceDark()
        guard let data = FileManager.default.contents(atPath: appStoragePath),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AntigravityAppState(zoomLevel: 0, isDarkTheme: fallbackDark)
        }

        var zoomLevel: Double = 0
        if let zoomStr = dict["zoomLevel"] as? String, let parsed = Double(zoomStr) {
            zoomLevel = parsed
        } else if let zoomNum = dict["zoomLevel"] as? NSNumber {
            zoomLevel = zoomNum.doubleValue
        }

        var isDark = fallbackDark
        if let hex = dict["hubSurfaceBackgroundColor"] as? String,
           let luminance = Self.hexLuminance(hex) {
            isDark = luminance < 0.5
        }

        let state = AntigravityAppState(zoomLevel: zoomLevel, isDarkTheme: isDark)
        if let currentStamp {
            appStateCache = CachedAppState(stamp: currentStamp, state: state)
        }
        return state
    }

    func readPeriodStats(hours: Int) -> PeriodUsageStats {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600.0)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty(hours: hours)
        }

        var activeChats = 0
        var modelSteps = 0
        var totalIn = 0
        var totalCache = 0
        var totalOut = 0
        var modelCounts: [String: Int] = [:]
        var modelOutputs: [String: Int] = [:]

        for dirURL in entries {
            let convId = dirURL.lastPathComponent
            guard Self.isValidConversationId(convId),
                  let path = resolveTranscriptPath(conversationId: convId),
                  let stamp = fileStamp(atPath: path),
                  let mtime = stamp.modificationDate,
                  mtime >= cutoff else {
                continue
            }

            let records = readStepRecords(conversationId: convId, path: path, stamp: stamp)
            var matchedThisChat = false
            for rec in records where rec.timestamp >= cutoff {
                matchedThisChat = true
                modelSteps += 1
                totalIn += rec.inputTokens
                totalCache += rec.cacheReadTokens
                totalOut += rec.outputTokens
                if !rec.model.isEmpty {
                    modelCounts[rec.model, default: 0] += 1
                    modelOutputs[rec.model, default: 0] += rec.outputTokens
                }
            }
            if matchedThisChat {
                activeChats += 1
            }
        }

        let denom = totalIn + totalCache
        let avgCache = denom > 0 ? Int((Double(totalCache) / Double(denom) * 100.0).rounded()) : 0
        let usage = modelCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { ModelUsageCount(name: $0.key, steps: $0.value, outputTokens: modelOutputs[$0.key] ?? 0) }

        return PeriodUsageStats(
            windowHours: hours,
            activeChats: activeChats,
            modelSteps: modelSteps,
            totalInputTokens: totalIn,
            totalCacheReadTokens: totalCache,
            totalOutputTokens: totalOut,
            avgCacheHitPercent: avgCache,
            modelUsage: usage
        )
    }

    private func readStepRecords(conversationId: String, path: String, stamp: FileStamp) -> [StepRecord] {
        if let cached = stepLogCache[conversationId],
           cached.path == path,
           cached.stamp == stamp {
            return cached.records
        }

        guard let data = FileManager.default.contents(atPath: path),
              let rawText = String(data: data, encoding: .utf8) else {
            return []
        }

        let fallbackDate = stamp.modificationDate ?? Date.distantPast
        var records: [StepRecord] = []

        rawText.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let inVal = Self.intValue(obj["input_tokens"]) else {
                return
            }
            let cacheVal = Self.intValue(obj["cache_read_tokens"]) ?? 0
            let outVal = Self.intValue(obj["output_tokens"]) ?? 0
            let modelName = (obj["model"] as? String) ?? ""
            let ts = (obj["created_at"] as? String).flatMap { Self.parseDate($0) } ?? fallbackDate
            records.append(
                StepRecord(
                    timestamp: ts,
                    model: modelName,
                    inputTokens: inVal,
                    cacheReadTokens: cacheVal,
                    outputTokens: outVal
                )
            )
        }

        stepLogCache[conversationId] = CachedStepLog(path: path, stamp: stamp, records: records)
        return records
    }

    // MARK: - Private Helpers

    private func buildTitleCandidates(from rawTitle: String) -> [String] {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = []
        func appendUnique(_ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty && !candidates.contains(v) {
                candidates.append(v)
            }
        }

        if let lastDash = trimmed.range(of: " - ", options: .backwards) {
            appendUnique(String(trimmed[..<lastDash.lowerBound]))
        }
        if let firstDash = trimmed.range(of: " - ") {
            appendUnique(String(trimmed[..<firstDash.lowerBound]))
        }
        appendUnique(trimmed)
        return candidates
    }

    private func openReadOnlyDB() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db {
            sqlite3_busy_timeout(db, 200)
            sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)
            return db
        }
        if let db { sqlite3_close(db) }

        var immutableDb: OpaquePointer?
        let uri = "file:\(dbPath)?immutable=1"
        if sqlite3_open_v2(uri, &immutableDb, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let immutableDb {
            sqlite3_busy_timeout(immutableDb, 200)
            return immutableDb
        }
        if let immutableDb { sqlite3_close(immutableDb) }
        return nil
    }

    private func queryRecentSummariesFromDB(limit: Int) -> [(id: String, title: String)] {
        guard let db = openReadOnlyDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT conversation_id, title FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [(id: String, title: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if !id.isEmpty {
                rows.append((id, title))
            }
        }
        return rows
    }

    private func scanRecentInBrain(limit: Int) -> [(id: String, title: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [(id: String, mtime: Date)] = []
        for dirURL in entries {
            let name = dirURL.lastPathComponent
            guard Self.isValidConversationId(name),
                  let path = resolveTranscriptPath(conversationId: name),
                  let stamp = fileStamp(atPath: path),
                  let mtime = stamp.modificationDate else {
                continue
            }
            items.append((name, mtime))
        }
        items.sort { $0.mtime > $1.mtime }
        return items.prefix(limit).map { ($0.id, "") }
    }

    private func queryConversationSummaries(candidates: [String], allowLatestFallback: Bool) -> (id: String, title: String)? {
        guard let db = openReadOnlyDB() else { return nil }
        defer { sqlite3_close(db) }

        let exactSQL = "SELECT conversation_id, title FROM conversation_summaries WHERE title = ? ORDER BY last_modified_time DESC LIMIT 1;"
        let prefixSQL = "SELECT conversation_id, title FROM conversation_summaries WHERE title LIKE ? ESCAPE '\\' ORDER BY last_modified_time DESC LIMIT 1;"

        for candidate in candidates {
            if let match = runSingleStringQuery(db: db, sql: exactSQL, param: candidate) {
                return match
            }
            if candidate.hasSuffix("...") || candidate.hasSuffix("…") {
                let stripped = candidate
                    .replacingOccurrences(of: "...", with: "")
                    .replacingOccurrences(of: "…", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    let escaped = Self.escapeLikePattern(stripped) + "%"
                    if let match = runSingleStringQuery(db: db, sql: prefixSQL, param: escaped) {
                        return match
                    }
                }
            }
        }

        guard allowLatestFallback else { return nil }
        let latestSQL = "SELECT conversation_id, title FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 1;"
        return runNoParamQuery(db: db, sql: latestSQL)
    }

    private func runSingleStringQuery(db: OpaquePointer, sql: String, param: String) -> (id: String, title: String)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = param.withCString { cStr in
            sqlite3_bind_text(stmt, 1, cStr, -1, SQLITE_TRANSIENT)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if !id.isEmpty {
                return (id, title)
            }
        }
        return nil
    }

    private func runNoParamQuery(db: OpaquePointer, sql: String) -> (id: String, title: String)? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if !id.isEmpty {
                return (id, title)
            }
        }
        return nil
    }

    private func resolveTranscriptPath(conversationId: String) -> String? {
        let logsDir = brainDir
            .appendingPathComponent(conversationId)
            .appendingPathComponent(".system_generated/logs")
        let full = logsDir.appendingPathComponent("transcript_full.jsonl").path
        if FileManager.default.fileExists(atPath: full) {
            return full
        }
        let compact = logsDir.appendingPathComponent("transcript.jsonl").path
        if FileManager.default.fileExists(atPath: compact) {
            return compact
        }
        return nil
    }

    private func findNewestTranscriptInBrain() -> String? {
        scanRecentInBrain(limit: 1).first?.id
    }

    private func fileStamp(atPath path: String) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let mtime = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return FileStamp(modificationDate: mtime, fileSize: size)
    }

    private static func isValidConversationId(_ id: String) -> Bool {
        guard let regex = uuidRegex else { return id.count >= 8 }
        let range = NSRange(location: 0, length: id.utf16.count)
        return regex.firstMatch(in: id, options: [], range: range) != nil
    }

    private static func escapeLikePattern(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func cleanTitle(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "<ADDITIONAL_METADATA>[\\s\\S]*?</ADDITIONAL_METADATA>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<USER_REQUEST>", with: "")
        text = text.replacingOccurrences(of: "</USER_REQUEST>", with: "")
        let singleLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if singleLine.count > 60 {
            return String(singleLine.prefix(57)) + "..."
        }
        return singleLine
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let num = any as? NSNumber {
            return num.intValue
        }
        if let str = any as? String, let parsed = Int(str) {
            return parsed
        }
        return nil
    }

    private static func parseDate(_ raw: String) -> Date? {
        isoFormatterWithFractional.date(from: raw) ?? isoFormatter.date(from: raw)
    }

    private static func hexLuminance(_ rawHex: String) -> Double? {
        let hex = rawHex.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\r\n"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func isSystemAppearanceDark() -> Bool {
        let name = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua
    }

    private static func buildBreakdown(
        lastTotal: Int,
        firstModelTotal: Int?,
        firstUserChars: Int,
        systemMsgChars: Int,
        toolsChars: Int,
        assistantChars: Int,
        userChars: Int,
        totalOutputTokens: Int,
        userTurns: Int,
        toolCallsCount: Int,
        toolNameCounts: [String: Int]
    ) -> ContextBreakdown {
        let topTools = toolNameCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(3)
            .map { ToolUsageCount(name: $0.key, count: $0.value) }

        guard lastTotal > 0 else {
            return ContextBreakdown(
                systemTokens: 0,
                toolsTokens: 0,
                assistantTokens: 0,
                userTokens: 0,
                totalOutputTokens: totalOutputTokens,
                userTurns: userTurns,
                toolCallsCount: toolCallsCount,
                topTools: topTools
            )
        }

        let baseSystemEst: Int
        if let firstTotal = firstModelTotal {
            let est = firstTotal - (firstUserChars / 4)
            baseSystemEst = min(max(est, 0), min(lastTotal, 35_000))
        } else {
            baseSystemEst = 0
        }

        let rawSys = Double(baseSystemEst + systemMsgChars / 4)
        let rawTools = Double(toolsChars / 4)
        let rawAssistant = Double(assistantChars / 4)
        let rawUser = Double(userChars / 4)
        let rawSum = rawSys + rawTools + rawAssistant + rawUser

        let sysTok: Int
        let toolsTok: Int
        let assistantTok: Int
        let userTok: Int

        if rawSum > 0 {
            let scale = Double(lastTotal) / rawSum
            sysTok = Int((rawSys * scale).rounded())
            toolsTok = Int((rawTools * scale).rounded())
            assistantTok = Int((rawAssistant * scale).rounded())
            userTok = max(0, lastTotal - sysTok - toolsTok - assistantTok)
        } else {
            sysTok = lastTotal
            toolsTok = 0
            assistantTok = 0
            userTok = 0
        }

        return ContextBreakdown(
            systemTokens: sysTok,
            toolsTokens: toolsTok,
            assistantTokens: assistantTok,
            userTokens: userTok,
            totalOutputTokens: totalOutputTokens,
            userTurns: userTurns,
            toolCallsCount: toolCallsCount,
            topTools: topTools
        )
    }
}
