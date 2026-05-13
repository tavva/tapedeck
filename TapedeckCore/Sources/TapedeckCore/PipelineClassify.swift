// ABOUTME: Classify stage. Sends transcripts to Gemini, writes decisions to recordings.

import Foundation

extension Pipeline {
    func classifyNew() async throws {
        let pending = ((try? recordings.recordingsNeedingClassification()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.classify) }
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
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            for rec in pending {
                if inflight >= maxConcurrency { await group.next(); inflight -= 1 }
                group.addTask { [self] in await self.classifyOne(rec, hints: hints, threshold: threshold) }
                inflight += 1
            }
        }
    }

    private func classifyOne(_ rec: Recording, hints: [GeminiClient.ProjectHint], threshold: Double) async {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let txtURL = deps.layout.audioDir(date: date).appending(path: "\(stem).transcript.txt")
        do {
            let transcript = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? ""
            let decision = try await RetryPolicy.run { [gemini = deps.gemini] in
                try await gemini.classify(transcript: transcript, projects: hints)
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
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .classify,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("classify_failed", source: rec.sourceId, message: "\(error)")
        }
    }
}
