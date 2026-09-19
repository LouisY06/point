import Foundation

/// Lets an utterance pick the travel mode for one request without changing the saved default.
public enum TransitPhrases {
    public static func impliesTransit(_ text: String) -> Bool {
        let vehicle = #"(?:t|train|subway|metro|bus|tram|trolley|mbta|transit|public\s+(?:transit|transportation|transport))"#
        let patterns = [
            // "take the T", "using public transportation", "get on a bus", "by train", "hop on the Red Line"
            #"(?i)\b(?:take|taking|ride|riding|catch|use|using|by|on|via|with|through|hop\s+on|get\s+on|board)\s+(?:the\s+|a\s+)?"# + vehicle + #"\b"#,
            // These words are almost never part of a place name.
            #"(?i)\b(?:public\s+(?:transit|transportation|transport)|mbta|transit)\b"#,
            #"(?i)\b(?:red|orange|blue|green|silver)\s+line\b"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    public static func impliesWalking(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(?:walk|walking|on\s+foot|by\s+foot)\b"#, options: .regularExpression) != nil
    }
}
