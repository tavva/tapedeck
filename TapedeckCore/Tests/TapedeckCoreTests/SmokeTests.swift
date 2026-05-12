// ABOUTME: Build-the-package smoke test. Must pass once the package compiles.
// ABOUTME: Real tests live in feature-specific files.

import Testing
@testable import TapedeckCore

@Suite("TapedeckCore smoke")
struct SmokeTests {
    @Test func schemaVersionIsExposed() {
        #expect(TapedeckCore.schemaVersion == 1)
    }
}
