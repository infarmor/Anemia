import Foundation
import Testing

@testable import LoaderCore

/// `AntiCensorshipOptions` falls back per field on purpose — and its two
/// arrays have to fall back per *element*, or one drifted value costs every
/// noise generator and the ClientHello fragmentation while the profile name in
/// the UI stays exactly the same. That is a handshake failing far away from
/// the record that caused it.
struct AntiCensorshipDecodeTests {
    private func decode(_ json: String) -> AntiCensorshipOptions {
        try! JSONDecoder().decode(AntiCensorshipOptions.self, from: Data(json.utf8))
    }

    @Test func onePoisonedNoiseCostsOnlyItself() {
        let options = decode("""
            {"noises":[
              {"type":"rand","packet":"50-100","delay":"10-16"},
              {"type":"str","packet":700,"delay":"0-0"},
              {"type":"base64","packet":"AAXEyG8=","delay":"20-40"}
            ]}
            """)
        #expect(options.noises.count == 2, "one unreadable noise took the array: \(options.noises)")
        #expect(options.noises.map(\.type) == ["rand", "base64"])
    }

    @Test func healthyAndShapedWrongValuesStaySane() {
        let good = decode(#"{"noises":[{"type":"rand","packet":"50-100","delay":"10-16"}]}"#)
        #expect(good.noises.count == 1)
        // Not an array at all — the field's own default, as before.
        #expect(decode(#"{"noises":5}"#).noises.isEmpty)
        #expect(decode(#"{"noises":[]}"#).noises.isEmpty)
        let names = decode(#"{"mimicry":["yandex","vk",42],"noises":[]}"#)
        #expect(names.mimicry == ["yandex", "vk"], "one bad alias cost the list: \(names.mimicry)")
    }
}
