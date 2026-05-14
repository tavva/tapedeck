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
        await runBatchTranscribe(pending: pending)
    }

    /// User-triggered bulk transcription. Ignores `auto_transcribe` and the
    /// `maxFailuresPerStage` filter — the click is itself the retry signal.
    public func transcribePending() async throws {
        let pending = (try? recordings.recordingsNeedingTranscription()) ?? []
        await runBatchTranscribe(pending: pending)
    }

    func runBatchTranscribe(pending: [Recording]) async {
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
        let contentType = audioContentType(forExtension: rec.audioExtension)
        let (uploadURL, tempURL) = try cleanedUploadURL(for: audio, ext: rec.audioExtension)
        defer { if let t = tempURL { try? FileManager.default.removeItem(at: t) } }
        let result: DeepgramClient.Result
        do {
            result = try await RetryPolicy.run { [deepgram = deps.deepgram] in
                try await deepgram.transcribe(audioAt: uploadURL, contentType: contentType)
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

/// For multi-stream OGG files (Plaud devices interleave a PALUD.AI metadata
/// bitstream alongside the Opus audio, which Deepgram rejects), returns a
/// URL pointing at a temp-file copy with only the Opus pages. Returns the
/// original URL when no cleaning is needed.
private func cleanedUploadURL(for audio: URL, ext: String?) throws -> (URL, URL?) {
    let lowered = (ext ?? "").lowercased()
    guard lowered == "ogg" || lowered == "opus" || lowered == "oga" else {
        return (audio, nil)
    }
    let bytes = try Data(contentsOf: audio)
    guard let cleaned = OggRepacker.stripNonOpusStreams(bytes) else {
        return (audio, nil)
    }
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "tapedeck-ogg-\(UUID().uuidString).\(lowered)")
    try cleaned.write(to: tmp)
    return (tmp, tmp)
}

private func audioContentType(forExtension ext: String?) -> String {
    switch (ext ?? "").lowercased() {
    case "mp3":                 return "audio/mpeg"
    case "ogg", "opus", "oga":  return "audio/ogg"
    case "wav":                 return "audio/wav"
    case "m4a", "mp4", "aac":   return "audio/mp4"
    case "flac":                return "audio/flac"
    case "webm":                return "audio/webm"
    default:                    return "application/octet-stream"
    }
}
