import Foundation

// What Nook sends to the WhatsApp gateways (and Beeper) for a file, a poll, a place or a contact: the route and its
// fields, per gateway. Foundation only and without the network, so every request can be tested anywhere; the providers
// in WhatsAppProvider.swift send them. Field names follow each gateway's docs:
//   GOWA   — docs/openapi.yaml (/send/image, /send/video, /send/audio, /send/file, /send/sticker, /send/poll, …)
//   OpenWA — docs/06-api-specification.md (/messages/send-image … /messages/send-poll; unknown fields are refused)
//   Beeper — the Desktop API (/v1/assets/upload/base64, then /v1/chats/{id}/messages with the upload's id)

/// The file part of a multipart request: its form field, the file, and the name and type it goes with.
struct WAUpload: Equatable, Sendable {
    var field: String
    var path: String
    var name: String
    var mimeType: String
}

/// One request for something sent: where it goes, and its JSON, or its form fields and file.
struct WASendRequest: Sendable {
    var path: String
    var json: [String: any Sendable]? = nil
    var fields: [WAFormField] = []
    var upload: WAUpload? = nil
}

struct WAFormField: Equatable, Sendable {
    var name: String
    var value: String
}

enum WASend {
    // MARK: GOWA

    /// GOWA takes a file as multipart form data and everything else as JSON; `phone` is the chat's JID.
    static func gowa(_ outgoing: ChatOutgoing, chat: String, replyTo: String?) -> WASendRequest {
        switch outgoing {
        case .file(let file):
            var fields = [WAFormField(name: "phone", value: chat)]
            let caption = file.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let route: (path: String, field: String, caption: Bool, reply: Bool)
            switch file.kind {
            case .photo: route = ("/send/image", "image", true, true)
            case .video, .gif: route = ("/send/video", "video", true, true)
            case .sticker: route = ("/send/sticker", "sticker", false, false)
            case .audio, .voice: route = ("/send/audio", "audio", false, true)
            case .file: route = ("/send/file", "file", true, true)
            }
            if route.caption, !caption.isEmpty { fields.append(WAFormField(name: "caption", value: caption)) }
            if route.reply, let replyTo { fields.append(WAFormField(name: "reply_message_id", value: replyTo)) }
            if file.kind == .gif { fields.append(WAFormField(name: "gif_playback", value: "true")) }
            if file.kind == .voice { fields.append(WAFormField(name: "ptt", value: "true")) }
            return WASendRequest(path: route.path, fields: fields,
                                 upload: WAUpload(field: route.field, path: file.path, name: file.name, mimeType: file.mimeType))
        case .poll(let poll):
            let options = poll.cleanOptions
            return WASendRequest(path: "/send/poll", json: [
                "phone": chat, "question": poll.cleanQuestion, "options": options, "max_answer": poll.multiple ? options.count : 1,
            ])
        case .location(let place):
            // GOWA takes the coordinates as text.
            return WASendRequest(path: "/send/location", json: [
                "phone": chat, "latitude": String(place.latitude), "longitude": String(place.longitude),
            ])
        case .contact(let card):
            return WASendRequest(path: "/send/contact", json: [
                "phone": chat, "contact_name": card.name.trimmingCharacters(in: .whitespacesAndNewlines),
                "contact_phone": card.cleanPhone,
            ])
        }
    }

    // MARK: OpenWA

    /// OpenWA takes everything as JSON, a file as base64 (`data`, read by the caller). `chatId` is OpenWA's own form of
    /// the JID. A GIF goes as a video: OpenWA has no looping flag.
    static func openwa(_ outgoing: ChatOutgoing, chatId: String, replyTo: String?, data: Data? = nil) -> WASendRequest {
        var body: [String: any Sendable] = ["chatId": chatId]
        if let replyTo { body["quotedMessageId"] = replyTo }
        switch outgoing {
        case .file(let file):
            body["base64"] = (data ?? Data()).base64EncodedString()
            body["mimetype"] = file.mimeType
            body["filename"] = file.name
            let caption = file.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let path: String
            switch file.kind {
            case .photo: path = "/messages/send-image"
            case .video, .gif: path = "/messages/send-video"
            case .sticker: path = "/messages/send-sticker"
            case .audio, .voice: path = "/messages/send-audio"
            case .file: path = "/messages/send-document"
            }
            // Audio keeps no caption, a sticker has none.
            if !caption.isEmpty, ![.sticker, .audio, .voice].contains(file.kind) { body["caption"] = String(caption.prefix(1024)) }
            if file.kind == .voice { body["ptt"] = true }
            return WASendRequest(path: path, json: body)
        case .poll(let poll):
            body["name"] = poll.cleanQuestion
            body["options"] = poll.cleanOptions
            body["allowMultipleAnswers"] = poll.multiple
            return WASendRequest(path: "/messages/send-poll", json: body)
        case .location(let place):
            body["latitude"] = place.latitude
            body["longitude"] = place.longitude
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = place.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { body["description"] = String(name.prefix(1024)) }
            if !address.isEmpty { body["address"] = String(address.prefix(1024)) }
            return WASendRequest(path: "/messages/send-location", json: body)
        case .contact(let card):
            body["contactName"] = String(card.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
            body["contactNumber"] = String(card.cleanPhone.prefix(30))
            return WASendRequest(path: "/messages/send-contact", json: body)
        }
    }

    // MARK: Beeper

    /// Beeper first takes the file (as base64) and answers with an upload id.
    static func beeperUpload(_ file: ChatAttachment, data: Data) -> WASendRequest {
        WASendRequest(path: "/v1/assets/upload/base64", json: [
            "content": data.base64EncodedString(), "fileName": file.name, "mimeType": file.mimeType,
        ])
    }

    /// The upload's id in Beeper's answer.
    static func beeperUploadID(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? String, !error.isEmpty { return nil }
        return (object["uploadID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The message that carries it, in the chat (`path` is the chat's messages route): the upload by its id with what it
    /// is, the caption as its text. A place or a contact goes as text, which every network Beeper bridges can show.
    static func beeperMessage(_ outgoing: ChatOutgoing, path: String, uploadID: String?, replyTo: String?) -> WASendRequest {
        var body: [String: any Sendable] = [:]
        if let replyTo { body["replyToMessageID"] = replyTo }
        if case .file(let file) = outgoing, let uploadID {
            var attachment: [String: any Sendable] = ["uploadID": uploadID, "type": beeperType(file.kind),
                                                      "fileName": file.name, "mimeType": file.mimeType]
            if let seconds = file.seconds { attachment["duration"] = seconds }
            body["attachment"] = attachment
            let caption = file.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { body["text"] = caption }
        } else {
            body["text"] = outgoing.text
        }
        return WASendRequest(path: path, json: body)
    }

    static func beeperType(_ kind: ChatMedia.Kind) -> String {
        switch kind {
        case .photo: return "image"
        case .video: return "video"
        case .gif: return "gif"
        case .sticker: return "sticker"
        case .audio: return "audio"
        case .voice: return "voice-note"
        case .file: return "file"
        }
    }
}

/// A multipart/form-data body: the fields, then the file.
enum WAMultipart {
    static func boundary() -> String { "nook-" + UUID().uuidString }

    static func contentType(boundary: String) -> String { "multipart/form-data; boundary=" + boundary }

    static func body(boundary: String, fields: [WAFormField], upload: WAUpload, data: Data) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for field in fields {
            line("--" + boundary)
            line("Content-Disposition: form-data; name=\"\(quoted(field.name))\"")
            line("")
            line(field.value)
        }
        line("--" + boundary)
        line("Content-Disposition: form-data; name=\"\(quoted(upload.field))\"; filename=\"\(quoted(upload.name))\"")
        line("Content-Type: " + upload.mimeType)
        line("")
        body.append(data)
        line("")
        line("--" + boundary + "--")
        return body
    }

    /// A name inside the header's quotes: no quote, line break or backslash can end it early.
    static func quoted(_ text: String) -> String {
        String(text.map { "\"\\\r\n".contains($0) ? "_" : $0 })
    }
}
