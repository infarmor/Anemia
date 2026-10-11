import Foundation
import Testing

@testable import LoaderApp

/// `LogLineBuffer` reassembles engine stdout into lines for the failure
/// message. It capped what it *keeps* (the last 20 lines) but not what it
/// *accumulates* between newlines, so an engine that writes without ever
/// finishing a line grew the buffer for as long as it ran.
struct EngineLogBufferTests {
    @Test func linesSplitAcrossChunksStillReassemble() {
        let buffer = LogLineBuffer()
        #expect(buffer.append(Data("xray starts, the re".utf8)) == [])
        #expect(buffer.append(Data("ason is: port in use\nsecond line\n".utf8))
                == ["xray starts, the reason is: port in use", "second line"])
        buffer.finish()
        #expect(buffer.tailLines() == ["xray starts, the reason is: port in use", "second line"])
    }

    @Test func unterminatedStreamIsCapped() throws {
        let buffer = LogLineBuffer()
        let chunk = Data(repeating: 0x61, count: 8 * 1024)   // 'a', no newline
        var sawTruncation = false
        for _ in 0..<64 {
            // 512 KB in, and never a line ending.
            if buffer.append(chunk).contains(where: { $0.hasSuffix("…[truncated]") }) {
                sawTruncation = true
            }
            #expect(buffer.pendingCount <= LogLineBuffer.pendingCapacity,
                    "pending grew to \(buffer.pendingCount)")
        }
        // The overflow is reported (marked) rather than dropped silently — it
        // is the only thing the user will ever see about this run.
        #expect(sawTruncation)
        // Whatever is still buffered when a real newline arrives is at most one
        // capped fragment, and the line after it comes through intact.
        let final = buffer.append(Data("\ntail after the flood\n".utf8))
        #expect(final.last == "tail after the flood", "got \(final.count) lines")
        #expect(buffer.pendingCount == 0)
    }

    @Test func finishKeepsAnUnterminatedLastLine() {
        let buffer = LogLineBuffer()
        _ = buffer.append(Data("fatal error: no config".utf8))     // a crash, no newline
        buffer.finish()
        #expect(buffer.tailLines() == ["fatal error: no config"])
    }
}
