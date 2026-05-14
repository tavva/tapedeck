// ABOUTME: Download stage of Pipeline. Per-recording: fetch temp URL, stream audio,
// ABOUTME: write metadata sidecar, update state. Bounded parallelism via TaskGroup.

import Foundation

extension Pipeline {
    /// Authentication state shared by per-recording stage tasks so a 401 from any one
    /// of them propagates out as a cycle abort.
    actor AuthState {
        var failed = false
        func markFailed() { failed = true }
        func didFail() -> Bool { failed }
    }

    func downloadNew() async throws {
        let pending = ((try? recordings.recordingsNeedingDownload()) ?? [])
            .filter { !shouldSkipAfterFailures(sourceId: $0.sourceId, stage: SyncStage.download) }
        let auth = AuthState()
        try? writeHelperProgress(done: 0, total: pending.count, store: deps.store)
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0, done = 0
            for rec in pending {
                if inflight >= maxConcurrency {
                    await group.next(); inflight -= 1
                    done += 1
                    try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
                }
                group.addTask { [self] in await self.downloadOne(rec, auth: auth) }
                inflight += 1
            }
            while await group.next() != nil {
                done += 1
                try? writeHelperProgress(done: done, total: pending.count, store: deps.store)
            }
        }
        if await auth.didFail() { throw SourceClientError.unauthorised }
    }

    private func downloadOne(_ rec: Recording, auth: AuthState) async {
        do {
            let tempURL = try await RetryPolicy.run { [source = deps.source] in
                try await source.tempURL(for: rec.sourceId)
            }
            let date = Date(timeIntervalSince1970: TimeInterval(rec.startedAt) / 1000)
            let dir = deps.layout.audioDir(date: date)
            let stem = deps.layout.stem(sourceId: rec.sourceId, title: rec.filename)
            let target = dir.appending(path: stem)
                            .appendingPathExtension(tempURL.pathExtension.isEmpty ? "audio" : tempURL.pathExtension)
            let ext = try await RetryPolicy.run { [source = deps.source] in
                try await source.download(from: tempURL, target: target)
            }
            let metadata = try await RetryPolicy.run { [source = deps.source] in
                try await source.rawMetadata(for: [rec.sourceId])
            }
            try metadata.write(to: dir.appending(path: "\(stem).source.json"))
            try recordings.setDownloaded(sourceId: rec.sourceId, ext: ext, at: deps.now())
            try recordings.clearError(sourceId: rec.sourceId, stage: .download)
            deps.logger.info("download_ok", source: rec.sourceId)
        } catch SourceClientError.unauthorised {
            await auth.markFailed()
            deps.logger.error("download_unauthorised", source: rec.sourceId, message: "401")
        } catch {
            try? recordings.recordError(sourceId: rec.sourceId, stage: .download,
                                        at: deps.now(), message: "\(error)")
            deps.logger.error("download_failed", source: rec.sourceId, message: "\(error)")
        }
    }
}
