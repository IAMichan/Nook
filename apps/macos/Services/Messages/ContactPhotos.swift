import AppKit
import Contacts

/// Profile photos for the Chats tab, from the photos in Contacts: matched on a chat's phone number (a WhatsApp chat) or,
/// for a chat collected from a notification, on its name. Read on this Mac only, nothing is fetched from a chat app's
/// servers, and only with access to Contacts; `requestAccess` asks for it when you click the hint in the Chats tab.
@MainActor
final class ContactPhotos: ObservableObject {
    static let shared = ContactPhotos()

    /// Photos per handle key (`AppData.key`: a phone number by its last nine digits, an address in lowercase).
    @Published private(set) var byHandle: [String: NSImage] = [:]
    /// Photos per folded name ("marie dupont"), for chats that only know who by name.
    @Published private(set) var byName: [String: NSImage] = [:]
    @Published private(set) var access = CNContactStore.authorizationStatus(for: .contacts)

    /// Contacts change rarely: read them again after this long.
    private static let maxAge: TimeInterval = 600
    private var loadedAt: Date?
    private var loading = false

    private init() {}

    /// Whether the Chats tab should offer to show photos: Contacts was never asked.
    var canAsk: Bool { access == .notDetermined }

    func photo(handle: String?, name: String) -> NSImage? {
        if let handle, let image = byHandle[AppData.key(handle)] { return image }
        return byName[Self.fold(name)]
    }

    /// Reads the photos when there are none yet or they are old; does nothing without access.
    func refresh() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if access != status { access = status }
        guard access == .authorized, !loading else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.maxAge { return }
        loading = true
        Task {
            // Read off the main thread as plain data; the images are made here, one per contact.
            let found = await Task.detached(priority: .utility) { Self.read() }.value
            var handles: [String: NSImage] = [:]
            var names: [String: NSImage] = [:]
            for photo in found {
                guard let image = NSImage(data: photo.data) else { continue }
                for key in photo.handles where handles[key] == nil { handles[key] = image }
                for key in photo.names where names[key] == nil { names[key] = image }
            }
            byHandle = handles
            byName = names
            loadedAt = Date()
            loading = false
        }
    }

    /// Asks macOS for Contacts (only after your click), then reads the photos.
    func requestAccess() {
        Task {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
            loadedAt = nil
            refresh()
        }
    }

    /// One contact's photo and the keys it is found under.
    private struct Found: Sendable {
        var data: Data
        var handles: [String]
        var names: [String]
    }

    nonisolated private static func read() -> [Found] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        var found: [Found] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            guard contact.imageDataAvailable, let data = contact.thumbnailImageData else { return }
            let handles = (contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String })
                .map(AppData.key).filter { !$0.isEmpty }
            let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let names = [full, contact.nickname, contact.organizationName].filter { !$0.isEmpty }.map(fold)
            found.append(Found(data: data, handles: handles, names: names))
        }
        return found
    }

    nonisolated static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
