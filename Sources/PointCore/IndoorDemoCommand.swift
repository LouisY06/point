import Foundation

/// App commands are resolved before destination interpretation, GPS checks or map requests.
/// Match the complete request so a place containing "demo" is still a destination.
public enum IndoorDemoCommand {
    public static func matches(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let pattern = #"^(?:(?:hey )?point )?(?:(?:can|could|would) (?:you|we) |(?:i want to|i d like to|let s) )?(?:please )?(?:(?:(?:go|switch) (?:in|into|to) |enter |start |open |enable |turn on |activate )?(?:the )?(?:indoor )?demo(?: mode)?|(?:set up|setup|place|create) (?:some )?(?:virtual|indoor|test) beacons|(?:open |start )?(?:the )?(?:indoor )?beacon (?:demo|test)|test beacons)(?: (?:please|now))?[.!?]*$"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }
}
