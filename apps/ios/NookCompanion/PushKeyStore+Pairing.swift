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
}
