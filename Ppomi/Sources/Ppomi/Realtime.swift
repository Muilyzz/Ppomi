// The real-time mouth and ear: one OpenAI Realtime (speech-to-speech, GA schema) session over a WebSocket. The mic streams
// 24 kHz PCM16 up, the model's voice streams down into an AVAudioPlayerNode on the same voice-processed engine (echo
// cancelled), the server's VAD decides turns and cuts the answer when the person speaks. Tool calls run on a serial
// background queue through `execute` (the same Tools.execute as text chat, so the payment gate is the same code).
// Nothing here treats a transcript as an answer to a pending question: approvals stay on the window's buttons.
import AVFoundation
import Foundation

@MainActor
final class RealtimeVoice {
    struct Config {
        var model = AppSettings.env("OPENAI_REALTIME_MODEL") ?? "gpt-realtime-2.1"   // the newest on the account (2026-09-04); .env overrides
        var voice = "marin"; var instructions: String; var tools: [ToolSpec]
    }
    enum Event: Equatable { case userSaid(String), assistantSaid(String), toolCall(String), closed(String) }   // closed(이유)
    var onEvent: (@MainActor (Event) -> Void)?
    /// 도구 실행: 백그라운드 큐에서 호출된다(폰 조작은 오래 걸림). 결과 문자열이 function_call_output 으로 들어간다.
    var execute: ((String, [String: Any]) -> String)?
    private(set) var isOpen = false
    nonisolated static let debug = AppSettings.env("PPOMI_REALTIME_DEBUG") != nil   // print every server event type

    init(config: Config, apiKey: String) { self.config = config; self.apiKey = apiKey }

    /// WebSocket → session.update → mic streaming → speaker. Throws (after cleaning up, no .closed) when any step fails.
    func open() async throws {
        teardown()                                                // a second open() on the same instance: no .closed for the window
        isOpen = true
        do {
            let sock = URLSession.shared.webSocketTask(with: request())
            socket = sock
            sock.resume()
            Self.send(sock, sessionUpdate())
            receiver = Task { [weak self] in
                while let sock = self?.socket {
                    do { let m = try await sock.receive(); self?.handle(m) }
                    catch { self?.close("연결 끊김: \(error.localizedDescription)"); return }
                }
            }
            try startAudio(sock)
        } catch { teardown(); throw error }
    }

    func close(_ reason: String) {
        guard isOpen else { return }
        teardown()
        onEvent?(.closed(reason))
    }

    /// Make the model speak first (the arrival greeting): one response.create with its own instructions.
    func say(_ instructions: String) { Self.send(socket, ["type": "response.create", "response": ["instructions": instructions]]) }

    // MARK: wire

    private let config: Config
    private let apiKey: String
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let speakUntil = Box(Date.distantPast)          // when the queued answer audio will have finished playing
    final class Box: @unchecked Sendable { var value: Date; init(_ v: Date) { value = v } }
    private var ready = false                                     // session.updated came: later errors are not the schema's fault
    private let tools = DispatchQueue(label: "ppomi.realtime.tools")   // serial: calls run in the order the model made them
    nonisolated static let rate = 24000.0
    nonisolated static let speaker = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    nonisolated static let mic = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!

    /// wss://<base host>/v1/realtime?model=… — the chat base URL with its scheme swapped.
    nonisolated static func url(base: String = AppSettings.baseURL, model: String) -> URL {
        var c = URLComponents(string: base) ?? URLComponents(string: "https://api.openai.com/v1")!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/realtime"
        c.queryItems = [URLQueryItem(name: "model", value: model)]
        return c.url!
    }
    private func request() -> URLRequest {
        var r = URLRequest(url: Self.url(model: config.model))
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// A chat-completions tool ({type, function:{name…}}) flattened the way Realtime wants it ({type, name, description, parameters}).
    nonisolated static func tool(_ t: ToolSpec) -> [String: Any] {
        var d = t.json["function"] as? [String: Any] ?? [:]
        d["type"] = "function"
        return d
    }

    private func sessionUpdate() -> [String: Any] {
        let fmt: [String: Any] = ["type": "audio/pcm", "rate": Int(Self.rate)]
        return ["type": "session.update", "session": [
            "type": "realtime",
            "instructions": config.instructions,
            "output_modalities": ["audio"],
            "audio": ["input": ["format": fmt,
                                "noise_reduction": ["type": "near_field"],                      // laptop mic, person close by
                                "transcription": ["model": "gpt-4o-transcribe", "language": "ko",
                                                  "prompt": "뽀미, 여기어때, 타니베이, 잔액, 지출, 예약, 결제 승인"],   // names the transcriber keeps misspelling
                                "turn_detection": ["type": "semantic_vad", "eagerness": "medium",   // end of turn by meaning, not 600 ms of silence
                                                   "create_response": true, "interrupt_response": true]],
                      "output": ["format": fmt, "voice": config.voice]],
            "tools": config.tools.map(Self.tool),
            "tool_choice": "auto"]]
    }

    nonisolated static func send(_ sock: URLSessionWebSocketTask?, _ json: [String: Any]) {
        guard let sock, let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        sock.send(.string(String(decoding: data, as: UTF8.self))) { if let e = $0 { print("Realtime send: \(e.localizedDescription)") } }
    }

    // MARK: receive

    /// The events that mean something to the window. Both GA (output_audio…) and beta (audio…) names.
    nonisolated static func parse(_ j: [String: Any]) -> Event? {
        let t = (j["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)   // empty: the VAD fired on noise — no bubble, no log row
        switch j["type"] as? String {
        case "conversation.item.input_audio_transcription.completed": return t.isEmpty ? nil : .userSaid(t)
        case "response.output_audio_transcript.done", "response.audio_transcript.done": return t.isEmpty ? nil : .assistantSaid(t)
        case "response.function_call_arguments.done": return .toolCall(j["name"] as? String ?? "")
        default: return nil
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        let text: String
        switch msg {
        case .string(let s): text = s
        case .data(let d): text = String(decoding: d, as: UTF8.self)
        @unknown default: return
        }
        guard let j = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let type = j["type"] as? String else { return }
        if Self.debug { print("Realtime ← \(type)") }
        if let e = Self.parse(j) { onEvent?(e) }
        switch type {
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = j["delta"] as? String, let d = Data(base64Encoded: b64), let buf = Self.pcm(d) {
                player?.scheduleBuffer(buf)
                let secs = Double(buf.frameLength) / Self.rate
                speakUntil.value = max(speakUntil.value, Date()).addingTimeInterval(secs + 0.35)   // queue end + a little tail
            }
        case "input_audio_buffer.speech_started":                // the person talks over the answer: drop what is queued
            player?.stop(); player?.play()
        case "session.updated": ready = true
        case "error":
            let m = (j["error"] as? [String: Any])?["message"] as? String ?? text
            print("Realtime error: \(m)")
            if !ready { close("session.update 거부: \(m)") }        // after that, errors are per-event (e.g. a response already running)
        case "response.function_call_arguments.done":
            let name = j["name"] as? String ?? "", callId = j["call_id"] as? String ?? ""
            let args = (j["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            let exec = execute, sock = socket
            tools.async {
                let out = exec?(name, args) ?? "도구 없음: \(name)"
                Self.send(sock, ["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callId, "output": String(out.prefix(4000))]])
                Self.send(sock, ["type": "response.create"])
            }
        default: break
        }
    }

    /// 24 kHz mono little-endian Int16 bytes → a Float32 buffer the player takes.
    nonisolated static func pcm(_ data: Data) -> AVAudioPCMBuffer? {
        let n = data.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: speaker, frameCapacity: AVAudioFrameCount(n)), let out = buf.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        buf.frameLength = AVAudioFrameCount(n)
        return buf
    }

    // MARK: audio

    private func startAudio(_ sock: URLSessionWebSocketTask) throws {
        let engine = AVAudioEngine(), node = engine.inputNode
        // Voice processing (hardware echo cancellation) made this engine fail to open on the 2026-09-04 Mac; opt in with PPOMI_AEC=1.
        // Without it the mic is muted in software while the model's audio is still playing (speakUntil), so it never hears itself.
        if ProcessInfo.processInfo.environment["PPOMI_AEC"] != nil { try? node.setVoiceProcessingEnabled(true) }
        let inFormat = node.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw Chat.Failure(description: "입력 장치 없음") }
        guard let converter = AVAudioConverter(from: inFormat, to: Self.mic) else { throw Chat.Failure(description: "마이크 포맷 변환 불가") }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.speaker)
        let mic = Self.mic, ratio = Self.rate / inFormat.sampleRate, until = speakUntil
        node.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            guard let out = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16) else { return }
            var given = false
            var err: NSError?
            let st = converter.convert(to: out, error: &err) { _, status in
                status.pointee = given ? .noDataNow : .haveData
                defer { given = true }
                return given ? nil : buffer
            }
            guard st != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            if Date() < until.value { return }                    // our own voice is on the speaker: don't feed it back as the person's
            Self.send(sock, ["type": "input_audio_buffer.append", "audio": Data(bytes: ch[0], count: Int(out.frameLength) * 2).base64EncodedString()])
        }
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine; self.player = player
        print("Realtime: mic \(inFormat.sampleRate) Hz → \(Int(Self.rate)) Hz, model \(config.model), voice \(config.voice)")
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        engine = nil; player = nil; receiver = nil; socket = nil; ready = false; isOpen = false
    }
}
