// ABOUTME: Classify stage. Sends transcripts to Gemini, writes decisions to recordings.

import Foundation

extension Pipeline {
    /// Runs as part of `runCycle()`. Gated by `app_state.auto_classify` so that
    /// users opt into automatic classification; the manual bulk/per-recording
    /// entry points below are the default path.
    func classifyNew() async throws {
        guard try autoClassifyEnabled() else {
            deps.logger.info("classify_skipped_auto_disabled", source: nil)
            return
        }
        let pending = ((try? recordings.recordingsNeedingClassification()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.classify) }
        try await runBatchClassify(pending: pending)
    }

    /// User-triggered bulk classification. Runs regardless of `auto_classify`
    /// and bypasses the `maxFailuresPerStage` filter — the click is itself the
    /// retry signal.
    public func classifyPending() async throws {
        let pending = (try? recordings.recordingsNeedingClassification()) ?? []
        try await runBatchClassify(pending: pending)
    }

    /// User-triggered single-recording classification. Records errors to
    /// `recording_errors` and rethrows so the caller can react.
    public func classifyOne(sourceId: String) async throws {
        guard let rec = try recordings.find(sourceId: sourceId) else {
            throw ClassifyError.unknownRecording(sourceId)
        }
        let activeProjects = (try? projects.listActive()) ?? []
        guard !activeProjects.isEmpty else {
            try? recordings.recordError(sourceId: sourceId, stage: .classify,
                                        at: deps.now(),
                                        message: "no active projects")
            throw ClassifyError.noActiveProjects
        }
        let hints = activeProjects.map {
            GeminiClient.ProjectHint(id: $0.id, name: $0.displayName, description: $0.description)
        }
        let threshold = (try? classifierThreshold()) ?? 0.7
        try? writeHelperProgress(done: 0, total: 1, store: deps.store)
        do {
            try await performClassifyOne(rec, hints: hints, threshold: threshold)
            try? writeHelperProgress(done: 1, total: 1, store: deps.store)
        } catch {
            try? recordings.recordError(sourceId: sourceId, stage: .classify,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("classify_failed", source: sourceId, message: "\(error)")
            throw error
        }
    }

    private func runBatchClassify(pending: [Recording]) async throws {
        guard !pending.isEmpty else { return }
        let activeProjects = (try? projects.listActive()) ?? []
        guard !activeProjects.isEmpty else {
            deps.logger.info("classify_skipped_no_projects", source: nil)
            return
        }
        let hints = activeProjects.map {
            GeminiClient.ProjectHint(id: $0.id, name: $0.displayName, description: $0.description)
        }
        let threshold = (try? classifierThreshold()) ?? 0.7
        try? writeHelperProgress(done: 0, total: pending.count, store: deps.store)
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0, done = 0
            for rec in pending {
                if inflight >= maxConcurrency {
                    await group.next(); inflight -= 1
                    done += 1
                    try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
                }
                group.addTask { [self] in await self.classifyOneAndRecord(rec, hints: hints, threshold: threshold) }
                inflight += 1
            }
            while await group.next() != nil {
                done += 1
                try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
            }
        }
    }

    private func classifyOneAndRecord(_ rec: Recording, hints: [GeminiClient.ProjectHint], threshold: Double) async {
        do {
            try await performClassifyOne(rec, hints: hints, threshold: threshold)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .classify,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("classify_failed", source: rec.sourceId, message: "\(error)")
        }
    }

    private func performClassifyOne(_ rec: Recording, hints: [GeminiClient.ProjectHint], threshold: Double) async throws {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let txtURL = deps.layout.audioDir(date: date).appending(path: "\(stem).transcript.txt")
        let transcript: String
        do {
            transcript = try String(contentsOf: txtURL, encoding: .utf8)
        } catch {
            throw ClassifyError.transcriptMissing(txtURL)
        }
        let decision: GeminiClient.Decision
        do {
            decision = try await RetryPolicy.run { [gemini = deps.gemini] in
                try await gemini.classify(transcript: transcript, projects: hints)
            }
        } catch {
            throw ClassifyError.providerFailed("\(error)")
        }
        let assign = decision.confidence >= threshold && decision.projectId != nil
        let linkState: Recording.LinkState = assign ? .pendingRelink : .none
        try recordings.setClassification(
            sourceId: rec.sourceId,
            projectId: assign ? decision.projectId : nil,
            confidence: decision.confidence,
            reasoning: decision.reasoning,
            by: "gemini-3-flash-preview",
            at: deps.now(),
            linkState: linkState)
        try recordings.clearError(sourceId: rec.sourceId, stage: .classify)
        deps.logger.info("classify_ok", source: rec.sourceId)
    }
}
