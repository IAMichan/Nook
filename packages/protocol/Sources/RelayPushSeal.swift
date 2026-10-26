import Foundation

// Sealing a relay push (`RelayPush`) with the companion's own sealing (`CompanionSeal`, unchanged): the plaintext is
// the JSON of `RelayPushContent`, the key the push key derived from the pairing key, the direction Mac → phone.

extension RelayPush {
    /// On the Mac: the envelope for one phone.
    static func seal(_ content: RelayPushContent, pairingKey: Data, deviceID: String) throws -> Data {
        try CompanionSeal.seal(JSONEncoder().encode(content), pairingKey: pushKey(pairingKey: pairingKey), deviceID: deviceID,
                               direction: .response)
    }

    /// On the phone (the Notification Service Extension), with the push key it keeps.
    static func open(_ envelope: Data, pushKey: Data) throws -> RelayPushContent {
        let plain = try CompanionSeal.open(envelope, pairingKey: pushKey, direction: .response)
        return try JSONDecoder().decode(RelayPushContent.self, from: plain)
    }
}
