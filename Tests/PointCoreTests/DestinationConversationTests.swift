import CoreLocation
import Foundation
import Testing
@testable import PointCore

struct DestinationConversationTests {
    @Test func intentModelDefaultsToGPT55WithReasoningOff() {
        let defaults = VoiceConfiguration()
        #expect(defaults.intentModel == "gpt-5.5" && defaults.intentReasoning == "none")
        let custom = VoiceConfiguration(fileContents: "OPENAI_INTENT_MODEL=gpt-4.1\nOPENAI_INTENT_REASONING=low")
        #expect(custom.intentModel == "gpt-4.1" && custom.intentReasoning == "low")
        // Only reasoning models take the effort parameter; older models reject it.
        #expect(OpenAIDestinationInterpreter.supportsReasoningEffort("gpt-5.5"))
        #expect(OpenAIDestinationInterpreter.supportsReasoningEffort("o4-mini"))
        #expect(!OpenAIDestinationInterpreter.supportsReasoningEffort("gpt-4.1"))
        #expect(!OpenAIDestinationInterpreter.supportsReasoningEffort("gpt-4o-mini"))
    }

    @Test func intentContextSeparatesCurrentCityFromRequestedCity() throws {
        let context = DestinationContext(requestedCity: "Cambridge", currentCity: "Boston", confirmationPending: true,
                                         destinationName: "Shake Shack")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        #expect(json["currentCity"] as? String == "Boston")
        #expect(json["requestedCity"] as? String == "Cambridge")
        let unknown = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(DestinationContext())) as? [String: Any])
        #expect(unknown["currentCity"] == nil)
    }

    @Test func nearbyShortWalkDoesNotWarnOnNeighborhoodCityMismatch() {
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Back Bay",
                                         duration: 15 * 60, routeDistanceMeters: 900) == nil)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Back Bay",
                                         duration: 30 * 60, routeDistanceMeters: 1_500) == nil)
        // Keep real long-walk review even when coordinates are geographically close.
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Back Bay",
                                         duration: 50 * 60, routeDistanceMeters: 1_400)?.contains("50 minutes") == true)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Cambridge",
                                         duration: 40 * 60, routeDistanceMeters: 3_000) != nil)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Cambridge",
                                         duration: 20 * 60, routeDistanceMeters: .nan) != nil)
    }

    private func destination(city: String? = "Boston") -> PlaceCandidate {
        PlaceCandidate(id: "one", name: "Shake Shack", address: "Full address", coordinate: .init(latitude: 42.36, longitude: -71.06), city: city)
    }

    @Test func localShortWalkDoesNotNeedAnExtraConfirmation() {
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Boston", duration: 20 * 60) == nil)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "boston", duration: 45 * 60) == nil)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Boston, MA", duration: 20 * 60) == nil)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "City of Boston", duration: 20 * 60) == nil)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Dorchester", originCityAliases: ["Boston"], duration: 20 * 60) == nil)
        // A neighbourhood label on the place ("Back Bay") with the destination geocoded to the origin's city.
        #expect(WalkingRouteReview.prompt(destination: destination(city: "Back Bay"), originCity: "Boston", duration: 20 * 60,
                                         destinationCityAliases: ["Boston", "Back Bay"]) == nil)
    }

    @Test func anotherCityTriggersEvenForShortWalks() {
        let question = WalkingRouteReview.prompt(destination: destination(), originCity: "Cambridge", duration: 20 * 60)
        #expect(question == "Shake Shack is in Boston. Are you sure you want to walk there?")
    }

    @Test func longWalkCombinesCityAndTimeInOneQuestion() {
        let question = WalkingRouteReview.prompt(destination: destination(), originCity: "Cambridge", duration: 90 * 60)
        #expect(question == "The walk to Shake Shack in Boston is about 1 hour and 30 minutes, longer than 45 minutes. Are you sure you want to walk there?")
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Boston", duration: 45 * 60 + 1)?.contains("46 minutes") == true)
    }

    @Test func unknownTimeIsNeverInvented() {
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Cambridge", duration: nil)?.contains("minutes") == false)
        #expect(WalkingRouteReview.prompt(destination: destination(), originCity: "Boston", duration: .nan) == nil)
    }
}
