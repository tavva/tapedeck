// ABOUTME: Helper writes its current stage + per-stage progress into app_state so the
// ABOUTME: UI can surface launchd-triggered and internal-stage activity.

import Foundation
import GRDB

public enum HelperStage: String, Sendable, Equatable {
    case idle, syncing, transcribing, classifying
}

public func writeHelperStage(_ stage: HelperStage,
                             store: Store,
                             now: () -> Int64) throws {
    let ts = String(now())
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [stage.rawValue])
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_started_at', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [ts])
        // Reset progress counters atomically so the UI never sees the
        // previous stage's "N of N" briefly attributed to the new stage.
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage_done', '0')
            ON CONFLICT(key) DO UPDATE SET value = '0'
        """)
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage_total', '0')
            ON CONFLICT(key) DO UPDATE SET value = '0'
        """)
    }
}

public func writeHelperProgress(done: Int, total: Int, store: Store) throws {
    try store.write { db in
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage_done', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [String(done)])
        try db.execute(sql: """
            INSERT INTO app_state(key, value) VALUES('helper_stage_total', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [String(total)])
    }
}

public func clearHelperStage(store: Store, now: () -> Int64) throws {
    // writeHelperStage already zeroes the progress counters in the same txn.
    try writeHelperStage(.idle, store: store, now: now)
}
