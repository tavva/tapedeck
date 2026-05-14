// ABOUTME: SQL access for speaker_usage. Drives the rename-flow dropdown.
// ABOUTME: Holds no business logic — see SpeakerEditor for the rename flow.

import Foundation
import GRDB

public struct KnownSpeaker: Sendable, Equatable {
    public let name: String
    public let inCurrentProject: Bool

    public init(name: String, inCurrentProject: Bool) {
        self.name = name
        self.inCurrentProject = inCurrentProject
    }
}

public struct SpeakerRepository: Sendable {
    let store: Store

    public init(store: Store) { self.store = store }
}
