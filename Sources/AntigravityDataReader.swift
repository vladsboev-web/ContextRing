import AppKit
import Foundation
import SQLite3

/// Read-only local reader for Antigravity conversation metadata, transcripts, and app state.
final class AntigravityDataReader {
    private struct FileStamp: Equatable {
        let modificationDate: Date?
        let fileSize: UInt64
    }

    private struct DBCombinedStamp: Equatable {
        let dbStamp: FileStamp?
        let walStamp: FileStamp?
    }

    private struct CachedAppState {
        let appStorageStamp: FileStamp?
        let userSettingsStamp: FileStamp?
        let state: AntigravityAppState
    }

    private struct StepRecord {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let contextTokens: Int
        let turnIndex: Int
        let isCompaction: Bool
        let toolNames: [String]
        let fileNames: [String]
    }

    private struct CachedTitleResolution {
        let rawTitle: String
        let dbStamp: DBCombinedStamp
        let result: (id: String, title: String)?
    }

    private struct CachedRecentSummaries {
        let limit: Int
        let dbStamp: DBCombinedStamp
        let rows: [(id: String, title: String)]
    }

    private struct CachedPeriodStats {
        let hours: Int
        let oldestIncludedTimestamp: Date?
        let fileSignatures: [String: FileStamp]
        let stats: PeriodUsageStats
    }

    private enum OrchestratorPhase {
        case planner
        case executor
    }

    private struct ParsedStepEntry {
        let stepIndex: Int
        let turnIndex: Int
        let segmentIndex: Int
        let phase: OrchestratorPhase
        let effectiveModel: String
        let modelKey: String
        let inputTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        let contextTokens: Int
        let isCompaction: Bool
        let isModelSwitch: Bool
        let isEffortSwitch: Bool
        let userCharsDelta: Int
        let assistantCharsDelta: Int
        let thinkingCharsDelta: Int
        let filesCharsDelta: Int
        let toolsCharsDelta: Int
        let systemCharsDelta: Int
        let historyCharsDelta: Int
        let checkpointCharsDelta: Int
        let toolCallsDelta: Int
        let toolNames: [String]
        let fileNames: [String]
        let timestamp: Date?
        let mediaCountDelta: Int
        let errorCountDelta: Int
    }

    private final class IncrementalTranscriptState {
        var path: String
        var lastProcessedOffset: UInt64 = 0
        var lastKnownStamp: FileStamp?

        var extractedTitle = ""
        var totalSteps = 0
        var userTurns = 0
        var currentTurnIndex = 0

        var currentUIModel = ""
        var lastRecordedEffectiveModel = ""
        var lastRawStepModelInSegment = ""
        var currentSegmentIndex = 0
        var segmentIsOrchestrator: [Int: Bool] = [0: false]
        var currentPhase: OrchestratorPhase = .planner

        var pendingCompaction = false
        var pendingModelSwitch = false
        var pendingEffortSwitch = false
        var pendingPhaseChange = false
        var compactionEvents = 0

        var allTimePeak = 0
        var segmentPeak = 0
        var checkpointExtraInputTokens = 0
        var checkpointExtraCacheTokens = 0
        var checkpointExtraOutputTokens = 0

        var pendingUserChars = 0
        var pendingAssistantChars = 0
        var pendingThinkingChars = 0
        var pendingFilesChars = 0
        var pendingToolsChars = 0
        var pendingSystemChars = 0
        var pendingHistoryChars = 0
        var pendingCheckpointChars = 0
        var pendingToolCalls = 0
        var pendingToolNames: [String] = []
        var pendingFileNames: [String] = []
        var pendingMediaCount = 0
        var pendingErrorCount = 0
        var lastStepFileToolRatio: Double = 0.0

        var parsedSteps: [ParsedStepEntry] = []
        var stepRecords: [StepRecord] = []
        var cachedStats: (fallbackTitle: String, stamp: FileStamp, stats: TranscriptStats)?

        init(path: String) {
            self.path = path
        }

        func processLineData(_ trimmedData: Data, fallbackTimestamp: Date) {
            guard let obj = (try? JSONSerialization.jsonObject(with: trimmedData)) as? [String: Any] else {
                return
            }

            totalSteps += 1
            let stepType = (obj["type"] as? String) ?? ""
            let source = (obj["source"] as? String) ?? ""
            let contentStr = (obj["content"] as? String) ?? ""
            let parsedDate = (obj["created_at"] as? String).flatMap { AntigravityDataReader.parseDate($0) }

            if let mediaArr = obj["media"] as? [Any] {
                pendingMediaCount += mediaArr.count
            }
            if let errStr = obj["error"] as? String, !errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingErrorCount += 1
            }

            let isCompactionLine = AntigravityDataReader.isCompactionMarker(
                stepType: stepType,
                source: source,
                content: contentStr
            )

            if isCompactionLine {
                if !pendingCompaction {
                    compactionEvents += 1
                    pendingCompaction = true
                }
                segmentPeak = 0
                pendingUserChars = 0
                pendingAssistantChars = 0
                pendingThinkingChars = 0
                pendingFilesChars = 0
                pendingToolsChars = 0
                pendingSystemChars = 0
                pendingHistoryChars = 0
                pendingCheckpointChars = contentStr.count

                if let inVal = AntigravityDataReader.intValue(obj["input_tokens"]) {
                    let cacheVal = AntigravityDataReader.intValue(obj["cache_read_tokens"]) ?? 0
                    let outVal = AntigravityDataReader.intValue(obj["output_tokens"]) ?? 0
                    let total = inVal + cacheVal
                    allTimePeak = max(allTimePeak, total)
                    checkpointExtraInputTokens += inVal
                    checkpointExtraCacheTokens += cacheVal
                    checkpointExtraOutputTokens += outVal
                    let modelName = (obj["model"] as? String) ?? currentUIModel
                    stepRecords.append(
                        StepRecord(
                            timestamp: parsedDate ?? fallbackTimestamp,
                            model: modelName,
                            inputTokens: inVal,
                            cacheReadTokens: cacheVal,
                            outputTokens: outVal,
                            contextTokens: total,
                            turnIndex: 0,
                            isCompaction: false,
                            toolNames: [],
                            fileNames: []
                        )
                    )
                }
                return
            }

            var hasExitPlanTool = false
            var hasEnterPlanTool = false

            switch stepType {
            case "USER_INPUT":
                userTurns += 1
                currentTurnIndex = userTurns
                currentPhase = .planner
                handleSettingsChangeIfPresent(in: contentStr)
                pendingUserChars += contentStr.count
                if extractedTitle.isEmpty && !contentStr.isEmpty {
                    extractedTitle = AntigravityDataReader.cleanTitle(contentStr)
                }
            case "PLANNER_RESPONSE":
                pendingAssistantChars += contentStr.count
                if let thinkingStr = obj["thinking"] as? String {
                    pendingThinkingChars += thinkingStr.count
                }
                if let toolCalls = obj["tool_calls"] as? [[String: Any]] {
                    pendingToolCalls += toolCalls.count
                    var fileCallsCount = 0
                    for call in toolCalls {
                        let callChars = AntigravityDataReader.estimateJSONCharCount(call)
                        let name = (call["name"] as? String) ?? ""
                        if !name.isEmpty {
                            pendingToolNames.append(name)
                            if name == "exit_plan_mode" {
                                hasExitPlanTool = true
                            } else if name == "enter_plan_mode" {
                                hasEnterPlanTool = true
                            }
                        }
                        if let fileName = AntigravityDataReader.extractTouchedFileName(from: call) {
                            pendingFileNames.append(fileName)
                        }
                        if AntigravityDataReader.isFileToolName(name) {
                            pendingFilesChars += callChars
                            fileCallsCount += 1
                        } else {
                            pendingToolsChars += callChars
                        }
                    }
                    lastStepFileToolRatio = toolCalls.isEmpty ? 0.0 : Double(fileCallsCount) / Double(toolCalls.count)
                } else {
                    lastStepFileToolRatio = 0.0
                }
            case "SYSTEM_MESSAGE":
                pendingSystemChars += contentStr.count
                if contentStr.contains("Plan mode is off") {
                    segmentIsOrchestrator[currentSegmentIndex] = true
                    currentPhase = .executor
                    pendingPhaseChange = true
                } else if contentStr.contains("[plan review") {
                    segmentIsOrchestrator[currentSegmentIndex] = true
                    currentPhase = .planner
                    pendingPhaseChange = true
                }
            case "EPHEMERAL_MESSAGE":
                pendingSystemChars += contentStr.count
            case "CONVERSATION_HISTORY":
                pendingHistoryChars += contentStr.count
            case "VIEW_FILE", "CODE_ACTION":
                pendingFilesChars += contentStr.count
            case "RUN_COMMAND", "SEARCH_WEB", "LIST_DIRECTORY", "GREP_SEARCH", "READ_URL_CONTENT", "ERROR_MESSAGE":
                pendingToolsChars += contentStr.count
            case "GENERIC":
                if AntigravityDataReader.looksLikeFileToolOutput(contentStr) {
                    pendingFilesChars += contentStr.count
                } else if AntigravityDataReader.looksLikeCommandOutput(contentStr) {
                    pendingToolsChars += contentStr.count
                } else if lastStepFileToolRatio >= 0.99 {
                    pendingFilesChars += contentStr.count
                } else if lastStepFileToolRatio <= 0.01 {
                    pendingToolsChars += contentStr.count
                } else {
                    let fPart = Int((Double(contentStr.count) * lastStepFileToolRatio).rounded())
                    pendingFilesChars += fPart
                    pendingToolsChars += (contentStr.count - fPart)
                }
            default:
                break
            }

            if hasExitPlanTool || hasEnterPlanTool {
                segmentIsOrchestrator[currentSegmentIndex] = true
            }

            if let inVal = AntigravityDataReader.intValue(obj["input_tokens"]) {
                let cacheVal = AntigravityDataReader.intValue(obj["cache_read_tokens"]) ?? 0
                let outVal = AntigravityDataReader.intValue(obj["output_tokens"]) ?? 0
                let total = inVal + cacheVal
                let stepIdx = AntigravityDataReader.intValue(obj["step_index"]) ?? totalSteps
                let rawStepModel = (obj["model"] as? String) ?? ""
                let effectiveModel = !rawStepModel.isEmpty ? rawStepModel : currentUIModel
                let modelKey = AntigravityDataReader.normalizedModelKey(effectiveModel)

                if !rawStepModel.isEmpty {
                    if !lastRawStepModelInSegment.isEmpty && lastRawStepModelInSegment != rawStepModel && !pendingModelSwitch && !pendingEffortSwitch {
                        segmentIsOrchestrator[currentSegmentIndex] = true
                        pendingPhaseChange = true
                    }
                    lastRawStepModelInSegment = rawStepModel
                }

                var stepCompacted = false
                if pendingCompaction {
                    stepCompacted = true
                    pendingCompaction = false
                    segmentPeak = total
                } else if segmentPeak >= 100_000 {
                    let drop = segmentPeak - total
                    let sameModel = lastRecordedEffectiveModel.isEmpty || effectiveModel == lastRecordedEffectiveModel
                    if !pendingModelSwitch && !pendingEffortSwitch && !pendingPhaseChange && sameModel,
                       Double(drop) / Double(segmentPeak) >= 0.75 {
                        compactionEvents += 1
                        stepCompacted = true
                        segmentPeak = total
                    } else {
                        segmentPeak = max(segmentPeak, total)
                    }
                } else {
                    segmentPeak = max(segmentPeak, total)
                }

                allTimePeak = max(allTimePeak, total)

                if currentTurnIndex == 0 {
                    currentTurnIndex = 1
                }

                let stepEntry = ParsedStepEntry(
                    stepIndex: stepIdx,
                    turnIndex: currentTurnIndex,
                    segmentIndex: currentSegmentIndex,
                    phase: currentPhase,
                    effectiveModel: effectiveModel,
                    modelKey: modelKey,
                    inputTokens: inVal,
                    cacheReadTokens: cacheVal,
                    outputTokens: outVal,
                    contextTokens: total,
                    isCompaction: stepCompacted,
                    isModelSwitch: pendingModelSwitch,
                    isEffortSwitch: pendingEffortSwitch,
                    userCharsDelta: pendingUserChars,
                    assistantCharsDelta: pendingAssistantChars,
                    thinkingCharsDelta: pendingThinkingChars,
                    filesCharsDelta: pendingFilesChars,
                    toolsCharsDelta: pendingToolsChars,
                    systemCharsDelta: pendingSystemChars,
                    historyCharsDelta: pendingHistoryChars,
                    checkpointCharsDelta: pendingCheckpointChars,
                    toolCallsDelta: pendingToolCalls,
                    toolNames: pendingToolNames,
                    fileNames: pendingFileNames,
                    timestamp: parsedDate,
                    mediaCountDelta: pendingMediaCount,
                    errorCountDelta: pendingErrorCount
                )
                parsedSteps.append(stepEntry)

                stepRecords.append(
                    StepRecord(
                        timestamp: parsedDate ?? fallbackTimestamp,
                        model: effectiveModel,
                        inputTokens: inVal,
                        cacheReadTokens: cacheVal,
                        outputTokens: outVal,
                        contextTokens: total,
                        turnIndex: currentTurnIndex,
                        isCompaction: stepCompacted,
                        toolNames: pendingToolNames,
                        fileNames: pendingFileNames
                    )
                )

                pendingModelSwitch = false
                pendingEffortSwitch = false
                pendingPhaseChange = false
                pendingUserChars = 0
                pendingAssistantChars = 0
                pendingThinkingChars = 0
                pendingFilesChars = 0
                pendingToolsChars = 0
                pendingSystemChars = 0
                pendingHistoryChars = 0
                pendingCheckpointChars = 0
                pendingToolCalls = 0
                pendingToolNames.removeAll(keepingCapacity: true)
                pendingFileNames.removeAll(keepingCapacity: true)
                pendingMediaCount = 0
                pendingErrorCount = 0
                lastRecordedEffectiveModel = effectiveModel
            }

            if hasExitPlanTool {
                currentPhase = .executor
                pendingPhaseChange = true
            } else if hasEnterPlanTool {
                currentPhase = .planner
                pendingPhaseChange = true
            }
        }

        private func handleSettingsChangeIfPresent(in content: String) {
            guard content.contains("Model Selection") else { return }
            let changes = AntigravityDataReader.parseModelSelectionChanges(from: content)
            for change in changes {
                if change.from.caseInsensitiveCompare("None") == .orderedSame {
                    if currentUIModel.isEmpty {
                        currentUIModel = change.to
                        if change.to.lowercased().contains("orchestrator") {
                            segmentIsOrchestrator[currentSegmentIndex] = true
                        }
                    }
                    continue
                }
                guard change.from != change.to else { continue }

                let fromBase = AntigravityDataReader.normalizedModelKey(change.from)
                let toBase = AntigravityDataReader.normalizedModelKey(change.to)
                if fromBase == toBase && !fromBase.isEmpty {
                    pendingEffortSwitch = true
                    currentUIModel = change.to
                } else {
                    pendingModelSwitch = true
                    currentSegmentIndex += 1
                    currentPhase = .planner
                    lastRawStepModelInSegment = ""
                    segmentIsOrchestrator[currentSegmentIndex] = change.to.lowercased().contains("orchestrator")
                    currentUIModel = change.to
                }
            }
        }

        func buildTranscriptStats(conversationId: String, fallbackTitle: String, stamp: FileStamp) -> TranscriptStats {
            if let cached = cachedStats,
               cached.fallbackTitle == fallbackTitle,
               cached.stamp == stamp {
                return cached.stats
            }

            let allSnapshot = buildSnapshot(
                for: parsedSteps,
                extraInputTokens: checkpointExtraInputTokens,
                extraCacheTokens: checkpointExtraCacheTokens,
                extraOutputTokens: checkpointExtraOutputTokens,
                overridePeak: allTimePeak,
                overrideCompactions: compactionEvents,
                overrideUserTurns: userTurns,
                fallbackUpdatedAt: stamp.modificationDate
            )

            let manualSteps = parsedSteps.filter { segmentIsOrchestrator[$0.segmentIndex] != true }
            let orchSteps = parsedSteps.filter { segmentIsOrchestrator[$0.segmentIndex] == true }

            let hasManualMode = !manualSteps.isEmpty
            let hasOrchestratorMode = !orchSteps.isEmpty

            var scopedSnapshots: [ChatStatsScope: ScopedStatsSnapshot] = [
                .allChat: allSnapshot
            ]

            var manualModelItems: [ManualModelScopeItem] = []
            if hasManualMode {
                scopedSnapshots[.manualAll] = buildSnapshot(
                    for: manualSteps,
                    extraInputTokens: 0,
                    extraCacheTokens: 0,
                    extraOutputTokens: 0,
                    overridePeak: nil,
                    overrideCompactions: nil,
                    overrideUserTurns: nil,
                    fallbackUpdatedAt: stamp.modificationDate
                )

                var groupedManual: [String: [ParsedStepEntry]] = [:]
                var manualOrder: [String] = []
                for step in manualSteps {
                    let key = step.modelKey.isEmpty ? "default" : step.modelKey
                    if groupedManual[key] == nil {
                        manualOrder.append(key)
                    }
                    groupedManual[key, default: []].append(step)
                }

                var rawShortNames: [String: String] = [:]
                var shortCounts: [String: Int] = [:]
                for key in manualOrder {
                    let full = groupedManual[key]?.last?.effectiveModel ?? key
                    let short = RingViewModel.shortModelName(full)
                    rawShortNames[key] = short
                    shortCounts[short, default: 0] += 1
                }

                for key in manualOrder {
                    guard let stepsForModel = groupedManual[key], !stepsForModel.isEmpty else { continue }
                    let full = stepsForModel.last?.effectiveModel ?? key
                    let baseShort = rawShortNames[key] ?? full
                    let label: String
                    if (shortCounts[baseShort] ?? 0) > 1 {
                        label = AntigravityDataReader.stripEffortSuffix(full)
                    } else {
                        label = baseShort
                    }
                    manualModelItems.append(
                        ManualModelScopeItem(
                            id: key,
                            shortName: label,
                            fullName: full,
                            steps: stepsForModel.count
                        )
                    )
                    scopedSnapshots[.manualModel(key)] = buildSnapshot(
                        for: stepsForModel,
                        extraInputTokens: 0,
                        extraCacheTokens: 0,
                        extraOutputTokens: 0,
                        overridePeak: nil,
                        overrideCompactions: nil,
                        overrideUserTurns: nil,
                        fallbackUpdatedAt: stamp.modificationDate
                    )
                }
            }

            if hasOrchestratorMode {
                scopedSnapshots[.orchestratorAll] = buildSnapshot(
                    for: orchSteps,
                    extraInputTokens: 0,
                    extraCacheTokens: 0,
                    extraOutputTokens: 0,
                    overridePeak: nil,
                    overrideCompactions: nil,
                    overrideUserTurns: nil,
                    fallbackUpdatedAt: stamp.modificationDate
                )

                let plannerSteps = orchSteps.filter { $0.phase == .planner }
                if !plannerSteps.isEmpty {
                    scopedSnapshots[.orchestratorPlanner] = buildSnapshot(
                        for: plannerSteps,
                        extraInputTokens: 0,
                        extraCacheTokens: 0,
                        extraOutputTokens: 0,
                        overridePeak: nil,
                        overrideCompactions: nil,
                        overrideUserTurns: nil,
                        fallbackUpdatedAt: stamp.modificationDate
                    )
                }

                let executorSteps = orchSteps.filter { $0.phase == .executor }
                if !executorSteps.isEmpty {
                    scopedSnapshots[.orchestratorExecutor] = buildSnapshot(
                        for: executorSteps,
                        extraInputTokens: 0,
                        extraCacheTokens: 0,
                        extraOutputTokens: 0,
                        overridePeak: nil,
                        overrideCompactions: nil,
                        overrideUserTurns: nil,
                        fallbackUpdatedAt: stamp.modificationDate
                    )
                }
            }

            let displayTitle = !fallbackTitle.isEmpty
                ? fallbackTitle
                : (!extractedTitle.isEmpty ? extractedTitle : String(conversationId.prefix(8)))
            let lastStepTimestamp = parsedSteps.last?.timestamp

            let stats = TranscriptStats(
                conversationId: conversationId,
                title: displayTitle,
                contextTokens: allSnapshot.contextTokens,
                lastInputTokens: allSnapshot.lastInputTokens,
                lastCacheReadTokens: allSnapshot.lastCacheReadTokens,
                lastOutputTokens: allSnapshot.lastOutputTokens,
                lastDelta: allSnapshot.lastDelta,
                cacheHitPercent: allSnapshot.cacheHitPercent,
                model: allSnapshot.model,
                totalModelSteps: allSnapshot.totalModelSteps,
                peakTokens: allSnapshot.peakTokens,
                compactionEvents: allSnapshot.compactionEvents,
                recentSteps: allSnapshot.recentSteps,
                recentMessages: allSnapshot.recentMessages,
                breakdown: allSnapshot.breakdown,
                sessionStats: allSnapshot.sessionStats,
                hasManualMode: hasManualMode,
                hasOrchestratorMode: hasOrchestratorMode,
                manualModels: manualModelItems,
                scopedSnapshots: scopedSnapshots,
                updatedAt: lastStepTimestamp ?? stamp.modificationDate
            )

            cachedStats = (fallbackTitle: fallbackTitle, stamp: stamp, stats: stats)
            return stats
        }

        private func buildSnapshot(
            for steps: [ParsedStepEntry],
            extraInputTokens: Int,
            extraCacheTokens: Int,
            extraOutputTokens: Int,
            overridePeak: Int?,
            overrideCompactions: Int?,
            overrideUserTurns: Int?,
            fallbackUpdatedAt: Date?
        ) -> ScopedStatsSnapshot {
            guard let lastStep = steps.last else {
                return ScopedStatsSnapshot(
                    contextTokens: 0,
                    lastInputTokens: 0,
                    lastCacheReadTokens: 0,
                    lastOutputTokens: 0,
                    lastDelta: 0,
                    cacheHitPercent: 0,
                    model: "",
                    totalModelSteps: 0,
                    peakTokens: overridePeak ?? 0,
                    compactionEvents: overrideCompactions ?? 0,
                    recentSteps: [],
                    recentMessages: [],
                    breakdown: .empty,
                    sessionStats: .empty
                )
            }

            var totalIn = extraInputTokens
            var totalCache = extraCacheTokens
            var totalOut = extraOutputTokens
            var stepPeak = 0
            var stepCompactions = 0

            var modelStepCounts: [String: Int] = [:]
            var modelOutputCounts: [String: Int] = [:]
            var modelLastSeenIndex: [String: Int] = [:]

            var toolCallsCount = 0
            var toolNameCounts: [String: Int] = [:]
            var fileTouchesCount = 0
            var fileNameCounts: [String: Int] = [:]
            var mediaCount = 0
            var errorCount = 0

            var firstTimestamp: Date?
            var lastTimestamp: Date?

            var firstModelTotal: Int?
            var firstUserChars = 0
            var userChars = 0
            var assistantChars = 0
            var thinkingChars = 0
            var filesChars = 0
            var toolsChars = 0
            var systemChars = 0
            var historyChars = 0
            var checkpointChars = 0

            var stepSamples: [ModelStepSample] = []
            var prevStepContext = 0

            var turnOrder: [Int] = []
            var turnAccum: [Int: (
                steps: Int,
                endTokens: Int,
                sumIn: Int,
                sumCache: Int,
                lastCache: Int,
                hadCompaction: Bool,
                hadModelSwitch: Bool,
                hadEffortSwitch: Bool
            )] = [:]

            for (idx, step) in steps.enumerated() {
                totalIn += step.inputTokens
                totalCache += step.cacheReadTokens
                totalOut += step.outputTokens
                stepPeak = max(stepPeak, step.contextTokens)
                if step.isCompaction {
                    stepCompactions += 1
                    userChars = 0
                    assistantChars = 0
                    thinkingChars = 0
                    filesChars = 0
                    toolsChars = 0
                    systemChars = 0
                    historyChars = 0
                    checkpointChars = 0
                }

                if firstModelTotal == nil {
                    firstModelTotal = step.contextTokens
                    firstUserChars = step.userCharsDelta
                }

                userChars += step.userCharsDelta
                assistantChars += step.assistantCharsDelta
                thinkingChars += step.thinkingCharsDelta
                filesChars += step.filesCharsDelta
                toolsChars += step.toolsCharsDelta
                systemChars += step.systemCharsDelta
                historyChars += step.historyCharsDelta
                checkpointChars += step.checkpointCharsDelta

                toolCallsCount += step.toolCallsDelta
                for name in step.toolNames {
                    toolNameCounts[name, default: 0] += 1
                }
                fileTouchesCount += step.fileNames.count
                for fname in step.fileNames {
                    fileNameCounts[fname, default: 0] += 1
                }
                mediaCount += step.mediaCountDelta
                errorCount += step.errorCountDelta

                if let ts = step.timestamp {
                    if firstTimestamp == nil { firstTimestamp = ts }
                    lastTimestamp = ts
                }

                if !step.effectiveModel.isEmpty {
                    modelStepCounts[step.effectiveModel, default: 0] += 1
                    modelOutputCounts[step.effectiveModel, default: 0] += step.outputTokens
                    modelLastSeenIndex[step.effectiveModel] = idx
                }

                let stepDelta = idx > 0 ? (step.contextTokens - prevStepContext) : step.contextTokens
                prevStepContext = step.contextTokens

                stepSamples.append(
                    ModelStepSample(
                        stepIndex: step.stepIndex,
                        contextTokens: step.contextTokens,
                        delta: stepDelta,
                        isCompaction: step.isCompaction,
                        isModelSwitch: step.isModelSwitch,
                        isEffortSwitch: step.isEffortSwitch
                    )
                )

                if var existingTurn = turnAccum[step.turnIndex] {
                    existingTurn.steps += 1
                    existingTurn.endTokens = step.contextTokens
                    existingTurn.sumIn += step.inputTokens
                    existingTurn.sumCache += step.cacheReadTokens
                    existingTurn.lastCache = step.cacheReadTokens
                    existingTurn.hadCompaction = existingTurn.hadCompaction || step.isCompaction
                    existingTurn.hadModelSwitch = existingTurn.hadModelSwitch || step.isModelSwitch
                    existingTurn.hadEffortSwitch = existingTurn.hadEffortSwitch || step.isEffortSwitch
                    turnAccum[step.turnIndex] = existingTurn
                } else {
                    turnOrder.append(step.turnIndex)
                    turnAccum[step.turnIndex] = (
                        steps: 1,
                        endTokens: step.contextTokens,
                        sumIn: step.inputTokens,
                        sumCache: step.cacheReadTokens,
                        lastCache: step.cacheReadTokens,
                        hadCompaction: step.isCompaction,
                        hadModelSwitch: step.isModelSwitch,
                        hadEffortSwitch: step.isEffortSwitch
                    )
                }
            }

            var messageSamples: [MessageTurnSample] = []
            var prevTurnEndTokens = 0
            for tIdx in turnOrder {
                guard let t = turnAccum[tIdx] else { continue }
                let turnDelta = t.endTokens - prevTurnEndTokens
                prevTurnEndTokens = t.endTokens
                let turnDenom = t.sumIn + t.sumCache
                let turnCachePct = turnDenom > 0
                    ? Int((Double(t.sumCache) / Double(turnDenom) * 100.0).rounded())
                    : 0
                messageSamples.append(
                    MessageTurnSample(
                        turnIndex: tIdx,
                        contextTokens: t.endTokens,
                        delta: turnDelta,
                        modelStepsInTurn: t.steps,
                        cacheReadTokens: t.lastCache,
                        cacheHitPercent: turnCachePct,
                        hadCompaction: t.hadCompaction,
                        hadModelSwitch: t.hadModelSwitch,
                        hadEffortSwitch: t.hadEffortSwitch
                    )
                )
            }

            let sortedModels = modelStepCounts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    let lhsLast = modelLastSeenIndex[lhs.key] ?? -1
                    let rhsLast = modelLastSeenIndex[rhs.key] ?? -1
                    return lhsLast > rhsLast
                }
                .map { ModelUsageCount(name: $0.key, steps: $0.value, outputTokens: modelOutputCounts[$0.key] ?? 0) }

            let primaryModel = sortedModels.first?.name ?? lastStep.effectiveModel
            let otherModelsCount = max(0, sortedModels.count - 1)
            let sessionDenom = totalIn + totalCache
            let avgCacheHitPercent = sessionDenom > 0
                ? Int((Double(totalCache) / Double(sessionDenom) * 100.0).rounded())
                : 0
            let durationSeconds: Int
            if let firstTimestamp, let lastTimestamp, lastTimestamp >= firstTimestamp {
                durationSeconds = Int(lastTimestamp.timeIntervalSince(firstTimestamp).rounded())
            } else {
                durationSeconds = 0
            }

            let effectiveTurns = overrideUserTurns.map { max($0, messageSamples.count) } ?? messageSamples.count
            let sessionStats = ChatSessionStats(
                primaryModel: primaryModel,
                otherModelsCount: otherModelsCount,
                modelUsage: sortedModels,
                totalInputTokens: totalIn,
                totalCacheReadTokens: totalCache,
                totalOutputTokens: totalOut,
                avgCacheHitPercent: avgCacheHitPercent,
                durationSeconds: durationSeconds,
                mediaCount: mediaCount,
                errorCount: errorCount,
                userMessageCount: effectiveTurns
            )

            let breakdown = AntigravityDataReader.buildBreakdown(
                lastTotal: lastStep.contextTokens,
                firstModelTotal: firstModelTotal,
                firstUserChars: firstUserChars,
                systemMsgChars: systemChars,
                historyChars: historyChars,
                checkpointChars: checkpointChars,
                filesChars: filesChars,
                toolsChars: toolsChars,
                assistantChars: assistantChars,
                thinkingChars: thinkingChars,
                userChars: userChars,
                totalOutputTokens: totalOut,
                userTurns: effectiveTurns,
                mediaCount: mediaCount,
                toolCallsCount: toolCallsCount,
                fileTouchesCount: fileTouchesCount,
                toolNameCounts: toolNameCounts,
                fileNameCounts: fileNameCounts
            )

            let lastDelta: Int
            if steps.count > 1 {
                lastDelta = lastStep.contextTokens - steps[steps.count - 2].contextTokens
            } else {
                lastDelta = lastStep.contextTokens
            }

            let cacheHitPercent = lastStep.contextTokens > 0
                ? Int((Double(lastStep.cacheReadTokens) / Double(lastStep.contextTokens) * 100.0).rounded())
                : 0

            return ScopedStatsSnapshot(
                contextTokens: lastStep.contextTokens,
                lastInputTokens: lastStep.inputTokens,
                lastCacheReadTokens: lastStep.cacheReadTokens,
                lastOutputTokens: lastStep.outputTokens,
                lastDelta: lastDelta,
                cacheHitPercent: cacheHitPercent,
                model: lastStep.effectiveModel,
                totalModelSteps: steps.count,
                peakTokens: overridePeak ?? stepPeak,
                compactionEvents: overrideCompactions ?? stepCompactions,
                recentSteps: Array(stepSamples.suffix(6).reversed()),
                recentMessages: Array(messageSamples.suffix(6).reversed()),
                breakdown: breakdown,
                sessionStats: sessionStats
            )
        }
    }

    private let homeDir: URL
    private let dbPath: String
    private let brainDir: URL
    private let appStoragePath: String
    private let userSettingsPath: String

    private var transcriptStates: [String: IncrementalTranscriptState] = [:]
    private var appStateCache: CachedAppState?
    private var cachedTitleResolution: CachedTitleResolution?
    private var cachedRecentSummaries: CachedRecentSummaries?
    private var periodCache: [Int: CachedPeriodStats] = [:]

    private static let uuidRegex = try? NSRegularExpression(pattern: "^[0-9a-f-]{8,}$", options: [.caseInsensitive])
    private static let modelSelectionRegex = try? NSRegularExpression(
        pattern: "changed setting `Model Selection` from ([^\\n]+?) to ([^\\n.]+(?:\\.[^\\n.]*)*?)\\.",
        options: []
    )
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
        self.userSettingsPath = home.appendingPathComponent("Library/Application Support/Antigravity/User/settings.json").path
    }

    // MARK: - Watched File Paths

    var dbFilePath: String { dbPath }
    var dbWalFilePath: String { dbPath + "-wal" }
    var appStorageFilePath: String { appStoragePath }
    var userSettingsFilePath: String { userSettingsPath }
    var brainDirectoryPath: String { brainDir.path }

    func transcriptFilePath(forConversationId conversationId: String) -> String? {
        resolveTranscriptPath(conversationId: conversationId)
    }

    func watchedFilePaths(forConversationId conversationId: String?) -> [String] {
        var paths: [String] = []
        let fm = FileManager.default
        for candidate in [dbPath, dbWalFilePath, appStoragePath] {
            if fm.fileExists(atPath: candidate) {
                paths.append(candidate)
            }
        }
        if let conversationId, let transcriptPath = resolveTranscriptPath(conversationId: conversationId) {
            paths.append(transcriptPath)
        }
        return paths
    }

    // MARK: - Public API

    func resolveConversationId(forWindowTitle rawTitle: String) -> (id: String, title: String)? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGenericTitle = trimmed.isEmpty || trimmed.caseInsensitiveCompare("Antigravity") == .orderedSame
        let dbStamp = currentDBStamp()

        if let cached = cachedTitleResolution,
           cached.rawTitle == trimmed,
           cached.dbStamp == dbStamp,
           (!isGenericTitle || cached.result != nil) {
            return cached.result
        }

        let candidates = isGenericTitle ? [] : buildTitleCandidates(from: trimmed)
        let dbMatch = queryConversationSummaries(candidates: candidates, allowLatestFallback: isGenericTitle)

        if let dbMatch {
            cachedTitleResolution = CachedTitleResolution(rawTitle: trimmed, dbStamp: dbStamp, result: dbMatch)
            return dbMatch
        }

        if !isGenericTitle {
            cachedTitleResolution = CachedTitleResolution(rawTitle: trimmed, dbStamp: dbStamp, result: nil)
            return nil
        }

        if let latestId = findNewestTranscriptInBrain() {
            return (latestId, "")
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
        let dbStamp = currentDBStamp()
        var entries: [(id: String, title: String)]

        if let cached = cachedRecentSummaries,
           cached.dbStamp == dbStamp,
           cached.limit >= limit {
            entries = Array(cached.rows.prefix(limit))
        } else {
            entries = queryRecentSummariesFromDB(limit: limit)
            if !entries.isEmpty {
                cachedRecentSummaries = CachedRecentSummaries(limit: limit, dbStamp: dbStamp, rows: entries)
            } else {
                entries = scanRecentInBrain(limit: limit)
            }
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
        guard let transcriptPath = resolveTranscriptPath(conversationId: conversationId),
              let currentStamp = fileStamp(atPath: transcriptPath),
              let state = ensureIncrementalState(conversationId: conversationId, path: transcriptPath, stamp: currentStamp) else {
            return nil
        }
        return state.buildTranscriptStats(conversationId: conversationId, fallbackTitle: fallbackTitle, stamp: currentStamp)
    }

    func readAppState() -> AntigravityAppState {
        let appStamp = fileStamp(atPath: appStoragePath)
        let settingsStamp = fileStamp(atPath: userSettingsPath)
        if let cached = appStateCache,
           cached.appStorageStamp == appStamp,
           cached.userSettingsStamp == settingsStamp {
            return cached.state
        }

        var zoomLevel: Double = 0
        var hubIsDark: Bool? = nil
        if let data = FileManager.default.contents(atPath: appStoragePath),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let zoomStr = dict["zoomLevel"] as? String, let parsed = Double(zoomStr) {
                zoomLevel = parsed
            } else if let zoomNum = dict["zoomLevel"] as? NSNumber {
                zoomLevel = zoomNum.doubleValue
            }
            if let hex = dict["hubSurfaceBackgroundColor"] as? String,
               let luminance = Self.hexLuminance(hex) {
                hubIsDark = luminance < 0.5
            }
        }

        var themeSettingIsDark: Bool? = nil
        if let settingsData = FileManager.default.contents(atPath: userSettingsPath),
           let settingsDict = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any],
           let colorTheme = settingsDict["workbench.colorTheme"] as? String {
            let lower = colorTheme.lowercased()
            if lower.contains("light") {
                themeSettingIsDark = false
            } else if lower.contains("dark")
                || lower.contains("black")
                || lower.contains("night")
                || lower.contains("abyss")
                || lower.contains("monokai")
                || lower.contains("dracula") {
                themeSettingIsDark = true
            }
        }

        let isDark = themeSettingIsDark ?? hubIsDark ?? Self.isSystemAppearanceDark()
        let state = AntigravityAppState(zoomLevel: zoomLevel, isDarkTheme: isDark)
        appStateCache = CachedAppState(appStorageStamp: appStamp, userSettingsStamp: settingsStamp, state: state)
        return state
    }

    func readPeriodStats(hours: Int) -> PeriodUsageStats {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600.0)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty(hours: hours)
        }

        var validIds = Set<String>()
        var eligible: [(convId: String, path: String, stamp: FileStamp)] = []
        var signatures: [String: FileStamp] = [:]

        for dirURL in entries {
            let convId = dirURL.lastPathComponent
            guard Self.isValidConversationId(convId) else { continue }
            validIds.insert(convId)

            guard let path = resolveTranscriptPath(conversationId: convId),
                  let stamp = fileStamp(atPath: path),
                  let mtime = stamp.modificationDate,
                  mtime >= cutoff else {
                continue
            }

            eligible.append((convId, path, stamp))
            signatures[convId] = stamp
        }

        pruneTranscriptStates(keeping: validIds)

        if let cached = periodCache[hours],
           cached.fileSignatures == signatures,
           (cached.oldestIncludedTimestamp == nil || cached.oldestIncludedTimestamp! >= cutoff) {
            return cached.stats
        }

        let dbTitles = queryTitlesMapFromDB()

        var activeChats = 0
        var userMessages = 0
        var modelSteps = 0
        var compactionEvents = 0
        var totalIn = 0
        var totalCache = 0
        var totalOut = 0
        var totalDurationSeconds = 0
        var totalToolCalls = 0
        var totalFileTouches = 0
        var overallPeak = 0

        var modelCounts: [String: Int] = [:]
        var modelOutputs: [String: Int] = [:]
        var toolCounts: [String: Int] = [:]
        var fileCounts: [String: Int] = [:]
        var chatItemsWithDate: [(item: PeriodChatItem, latest: Date)] = []
        var oldestIncluded: Date?

        for item in eligible {
            guard let state = ensureIncrementalState(conversationId: item.convId, path: item.path, stamp: item.stamp) else {
                continue
            }

            var matchedThisChat = false
            var chatTurns = Set<Int>()
            var chatSteps = 0
            var chatPeak = 0
            var chatFirstTS: Date?
            var chatLastTS: Date?

            for rec in state.stepRecords where rec.timestamp >= cutoff {
                matchedThisChat = true
                if oldestIncluded == nil || rec.timestamp < oldestIncluded! {
                    oldestIncluded = rec.timestamp
                }
                if chatFirstTS == nil || rec.timestamp < chatFirstTS! {
                    chatFirstTS = rec.timestamp
                }
                if chatLastTS == nil || rec.timestamp > chatLastTS! {
                    chatLastTS = rec.timestamp
                }

                modelSteps += 1
                chatSteps += 1
                if rec.turnIndex > 0 {
                    chatTurns.insert(rec.turnIndex)
                }
                if rec.isCompaction {
                    compactionEvents += 1
                }
                chatPeak = max(chatPeak, rec.contextTokens)
                overallPeak = max(overallPeak, rec.contextTokens)

                totalIn += rec.inputTokens
                totalCache += rec.cacheReadTokens
                totalOut += rec.outputTokens

                if !rec.model.isEmpty {
                    modelCounts[rec.model, default: 0] += 1
                    modelOutputs[rec.model, default: 0] += rec.outputTokens
                }
                totalToolCalls += rec.toolNames.count
                for tName in rec.toolNames {
                    toolCounts[tName, default: 0] += 1
                }
                totalFileTouches += rec.fileNames.count
                for fName in rec.fileNames {
                    fileCounts[fName, default: 0] += 1
                }
            }

            if matchedThisChat {
                activeChats += 1
                userMessages += chatTurns.count
                if let first = chatFirstTS, let last = chatLastTS, last >= first {
                    totalDurationSeconds += Int(last.timeIntervalSince(first).rounded())
                }
                let dbTitle = dbTitles[item.convId] ?? ""
                let title = !dbTitle.isEmpty
                    ? dbTitle
                    : (!state.extractedTitle.isEmpty ? state.extractedTitle : String(item.convId.prefix(8)))
                let latest = chatLastTS ?? item.stamp.modificationDate ?? cutoff
                chatItemsWithDate.append((
                    item: PeriodChatItem(
                        id: item.convId,
                        title: title,
                        peakTokens: chatPeak,
                        steps: chatSteps
                    ),
                    latest: latest
                ))
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
        let topTools = toolCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { ToolUsageCount(name: $0.key, count: $0.value) }
        let topFiles = fileCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { FileUsageCount(name: $0.key, count: $0.value) }
        let sortedChats = chatItemsWithDate
            .sorted { $0.latest > $1.latest }
            .map { $0.item }

        let stats = PeriodUsageStats(
            windowHours: hours,
            activeChats: activeChats,
            userMessages: userMessages,
            modelSteps: modelSteps,
            compactionEvents: compactionEvents,
            totalInputTokens: totalIn,
            totalCacheReadTokens: totalCache,
            totalOutputTokens: totalOut,
            avgCacheHitPercent: avgCache,
            totalDurationSeconds: totalDurationSeconds,
            totalToolCalls: totalToolCalls,
            totalFileTouches: totalFileTouches,
            peakTokens: overallPeak,
            modelUsage: usage,
            topTools: topTools,
            topFiles: topFiles,
            activeChatItems: sortedChats
        )

        periodCache[hours] = CachedPeriodStats(
            hours: hours,
            oldestIncludedTimestamp: oldestIncluded,
            fileSignatures: signatures,
            stats: stats
        )
        return stats
    }

    // MARK: - Incremental Transcript Engine

    private func ensureIncrementalState(conversationId: String, path: String, stamp: FileStamp) -> IncrementalTranscriptState? {
        if let existing = transcriptStates[conversationId], existing.path == path {
            if existing.lastKnownStamp == stamp {
                return existing
            }
            if stamp.fileSize == existing.lastProcessedOffset {
                existing.lastKnownStamp = stamp
                return existing
            }
            if stamp.fileSize > existing.lastProcessedOffset {
                if appendTailLines(to: existing, fromOffset: existing.lastProcessedOffset, stamp: stamp) {
                    return existing
                }
                return nil
            }
        }

        let fresh = IncrementalTranscriptState(path: path)
        guard appendTailLines(to: fresh, fromOffset: 0, stamp: stamp) else {
            return nil
        }
        transcriptStates[conversationId] = fresh
        return fresh
    }

    private func appendTailLines(to state: IncrementalTranscriptState, fromOffset: UInt64, stamp: FileStamp) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: state.path) else {
            return false
        }
        defer { try? handle.close() }

        let chunk: Data
        do {
            try handle.seek(toOffset: fromOffset)
            chunk = try handle.readToEnd() ?? Data()
        } catch {
            return false
        }

        guard !chunk.isEmpty else {
            state.lastKnownStamp = stamp
            return true
        }

        let fallbackTimestamp = stamp.modificationDate ?? Date.distantPast
        var lineStart = chunk.startIndex
        var consumedBytes = 0

        while lineStart < chunk.endIndex {
            if let newlineIdx = chunk[lineStart...].firstIndex(of: 0x0A) {
                let rawSlice = chunk[lineStart..<newlineIdx]
                if let trimmedData = trimmedLineData(rawSlice) {
                    state.processLineData(trimmedData, fallbackTimestamp: fallbackTimestamp)
                }
                consumedBytes = (newlineIdx - chunk.startIndex) + 1
                lineStart = chunk.index(after: newlineIdx)
            } else {
                let trailingSlice = chunk[lineStart..<chunk.endIndex]
                if let trimmedData = trimmedLineData(trailingSlice) {
                    if let parsed = try? JSONSerialization.jsonObject(with: trimmedData),
                       parsed is [String: Any] {
                        state.processLineData(trimmedData, fallbackTimestamp: fallbackTimestamp)
                        consumedBytes = chunk.count
                    }
                } else {
                    consumedBytes = chunk.count
                }
                break
            }
        }

        if consumedBytes > 0 {
            state.lastProcessedOffset = fromOffset + UInt64(consumedBytes)
            state.cachedStats = nil
        }
        state.lastKnownStamp = stamp
        return true
    }

    private func trimmedLineData(_ slice: Data.SubSequence) -> Data? {
        var start = slice.startIndex
        var end = slice.endIndex
        while start < end && isASCIIWhitespace(slice[start]) {
            start = slice.index(after: start)
        }
        while end > start && isASCIIWhitespace(slice[slice.index(before: end)]) {
            end = slice.index(before: end)
        }
        guard start < end else { return nil }
        return Data(slice[start..<end])
    }

    private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    private func pruneTranscriptStates(keeping validIds: Set<String>) {
        guard transcriptStates.count > validIds.count else { return }
        for key in Array(transcriptStates.keys) where !validIds.contains(key) {
            transcriptStates.removeValue(forKey: key)
        }
    }

    // MARK: - Model & Compaction Classification Helpers

    private static func isCompactionMarker(stepType: String, source: String, content: String) -> Bool {
        if stepType == "CHECKPOINT" {
            return true
        }
        if stepType == "SYSTEM_MESSAGE" || source == "SYSTEM" {
            return content.contains("Resuming from a compaction")
                || content.contains("lost access to the full conversation history")
                || content.contains("This conversation grew too large")
                || content.contains("history before this point may be missing or incomplete")
                || content.contains("{{ CHECKPOINT")
                || content.contains("earlier parts of this conversation have been truncated")
        }
        return false
    }

    private static func parseModelSelectionChanges(from content: String) -> [(from: String, to: String)] {
        guard let regex = modelSelectionRegex else { return [] }
        let nsRange = NSRange(location: 0, length: content.utf16.count)
        let matches = regex.matches(in: content, options: [], range: nsRange)
        var results: [(from: String, to: String)] = []
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let fromRange = Range(match.range(at: 1), in: content),
                  let toRange = Range(match.range(at: 2), in: content) else {
                continue
            }
            let fromStr = String(content[fromRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let toStr = String(content[toRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !fromStr.isEmpty && !toStr.isEmpty {
                results.append((from: fromStr, to: toStr))
            }
        }
        return results
    }

    private static func stripEffortSuffix(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s*\((x?high|medium|low)\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"-(x?high|medium|low)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedModelKey(_ raw: String) -> String {
        let noEffort = stripEffortSuffix(raw)
        let lower = noEffort.lowercased()
        let cleaned = lower
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ".", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned
    }

    // MARK: - Private Helpers

    private func currentDBStamp() -> DBCombinedStamp {
        DBCombinedStamp(
            dbStamp: fileStamp(atPath: dbPath),
            walStamp: fileStamp(atPath: dbWalFilePath)
        )
    }

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
            let tail = String(trimmed[lastDash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.caseInsensitiveCompare("Antigravity") != .orderedSame {
                appendUnique(tail)
            }
        }
        if let firstDash = trimmed.range(of: " - ") {
            appendUnique(String(trimmed[..<firstDash.lowerBound]))
        }
        if let lastEmDash = trimmed.range(of: " — ", options: .backwards) {
            appendUnique(String(trimmed[..<lastEmDash.lowerBound]))
            let tail = String(trimmed[lastEmDash.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.caseInsensitiveCompare("Antigravity") != .orderedSame {
                appendUnique(tail)
            }
        }
        appendUnique(trimmed)
        return candidates
    }

    private func openReadOnlyDB() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var rwDb: OpaquePointer?
        if sqlite3_open_v2(dbPath, &rwDb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let rwDb {
            sqlite3_busy_timeout(rwDb, 200)
            sqlite3_exec(rwDb, "PRAGMA query_only = ON;", nil, nil, nil)
            return rwDb
        }
        if let rwDb { sqlite3_close(rwDb) }

        var roDb: OpaquePointer?
        if sqlite3_open_v2(dbPath, &roDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let roDb {
            sqlite3_busy_timeout(roDb, 200)
            return roDb
        }
        if let roDb { sqlite3_close(roDb) }

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
        return querySummaryRows(db: db, sql: sql, intParam: Int32(limit))
    }

    private func queryTitlesMapFromDB() -> [String: String] {
        guard let db = openReadOnlyDB() else { return [:] }
        defer { sqlite3_close(db) }

        let sql = "SELECT conversation_id, title FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 200;"
        var map: [String: String] = [:]
        for row in querySummaryRows(db: db, sql: sql) where !row.title.isEmpty {
            map[row.id] = row.title
        }
        return map
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
        let workspaceSQL = "SELECT conversation_id, title FROM conversation_summaries WHERE workspace_uris LIKE ? ESCAPE '\\' ORDER BY last_modified_time DESC LIMIT 1;"

        for candidate in candidates {
            if let match = querySummaryRows(db: db, sql: exactSQL, stringParam: candidate).first {
                return match
            }
            if candidate.hasSuffix("...") || candidate.hasSuffix("…") {
                let stripped = candidate
                    .replacingOccurrences(of: "...", with: "")
                    .replacingOccurrences(of: "…", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    let escaped = Self.escapeLikePattern(stripped) + "%"
                    if let match = querySummaryRows(db: db, sql: prefixSQL, stringParam: escaped).first {
                        return match
                    }
                }
            }
        }

        for candidate in candidates {
            let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? candidate
            let patterns = encoded == candidate
                ? ["%/" + Self.escapeLikePattern(candidate) + "\"%"]
                : ["%/" + Self.escapeLikePattern(encoded) + "\"%", "%/" + Self.escapeLikePattern(candidate) + "\"%"]
            for pat in patterns {
                if let match = querySummaryRows(db: db, sql: workspaceSQL, stringParam: pat).first {
                    return match
                }
            }
        }

        guard allowLatestFallback else { return nil }
        let latestSQL = "SELECT conversation_id, title FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 1;"
        return querySummaryRows(db: db, sql: latestSQL).first
    }

    private func querySummaryRows(
        db: OpaquePointer,
        sql: String,
        stringParam: String? = nil,
        intParam: Int32? = nil
    ) -> [(id: String, title: String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        if let stringParam {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = stringParam.withCString { cStr in
                sqlite3_bind_text(stmt, 1, cStr, -1, SQLITE_TRANSIENT)
            }
        } else if let intParam {
            sqlite3_bind_int(stmt, 1, intParam)
        }

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

    private func resolveTranscriptPath(conversationId: String) -> String? {
        let logsDir = brainDir
            .appendingPathComponent(conversationId)
            .appendingPathComponent(".system_generated/logs")
        let compact = logsDir.appendingPathComponent("transcript.jsonl").path
        if FileManager.default.fileExists(atPath: compact) {
            return compact
        }
        let full = logsDir.appendingPathComponent("transcript_full.jsonl").path
        if FileManager.default.fileExists(atPath: full) {
            return full
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

    private static func estimateJSONCharCount(_ value: Any) -> Int {
        switch value {
        case let str as String:
            return str.count + 2
        case let dict as [String: Any]:
            var sum = 2
            for (k, v) in dict {
                sum += k.count + 4 + estimateJSONCharCount(v)
            }
            return sum
        case let array as [Any]:
            var sum = 2
            for item in array {
                sum += estimateJSONCharCount(item) + 1
            }
            return sum
        default:
            return 6
        }
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
        text = text.replacingOccurrences(of: "<USER_SETTINGS_CHANGE>[\\s\\S]*?</USER_SETTINGS_CHANGE>", with: "", options: .regularExpression)
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

    private static func isFileToolName(_ name: String) -> Bool {
        switch name {
        case "read_file", "view_file", "edit_file", "write_file", "write_to_file", "replace_file_content":
            return true
        default:
            return false
        }
    }

    private static func extractTouchedFileName(from call: [String: Any]) -> String? {
        guard let args = (call["args"] as? [String: Any]) ?? (call["arguments"] as? [String: Any]) else {
            return nil
        }
        for key in ["Path", "AbsolutePath", "TargetFile", "File", "path"] {
            if let raw = args[key] as? String, !raw.isEmpty {
                let name = (raw as NSString).lastPathComponent
                if !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    private static func looksLikeFileToolOutput(_ content: String) -> Bool {
        content.hasPrefix("Showing lines ")
            || content.hasPrefix("File Path: ")
            || content.hasPrefix("Made ")
            || content.hasPrefix("Created file")
            || (content.contains("Showing lines ") && content.contains("Completed At:"))
    }

    private static func looksLikeCommandOutput(_ content: String) -> Bool {
        content.hasPrefix("Command exited")
            || content.hasPrefix("Tool is running as a background task")
            || content.contains("Command exited with code")
    }

    private static func buildBreakdown(
        lastTotal: Int,
        firstModelTotal: Int?,
        firstUserChars: Int,
        systemMsgChars: Int,
        historyChars: Int,
        checkpointChars: Int,
        filesChars: Int,
        toolsChars: Int,
        assistantChars: Int,
        thinkingChars: Int,
        userChars: Int,
        totalOutputTokens: Int,
        userTurns: Int,
        mediaCount: Int,
        toolCallsCount: Int,
        fileTouchesCount: Int,
        toolNameCounts: [String: Int],
        fileNameCounts: [String: Int]
    ) -> ContextBreakdown {
        let topTools = toolNameCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { ToolUsageCount(name: $0.key, count: $0.value) }

        let topFiles = fileNameCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { FileUsageCount(name: $0.key, count: $0.value) }

        guard lastTotal > 0 else {
            return ContextBreakdown(
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
                totalOutputTokens: totalOutputTokens,
                userTurns: userTurns,
                mediaCount: mediaCount,
                toolCallsCount: toolCallsCount,
                fileTouchesCount: fileTouchesCount,
                topTools: topTools,
                topFiles: topFiles
            )
        }

        let baseSystemEst: Int
        if let firstTotal = firstModelTotal {
            let est = firstTotal - (firstUserChars / 4)
            baseSystemEst = min(max(est, 0), min(lastTotal, 35_000))
        } else {
            baseSystemEst = 0
        }

        let rawBasePrompt = Double(baseSystemEst)
        let rawSysMsg = Double(systemMsgChars / 4)
        let rawHistory = Double(historyChars / 4)
        let rawCheckpoint = Double(checkpointChars / 4)
        let rawFiles = Double(filesChars / 4)
        let rawTools = Double(toolsChars / 4)
        let rawAssistant = Double(assistantChars / 4)
        let rawThinking = Double(thinkingChars / 4)
        let rawUser = Double(userChars / 4)

        let rawSum = rawBasePrompt + rawSysMsg + rawHistory + rawCheckpoint
            + rawFiles + rawTools + rawAssistant + rawThinking + rawUser

        if rawSum <= 0 {
            return ContextBreakdown(
                systemTokens: lastTotal,
                basePromptTokens: lastTotal,
                systemMessageTokens: 0,
                historyTokens: 0,
                checkpointSummaryTokens: 0,
                filesTokens: 0,
                toolsTokens: 0,
                assistantTokens: 0,
                thinkingTokens: 0,
                userTokens: 0,
                totalOutputTokens: totalOutputTokens,
                userTurns: userTurns,
                mediaCount: mediaCount,
                toolCallsCount: toolCallsCount,
                fileTouchesCount: fileTouchesCount,
                topTools: topTools,
                topFiles: topFiles
            )
        }

        let scale = Double(lastTotal) / rawSum
        var basePromptTok = rawBasePrompt > 0 ? Int((rawBasePrompt * scale).rounded()) : 0
        let sysMsgTok = rawSysMsg > 0 ? Int((rawSysMsg * scale).rounded()) : 0
        let historyTok = rawHistory > 0 ? Int((rawHistory * scale).rounded()) : 0
        let checkpointTok = rawCheckpoint > 0 ? Int((rawCheckpoint * scale).rounded()) : 0
        var filesTok = rawFiles > 0 ? Int((rawFiles * scale).rounded()) : 0
        var toolsTok = rawTools > 0 ? Int((rawTools * scale).rounded()) : 0
        var assistantTok = rawAssistant > 0 ? Int((rawAssistant * scale).rounded()) : 0
        let thinkingTok = rawThinking > 0 ? Int((rawThinking * scale).rounded()) : 0
        var userTok = rawUser > 0 ? Int((rawUser * scale).rounded()) : 0

        let currentSum = basePromptTok + sysMsgTok + historyTok + checkpointTok
            + filesTok + toolsTok + assistantTok + thinkingTok + userTok
        let diff = lastTotal - currentSum
        if diff != 0 {
            if userTok > 0 && userTok + diff >= 0 {
                userTok += diff
            } else if filesTok > 0 && filesTok + diff >= 0 {
                filesTok += diff
            } else if toolsTok > 0 && toolsTok + diff >= 0 {
                toolsTok += diff
            } else if assistantTok > 0 && assistantTok + diff >= 0 {
                assistantTok += diff
            } else {
                basePromptTok = max(0, basePromptTok + diff)
            }
        }

        let sysTotalTok = basePromptTok + sysMsgTok + historyTok + checkpointTok

        return ContextBreakdown(
            systemTokens: sysTotalTok,
            basePromptTokens: basePromptTok,
            systemMessageTokens: sysMsgTok,
            historyTokens: historyTok,
            checkpointSummaryTokens: checkpointTok,
            filesTokens: filesTok,
            toolsTokens: toolsTok,
            assistantTokens: assistantTok,
            thinkingTokens: thinkingTok,
            userTokens: userTok,
            totalOutputTokens: totalOutputTokens,
            userTurns: userTurns,
            mediaCount: mediaCount,
            toolCallsCount: toolCallsCount,
            fileTouchesCount: fileTouchesCount,
            topTools: topTools,
            topFiles: topFiles
        )
    }
}
