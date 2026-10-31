import Foundation

/// A local default, not an assertion about the region of a COROS account.
/// An existing grant always stays bound to its original regional issuer.
public struct AutomaticConnectionConfiguration: Equatable, Sendable {
    public let region: COROSRegion
    public let timeZoneIdentifier: String

    public init(timeZone: TimeZone = .autoupdatingCurrent, authenticatedRegion: COROSRegion? = nil) {
        timeZoneIdentifier = timeZone.identifier
        region = authenticatedRegion ?? Self.inferredRegion(for: timeZone.identifier)
    }

    private static func inferredRegion(for identifier: String) -> COROSRegion {
        let chinaZones: Set<String> = [
            "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Chungking",
            "Asia/Harbin", "PRC"
        ]
        let europeanAtlanticZones: Set<String> = [
            "Atlantic/Azores", "Atlantic/Canary", "Atlantic/Faroe", "Atlantic/Faeroe",
            "Atlantic/Madeira", "Atlantic/Reykjavik", "Iceland"
        ]
        if chinaZones.contains(identifier) { return .china }
        if identifier.hasPrefix("Europe/") || europeanAtlanticZones.contains(identifier) { return .europe }
        return .unitedStates
    }
}
