import SwiftUI
import AppKit
import AVFoundation
import Combine
import Contacts
import MapKit
import UniformTypeIdentifiers

/// What a chat's answer field holds besides text, as a chat app's composer does: files waiting to go (photos, videos,
/// GIFs, stickers, documents, a recorded voice message) and the panel open above the field to make a poll, pick a place,
/// pick a contact or a sticker. `ChatsDetail` owns one per open chat and sends what it makes; nothing goes without your
/// own click.
@MainActor
final class ChatComposerModel: ObservableObject {
    enum Panel: Equatable {
        case poll, place, contact, stickers
    }

    /// Files waiting to go, in the order they were added.
    @Published var files: [ChatAttachment] = []
    @Published var panel: Panel?
    /// Why the last file could not be added (too large, not a file).
    @Published var problem: String?

    @Published var poll = ChatPollDraft()
    @Published var placeQuery = ""
    @Published var places: [ChatPlace] = []
    @Published var lookingUp = false
    @Published var contactQuery = ""
    @Published var contacts: [ChatContactCard] = []
    @Published var contactsDenied = false

    let recorder = ChatVoiceRecorder()
    private var bag = Set<AnyCancellable>()

    init() {
        // The field turns into the recording bar and back as the recorder starts and stops.
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// At most this many files wait at once, as in WhatsApp's own picker.
    static let maxFiles = 10

    var hasFiles: Bool { !files.isEmpty }

    /// Adds files chosen, dropped or pasted: each as what it looks like (or as `kind`), the oldest first.
    func add(_ urls: [URL], as kind: ChatMedia.Kind? = nil) {
        problem = nil
        for url in urls {
            guard files.count < Self.maxFiles else { problem = tr("chat.compose.tooMany", Self.maxFiles); break }
            guard let file = ChatAttachment(url: url, as: kind) else { problem = tr("chat.compose.notAFile", url.lastPathComponent); continue }
            guard !file.tooLarge else { problem = tr("chat.compose.tooLarge", file.name); continue }
            files.append(file)
        }
        if !files.isEmpty, panel != .stickers { panel = nil }
    }

    /// A picture without a file of its own (a screenshot on the pasteboard, a picture dragged from a browser).
    func add(_ image: NSImage) {
        do {
            add([try ChatSendPrep.save(image)], as: .photo)
        } catch {
            problem = error.localizedDescription
        }
    }

    func remove(_ id: String) {
        files.removeAll { $0.id == id }
    }

    /// One waiting file goes as another kind (a picture as a sticker, a video as a GIF, anything as a document).
    func change(_ id: String, to kind: ChatMedia.Kind) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index] = files[index].sent(as: kind)
    }

    func open(_ panel: Panel) {
        problem = nil
        self.panel = self.panel == panel ? nil : panel
        if panel == .poll, poll.options.isEmpty { poll = ChatPollDraft() }
    }

    func closePanel() {
        panel = nil
    }

    /// After sending: the files and the form that went are gone; a poll's form starts empty again.
    func sent(_ outgoing: ChatOutgoing) {
        switch outgoing {
        case .file(let file): files.removeAll { $0.id == file.id }
        case .poll: poll = ChatPollDraft(); panel = nil
        case .location: placeQuery = ""; places = []; panel = nil
        case .contact: contactQuery = ""; panel = nil
        }
    }

    /// The chat changed: nothing waiting for the old one goes to the new one.
    func reset() {
        files = []
        panel = nil
        problem = nil
        poll = ChatPollDraft()
        placeQuery = ""
        places = []
        contactQuery = ""
        recorder.cancel()
    }

    // MARK: Files from elsewhere

    /// Files and pictures dropped on the chat. True when there was one to take.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in self?.add([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                took = true
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in self?.add(image) }
                }
            }
        }
        return took
    }

    /// Cmd-V with files or a picture on the pasteboard (and no text, which the field pastes itself). True when taken.
    func paste() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
            return true
        }
        guard board.string(forType: .string) == nil, let image = NSImage(pasteboard: board) else { return false }
        add(image)
        return true
    }

    /// Whether the pasteboard holds a picture to send, for "Paste picture" in the "+" menu.
    var canPastePicture: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Picks files in the Mac's own panel, opened in front of the notch.
    func choose(_ kind: ChatMedia.Kind?, types: [UTType]) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = kind != .sticker
        if !types.isEmpty { picker.allowedContentTypes = types }
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK else { return }
        add(picker.urls, as: kind)
    }

    // MARK: Places

    /// Coordinates or a map link are taken as they are; anything else is looked up in Apple Maps (a café, an address).
    func lookUpPlace() async {
        let query = placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let point = ChatPlace.coordinates(in: query) {
            places = [ChatPlace(latitude: point.latitude, longitude: point.longitude)]
            return
        }
        lookingUp = true
        defer { lookingUp = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let response = try? await MKLocalSearch(request: request).start() else {
            places = []
            return
        }
        places = response.mapItems.prefix(6).compactMap { item in
            let coordinate = item.placemark.coordinate
            let place = ChatPlace(latitude: coordinate.latitude, longitude: coordinate.longitude, name: item.name ?? "",
                                  address: item.placemark.title ?? "")
            return place.isValid ? place : nil
        }
    }

    // MARK: Contacts

    /// Your contacts with a phone number whose name or number holds what is typed, each number its own card. Asks for
    /// Contacts once, when you open this panel.
    func lookUpContacts() async {
        if !(await ChatContactsAccess.granted()) {
            contactsDenied = true
            contacts = []
            return
        }
        contactsDenied = false
        let query = Research.fold(contactQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        var cards: [ChatContactCard] = []
        for entry in await ContactDirectory.entries() {
            let phones = entry.handles.filter { !$0.contains("@") && $0.filter(\.isNumber).count >= 6 }
            guard !phones.isEmpty else { continue }
            let name = Research.fold(entry.name)
            for phone in phones where query.isEmpty || name.contains(query) || phone.filter(\.isNumber).contains(query) {
                cards.append(ChatContactCard(name: entry.name, phone: phone))
            }
            if cards.count >= 40 { break }
        }
        contacts = cards.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Contacts may be read for the contact panel: asked once, the first time it opens.
@MainActor
enum ChatContactsAccess {
    static func granted() async -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return true
        case .notDetermined: return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        default: return false
        }
    }
}

/// A voice message recorded on this Mac's microphone, as AAC in an .m4a file; the gateways turn it into WhatsApp's own
/// voice note format when they send it.
@MainActor
final class ChatVoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var started: Date?
    /// How loud it is now, 0…1, for the bars while recording.
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var meter: Timer?

    /// Starts recording; asks for the microphone the first time. Throws with a sentence you can act on.
    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NookError(tr("chat.compose.voice.noMic")) }
        default: throw NookError(tr("chat.compose.voice.noMic"))
        }
        let url = try ChatSendPrep.destination(name: tr("chat.compose.voice.fileName") + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw NookError(tr("chat.compose.voice.failed")) }
        self.recorder = recorder
        recording = true
        started = Date()
        meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.measure() }
        }
    }

    private func measure() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // -50 dB and below is silence.
        level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
    }

    /// Stops and hands over the recording as a voice message; nil when it was too short to send.
    func finish() -> ChatAttachment? {
        guard let recorder else { return nil }
        let seconds = recorder.currentTime
        recorder.stop()
        clear()
        guard seconds >= 0.6 else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        return ChatAttachment(url: recorder.url, as: .voice, seconds: seconds)
    }

    /// Stops and throws the recording away.
    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        clear()
    }

    private func clear() {
        meter?.invalidate()
        meter = nil
        recorder = nil
        recording = false
        started = nil
        level = 0
    }
}

// MARK: - The buttons beside the field

/// "+" before the field: everything a chat can take besides text, as far as this chat's app can send it.
struct ChatAttachMenu: View {
    @ObservedObject var model: ChatComposerModel
    let sends: Set<ChatOutgoing.Kind>

    var body: some View {
        Menu {
            if sends.contains(.photo) || sends.contains(.video) {
                Button { model.choose(nil, types: [.image, .movie]) } label: {
                    Label(tr("chat.compose.photoVideo"), systemImage: "photo.on.rectangle")
                }
            }
            if sends.contains(.file) {
                Button { model.choose(.file, types: []) } label: { Label(tr("chat.compose.file"), systemImage: "doc") }
            }
            if sends.contains(.gif) {
                Button { model.choose(.gif, types: [.gif, .mpeg4Movie, .quickTimeMovie]) } label: {
                    Label(tr("chat.media.gif"), systemImage: "play.square.stack")
                }
            }
            if sends.contains(.sticker) {
                Button { model.open(.stickers) } label: { Label(tr("chat.compose.stickers"), systemImage: "face.smiling.inverse") }
            }
            if sends.contains(.audio) {
                Button { model.choose(.audio, types: [.audio]) } label: { Label(tr("chat.media.audio"), systemImage: "music.note") }
            }
            if sends.contains(.poll) || sends.contains(.location) || sends.contains(.contact) { Divider() }
            if sends.contains(.poll) {
                Button { model.open(.poll) } label: { Label(tr("chat.compose.poll"), systemImage: "chart.bar.xaxis") }
            }
            if sends.contains(.location) {
                Button { model.open(.place) } label: { Label(tr("chat.compose.place"), systemImage: "mappin.and.ellipse") }
            }
            if sends.contains(.contact) {
                Button {
                    model.open(.contact)
                    Task { await model.lookUpContacts() }
                } label: { Label(tr("chat.compose.contact"), systemImage: "person.crop.circle") }
            }
            if sends.contains(.photo), model.canPastePicture {
                Divider()
                Button { _ = model.paste() } label: { Label(tr("chat.compose.pastePicture"), systemImage: "doc.on.clipboard") }
            }
        } label: {
            Image(systemName: "plus")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .composerMenu()
        .help(tr("chat.compose.attach"))
        .accessibilityLabel(tr("chat.compose.attach"))
    }
}

/// The smiley before the field: every emoji, put where you type.
struct ChatEmojiButton: View {
    @Binding var text: String
    @State private var picking = false

    var body: some View {
        ToolbarIconButton("face.smiling", tr("chat.compose.emoji"), height: 26, width: 26) { picking = true }
            .popover(isPresented: $picking, arrowEdge: .top) {
                EmojiBrowser { emoji in
                    text += emoji
                }
            }
    }
}

/// The microphone in place of send while nothing is typed, as in WhatsApp: a click starts a voice message.
struct ChatMicButton: View {
    @ObservedObject var recorder: ChatVoiceRecorder
    let failed: (Error) -> Void

    var body: some View {
        NookIconButton(systemName: "mic.fill", label: tr("chat.compose.voice"), filled: true, size: 28) {
            Task { @MainActor in
                do { try await recorder.start() } catch { failed(error) }
            }
        }
    }
}

/// Stands in for the field while a voice message records: throw it away, how long it is and how loud, and send.
struct ChatRecordingBar: View {
    @ObservedObject var recorder: ChatVoiceRecorder
    let send: (ChatAttachment) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            ToolbarIconButton("trash", tr("chat.compose.voice.discard"), height: 28, width: 28) { recorder.cancel() }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: NookTheme.Spacing.sm) {
                    Circle()
                        .fill(NookTheme.coral)
                        .frame(width: 8, height: 8)
                        .opacity(reduceMotion ? 1 : 0.5 + 0.5 * recorder.level)
                    Text(clock(context.date))
                        .font(NookTheme.TextStyle.label.monospacedDigit())
                        .foregroundStyle(NookTheme.paper)
                }
            }
            LevelBars(level: recorder.level)
                .frame(maxWidth: .infinity, alignment: .leading)
            NookIconButton(systemName: "arrow.up", label: tr("chats.send"), filled: true, size: 28) {
                if let voice = recorder.finish() { send(voice) }
            }
        }
        .padding(.leading, NookTheme.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("chat.compose.voice.recording"))
    }

    private func clock(_ now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(recorder.started ?? now))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// How loud the voice is: a row of bars that rise with it.
private struct LevelBars: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<18, id: \.self) { index in
                let wave = 0.35 + 0.65 * abs(sin(Double(index) * 1.7))
                Capsule()
                    .fill(NookTheme.textSecondary)
                    .frame(width: 3, height: 4 + 14 * CGFloat(level * wave))
            }
        }
        .frame(height: 18)
        .animation(NookTheme.hover, value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - Above the field

/// A sticker or GIF the sticker panel offers: from this chat, or one you sent before.
struct ChatShelfItem: Equatable {
    var url: URL
    var gif: Bool
}

/// What waits above the field: the files about to go, and the panel that is open (a poll, a place, a contact, a
/// sticker). `send` sends one thing at once (a poll, a place, a contact, a sticker); the files go with the send button.
struct ChatComposerPanels: View {
    @ObservedObject var model: ChatComposerModel
    let sends: Set<ChatOutgoing.Kind>
    /// Stickers and GIFs from this chat, newest first, to send again.
    let chatStickers: [ChatShelfItem]
    let send: (ChatOutgoing) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let problem = model.problem {
                Text(problem)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .lineLimit(2)
                    .padding(.horizontal, NookTheme.Spacing.xs)
            }
            switch model.panel {
            case .poll: ChatPollForm(model: model, send: send)
            case .place: ChatPlaceForm(model: model, send: send)
            case .contact: ChatContactForm(model: model, send: send)
            case .stickers: ChatStickerShelf(model: model, chatStickers: chatStickers, sends: sends, send: send)
            case nil: EmptyView()
            }
            if model.hasFiles {
                ChatAttachmentTray(model: model, sends: sends)
            }
        }
        .animation(NookTheme.reveal, value: model.panel)
        .animation(NookTheme.reveal, value: model.files)
    }
}

/// The files about to go, side by side: a picture of each, its name and size, what it goes as, and a cross.
private struct ChatAttachmentTray: View {
    @ObservedObject var model: ChatComposerModel
    let sends: Set<ChatOutgoing.Kind>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ForEach(model.files) { file in
                    ChatAttachmentChip(file: file, kinds: file.alternatives.filter { sends.contains(ChatOutgoing.Kind($0)) },
                                       change: { model.change(file.id, to: $0) }, remove: { model.remove(file.id) })
                }
            }
            .padding(NookTheme.Spacing.xs)
        }
        .panelCard()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct ChatAttachmentChip: View {
    let file: ChatAttachment
    let kinds: [ChatMedia.Kind]
    let change: (ChatMedia.Kind) -> Void
    let remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            preview
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(file.name)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                HStack(spacing: NookTheme.Spacing.xs) {
                    kindMenu
                    Text(ChatAttachment.size(file.bytes))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            ToolbarIconButton("xmark", tr("chat.compose.remove"), height: 22, width: 22, remove)
        }
        .padding(NookTheme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.smoke))
        .task(id: file.path) { thumbnail = await ChatAttachmentThumbnail.make(file) }
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFill()
        } else {
            Image(systemName: ChatAttachmentThumbnail.symbol(file.kind))
                .font(NookTheme.font(16, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NookTheme.graphite)
        }
    }

    /// What it goes as: a click offers the other kinds this file can go as.
    @ViewBuilder private var kindMenu: some View {
        if kinds.count > 1 {
            Menu {
                ForEach(kinds, id: \.self) { kind in
                    Button { change(kind) } label: {
                        if kind == file.kind { Label(Self.title(kind), systemImage: "checkmark") } else { Text(Self.title(kind)) }
                    }
                }
            } label: {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Text(Self.title(file.kind))
                    Image(systemName: "chevron.down").font(NookTheme.font(8, .bold))
                }
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textSecondary)
            }
            .composerMenu()
            .help(tr("chat.compose.sendAs"))
        } else {
            Text(Self.title(file.kind))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textSecondary)
        }
    }

    static func title(_ kind: ChatMedia.Kind) -> String {
        switch kind {
        case .photo: return tr("whatsapp.file.photo")
        case .video: return tr("whatsapp.file.video")
        case .gif: return tr("chat.media.gif")
        case .sticker: return tr("chat.media.sticker")
        case .audio: return tr("chat.media.audio")
        case .voice: return tr("whatsapp.file.voice")
        case .file: return tr("whatsapp.file.document")
        }
    }
}

/// A small picture of a file about to go: the photo, a video's first frame, a document's first page.
@MainActor
enum ChatAttachmentThumbnail {
    static func make(_ file: ChatAttachment) async -> NSImage? {
        switch file.kind {
        case .photo, .sticker:
            return ChatMediaImages.image(file.url, side: 120)
        case .gif where ChatMediaImages.isPicture(file.url):
            return ChatMediaImages.image(file.url, side: 120)
        case .video, .gif:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            guard let frame = try? await generator.image(at: .zero).image else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        case .file:
            return NSWorkspace.shared.icon(forFile: file.path)
        default:
            return nil
        }
    }

    static func symbol(_ kind: ChatMedia.Kind) -> String {
        switch kind {
        case .photo: return "photo"
        case .video: return "video"
        case .gif: return "play.square.stack"
        case .sticker: return "face.smiling"
        case .audio: return "music.note"
        case .voice: return "waveform"
        case .file: return "doc"
        }
    }
}

/// The frame of every panel above the field: what it is, a cross to close it, and its content.
private struct ChatComposePanel<Content: View>: View {
    let symbol: String
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: symbol)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.sm)
                ToolbarIconButton("xmark", tr("chat.compose.close"), close)
            }
            content
        }
        .padding(NookTheme.Spacing.md)
        .panelCard()
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .contain)
    }
}

/// A one-line field inside a panel, as the draft panel's own.
private struct ChatPanelField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding? = nil
    var submit: () -> Void = {}

    var body: some View {
        Group {
            if let focused {
                field.focused(focused)
            } else {
                field
            }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .frame(minHeight: 28)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control, style: .continuous)
    }

    private var field: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary))
            .textFieldStyle(.plain)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.paper)
            .onSubmit(submit)
    }
}

// MARK: Poll

private struct ChatPollForm: View {
    @ObservedObject var model: ChatComposerModel
    let send: (ChatOutgoing) -> Void
    @FocusState private var questionFocused: Bool

    var body: some View {
        ChatComposePanel(symbol: "chart.bar.xaxis", title: tr("chat.compose.poll"), close: { model.closePanel() }) {
            ChatPanelField(prompt: tr("chat.compose.poll.question"), text: $model.poll.question, focused: $questionFocused)
            ForEach(model.poll.options.indices, id: \.self) { index in
                HStack(spacing: NookTheme.Spacing.xs) {
                    ChatPanelField(prompt: tr("chat.compose.poll.option", index + 1), text: option(index))
                    if model.poll.options.count > ChatPollDraft.minOptions {
                        ToolbarIconButton("minus.circle", tr("chat.compose.remove")) { model.poll.options.remove(at: index) }
                    }
                }
            }
            Toggle(tr("chat.compose.poll.multiple"), isOn: $model.poll.multiple)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
            HStack(spacing: NookTheme.Spacing.sm) {
                if let problem = model.poll.problem, !model.poll.cleanQuestion.isEmpty {
                    Text(tr(problem, ChatPollDraft.maxOptions))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                SmallPrimaryButton(title: tr("chats.send"), systemName: "arrow.up") { send(.poll(model.poll)) }
                    .disabled(model.poll.problem != nil)
            }
        }
        .onAppear { questionFocused = true }
    }

    /// An option's field: typing in the last one adds an empty one under it, up to twelve.
    private func option(_ index: Int) -> Binding<String> {
        Binding(get: { model.poll.options.indices.contains(index) ? model.poll.options[index] : "" },
                set: { value in
                    guard model.poll.options.indices.contains(index) else { return }
                    model.poll.options[index] = value
                    model.poll = model.poll.withSpareOption()
                })
    }
}

// MARK: Place

private struct ChatPlaceForm: View {
    @ObservedObject var model: ChatComposerModel
    let send: (ChatOutgoing) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ChatComposePanel(symbol: "mappin.and.ellipse", title: tr("chat.compose.place"), close: { model.closePanel() }) {
            HStack(spacing: NookTheme.Spacing.xs) {
                ChatPanelField(prompt: tr("chat.compose.place.prompt"), text: $model.placeQuery, focused: $focused) { lookUp() }
                if model.lookingUp {
                    ProgressView().controlSize(.small)
                } else {
                    ToolbarIconButton("return", tr("chat.compose.place.search")) { lookUp() }
                }
            }
            if model.places.isEmpty {
                Text(tr("chat.compose.place.hint"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.places.enumerated()), id: \.offset) { index, place in
                        if index > 0 { NookRowSeparator() }
                        ChatPickRow(symbol: "mappin.circle.fill", title: place.title,
                                    detail: place.address.isEmpty || place.address == place.title ? place.coordinates : place.address) {
                            send(.location(place))
                        }
                    }
                }
            }
        }
        .onAppear { focused = true }
    }

    private func lookUp() {
        Task { await model.lookUpPlace() }
    }
}

// MARK: Contact

private struct ChatContactForm: View {
    @ObservedObject var model: ChatComposerModel
    let send: (ChatOutgoing) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ChatComposePanel(symbol: "person.crop.circle", title: tr("chat.compose.contact"), close: { model.closePanel() }) {
            NookSearchField(prompt: tr("chat.compose.contact.search"), text: $model.contactQuery, style: .inline, focus: $focused)
                .onChange(of: model.contactQuery) { _, _ in Task { await model.lookUpContacts() } }
            if model.contactsDenied {
                Text(tr("chat.compose.contact.denied"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.contacts.isEmpty {
                ListEmptyNote(tr("chat.compose.contact.none"))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.contacts.enumerated()), id: \.offset) { index, card in
                            if index > 0 { NookRowSeparator() }
                            ChatPickRow(symbol: "person.crop.circle.fill", title: card.name, detail: card.phone) {
                                send(.contact(card))
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .onAppear { focused = true }
    }
}

/// A row to pick in a panel (a place, a contact): a click sends it.
private struct ChatPickRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(systemName: symbol)
                    .font(NookTheme.font(16))
                    .foregroundStyle(NookTheme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(detail)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                Image(systemName: "arrow.up.circle.fill")
                    .font(NookTheme.font(15))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, NookTheme.Spacing.sm)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(NookTheme.rowFill(selected: false, hovering: hovering, rest: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("chat.compose.sendThis", title))
        .accessibilityLabel(tr("chat.compose.sendThis", title))
    }
}

// MARK: Stickers and GIFs

/// Stickers and GIFs to send with one click: the ones in this chat and the ones you sent before, and a picture or GIF
/// of your own from a file.
private struct ChatStickerShelf: View {
    @ObservedObject var model: ChatComposerModel
    let chatStickers: [ChatShelfItem]
    let sends: Set<ChatOutgoing.Kind>
    let send: (ChatOutgoing) -> Void

    private static let cell: CGFloat = 64
    private let columns = [GridItem(.adaptive(minimum: ChatStickerShelf.cell, maximum: ChatStickerShelf.cell), spacing: NookTheme.Spacing.sm)]

    /// The ones you sent first, then this chat's; a GIF only where this app can send one.
    private var items: [ChatShelfItem] {
        var seen = Set<String>()
        let sent = ChatStickers.recent().map { ChatShelfItem(url: $0, gif: ChatStickers.isGIF($0)) }
        return (sent + chatStickers).filter { (!$0.gif || sends.contains(.gif)) && seen.insert($0.url.path).inserted }
    }

    var body: some View {
        ChatComposePanel(symbol: "face.smiling.inverse", title: tr("chat.compose.stickers"), close: { model.closePanel() }) {
            if items.isEmpty {
                ListEmptyNote(tr("chat.compose.stickers.none"))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        ForEach(items, id: \.url.path) { item in
                            ChatStickerCell(url: item.url, side: Self.cell) { pick(item) }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if sends.contains(.sticker) {
                    SmallGhostButton(title: tr("chat.compose.stickers.fromFile")) {
                        model.choose(.sticker, types: [.image])
                    }
                }
                if sends.contains(.gif) {
                    SmallGhostButton(title: tr("chat.compose.stickers.gifFromFile")) {
                        model.choose(.gif, types: [.gif, .mpeg4Movie, .quickTimeMovie])
                    }
                }
            }
        }
    }

    /// One click sends it: a sticker as a sticker, a GIF as a GIF.
    private func pick(_ item: ChatShelfItem) {
        guard let file = ChatAttachment(url: item.url, as: item.gif ? .gif : .sticker) else { return }
        send(.file(file))
    }
}

private struct ChatStickerCell: View {
    let url: URL
    let side: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = ChatMediaImages.image(url, side: side * 2) {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "play.square.stack")
                        .font(NookTheme.font(18))
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .fill(hovering ? NookTheme.smoke : NookTheme.graphite))
            .hoverLift(hovering, scale: 1.04)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("chat.compose.sendSticker"))
        .accessibilityLabel(tr("chat.compose.sendSticker"))
    }
}
