import XCTest
@testable import Ppomi

/// The pure parts of RealtimeVoice: no socket, no microphone. open() is never called here.
final class RealtimeTests: XCTestCase {
    func testToolFlattening() {
        let spec = ToolSpec(name: "phone_tap", description: "탭한다", params: ["text": ("string", "글자"), "x": ("number", nil)], required: ["text"])
        let t = RealtimeVoice.tool(spec)
        XCTAssertEqual(t["type"] as? String, "function")
        XCTAssertEqual(t["name"] as? String, "phone_tap")
        XCTAssertEqual(t["description"] as? String, "탭한다")
        XCTAssertNil(t["function"])                                  // flattened, not nested like chat-completions
        let p = t["parameters"] as? [String: Any]
        XCTAssertEqual(p?["type"] as? String, "object")
        XCTAssertEqual(p?["required"] as? [String], ["text"])
        let props = p?["properties"] as? [String: [String: String]]
        XCTAssertEqual(props?["text"], ["type": "string", "description": "글자"])
        XCTAssertEqual(props?["x"], ["type": "number"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(t))
    }

    private func j(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }

    func testParseEvents() {
        XCTAssertEqual(RealtimeVoice.parse(j(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":" 오늘 지출 얼마야 \n"}"#)), .userSaid("오늘 지출 얼마야"))
        XCTAssertEqual(RealtimeVoice.parse(j(#"{"type":"response.output_audio_transcript.done","transcript":"3만 원이야"}"#)), .assistantSaid("3만 원이야"))   // GA
        XCTAssertEqual(RealtimeVoice.parse(j(#"{"type":"response.audio_transcript.done","transcript":"3만 원이야"}"#)), .assistantSaid("3만 원이야"))          // beta
        XCTAssertEqual(RealtimeVoice.parse(j(#"{"type":"response.function_call_arguments.done","name":"today_spending","call_id":"c1","arguments":"{}"}"#)), .toolCall("today_spending"))
        XCTAssertNil(RealtimeVoice.parse(j(#"{"type":"response.output_audio.delta","delta":"AAA="}"#)))
        XCTAssertNil(RealtimeVoice.parse(j(#"{"type":"session.updated"}"#)))
        XCTAssertNil(RealtimeVoice.parse(j(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":" \n"}"#)))   // noise: nothing to show
        XCTAssertNil(RealtimeVoice.parse(["no": "type"]))
    }

    func testURL() {
        XCTAssertEqual(RealtimeVoice.url(base: "https://api.openai.com/v1", model: "gpt-realtime").absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
        XCTAssertEqual(RealtimeVoice.url(base: "http://localhost:8080/v1/", model: "m").absoluteString, "ws://localhost:8080/v1/realtime?model=m")
    }

    func testPCM16ToFloat() {
        var le: [UInt8] = []
        for v in [Int16(0), Int16.max, Int16.min] { le += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
        let buf = RealtimeVoice.pcm(Data(le + [0x01]))              // a trailing odd byte is dropped
        XCTAssertEqual(buf?.frameLength, 3)
        XCTAssertEqual(buf?.format.sampleRate, 24000)
        let f = buf!.floatChannelData![0]
        XCTAssertEqual(f[0], 0); XCTAssertEqual(f[1], Float(Int16.max) / 32768, accuracy: 1e-6); XCTAssertEqual(f[2], -1)
        XCTAssertNil(RealtimeVoice.pcm(Data([0x01])))
    }
}
