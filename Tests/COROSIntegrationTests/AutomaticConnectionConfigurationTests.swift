import Foundation
import Testing
@testable import COROSIntegration

struct AutomaticConnectionConfigurationTests {
    @Test func infersRegionFromZoneIdentityRatherThanUTCOffset() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let singapore = try #require(TimeZone(identifier: "Asia/Singapore"))
        #expect(AutomaticConnectionConfiguration(timeZone: shanghai).region == .china)
        #expect(AutomaticConnectionConfiguration(timeZone: singapore).region == .unitedStates)
    }

    @Test func handlesEuropeanAndOtherZones() throws {
        for identifier in ["Europe/Paris", "Europe/London", "Atlantic/Azores"] {
            let zone = try #require(TimeZone(identifier: identifier))
            #expect(AutomaticConnectionConfiguration(timeZone: zone).region == .europe)
        }
        for identifier in ["America/New_York", "Asia/Tokyo", "Australia/Sydney", "GMT"] {
            let zone = try #require(TimeZone(identifier: identifier))
            #expect(AutomaticConnectionConfiguration(timeZone: zone).region == .unitedStates)
        }
    }

    @Test func travelUpdatesCalendarZoneWithoutMovingAnAuthorizedGrant() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let configuration = AutomaticConnectionConfiguration(timeZone: zone, authenticatedRegion: .china)
        #expect(configuration.region == .china)
        #expect(configuration.timeZoneIdentifier == "America/Los_Angeles")
    }
}
