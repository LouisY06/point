import CoreLocation
import Foundation

/// Picks a destination without a chooser. A chain or generic name ("McDonald's", "a coffee
/// shop") goes to the closest result; a qualified request ("the McDonald's on Mass Ave",
/// "77 Mass Ave") trusts the search ranking, which already applied the qualifier. The chooser
/// only appears when the search returns nothing.
public enum DestinationResolver {
    public enum Decision {
        case go(PlaceCandidate)
        case choose([PlaceCandidate])
    }

    public static func resolve(request text: String, candidates: [PlaceCandidate],
                               from origin: CLLocationCoordinate2D) -> Decision {
        guard let first = candidates.first else { return .choose([]) }
        guard candidates.count > 1 else { return .go(first) }
        let query = VoiceDestination.destinationQuery(from: text)
        func distance(_ place: PlaceCandidate) -> Double { RouteGeometry.distanceMeters(origin, place.coordinate) }
        let matching = candidates.filter { matches(name: $0.name, query: query) }
        if wantsNearest(text) {
            return .go((matching.isEmpty ? candidates : matching).min { distance($0) < distance($1) }!)
        }
        if hasQualifier(query) { return .go(first) }
        // Prefer results whose name matches what was asked for; otherwise the closest of whatever came back.
        return .go((matching.isEmpty ? candidates : matching).min { distance($0) < distance($1) }!)
    }

    /// "nearest McDonald's", "closest pharmacy", "a coffee shop near me".
    public static func wantsNearest(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(?:nearest|closest|near me|nearby|close to me)\b"#, options: .regularExpression) != nil
    }

    /// A street number or a "<place> on/in/at/near <somewhere>" phrase narrows the search.
    public static func hasQualifier(_ query: String) -> Bool {
        query.range(of: #"\d"#, options: .regularExpression) != nil
            || query.range(of: #"(?i)\s(?:on|in|at|near|by|next to|across from|beside|behind|opposite|inside|off|downtown)\s+\S"#,
                           options: .regularExpression) != nil
    }

    static func matches(name: String, query: String) -> Bool {
        let name = normalized(name), query = normalized(query)
        guard !name.isEmpty, !query.isEmpty else { return false }
        return name.contains(query) || query.contains(name)
    }

    static func normalized(_ text: String) -> String {
        // "McDonald's" and "McDonalds" must compare equal, so apostrophes vanish rather than split.
        let text = text.lowercased().replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
        let letters = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").filter { !["the", "a", "an"].contains($0) }.joined(separator: " ")
    }
}
