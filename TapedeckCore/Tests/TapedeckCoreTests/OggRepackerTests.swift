// ABOUTME: Validates the Ogg CRC-32 implementation against a real Plaud
// ABOUTME: OpusHead page, then exercises the multi-stream → Opus-only repack.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("OggRepacker")
struct OggRepackerTests {

    // The 47-byte OpusHead BOS page from a real Plaud device recording.
    // Fixed header: 0-3 "OggS", 4 ver, 5 type, 6-13 granule, 14-17 serial,
    //               18-21 seq, 22-25 CRC, 26 seg_count, 27 seg_table.
    // CRC bytes (22-25) hold the libogg-computed value 0x172673AC.
    private let plaudOpusHeadPage: [UInt8] = [
        0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE9, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xAC, 0x73, 0x26, 0x17, 0x01, 0x13, 0x4F, 0x70, 0x75, 0x73,
        0x48, 0x65, 0x61, 0x64, 0x01, 0x01, 0x00, 0x00, 0x80, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, // 47
    ]

    @Test func crc32_matchesLibogg_onRealPlaudPage() {
        var bytes = Data(plaudOpusHeadPage)
        // Zero CRC field (bytes 22-25) before computing.
        bytes[22] = 0; bytes[23] = 0; bytes[24] = 0; bytes[25] = 0
        #expect(OggRepacker.crc32(bytes) == 0x1726_73AC)
    }

    @Test func crc32_emptyInputIsZero() {
        #expect(OggRepacker.crc32(Data()) == 0)
    }

    // MARK: repack

    /// Builds a complete, CRC-valid Ogg page. `payload.count` ≤ 255 to keep the
    /// segment table at a single byte — enough for these tests.
    private func makePage(serial: UInt32, sequence: UInt32, type: UInt8, payload: Data) -> Data {
        precondition(payload.count <= 255)
        var page = Data(count: 27 + 1 + payload.count)
        page[0] = 0x4F; page[1] = 0x67; page[2] = 0x67; page[3] = 0x53
        page[4] = 0      // version
        page[5] = type   // header type
        // granule_position bytes 6-13 stay zero
        page[14] = UInt8(serial & 0xFF)
        page[15] = UInt8((serial >> 8) & 0xFF)
        page[16] = UInt8((serial >> 16) & 0xFF)
        page[17] = UInt8((serial >> 24) & 0xFF)
        page[18] = UInt8(sequence & 0xFF)
        page[19] = UInt8((sequence >> 8) & 0xFF)
        page[20] = UInt8((sequence >> 16) & 0xFF)
        page[21] = UInt8((sequence >> 24) & 0xFF)
        // CRC bytes 22-25 stay zero for the checksum
        page[26] = 1                       // segment count
        page[27] = UInt8(payload.count)    // segment table
        page.replaceSubrange(28..<28 + payload.count, with: payload)
        let crc = OggRepacker.crc32(page)
        page[22] = UInt8(crc & 0xFF)
        page[23] = UInt8((crc >> 8) & 0xFF)
        page[24] = UInt8((crc >> 16) & 0xFF)
        page[25] = UInt8((crc >> 24) & 0xFF)
        return page
    }

    private let opusSerial: UInt32 = 0x0000_03E9 // 1001
    private let plaudSerial: UInt32 = 0x0000_03EA // 1002

    @Test func stripNonOpusStreams_returnsNil_forNonOggInput() {
        #expect(OggRepacker.stripNonOpusStreams(Data([0,1,2,3])) == nil)
        #expect(OggRepacker.stripNonOpusStreams(Data()) == nil)
    }

    @Test func stripNonOpusStreams_returnsNil_whenAlreadySingleStream() {
        let opusHead = Data("OpusHead".utf8) + Data(repeating: 0, count: 11)
        let opusTags = Data("OpusTags".utf8) + Data(repeating: 0, count: 4)
        let file = makePage(serial: opusSerial, sequence: 0, type: 0x02, payload: opusHead)
                 + makePage(serial: opusSerial, sequence: 1, type: 0x00, payload: opusTags)

        #expect(OggRepacker.stripNonOpusStreams(file) == nil)
    }

    @Test func stripNonOpusStreams_returnsNil_whenNoOpusStreamPresent() {
        let plaud = Data("PLAUD.AI metadata".utf8)
        let file = makePage(serial: plaudSerial, sequence: 0, type: 0x02, payload: plaud)

        #expect(OggRepacker.stripNonOpusStreams(file) == nil)
    }

    @Test func stripNonOpusStreams_keepsOnlyOpusPages_renumberedAndReCRCed() throws {
        let opusHead = Data("OpusHead".utf8) + Data(repeating: 0, count: 11)
        let plaud = Data("PLAUD.AI metadata".utf8) + Data(repeating: 0, count: 200)
        let opusTags = Data("OpusTags".utf8) + Data(repeating: 0xAB, count: 30)
        let opusAudio = Data(repeating: 0xCD, count: 60)

        let input = makePage(serial: opusSerial, sequence: 0, type: 0x02, payload: opusHead)
                  + makePage(serial: plaudSerial, sequence: 0, type: 0x02, payload: plaud)
                  + makePage(serial: opusSerial, sequence: 1, type: 0x00, payload: opusTags)
                  + makePage(serial: opusSerial, sequence: 2, type: 0x00, payload: opusAudio)

        let cleaned = try #require(OggRepacker.stripNonOpusStreams(input))

        // Walk emitted pages: 3 of them, all serial=opus, sequence 0/1/2, valid CRCs.
        var offset = 0
        var seenSequences: [UInt32] = []
        var seenSerials: [UInt32] = []
        while let page = OggRepacker.Page.parse(cleaned, at: offset) {
            seenSerials.append(page.serial)
            seenSequences.append(UInt32(cleaned[offset+18])
                                 | (UInt32(cleaned[offset+19]) << 8)
                                 | (UInt32(cleaned[offset+20]) << 16)
                                 | (UInt32(cleaned[offset+21]) << 24))

            // CRC self-check: zero the field, recompute, compare to stored value.
            let storedCRC = UInt32(cleaned[offset+22])
                          | (UInt32(cleaned[offset+23]) << 8)
                          | (UInt32(cleaned[offset+24]) << 16)
                          | (UInt32(cleaned[offset+25]) << 24)
            var bytes = Data(cleaned[offset..<offset+page.length])
            bytes[22] = 0; bytes[23] = 0; bytes[24] = 0; bytes[25] = 0
            #expect(OggRepacker.crc32(bytes) == storedCRC)

            offset = page.endOffset
        }
        #expect(offset == cleaned.count)
        #expect(seenSerials == [opusSerial, opusSerial, opusSerial])
        #expect(seenSequences == [0, 1, 2])
    }
}
