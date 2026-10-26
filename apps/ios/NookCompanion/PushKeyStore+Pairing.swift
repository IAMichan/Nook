import Foundation

// The app's side of `PushKeyStore`: it knows the pairings (the extension, which shares PushKeyStore.swift, does not).
extension PushKeyStore {
    /// Keeps the push key of a pairing, so the extension can open what the Mac sends through the relay.
    static func remember(pairingKey: Data) {
        set(RelayPush.pushKey(pairingKey: pairingKey), forDevice: PairedDevice.identifier(forKey: pairingKey))
    }

    static func forget(pairingKey: Data) {
        set(nil, forDevice: PairedDevice.identifier(forKey: pairingKey))
    }

    /// Keeps exactly the push keys of these pairings (one per paired Mac), dropping those of Macs that were removed.
    static func sync(pairingKeys: [Data]) {
        let kept = Set(pairingKeys.map { PairedDevice.identifier(forKey: $0) })
        for device in all().keys where !kept.contains(device) { set(nil, forDevice: device) }
        for key in pairingKeys { remember(pairingKey: key) }
    }
}
