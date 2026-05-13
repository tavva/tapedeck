// ABOUTME: Transcribe stage. Runs Deepgram against each downloaded audio file.

import Foundation

extension Pipeline {
    func transcribeNew() async throws {
        guard try autoTranscribeEnabled() else {
            deps.logger.info("transcribe_skipped_auto_disabled", source: nil)
            return
        }
        let pending = ((try? recordings.recordingsNeedingTranscription()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.transcribe) }
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            for rec in pending {
                if inflight >= maxConcurrency { await group.next(); inflight -= 1 }
                group.addTask { [self] in await self.transcribeOneSilently(rec) }
                inflight += 1
            }
        }
    }

    /// User-triggered single-recording transcription. Bypasses the failure
    /// gate; records errors to `recording_errors` and rethrows.
    public func transcribeOne(sourceId: String) async throws {
        guard let rec = try recordings.find(sourceId: sourceId) else {
            throw TranscribeError.unknownRecording(sourceId)
        }
        do {
            try await performTranscribeOne(rec)
        } catch {
            try? recordings.recordError(sourceId: sourceId, stage: .transcribe,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("transcribe_failed", source: sourceId, message: "\(error)")
            throw error
        }
    }

    /// Batch path. Silent on per-recording failure: records and continues.
    private func transcribeOneSilently(_ rec: Recording) async {
        do {
            try await performTranscribeOne(rec)
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .transcribe,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("transcribe_failed", source: rec.sourceId, message: "\(error)")
        }
    }

    private func performTranscribeOne(_ rec: Recording) async throws {
        let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
        let dir = deps.layout.audioDir(date: date)
        let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
        let audio = dir.appending(path: "\(stem).\(rec.audioExtension ?? "audio")")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw TranscribeError.audioMissing(audio)
        }
        let result: DeepgramClient.Result
        do {
            result = try await RetryPolicy.run { [deepgram = deps.deepgram] in
                try await deepgram.transcribe(audioAt: audio, contentType: "audio/*")
            }
        } catch {
            throw TranscribeError.providerFailed("\(error)")
        }
        try result.raw.write(to: dir.appending(path: "\(stem).deepgram.json"))
        let txt = renderTranscript(result.utterances, fallback: result.transcript)
        try txt.write(to: dir.appending(path: "\(stem).transcript.txt"),
                      atomically: true, encoding: .utf8)
        try recordings.setTranscribed(sourceId: rec.sourceId, at: deps.now())
        try recordings.clearError(sourceId: rec.sourceId, stage: .transcribe)
        if rec.linkedProjectId != nil {
            try recordings.markPendingRelink(sourceId: rec.sourceId)
        }
        deps.logger.info("transcribe_ok", source: rec.sourceId)
    }
}
