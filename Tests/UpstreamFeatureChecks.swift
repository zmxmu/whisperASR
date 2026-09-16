// swiftc Sources/Models.swift Sources/SubtitleFormatter.swift Tests/UpstreamFeatureChecks.swift -o /tmp/UpstreamFeatureChecks
import Foundation

@main
struct UpstreamFeatureChecks {
    static func main() throws {
        // Existing persisted transcripts have no speaker fields.
        let oldJSON = Data(#"{"start":1.25,"end":2.5,"text":"你好"}"#.utf8)
        var segment = try JSONDecoder().decode(TranscriptionSegment.self, from: oldJSON)
        precondition(segment.speakerDisplayName == nil)
        segment.speakerName = "Alice"
        segment.speakerID = UUID()
        let restored = try JSONDecoder().decode(TranscriptionSegment.self,
            from: JSONEncoder().encode(segment))
        precondition(restored == segment)
        precondition(SubtitleFormatter.make(.srt, segments: [segment]) ==
            "1\n00:00:01,250 --> 00:00:02,500\nAlice: 你好\n\n")
        precondition(SubtitleFormatter.make(.vtt, segments: [segment]).hasPrefix("WEBVTT\n\n00:00:01.250"))
        precondition(SubtitleFormatter.make(.sub, segments: [segment], title: "Meeting")
            .contains("00:00:01.25,00:00:02.50\nAlice: 你好"))
        precondition(SubtitleFormatter.srtTime(59.9996) == "00:01:00,000")
        print("PASS: legacy transcript compatibility, speaker persistence, SRT/VTT/SUB exports")
    }
}
