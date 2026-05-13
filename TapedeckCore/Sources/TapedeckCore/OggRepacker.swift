// ABOUTME: Strips non-Opus bitstreams from a multi-stream OGG container.
// ABOUTME: Plaud devices interleave a PALUD.AI metadata stream alongside the
// ABOUTME: Opus audio, which Deepgram rejects as "corrupt or unsupported data".

import Foundation

public enum OggRepacker {
    /// Returns a cleaned single-stream OGG/Opus payload when the input contains
    /// non-Opus bitstreams interleaved with the Opus stream. Returns `nil` if the
    /// input is not OGG, contains no recognisable Opus stream, or already only
    /// contains the Opus stream (no work to do).
    public static func stripNonOpusStreams(_ data: Data) -> Data? {
        var pages: [Page] = []
        var offset = 0
        while offset < data.count {
            guard let page = Page.parse(data, at: offset) else { break }
            pages.append(page)
            offset = page.endOffset
        }
        guard !pages.isEmpty else { return nil }

        let opusMagic = Data("OpusHead".utf8)
        guard let opusPage = pages.first(where: { $0.payloadStartsWith(opusMagic, in: data) }) else {
            return nil
        }
        let opusSerial = opusPage.serial
        if pages.allSatisfy({ $0.serial == opusSerial }) { return nil }

        var out = Data()
        var seq: UInt32 = 0
        for page in pages where page.serial == opusSerial {
            out.append(page.rebuild(in: data, sequence: seq))
            seq += 1
        }
        return out
    }

    /// Ogg CRC-32: poly 0x04C11DB7, init 0, no input/output reflection, no XOR-out.
    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            let idx = Int(((crc >> 24) & 0xFF) ^ UInt32(byte))
            crc = (crc << 8) ^ table[idx]
        }
        return crc
    }

    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var r = UInt32(i) << 24
            for _ in 0..<8 {
                r = (r & 0x8000_0000 != 0) ? ((r &<< 1) ^ 0x04C1_1DB7) : (r &<< 1)
            }
            t[i] = r
        }
        return t
    }()

    struct Page {
        let offset: Int
        let length: Int
        let serial: UInt32
        let payloadOffset: Int
        let payloadLength: Int

        var endOffset: Int { offset + length }

        static func parse(_ data: Data, at offset: Int) -> Page? {
            guard offset + 27 <= data.count else { return nil }
            guard data[offset] == 0x4F, data[offset + 1] == 0x67,
                  data[offset + 2] == 0x67, data[offset + 3] == 0x53 else { return nil }
            let segCount = Int(data[offset + 26])
            guard offset + 27 + segCount <= data.count else { return nil }
            var payloadLen = 0
            for i in 0..<segCount {
                payloadLen += Int(data[offset + 27 + i])
            }
            let pageLen = 27 + segCount + payloadLen
            guard offset + pageLen <= data.count else { return nil }
            return Page(offset: offset, length: pageLen,
                        serial: readLE32(data, at: offset + 14),
                        payloadOffset: offset + 27 + segCount,
                        payloadLength: payloadLen)
        }

        func payloadStartsWith(_ magic: Data, in data: Data) -> Bool {
            guard payloadLength >= magic.count else { return false }
            return Data(data[payloadOffset..<payloadOffset + magic.count]) == magic
        }

        func rebuild(in data: Data, sequence: UInt32) -> Data {
            var bytes = Data(data[offset..<offset + length])
            writeLE32(&bytes, at: 18, value: sequence)
            writeLE32(&bytes, at: 22, value: 0)
            let crc = OggRepacker.crc32(bytes)
            writeLE32(&bytes, at: 22, value: crc)
            return bytes
        }
    }
}

private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

private func writeLE32(_ data: inout Data, at offset: Int, value: UInt32) {
    data[offset]     = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}
