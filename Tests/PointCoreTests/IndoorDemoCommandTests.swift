import Testing
@testable import PointCore

struct IndoorDemoCommandTests {
    @Test(arguments: [
        "Can you go into demo mode?", "go into demo mode", "Demo mode",
        "Please enter demo mode", "Could we start indoor demo mode, please?",
        "Hey Point, can you switch to demo mode?", "Let's go into demo mode",
        "I'd like to enter the indoor demo", "Set up virtual beacons",
        "Can you please set up some indoor beacons?", "Start the beacon demo",
        "Test beacons", "Activate demo mode now", "  ENTER\nDEMO MODE!  "
    ])
    func opensIndoorDemoWithoutDestinationResolution(_ text: String) {
        #expect(IndoorDemoCommand.matches(text))
    }

    @Test(arguments: [
        "", "Go to Demo Cafe", "Take me to Demo Mode on Main Street",
        "Don't go into demo mode", "Can you not enter demo mode?",
        "Exit demo mode", "What is demo mode?", "Is demo mode working?",
        "Start demo mode after going to the station", "Take the bus to Beacon Street",
        "Walk to Beacon Hill", "Yes", "No", "Demo Store", "Go to Cambridge"
    ])
    func doesNotStealDestinationsOrNegatedRequests(_ text: String) {
        #expect(!IndoorDemoCommand.matches(text))
    }
}
