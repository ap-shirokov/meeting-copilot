import Foundation

// Lossless local capture at the 24 kHz, mono, signed 16-bit PCM format
// already produced for Whisper. No audio is uploaded to LiteLLM.
final class PCMTrack: @unchecked Sendable {
    private let queue: DispatchQueue
    private let file: FileHandle
    private var dataBytes: UInt64
    private var closed = false

    init(url: URL, name: String) throws {
        queue = DispatchQueue(label:"meetingcopilot.audio.\(name).\(UUID().uuidString)", qos:.utility)
        try FileManager.default.createDirectory(
            at:url.deletingLastPathComponent(),withIntermediateDirectories:true
        )
        let manager = FileManager.default
        if !manager.fileExists(atPath:url.path) {
            guard manager.createFile(atPath:url.path,contents:Self.header(byteCount:0)) else {
                throw NSError(domain:"MeetingAudio",code:1,userInfo:[
                    NSLocalizedDescriptionKey:"Не удалось создать аудиофайл: \(url.path)"
                ])
            }
        }
        file = try FileHandle(forUpdating:url)
        let end = try file.seekToEnd()
        // Only append to a valid WAV produced by this app.
        guard end >= 44 else {
            try file.close()
            throw NSError(domain:"MeetingAudio",code:2,userInfo:[
                NSLocalizedDescriptionKey:"Повреждён заголовок аудиозаписи: \(url.lastPathComponent)"
            ])
        }
        try file.seek(toOffset:0)
        let signature = try file.read(upToCount:12) ?? Data()
        guard signature.count == 12,
              String(data:signature.prefix(4),encoding:.ascii) == "RIFF",
              String(data:signature.suffix(4),encoding:.ascii) == "WAVE" else {
            try file.close()
            throw NSError(domain:"MeetingAudio",code:3,userInfo:[
                NSLocalizedDescriptionKey:"Файл не является WAV: \(url.lastPathComponent)"
            ])
        }
        dataBytes = end - 44
        try file.seekToEnd()
    }

    private static func header(byteCount:UInt32) -> Data {
        var header = Data()
        func word(_ value:UInt16) {
            var n=value.littleEndian
            withUnsafeBytes(of:&n) { header.append(contentsOf:$0) }
        }
        func dword(_ value:UInt32) {
            var n=value.littleEndian
            withUnsafeBytes(of:&n) { header.append(contentsOf:$0) }
        }
        header.append(contentsOf:"RIFF".utf8)
        dword(byteCount + 36)
        header.append(contentsOf:"WAVEfmt ".utf8)
        dword(16); word(1); word(1)
        dword(24000); dword(48000)
        word(2); word(16)
        header.append(contentsOf:"data".utf8)
        dword(byteCount)
        return header
    }

    func append(_ pcm:Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [self] in
            guard !closed else { return }
            // Standard RIFF WAV has a 4GB limit. Don't produce invalid headers.
            guard dataBytes + UInt64(pcm.count) < UInt64(UInt32.max - 36) else { return }
            do {
                try file.write(contentsOf:pcm)
                dataBytes += UInt64(pcm.count)
            } catch {
                NSLog("Meeting Copilot audio write error: %@", error.localizedDescription)
            }
        }
    }

    func finish() {
        queue.sync {
            guard !closed else { return }
            closed = true
            do {
                try file.seek(toOffset:0)
                try file.write(contentsOf:Self.header(byteCount:UInt32(dataBytes)))
                try file.synchronize()
                try file.close()
            } catch {
                NSLog("Meeting Copilot audio finalize error: %@", error.localizedDescription)
            }
        }
    }
}

final class MeetingAudioRecorder: @unchecked Sendable {
    let microphone: PCMTrack
    let system: PCMTrack

    init(meetingID:UUID) throws {
        let directory = MeetingArchive.audioDirectory(meetingID)
        microphone = try PCMTrack(url:directory.appendingPathComponent("microphone.wav"),name:"microphone")
        system = try PCMTrack(url:directory.appendingPathComponent("system.wav"),name:"system")
    }
    func appendMicrophone(_ pcm:Data) { microphone.append(pcm) }
    func appendSystem(_ pcm:Data) { system.append(pcm) }
    func finish() {
        microphone.finish()
        system.finish()
    }
}
