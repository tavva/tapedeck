// ABOUTME: Transcribe stage. Runs Deepgram against each downloaded audio file.

import Foundation

extension Pipeline {
    func transcribeNew() async throws {
        let pending = ((try? recordings.recordingsNeedingTranscription()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.transcribe) }
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            for rec in pending {
                if inflight >= maxConcurrency { await group.next(); inflight -= 1 }
                group.addTask { [self] in await self.transcribeOne(rec) }
                inflight += 1
            }
        }
    }

    private func transcribeOne(_ rec: Recording) async {
        do {
            let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
            let dir = deps.layout.audioDir(date: date)
            let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
            let audio = dir.appending(path: "\(stem).\(rec.audioExtension ?? "audio")")
            let result = try await RetryPolicy.run { [deepgram = deps.deepgram] in
                try await deepgram.transcribe(audioAt: audio, contentType: "audio/*")
            }
            try result.raw.write(to: dir.appending(path: "\(stem).deepgram.json"))
            let txt = renderTranscript(result.utterances, fallback: result.transcript)
            try txt.write(to: dir.appending(path: "\(stem).transcript.txt"),
                          atomically: true, encoding: .utf8)
            try recordings.setTranscribed(sourceId: rec.sourceId, at: deps.now())
            try recordings.clearError(sourceId: rec.sourceId, stage: .transcribe)
            deps.logger.info("transcribe_ok", source: rec.sourceId)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("transcribe_failed", source: rec.sourceId, message: "\(error)")
        }
    }
}
