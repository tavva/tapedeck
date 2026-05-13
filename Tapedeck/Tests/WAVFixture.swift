// ABOUTME: Test helper. Writes a tiny PCM WAV to a temp URL so tests can exercise
// ABOUTME: AVAudioPlayer against a real file without committing binary fixtures.

import Foundation

enum WAVFixture {
    /// Writes ~100ms of mono 16-bit silence at 44.1kHz to a temp URL.
    /// Returns the URL; caller is responsible for cleanup.
    static func writeSilent() throws -> URL {
        let sampleRate: UInt32 = 44_100
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let numFrames: UInt32 = 4_410
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = numFrames * UInt32(blockAlign)
        let chunkSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))
        data.append(uint16LE(1))
        data.append(uint16LE(numChannels))
        data.append(uint32LE(sampleRate))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(dataSize))
        data.append(Data(count: Int(dataSize)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
              UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
}
