import Foundation

public enum ConversationCommand: Equatable {
    case start, pause, resume, repeatReply, endConversation, cancelRoute, atStop, boarded, notBoarded, alighted, replan

    public static func parse(_ text: String) -> Self? {
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        switch words {
        case "start", "start route", "start walking", "start navigation", "let s go", "go ahead": return .start
        case "pause", "pause route", "pause navigation": return .pause
        case "resume", "resume route", "resume navigation", "continue navigation": return .resume
        case "repeat", "repeat that", "say that again", "what did you say": return .repeatReply
        case "stop listening", "end conversation", "goodbye", "quiet": return .endConversation
        case "cancel", "cancel route", "cancel navigation", "never mind", "nevermind": return .cancelRoute
        case "i m at the stop", "i am at the stop", "at the stop": return .atStop
        case "i m on board", "i am on board", "i ve boarded", "on board": return .boarded
        case "not on board", "i m not on board", "i missed it": return .notBoarded
        case "i m off", "i am off", "i got off", "i ve got off": return .alighted
        case "replan", "replan from here": return .replan
        default: return nil
        }
    }
}

/// Echo-cancelled audio must contain sustained activity AND recognized words before interrupting.
/// This is a conservative local gate, not a guarantee of acoustic separation on every device.
public struct SpeechInterruptionDetector {
    private var voiceSince: TimeInterval?
    private var lastVoice: TimeInterval?
    private var floor = -65.0
    public init() {}
    public mutating func observeAudio(levelDB: Double, at time: TimeInterval) {
        guard levelDB.isFinite, time.isFinite else { return }
        if levelDB > min(-30, max(-52, floor + 12)) {
            if lastVoice.map({ time - $0 > 0.2 }) ?? true { voiceSince = time }
            lastVoice = time
        } else {
            floor += (max(-80, levelDB) - floor) * 0.04
        }
    }
    public func shouldInterrupt(transcript: String, assistantText: String, at time: TimeInterval) -> Bool {
        guard let voiceSince, let lastVoice, (0...0.4).contains(time - lastVoice), lastVoice - voiceSince >= 0.18 else { return false }
        func normalized(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let input = normalized(transcript), output = normalized(assistantText)
        guard !input.isEmpty else { return false }
        // Never interpret a repeated phrase from our own response as a new destination.
        if output.contains(input) { return false }
        return true
    }
}
