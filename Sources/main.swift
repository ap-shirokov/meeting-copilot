import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import Darwin

// Meeting Copilot: local MLX Whisper + ChatGPT subscription through localhost LiteLLM. macOS 14+.

struct MeetingRecord: Codable, Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var transcript: String
    var answer: String
    var responseHistory: [String]
    var requestCount: Int
    var inputTokens: Int
    var outputTokens: Int
    var lastLatency: Double
}

enum MeetingArchive {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MeetingCopilot/Meetings", isDirectory:true)
    }
    static func write(_ meeting: MeetingRecord) throws {
        try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meeting)
        try data.write(to:directory.appendingPathComponent(meeting.id.uuidString + ".json"), options:.atomic)
    }
    static func delete(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.removeItem(at:url)
    }
    static func load() -> [MeetingRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at:directory, includingPropertiesForKeys:nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf:$0) else { return nil }
            return try? JSONDecoder().decode(MeetingRecord.self, from:data)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    static func importLegacyIfNeeded() {
        let key = "meetingCopilotLegacyTextImportedV1"
        guard !UserDefaults.standard.bool(forKey:key) else { return }
        let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at:documents, includingPropertiesForKeys:nil)) ?? []
        var allSucceeded = true
        for url in files where url.lastPathComponent.hasPrefix("MeetingCopilot-") && url.pathExtension == "txt" {
            guard let raw = try? String(contentsOf:url,encoding:.utf8) else { continue }
            let numeric = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of:"MeetingCopilot-",with:"")
            let date = Double(numeric).map { Date(timeIntervalSince1970:$0) } ?? Date()
            let entry = MeetingRecord(id:UUID(), title:"Импорт · " + DateFormatter.localizedString(from:date,dateStyle:.medium,timeStyle:.short),
                createdAt:date, updatedAt:date, transcript:raw, answer:"", responseHistory:[],
                requestCount:0,inputTokens:0,outputTokens:0,lastLatency:0)
            do { try write(entry) } catch { allSucceeded = false }
        }
        if allSucceeded { UserDefaults.standard.set(true,forKey:key) }
    }
}

@MainActor final class MeetingState: ObservableObject {
    @Published var active = false
    @Published var status = "Готов к запуску"
    @Published var transcript = ""
    @Published var partialMine = ""
    @Published var partialOthers = ""
    @Published var answer = ""
    @Published var question = "Что важно уточнить прямо сейчас?"
    @Published var busy = false
    private var mic: MicCapture?
    private var system: SystemCapture?
    private var mine: Transcriber?
    private var others: Transcriber?
    private var sessionStarted = Date()
    @Published var sessionTitle = "Новая встреча"
    @Published var showSettings = false
    @Published var proxyStatus = "Проверка подключения"
    @Published var responseHistory: [String] = []
    @Published var meetings: [MeetingRecord] = []
    @Published var selectedID: UUID?
    @Published var starting = false

    init() {
        MeetingArchive.importLegacyIfNeeded()
        meetings = MeetingArchive.load()
        if let recent = meetings.first { apply(recent) }
        else { newMeeting() }
    }
    private func apply(_ item: MeetingRecord) {
        selectedID = item.id
        sessionTitle = item.title
        sessionStarted = item.createdAt
        transcript = item.transcript
        answer = item.answer
        responseHistory = item.responseHistory
        requestCount = item.requestCount
        inputTokens = item.inputTokens
        outputTokens = item.outputTokens
        lastLatency = item.lastLatency
        lastError = ""
        status = "Открыта сохранённая встреча"
    }
    private func persist() {
        guard let id = selectedID, let index = meetings.firstIndex(where:{$0.id == id}) else { return }
        var item = meetings[index]
        item.title = sessionTitle
        item.updatedAt = Date()
        item.transcript = transcript
        item.answer = answer
        item.responseHistory = responseHistory
        item.requestCount = requestCount
        item.inputTokens = inputTokens
        item.outputTokens = outputTokens
        item.lastLatency = lastLatency
        do {
            try MeetingArchive.write(item)
            meetings[index] = item
        } catch { status = "Ошибка локального сохранения: \(error.localizedDescription)" }
    }
    func rename(_ text: String) {
        sessionTitle = text
        persist()
    }
    func renameMeeting(_ id: UUID, to text: String) {
        guard !active && !starting && !busy,
              let index = meetings.firstIndex(where:{$0.id == id}) else { return }
        let title = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if id == selectedID {
            rename(title)
            return
        }
        var item = meetings[index]
        item.title = title
        item.updatedAt = Date()
        do {
            try MeetingArchive.write(item)
            meetings[index] = item
        } catch { status = "Не удалось переименовать: \(error.localizedDescription)" }
    }
    func deleteMeeting(_ id: UUID) {
        guard !active && !starting && !busy,
              let index = meetings.firstIndex(where:{$0.id == id}) else { return }
        let wasSelected = (selectedID == id)
        do { try MeetingArchive.delete(id) }
        catch { status = "Не удалось удалить встречу: \(error.localizedDescription)"; return }
        meetings.remove(at:index)
        if wasSelected {
            selectedID = nil
            if let next = meetings.first { apply(next) }
            else { newMeeting() }
        }
    }
    func newMeeting() {
        guard !starting && !busy else { return }
        if active { stop() }
        persist()
        let now = Date()
        let item = MeetingRecord(id:UUID(),
            title:"Встреча · " + DateFormatter.localizedString(from:now,dateStyle:.short,timeStyle:.short),
            createdAt:now,updatedAt:now,transcript:"",answer:"",responseHistory:[],
            requestCount:0,inputTokens:0,outputTokens:0,lastLatency:0)
        meetings.insert(item,at:0)
        apply(item)
        persist()
        status = "Новая встреча готова"
    }
    func openMeeting(_ id: UUID) {
        guard !active && !starting && !busy, let item = meetings.first(where:{$0.id == id}) else { return }
        persist()
        apply(item)
    }
    var duration: String {
        let seconds = max(0, Int(Date().timeIntervalSince(sessionStarted)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var utterances: [(speaker: String, time: String, text: String)] {
        transcript.split(separator: "\n").compactMap { line in
            let raw = String(line)
            guard let closing = raw.firstIndex(of: "]") else { return nil }
            let time = String(raw[raw.index(after:raw.startIndex)..<closing])
            let rest = raw[raw.index(after:closing)...].trimmingCharacters(in:.whitespaces)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            return (String(rest[..<colon]), time, String(rest[rest.index(after:colon)...]).trimmingCharacters(in:.whitespaces))
        }
    }
    let analysisModel = ProcessInfo.processInfo.environment["COPILOT_MODEL"] ?? "chatgpt/gpt-6-sol"
    @Published var requestCount = 0
    @Published var inputTokens = 0
    @Published var outputTokens = 0
    @Published var lastLatency = 0.0
    @Published var lastError = ""
    @Published var lastResponseStatus = ""
    private let gateway = ProcessInfo.processInfo.environment["COPILOT_LITELLM_URL"] ?? "http://127.0.0.1:4000"

    func start() {
        guard !active && !starting else { return }
        starting = true
        let currentMeeting = selectedID
        status = "Подключение…"
        let t1 = Transcriber(label: "Я")
        let t2 = Transcriber(label: "Другие")

        t1.onFinal = { [weak self] s in Task { @MainActor in guard self?.selectedID == currentMeeting else { return }; self?.append("Я", s); self?.partialMine = "" } }
        t2.onFinal = { [weak self] s in Task { @MainActor in guard self?.selectedID == currentMeeting else { return }; self?.append("Другие", s); self?.partialOthers = "" } }
        t1.onError = { [weak self] s in Task { @MainActor in self?.status = "Микрофон: \(s)" } }
        t2.onError = { [weak self] s in Task { @MainActor in self?.status = "Системный звук: \(s)" } }
        self.mine = t1; self.others = t2
        Task {
            do { try t1.connect(); try t2.connect() } catch { self.starting = false; self.status = "MLX Whisper: \(error.localizedDescription)"; return }
            let mic = MicCapture { data in t1.feed(data) }
            let sys = SystemCapture { data in t2.feed(data) }
            self.mic = mic; self.system = sys
            do {
                try mic.start()
                try await sys.start()
                active = true
                starting = false
                status = "Идёт транскрипция (Я / Другие)"
            } catch {
                starting = false
                status = "Ошибка доступа или захвата: \(error.localizedDescription)"
                stop()
                status = "Ошибка доступа или захвата: \(error.localizedDescription)"
            }
        }
    }
    private func append(_ who: String, _ message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        transcript += "[\(stamp)] \(who): \(message.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        persist()
    }
    func stop() {
        mic?.stop(); mic = nil
        let old = system; system = nil
        Task { await old?.stop() }
        mine?.close(); others?.close()
        mine = nil; others = nil
        active = false
        partialMine = ""; partialOthers = ""
        status = "Остановлено"
        persist()
    }
    func save() {
        let p = NSHomeDirectory() + "/Documents/MeetingCopilot-\(Int(Date().timeIntervalSince1970)).txt"
        do { try transcript.write(toFile: p, atomically: true, encoding: .utf8); status = "Сохранено: \(p)" }
        catch { status = "Не удалось сохранить: \(error.localizedDescription)" }
    }
    static func readMasterKey() -> String? {
        if let value = ProcessInfo.processInfo.environment["LITELLM_MASTER_KEY"], !value.isEmpty { return value }
        let path = NSHomeDirectory() + "/.meeting-copilot-litellm.env"
        guard let contents = try? String(contentsOfFile:path,encoding:.utf8) else { return nil }
        for rawLine in contents.components(separatedBy:.newlines) {
            var line = rawLine.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            if line.hasPrefix("LITELLM_MASTER_KEY=") {
                var value = String(line.dropFirst("LITELLM_MASTER_KEY=".count))
                value = value.trimmingCharacters(in:CharacterSet(charactersIn:"\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
    func ask() {
        guard !transcript.isEmpty, !busy else { return }
        busy = true
        let q = question
        let context = String(transcript.suffix(24000))
        requestCount += 1
        lastError = ""
        lastResponseStatus = "Запрос…"
        let begun = Date()
        let askedForID = selectedID
        Task {
            defer { busy = false; lastLatency = Date().timeIntervalSince(begun); persist() }
            do {
                guard let url = URL(string: gateway + "/v1/responses"),
                      url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" else {
                    throw NSError(domain:"Copilot", code:1, userInfo:[NSLocalizedDescriptionKey:"Разрешён только локальный LiteLLM (127.0.0.1 / localhost)"])
                }
                var req = URLRequest(url:url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField:"Content-Type")
                guard let masterKey = Self.readMasterKey() else {
                    throw NSError(domain:"LiteLLM",code:401,userInfo:[NSLocalizedDescriptionKey:"Не найден LITELLM_MASTER_KEY. Проверь ~/.meeting-copilot-litellm.env"])
                }
                req.setValue("Bearer \(masterKey)", forHTTPHeaderField:"Authorization")
                req.timeoutInterval = 90
                let system = "Ты ассистент системного аналитика на рабочем созвоне. Отвечай по-русски кратко и предметно, не придумывай факты. Если в транскрипте данных нет, скажи об этом. Возможны ошибки распознавания речи."
                let content = "Транскрипт встречи:\n\(context)\n\nВопрос: \(q)"
                req.httpBody = try JSONSerialization.data(withJSONObject:[
                    "model":analysisModel,
                    "instructions":system,
                    "input":content,
                    "store":false,
                    "stream":false
                ])
                let (data,res) = try await URLSession.shared.data(for:req)
                guard let http=res as? HTTPURLResponse else { throw NSError(domain:"LiteLLM",code:2,userInfo:[NSLocalizedDescriptionKey:"Нет HTTP ответа"]) }
                lastResponseStatus = "HTTP \(http.statusCode)"
                guard (200..<300).contains(http.statusCode) else {
                    throw NSError(domain:"LiteLLM",code:http.statusCode,userInfo:[NSLocalizedDescriptionKey:String(data:data,encoding:.utf8) ?? "Ошибка LiteLLM"])
                }
                let json = try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                let outputs = json["output"] as? [[String:Any]] ?? []
                let texts = outputs.flatMap { item in
                    (item["content"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }
                }
                guard selectedID == askedForID else { return }
                answer = texts.joined(separator:"\n")
                if answer.isEmpty { answer = "Модель не вернула ответ." }
                responseHistory.insert(answer, at: 0)
                if let usage=json["usage"] as? [String:Any] {
                    inputTokens += usage["input_tokens"] as? Int ?? 0
                    outputTokens += usage["output_tokens"] as? Int ?? 0
                }
            } catch {
                guard selectedID == askedForID else { return }
                lastError=error.localizedDescription
                answer="LiteLLM: \(error.localizedDescription)"
            }
        }
    }

}

// Each channel writes short WAV segments to a persistent local Python worker.
// The worker loads MLX Whisper once and emits newline-delimited JSON results.
final class Transcriber: @unchecked Sendable {
    var onFinal: ((String)->Void)?
    var onError: ((String)->Void)?
    private let label: String
    private let queue = DispatchQueue(label: "copilot.local.\(UUID().uuidString)")
    private var pending = Data()
    private var lastFlush = Date()
    private var process: Process?
    private var pipeIn: Pipe?
    private var pipeOut: Pipe?
    private var readBuffer = Data()
    private var seq = 0
    private var running = false
    private let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString)")
    init(label: String) { self.label=label }
    func connect() throws {
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let p = Process()
        let env = ProcessInfo.processInfo.environment
        let py = env["COPILOT_PYTHON"] ?? NSHomeDirectory() + "/Documents/Whisper/.venv/bin/python"
        let worker = env["COPILOT_WORKER"] ?? Bundle.main.path(forResource:"whisper_worker",ofType:"py") ?? (env["COPILOT_ROOT"] ?? "") + "/scripts/whisper_worker.py"
        p.executableURL = URL(fileURLWithPath:py)
        // Finder-launched apps do not inherit Homebrew PATH from the interactive shell.
        var workerEnvironment = env
        workerEnvironment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = workerEnvironment
        p.arguments = ["-u",worker]
        let input=Pipe(), output=Pipe(), errors=Pipe()
        p.standardInput=input; p.standardOutput=output; p.standardError=errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            if let value=String(data:h.availableData,encoding:.utf8), !value.isEmpty { self?.onError?(value.trimmingCharacters(in:.whitespacesAndNewlines)) }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk=h.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.consume(chunk) }
        }
        try p.run()
        process=p; pipeIn=input; pipeOut=output
        running=true
    }
    private func consume(_ bytes:Data) {
        readBuffer.append(bytes)
        while let newline=readBuffer.firstIndex(of:10) {
            let line=readBuffer.prefix(upTo:newline)
            readBuffer.removeSubrange(...newline)
            guard let json=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] else { continue }
            if let err=json["error"] as? String { onError?(err) }
            if let text=json["text"] as? String, !text.isEmpty { onFinal?(text) }
        }
    }
    func feed(_ bytes:Data) {
        queue.async {
            guard self.running else { return }
            self.pending.append(bytes)
            if Date().timeIntervalSince(self.lastFlush)>=5.0 { self.flush() }
        }
    }
    private func flush() {
        guard !pending.isEmpty else { return }
        // Suppress silent segments (simple RMS; not a substitute for VAD).
        let frames = pending.count/2
        if frames < 12000 { return }
        let rms:Double = pending.withUnsafeBytes { bytes in
            let p=bytes.bindMemory(to:Int16.self)
            guard !p.isEmpty else { return 0 }
            var sum=0.0
            for i in stride(from:0,to:p.count,by:8) { let v=Double(p[i])/32768; sum+=v*v }
            return sqrt(sum / Double((p.count+7)/8))
        }
        let audio=pending
        pending.removeAll(keepingCapacity:true)
        lastFlush=Date()
        if rms<0.004 { return }
        seq+=1
        let file=workspace.appendingPathComponent("\(seq).wav")
        var wav=Data()
        let size=UInt32(audio.count)
        func add16(_ n:UInt16) { var a=n.littleEndian; withUnsafeBytes(of:&a) { wav.append(contentsOf:$0) } }
        func add32(_ n:UInt32) { var a=n.littleEndian; withUnsafeBytes(of:&a) { wav.append(contentsOf:$0) } }
        wav.append(contentsOf:Array("RIFF".utf8)); add32(size+36)
        wav.append(contentsOf:Array("WAVEfmt ".utf8)); add32(16)
        add16(1); add16(1); add32(24000); add32(48000); add16(2); add16(16)
        wav.append(contentsOf:Array("data".utf8)); add32(size); wav.append(audio)
        do {
            try wav.write(to:file)
            let command = ["path":file.path]
            let data=try JSONSerialization.data(withJSONObject:command)
            var framed=data; framed.append(10)
            pipeIn?.fileHandleForWriting.write(framed)
        } catch { onError?("Ошибка локального аудио: \(error.localizedDescription)") }
    }
    func close() {
        queue.sync { self.flush(); self.running=false }
        pipeIn?.fileHandleForWriting.closeFile()
        // Permit transcription of pending segment, then terminate on worker exit.
    }
}

// Linear 48 kHz -> 24 kHz conversion, fast MVP implementation.
func pcm24k(_ samples: UnsafePointer<Float>, frames: Int, rate: Double, channels:Int = 1, interleaved:Bool = false) -> Data {
    guard frames > 0, rate > 0 else { return Data() }
    let count = Int(Double(frames) * 24000.0 / rate)
    var output = Data(capacity:count*2)
    for i in 0..<count {
        let src = min(frames-1,Int(Double(i)*rate/24000.0))
        let f = samples[interleaved ? src*channels : src]
        let v = Int16(max(-32768,min(32767,Int(f*32767))))
        var le = v.littleEndian
        withUnsafeBytes(of:&le) { output.append(contentsOf:$0) }
    }
    return output
}

final class MicCapture {
    private let engine = AVAudioEngine()
    private let output:(Data)->Void
    init(output:@escaping(Data)->Void) { self.output = output }
    func start() throws {
        let input = engine.inputNode
        let f = input.outputFormat(forBus:0)
        guard f.sampleRate > 0, f.channelCount > 0 else { throw NSError(domain:"Mic",code:2,userInfo:[NSLocalizedDescriptionKey:"Нет доступного входного аудиоформата. Проверь микрофон и разрешения."]) }
        input.installTap(onBus:0, bufferSize:2048, format:f) { [weak self] buf,_ in
            guard let floats=buf.floatChannelData?[0] else { return }
            self?.output(pcm24k(floats,frames:Int(buf.frameLength),rate:buf.format.sampleRate))
        }
        try engine.start()
    }
    func stop() { engine.inputNode.removeTap(onBus:0); engine.stop() }
}

final class SystemCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream:SCStream?
    private let output:(Data)->Void
    init(output:@escaping(Data)->Void) { self.output=output }
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        guard let display = content.displays.first else { throw NSError(domain:"Capture",code:1,userInfo:[NSLocalizedDescriptionKey:"Нет дисплея"]) }
        let filter = SCContentFilter(display:display, excludingWindows:[])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 16; config.height = 16
        config.minimumFrameInterval = CMTime(value:1,timescale:1)
        let s = SCStream(filter:filter,configuration:config,delegate:self)
        try s.addStreamOutput(self,type:.audio,sampleHandlerQueue:DispatchQueue(label:"copilot.system.audio"))
        stream = s
        try await s.startCapture()
    }
    func stop() async { try? await stream?.stopCapture(); stream = nil }
    func stream(_ stream:SCStream,didStopWithError error:Error) { print("SCStream: \(error)") }
    func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(buffer), let desc=CMSampleBufferGetFormatDescription(buffer),let asbd=CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let frames=CMSampleBufferGetNumSamples(buffer)
        var size=0
        var list=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:1,mDataByteSize:0,mData:nil))
        var retained:CMBlockBuffer?
        let result=CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer,bufferListSizeNeededOut:&size,bufferListOut:&list,bufferListSize:MemoryLayout<AudioBufferList>.size,blockBufferAllocator:kCFAllocatorDefault,blockBufferMemoryAllocator:kCFAllocatorDefault,flags:0,blockBufferOut:&retained)
        guard result == noErr,let ptr=list.mBuffers.mData else { return }
        // ScreenCaptureKit delivers Float32 PCM on supported macOS configurations.
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.pointee.mBitsPerChannel == 32 {
            let floatPtr=ptr.assumingMemoryBound(to:Float.self)
            let channels=max(1,Int(asbd.pointee.mChannelsPerFrame))
            output(pcm24k(floatPtr,frames:frames,rate:asbd.pointee.mSampleRate,channels:channels,interleaved:channels>1 && (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved)==0))
        }
    }
}

// Desktop window layout: visible, resizable, and intentionally included in screen sharing.
private enum Palette {
    static let canvas = Color(red:0.065,green:0.083,blue:0.112)
    static let panel = Color(red:0.10,green:0.125,blue:0.16)
    static let elevated = Color(red:0.14,green:0.17,blue:0.21)
    static let accent = Color(red:0.40,green:0.84,blue:0.76)
    static let secondary = Color(red:0.61,green:0.68,blue:0.73)
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            Text(title).font(.system(size:18,weight:.semibold))
            Text(subtitle).font(.system(size:12)).foregroundStyle(Palette.secondary)
        }
    }
}

private struct TranscriptBubble: View {
    let speaker:String
    let time:String
    let content:String
    private var isMine:Bool { speaker == "Я" }
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            ZStack {
                RoundedRectangle(cornerRadius:12).fill(isMine ? Palette.accent.opacity(0.17) : Color.orange.opacity(0.14))
                Image(systemName:isMine ? "person.fill" : "person.2.fill")
                    .foregroundStyle(isMine ? Palette.accent : Color.orange)
            }.frame(width:36,height:36)
            VStack(alignment:.leading,spacing:5) {
                HStack {
                    Text(speaker).font(.system(size:12,weight:.bold))
                    Text(time).font(.system(size:11)).foregroundStyle(Palette.secondary)
                }
                Text(content).font(.system(size:14)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:0)
        }
        .padding(14)
        .background(Palette.elevated.opacity(0.64),in:RoundedRectangle(cornerRadius:14))
    }
}

struct DashboardView:View {
    @ObservedObject var state:MeetingState
    @State private var selectedTab = 0
    @State private var secondsTick = 0
    @State private var meetingSearch = ""
    @State private var meetingToRename: UUID?
    @State private var renameDraft = ""
    @State private var showRenamePrompt = false
    @State private var meetingToDelete: UUID?
    @State private var showDeletePrompt = false
    private func prepareRename(_ item: MeetingRecord) {
        meetingToRename = item.id
        renameDraft = item.title
        showRenamePrompt = true
    }
    private func prepareDelete(_ item: MeetingRecord) {
        meetingToDelete = item.id
        showDeletePrompt = true
    }
    private var matchingMeetings: [MeetingRecord] {
        let query = meetingSearch.trimmingCharacters(in:.whitespacesAndNewlines)
        return state.meetings.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) ||
            $0.transcript.localizedCaseInsensitiveContains(query) ||
            $0.responseHistory.contains(where:{$0.localizedCaseInsensitiveContains(query)})
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        HStack(spacing:0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.07)).frame(width:1)
            VStack(spacing:0) {
                header
                Rectangle().fill(Color.white.opacity(0.07)).frame(height:1)
                HStack(spacing:0) {
                    transcriptPanel
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width:1)
                    assistantPanel
                }
            }
        }
        .background(Palette.canvas)
        .foregroundStyle(.white)
        .frame(minWidth:960,minHeight:620)
        .preferredColorScheme(.dark)
        .onAppear { state.proxyStatus = "LiteLLM · localhost:4000" }
        .alert("Переименовать встречу",isPresented:$showRenamePrompt) {
            TextField("Название встречи",text:$renameDraft)
            Button("Отмена",role:.cancel) { meetingToRename = nil }
            Button("Сохранить") {
                if let id = meetingToRename { state.renameMeeting(id,to:renameDraft) }
                meetingToRename = nil
            }
        } message: {
            Text("Новое название будет сохранено локально.")
        }
        .confirmationDialog(
            "Удалить встречу?",
            isPresented:$showDeletePrompt,
            titleVisibility:.visible
        ) {
            Button("Удалить встречу",role:.destructive) {
                if let id = meetingToDelete { state.deleteMeeting(id) }
                meetingToDelete = nil
            }
            Button("Отмена",role:.cancel) { meetingToDelete = nil }
        } message: {
            Text("Транскрипт и сохранённые ответы GPT будут удалены с этого Mac. Отменить удаление нельзя.")
        }
    }

    private var sidebar:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:11) {
                Image(systemName:"waveform.path").font(.system(size:19,weight:.semibold))
                    .frame(width:38,height:38).background(Palette.accent.opacity(0.18),in:RoundedRectangle(cornerRadius:11))
                    .foregroundStyle(Palette.accent)
                VStack(alignment:.leading,spacing:2) {
                    Text("Meeting").font(.system(size:17,weight:.bold))
                    Text("COPILOT").font(.system(size:10,weight:.semibold,design:.rounded)).tracking(3).foregroundStyle(Palette.accent)
                }
            }.padding(.top,9)
            Button { state.newMeeting() } label: {
                Label("Новая встреча",systemImage:"plus.circle.fill")
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            .buttonStyle(.borderedProminent).tint(Palette.accent)
            .disabled(state.starting || state.busy)
            Divider().overlay(.white.opacity(0.1))
            HStack {
                Text("ИСТОРИЯ ВСТРЕЧ").font(.system(size:10,weight:.bold)).tracking(1.2).foregroundStyle(Palette.secondary)
                Spacer()
                Text(String(state.meetings.count)).font(.system(size:11)).foregroundStyle(Palette.secondary)
            }
            TextField("Поиск по встречам и тексту…",text:$meetingSearch)
                .textFieldStyle(.roundedBorder)
                .font(.system(size:12))
            ScrollView {
                LazyVStack(alignment:.leading,spacing:6) {
                    ForEach(matchingMeetings) { item in
                        Button { state.openMeeting(item.id) } label: {
                            VStack(alignment:.leading,spacing:4) {
                                HStack(spacing:6) {
                                    Image(systemName:item.id == state.selectedID ? "waveform" : "text.bubble")
                                        .foregroundStyle(item.id == state.selectedID ? Palette.accent : Palette.secondary)
                                    Text(item.title.isEmpty ? "Без названия" : item.title)
                                        .font(.system(size:12,weight:.semibold))
                                        .lineLimit(2)
                                }
                                Text(DateFormatter.localizedString(from:item.createdAt,dateStyle:.short,timeStyle:.short))
                                    .font(.system(size:10)).foregroundStyle(Palette.secondary)
                                Text(item.transcript.isEmpty ? "Нет реплик" : String(item.transcript.suffix(110)))
                                    .font(.system(size:10))
                                    .foregroundStyle(Palette.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .padding(10)
                            .background(item.id == state.selectedID ? Palette.elevated : Color.clear,in:RoundedRectangle(cornerRadius:10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled((state.active || state.starting || state.busy) && item.id != state.selectedID)
                        .contextMenu {
                            Button("Открыть",systemImage:"arrow.up.right.square") { state.openMeeting(item.id) }
                            Button("Переименовать",systemImage:"pencil") { prepareRename(item) }
                            Divider()
                            Button("Удалить",systemImage:"trash",role:.destructive) { prepareDelete(item) }
                        }
                    }
                    if matchingMeetings.isEmpty {
                        Text("Ничего не найдено").font(.system(size:12)).foregroundStyle(Palette.secondary)
                            .padding(.vertical,12)
                    }
                }
            }
            Divider().overlay(.white.opacity(0.1))
            VStack(alignment:.leading,spacing:8) {
                Text("ПОДКЛЮЧЕНИЯ").font(.system(size:10,weight:.bold)).tracking(1.5).foregroundStyle(Palette.secondary)
                connectionLabel("MLX Whisper",icon:"waveform.path",color:Palette.accent)
                connectionLabel("LiteLLM · GPT",icon:"sparkles",color:Color(red:0.69,green:0.72,blue:1))
            }
            Text("Встречи хранятся локально на Mac. В GPT уходит текст только при запросе.")
                .font(.system(size:10)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
        .padding(16)
        .frame(width:252)
        .frame(maxHeight:.infinity,alignment:.topLeading)
        .background(Palette.panel)
    }
    private func sidebarItem(_ text:String,icon:String,selected:Bool)->some View {
        HStack(spacing:10) {
            Image(systemName:icon).frame(width:18)
            Text(text).font(.system(size:13,weight:selected ? .semibold : .medium))
            Spacer()
        }
        .foregroundStyle(selected ? .white : Palette.secondary)
        .padding(.horizontal,11).padding(.vertical,12)
        .background(selected ? Palette.elevated : Color.clear,in:RoundedRectangle(cornerRadius:10))
    }
    private func connectionLabel(_ name:String,icon:String,color:Color)->some View {
        HStack(spacing:9) {
            Image(systemName:icon).foregroundStyle(color)
            Text(name).font(.system(size:12))
        }.padding(.vertical,4)
    }
    private var header:some View {
        HStack(spacing:15) {
            VStack(alignment:.leading,spacing:5) {
                TextField("Название встречи",text:Binding(get:{state.sessionTitle},set:{state.rename($0)}))
                    .textFieldStyle(.plain).font(.system(size:21,weight:.semibold))
                HStack(spacing:7) {
                    Circle().fill(state.active ? Palette.accent : Palette.secondary).frame(width:7,height:7)
                    Text(state.status).font(.system(size:12)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text("\(state.inputTokens + state.outputTokens) токенов")
                .font(.system(size:12,design:.monospaced)).foregroundStyle(Palette.secondary)
            Button { state.save() } label: {
                Label("Экспорт",systemImage:"square.and.arrow.up")
            }.buttonStyle(.bordered)
            Button { state.active ? state.stop() : state.start() } label: {
                Label(state.active ? "Остановить" : "Начать запись",systemImage:state.active ? "stop.fill" : "record.circle")
                    .frame(minWidth:125)
            }.buttonStyle(.borderedProminent).tint(state.active ? .red : Palette.accent)
                .disabled(state.starting)
        }
        .padding(.horizontal,24).padding(.vertical,18)
        .background(Palette.panel.opacity(0.6))
    }
    private var transcriptPanel:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                SectionHeading(title:"Транскрипт",subtitle:"Реплики по мере распознавания")
                Spacer()
                Text("\(state.utterances.count) реплик")
                    .font(.system(size:11)).foregroundStyle(Palette.secondary)
            }.padding(22)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:11) {
                        if state.utterances.isEmpty {
                            VStack(spacing:13) {
                                Image(systemName:"waveform").font(.system(size:36)).foregroundStyle(Palette.accent)
                                Text("Разговор появится здесь").font(.system(size:17,weight:.semibold))
                                Text("Начни запись, чтобы видеть свои реплики и системный звук отдельно.")
                                    .font(.system(size:12)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth:.infinity).padding(.top,85)
                        }
                        ForEach(Array(state.utterances.enumerated()),id:\.offset) { item in
                            TranscriptBubble(speaker:item.element.speaker,time:item.element.time,content:item.element.text)
                                .id(item.offset)
                        }
                        if !state.partialMine.isEmpty { TranscriptBubble(speaker:"Я",time:"Сейчас",content:state.partialMine) }
                        if !state.partialOthers.isEmpty { TranscriptBubble(speaker:"Другие",time:"Сейчас",content:state.partialOthers) }
                    }.padding(.horizontal,22).padding(.bottom,20)
                }
                .onChange(of:state.utterances.count) { _, newCount in
                    if newCount > 0 { withAnimation { proxy.scrollTo(newCount - 1,anchor:.bottom) } }
                }
            }
            HStack(spacing:8) {
                Image(systemName:"lock.shield").foregroundStyle(Palette.accent)
                Text("Микрофон и звук системы разделены на два канала")
                    .font(.system(size:11)).foregroundStyle(Palette.secondary)
                Spacer()
            }.padding(15).background(Palette.panel)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var assistantPanel:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                SectionHeading(title:"ИИ-ассистент",subtitle:"Контекст встречи · GPT через LiteLLM")
                Spacer()
                Image(systemName:"sparkles").foregroundStyle(Palette.accent)
            }.padding(22)
            HStack(spacing:7) {
                Label("Уточнить",systemImage:"questionmark.circle")
                    .onTapGesture { state.question = "Какие вопросы остались открытыми?" }
                Spacer()
                Label("Решения",systemImage:"checkmark.circle")
                    .onTapGesture { state.question = "Какие решения приняты на встрече?" }
                Spacer()
                Label("Итоги",systemImage:"list.bullet")
                    .onTapGesture { state.question = "Кратко подведи итоги разговора и следующие действия." }
            }.font(.system(size:11)).foregroundStyle(Palette.accent).padding(.horizontal,22)
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    if state.answer.isEmpty {
                        VStack(alignment:.leading,spacing:11) {
                            Image(systemName:"brain.head.profile").font(.system(size:28)).foregroundStyle(Palette.accent)
                            Text("Спроси по ходу разговора").font(.system(size:17,weight:.semibold))
                            Text("Сформулирую ответ по транскрипту, выделю решения, риски и следующие шаги. Без выдуманных фактов.")
                                .font(.system(size:13)).foregroundStyle(Palette.secondary)
                        }.padding(18).frame(maxWidth:.infinity,alignment:.leading)
                            .background(Palette.elevated,in:RoundedRectangle(cornerRadius:16))
                    } else {
                        HStack {
                            Image(systemName:"sparkles").foregroundStyle(Palette.accent)
                            Text("ОТВЕТ GPT").font(.system(size:10,weight:.bold)).tracking(1.3).foregroundStyle(Palette.accent)
                        }
                        Text(state.answer).font(.system(size:14)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if !state.lastError.isEmpty {
                        Text(state.lastError).font(.system(size:12)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding(22)
            }
            Divider().overlay(.white.opacity(0.07))
            VStack(spacing:11) {
                HStack(spacing:12) {
                    metric("ЗАПРОСЫ",String(state.requestCount))
                    metric("ВХОД",String(state.inputTokens))
                    metric("ВЫХОД",String(state.outputTokens))
                    metric("LATENCY",String(format:"%.1f с",state.lastLatency))
                }
                HStack(spacing:8) {
                    TextField("Спроси об обсуждении…",text:$state.question,axis:.vertical)
                        .textFieldStyle(.plain).lineLimit(1...3).font(.system(size:13))
                        .onSubmit { state.ask() }
                    Button { state.ask() } label: { Image(systemName:"arrow.up") }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                        .disabled(state.busy || state.transcript.isEmpty)
                }
                .padding(10).background(Palette.elevated,in:RoundedRectangle(cornerRadius:12))
            }.padding(17).background(Palette.panel)
        }
        .frame(width:390)
        .frame(maxHeight:.infinity)
    }
    private func metric(_ name:String,_ value:String)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(name).font(.system(size:9,weight:.bold)).tracking(0.7).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size:12,weight:.semibold,design:.monospaced))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    let state = MeetingState()
    var window:NSWindow?
    var proxyProcess:Process?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingView(rootView:DashboardView(state:state))
        let frame = NSRect(x:130,y:130,width:1200,height:760)
        let w = NSWindow(contentRect:frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "Meeting Copilot"
        w.contentView = host
        w.minSize = NSSize(width:960,height:620)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        window = w
        startLocalProxyIfPossible()
    }
    private func startLocalProxyIfPossible() {
        let env = ProcessInfo.processInfo.environment
        let exe = NSHomeDirectory() + "/.meeting-copilot-litellm/bin/litellm"
        guard FileManager.default.isExecutableFile(atPath:exe) else {
            state.status = "LiteLLM не установлен: см. README"
            return
        }
        guard let masterKey = MeetingState.readMasterKey() else {
            state.proxyStatus = "Не найден master key"
            return
        }
        guard let config = Bundle.main.path(forResource:"litellm-config",ofType:"yaml") else { return }
        // Another proxy may already be running on localhost:4000.
        // Avoid starting a second copy and reporting a misleading failure.
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        if socket >= 0 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(4000).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            Darwin.close(socket)
            if connected == 0 { state.proxyStatus = "LiteLLM подключён"; return }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath:exe)
        p.arguments = ["--config",config,"--host","127.0.0.1","--port","4000"]
        var variables = env
        variables["LITELLM_MASTER_KEY"] = masterKey
        variables["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = variables
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); proxyProcess = p }
        catch { state.status = "Не удалось запустить LiteLLM: \(error.localizedDescription)" }
    }
    func applicationWillTerminate(_ notification:Notification) {
        state.stop()
        if let p=proxyProcess,p.isRunning { p.terminate() }
    }
}

@main struct CopilotApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body:some Scene { Settings { EmptyView() } }
}
