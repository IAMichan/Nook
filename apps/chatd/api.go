package main

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/rs/zerolog"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// API is the local HTTP and WebSocket API Nook reads, on 127.0.0.1 only and behind a token. Its routes and JSON follow
// the part of Beeper's Client API that Nook already speaks (BeeperData, ChatLinkData), so Nook needs one client for both.
type API struct {
	token   string
	store   *Store
	nets    []*Network
	byID    map[string]*Network
	logins  *Logins
	live    *Hub
	log     zerolog.Logger
	version string
}

func NewAPI(token string, store *Store, nets []*Network, live *Hub, log zerolog.Logger, version string) *API {
	byID := make(map[string]*Network, len(nets))
	for _, net := range nets {
		byID[net.ID] = net
	}
	return &API{token: token, store: store, nets: nets, byID: byID, logins: NewLogins(), live: live, log: log, version: version}
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/info", a.info)
	mux.HandleFunc("GET /v1/bridges", a.authed(a.bridges))
	mux.HandleFunc("POST /v1/bridges/{bridge}/login-sessions", a.authed(a.startLogin))
	mux.HandleFunc("GET /v1/bridges/{bridge}/login-sessions/{session}", a.authed(a.getLogin))
	mux.HandleFunc("DELETE /v1/bridges/{bridge}/login-sessions/{session}", a.authed(a.cancelLogin))
	mux.HandleFunc("POST /v1/bridges/{bridge}/login-sessions/{session}/steps/{step}", a.authed(a.submitStep))
	mux.HandleFunc("POST /v1/bridges/{bridge}/logins/{login}/remove", a.authed(a.removeLogin))
	mux.HandleFunc("GET /v1/chats", a.authed(a.chats))
	mux.HandleFunc("PATCH /v1/chats/{chat}", a.authed(a.patchChat))
	mux.HandleFunc("POST /v1/chats/{chat}/read", a.authed(a.markRead))
	mux.HandleFunc("POST /v1/chats/{chat}/unread", a.authed(a.markUnread))
	mux.HandleFunc("POST /v1/chats/{chat}/archive", a.authed(a.archive))
	mux.HandleFunc("GET /v1/chats/{chat}/messages", a.authed(a.messages))
	mux.HandleFunc("POST /v1/chats/{chat}/paginate", a.authed(a.paginate))
	mux.HandleFunc("POST /v1/chats/{chat}/messages", a.authed(a.send))
	mux.HandleFunc("PUT /v1/chats/{chat}/messages/{message}", a.authed(a.edit))
	mux.HandleFunc("DELETE /v1/chats/{chat}/messages/{message}", a.authed(a.redact))
	mux.HandleFunc("POST /v1/chats/{chat}/messages/{message}/reactions", a.authed(a.react))
	mux.HandleFunc("DELETE /v1/chats/{chat}/messages/{message}/reactions/{key}", a.authed(a.unreact))
	mux.HandleFunc("POST /v1/assets/upload/base64", a.authed(a.upload))
	mux.HandleFunc("POST /v1/assets/download", a.authed(a.download))
	mux.HandleFunc("GET /v1/ws", a.authed(a.live.Serve))
	return mux
}

func (a *API) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		given := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(given), []byte(a.token)) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, map[string]any{"error": message, "message": message})
}

func readJSON(r *http.Request, into any) error {
	if r.Body == nil {
		return nil
	}
	err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 200<<20)).Decode(into)
	if err != nil && !errors.Is(err, http.ErrBodyReadAfterClose) && err.Error() != "EOF" {
		return err
	}
	return nil
}

func (a *API) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"app": "nook-chatd", "version": a.version})
}

// MARK: Linking

func (a *API) bridges(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, bridgesJSON(r.Context(), a.nets))
}

func (a *API) network(w http.ResponseWriter, r *http.Request) *Network {
	net := a.byID[r.PathValue("bridge")]
	if net == nil || net.Bridge == nil {
		writeError(w, http.StatusNotFound, "no such chat app")
		return nil
	}
	return net
}

func (a *API) session(w http.ResponseWriter, r *http.Request) *LoginSession {
	session := a.logins.Get(r.PathValue("session"))
	if session == nil || session.Network.ID != r.PathValue("bridge") {
		writeError(w, http.StatusNotFound, "no such login")
		return nil
	}
	return session
}

func (a *API) startLogin(w http.ResponseWriter, r *http.Request) {
	net := a.network(w, r)
	if net == nil {
		return
	}
	session, err := a.logins.Start(r.Context(), net)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session.JSON())
}

func (a *API) getLogin(w http.ResponseWriter, r *http.Request) {
	if session := a.session(w, r); session != nil {
		writeJSON(w, http.StatusOK, session.JSON())
	}
}

func (a *API) cancelLogin(w http.ResponseWriter, r *http.Request) {
	if session := a.session(w, r); session != nil {
		session.Cancel()
		writeJSON(w, http.StatusOK, session.JSON())
	}
}

func (a *API) submitStep(w http.ResponseWriter, r *http.Request) {
	session := a.session(w, r)
	if session == nil {
		return
	}
	var body struct {
		Type   string            `json:"type"`
		Fields map[string]string `json:"fields"`
	}
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	// Waiting for a scan answers a little before Nook's own 120 s timeout; Nook then asks again.
	if err := session.Submit(r.PathValue("step"), body.Type, body.Fields, 100*time.Second); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, session.JSON())
}

func (a *API) removeLogin(w http.ResponseWriter, r *http.Request) {
	net := a.network(w, r)
	if net == nil {
		return
	}
	user, err := net.User(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, login := range user.GetUserLogins() {
		if string(login.ID) == r.PathValue("login") {
			login.Logout(r.Context())
			writeJSON(w, http.StatusOK, map[string]any{"success": true})
			return
		}
	}
	writeError(w, http.StatusNotFound, "no such account")
}

// MARK: Chats

func fileURL(path string) string {
	if path == "" {
		return ""
	}
	return (&url.URL{Scheme: "file", Path: path}).String()
}

func (a *API) mediaURL(uri string) string {
	if uri == "" {
		return ""
	}
	path, _, _ := a.store.MediaPath(id.ContentURIString(uri))
	return fileURL(path)
}

// selfIDs are you in a network: the local user, and your own account there as the network shows it.
func (a *API) isSelf(ctx context.Context, net *Network, user id.UserID) bool {
	if user == me {
		return true
	}
	ghost, ok := net.Matrix.ParseGhostMXID(user)
	if !ok {
		return false
	}
	bridgeUser, err := net.User(ctx)
	if err != nil {
		return false
	}
	for _, login := range bridgeUser.GetUserLoginIDs() {
		if string(login) == string(ghost) {
			return true
		}
	}
	return false
}

func (a *API) chatJSON(ctx context.Context, room *Room) map[string]any {
	net := a.byID[room.Bridge]
	members, _ := a.store.Members(room.ID)
	var people []map[string]any
	var others []string
	for _, member := range members {
		if member.Membership != event.MembershipJoin || (net != nil && member.User == net.Matrix.botMXID()) {
			continue
		}
		self := net != nil && a.isSelf(ctx, net, member.User)
		people = append(people, map[string]any{"id": string(member.User), "fullName": member.Name, "imgURL": a.mediaURL(member.Avatar),
			"isSelf": self})
		if !self && member.Name != "" {
			others = append(others, member.Name)
		}
	}
	title := room.Name
	if title == "" {
		title = strings.Join(others, ", ")
	}
	kind := "group"
	if room.IsDirect {
		kind = "single"
	}
	network := room.Bridge
	if net != nil {
		network = net.App
	}
	return map[string]any{
		"id": string(room.ID), "accountID": room.Bridge, "network": network, "title": title, "type": kind,
		"unreadCount": room.Unread, "lastActivity": time.UnixMilli(room.LastTS).UTC().Format(time.RFC3339Nano),
		"imgURL": a.mediaURL(room.Avatar), "participants": map[string]any{"items": people},
		"isPinned": room.Pinned, "isMuted": room.Muted, "isArchived": room.Archived,
	}
}

func limitParam(r *http.Request, fallback, most int) int {
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 {
		return min(n, most)
	}
	return fallback
}

func (a *API) chats(w http.ResponseWriter, r *http.Request) {
	rooms, err := a.store.Rooms(me, limitParam(r, 50, 500))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	items := make([]map[string]any, 0, len(rooms))
	for _, room := range rooms {
		if a.byID[room.Bridge] == nil {
			continue
		}
		items = append(items, a.chatJSON(r.Context(), room))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// chat is the room of the request, with its network.
func (a *API) chat(w http.ResponseWriter, r *http.Request) (*Room, *Network) {
	room, err := a.store.Room(me, id.RoomID(r.PathValue("chat")))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return nil, nil
	}
	if room == nil || a.byID[room.Bridge] == nil || a.byID[room.Bridge].Bridge == nil {
		writeError(w, http.StatusNotFound, "no such chat")
		return nil, nil
	}
	return room, a.byID[room.Bridge]
}

func (a *API) messages(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	list, err := a.store.Messages(room.ID, limitParam(r, 30, 500))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	ids := make([]id.EventID, len(list))
	for i, e := range list {
		ids[i] = e.ID
	}
	reactions, _ := a.store.Reactions(ids)
	names := map[id.UserID]string{}
	if members, err := a.store.Members(room.ID); err == nil {
		for _, member := range members {
			names[member.User] = member.Name
		}
	}
	items := make([]map[string]any, 0, len(list))
	for _, e := range list {
		if e.Sender == net.Matrix.botMXID() {
			continue
		}
		items = append(items, a.messageJSON(r.Context(), net, room, e, reactions[e.ID], names))
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// paginate brings in the chat's next batch of older messages from its network (what Beeper does when you scroll back):
// `{"hasMore": bool}` once they are in the chat's messages. A network that has to ask the phone first (WhatsApp, for
// what is older than its first sync) answers `hasMore` while the phone sends them; they come in shortly after.
func (a *API) paginate(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	ctx := r.Context()
	portal, err := net.Bridge.GetPortalByMXID(ctx, room.ID)
	if err != nil || portal == nil {
		writeError(w, http.StatusNotFound, "no such chat")
		return
	}
	var source *bridgev2.UserLogin
	if logins, err := net.Bridge.GetUserLoginsInPortal(ctx, portal.PortalKey); err == nil {
		for _, login := range logins {
			if login.Client != nil && login.Client.IsLoggedIn() {
				source = login
				break
			}
		}
	}
	if source == nil {
		writeError(w, http.StatusConflict, "the account of this chat is not linked")
		return
	}
	task, err := net.Bridge.DB.BackfillTask.GetNextForPortal(ctx, portal.PortalKey, false)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if task == nil || task.IsDone {
		writeJSON(w, http.StatusOK, map[string]any{"hasMore": false})
		return
	}
	done := make(chan error, 1)
	net.Bridge.WakeupBackfillQueue(&bridgev2.ManualBackfill{Source: source, Portal: portal, DoneCallback: func(err error) {
		select {
		case done <- err:
		default:
		}
	}})
	select {
	case err = <-done:
	case <-time.After(60 * time.Second):
		err = errors.New("the network did not answer in time")
	case <-ctx.Done():
		return
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	next, err := net.Bridge.DB.BackfillTask.GetNextForPortal(ctx, portal.PortalKey, false)
	writeJSON(w, http.StatusOK, map[string]any{"hasMore": err == nil && next != nil && !next.IsDone})
}

func (a *API) messageJSON(ctx context.Context, net *Network, room *Room, e *Stored, reactions []*Stored, names map[id.UserID]string) map[string]any {
	mine := a.isSelf(ctx, net, e.Sender)
	out := map[string]any{
		"id": string(e.ID), "chatID": string(room.ID), "timestamp": time.UnixMilli(e.TS).UTC().Format(time.RFC3339Nano),
		"senderID": string(e.Sender), "senderName": names[e.Sender], "isSender": mine, "isDeleted": e.Deleted, "type": "TEXT",
	}
	content, _ := e.Content.Parsed.(*event.MessageEventContent)
	if content == nil {
		content = &event.MessageEventContent{}
	}
	shown := content
	if e.Edited != nil {
		shown = e.Edited
		if shown.URL == "" && content.URL != "" {
			edited := *content
			edited.Body = shown.Body
			shown = &edited
		}
	}
	text := shown.Body
	switch {
	case e.Type == event.EventSticker.Type || shown.MsgType == event.MsgImage || shown.MsgType == event.MsgVideo ||
		shown.MsgType == event.MsgAudio || shown.MsgType == event.MsgFile:
		name := shown.FileName
		if name == "" {
			name = shown.Body
			text = ""
		} else if shown.Body == name {
			text = ""
		}
		attachment := map[string]any{"fileName": name, "srcURL": a.mediaURL(string(shown.URL)), "isSticker": e.Type == event.EventSticker.Type,
			"isVoiceNote": shown.MSC3245Voice != nil}
		kind := "FILE"
		switch {
		case e.Type == event.EventSticker.Type:
			attachment["type"], kind = "img", "STICKER"
		case shown.MsgType == event.MsgImage:
			attachment["type"], kind = "img", "IMAGE"
		case shown.MsgType == event.MsgVideo:
			attachment["type"], kind = "video", "VIDEO"
		case shown.MsgType == event.MsgAudio:
			attachment["type"], kind = "audio", "AUDIO"
			if shown.MSC3245Voice != nil {
				kind = "VOICE"
			}
		default:
			attachment["type"] = "unknown"
		}
		if info := shown.Info; info != nil {
			attachment["mimeType"] = info.MimeType
			attachment["isGif"] = info.MauGIF
			if info.Duration > 0 {
				attachment["duration"] = float64(info.Duration) / 1000
			}
		}
		out["attachments"] = []map[string]any{attachment}
		out["type"] = kind
	case shown.MsgType == event.MsgLocation:
		out["type"] = "LOCATION"
		if text == "" {
			text = shown.GeoURI
		}
	case shown.MsgType == event.MsgEmote:
		text = "* " + text
	}
	out["text"] = text
	if replyTo := content.RelatesTo.GetReplyTo(); replyTo != "" {
		out["linkedMessageID"] = string(replyTo)
	}
	list := make([]map[string]any, 0, len(reactions))
	for _, reaction := range reactions {
		if r, ok := reaction.Content.Parsed.(*event.ReactionEventContent); ok {
			participant := string(reaction.Sender)
			if a.isSelf(ctx, net, reaction.Sender) {
				participant = string(me)
			}
			list = append(list, map[string]any{"reactionKey": r.RelatesTo.Key, "participantID": participant})
		}
	}
	out["reactions"] = list
	if mine {
		if e.Status != "" && e.Status != string(event.MessageStatusSuccess) {
			out["sendStatus"] = map[string]any{"status": e.Status, "message": e.StatusText}
		}
		if room.OthersReadTS >= e.TS {
			out["seen"] = true
		}
	}
	return out
}

// MARK: Sending and acting

// queue hands an event from you to the network's bridge, as Matrix would.
func (a *API) queue(ctx context.Context, net *Network, room id.RoomID, evtType event.Type, content any) *event.Event {
	evt := &event.Event{ID: newEventID(), RoomID: room, Sender: me, Type: evtType, Timestamp: time.Now().UnixMilli(),
		Content: event.Content{Parsed: content}}
	evt.Content.VeryRaw, _ = json.Marshal(content)
	if redaction, ok := content.(*event.RedactionEventContent); ok {
		evt.Redacts = redaction.Redacts
	}
	go net.Bridge.QueueMatrixEvent(net.Bridge.BackgroundCtx, evt)
	return evt
}

func (a *API) send(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	var body struct {
		Text       string `json:"text"`
		ReplyTo    string `json:"replyToMessageID"`
		Attachment *struct {
			UploadID string  `json:"uploadID"`
			Type     string  `json:"type"`
			FileName string  `json:"fileName"`
			MimeType string  `json:"mimeType"`
			Duration float64 `json:"duration"`
		} `json:"attachment"`
	}
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	evtType := event.EventMessage
	content := &event.MessageEventContent{MsgType: event.MsgText, Body: strings.TrimSpace(body.Text)}
	if att := body.Attachment; att != nil {
		path, _, _ := a.store.MediaPath(id.ContentURIString(att.UploadID))
		if path == "" {
			writeError(w, http.StatusBadRequest, "unknown upload")
			return
		}
		content.URL = id.ContentURIString(att.UploadID)
		content.Info = &event.FileInfo{MimeType: att.MimeType, Duration: int(att.Duration * 1000)}
		if content.Body == "" {
			content.Body = att.FileName
		} else {
			content.FileName = att.FileName
		}
		switch att.Type {
		case "image":
			content.MsgType = event.MsgImage
		case "gif":
			content.MsgType = event.MsgImage
			content.Info.MauGIF = true
		case "sticker":
			evtType = event.EventSticker
			content.MsgType = ""
		case "video":
			content.MsgType = event.MsgVideo
		case "audio":
			content.MsgType = event.MsgAudio
		case "voice-note":
			content.MsgType = event.MsgAudio
			content.MSC3245Voice = &event.MSC3245Voice{}
			content.MSC1767Audio = &event.MSC1767Audio{Duration: int(att.Duration * 1000)}
		default:
			content.MsgType = event.MsgFile
		}
	}
	if content.Body == "" && content.URL == "" {
		writeError(w, http.StatusBadRequest, "nothing to send")
		return
	}
	if body.ReplyTo != "" {
		content.RelatesTo = (&event.RelatesTo{}).SetReplyTo(id.EventID(body.ReplyTo))
	}
	evt := &event.Event{ID: newEventID(), RoomID: room.ID, Sender: me, Type: evtType, Timestamp: time.Now().UnixMilli(),
		Content: event.Content{Parsed: content}}
	evt.Content.VeryRaw, _ = json.Marshal(content)
	if _, err := a.store.Add(evt.ID, room.ID, me, evtType, &evt.Content, time.UnixMilli(evt.Timestamp), string(event.MessageStatusPending)); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	a.store.MarkRead(room.ID, evt.Timestamp)
	go net.Bridge.QueueMatrixEvent(net.Bridge.BackgroundCtx, evt)
	writeJSON(w, http.StatusOK, map[string]any{"chatID": string(room.ID), "pendingMessageID": string(evt.ID)})
}

func (a *API) edit(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	var body struct {
		Text string `json:"text"`
	}
	if err := readJSON(r, &body); err != nil || strings.TrimSpace(body.Text) == "" {
		writeError(w, http.StatusBadRequest, "nothing to change")
		return
	}
	target := id.EventID(r.PathValue("message"))
	text := strings.TrimSpace(body.Text)
	content := &event.MessageEventContent{MsgType: event.MsgText, Body: "* " + text,
		NewContent: &event.MessageEventContent{MsgType: event.MsgText, Body: text}}
	content.RelatesTo = (&event.RelatesTo{}).SetReplace(target)
	evt := a.queue(r.Context(), net, room.ID, event.EventMessage, content)
	_, _ = a.store.Add(evt.ID, room.ID, me, event.EventMessage, &evt.Content, time.Now(), "")
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *API) redact(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	content := &event.RedactionEventContent{Redacts: id.EventID(r.PathValue("message"))}
	evt := a.queue(r.Context(), net, room.ID, event.EventRedaction, content)
	_, _ = a.store.Add(evt.ID, room.ID, me, event.EventRedaction, &evt.Content, time.Now(), "")
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *API) react(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	var body struct {
		Key string `json:"reactionKey"`
	}
	if err := readJSON(r, &body); err != nil || body.Key == "" {
		writeError(w, http.StatusBadRequest, "no emoji")
		return
	}
	content := &event.ReactionEventContent{RelatesTo: event.RelatesTo{Type: event.RelAnnotation,
		EventID: id.EventID(r.PathValue("message")), Key: body.Key}}
	evt := a.queue(r.Context(), net, room.ID, event.EventReaction, content)
	_, _ = a.store.Add(evt.ID, room.ID, me, event.EventReaction, &evt.Content, time.Now(), "")
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *API) unreact(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	key, _ := url.PathUnescape(r.PathValue("key"))
	reaction, _ := a.store.Reaction(id.EventID(r.PathValue("message")), me, key)
	if reaction == nil {
		writeJSON(w, http.StatusOK, map[string]any{"success": true})
		return
	}
	content := &event.RedactionEventContent{Redacts: reaction.ID}
	evt := a.queue(r.Context(), net, room.ID, event.EventRedaction, content)
	_, _ = a.store.Add(evt.ID, room.ID, me, event.EventRedaction, &evt.Content, time.Now(), "")
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *API) markRead(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	a.store.MarkRead(room.ID, time.Now().UnixMilli())
	if newest := a.store.NewestMessage(room.ID); newest != nil {
		content := &event.ReceiptEventContent{newest.ID: {event.ReceiptTypeRead: {me: {Timestamp: time.Now()}}}}
		evt := &event.Event{RoomID: room.ID, Sender: me, Type: event.EphemeralEventReceipt, Content: event.Content{Parsed: content}}
		go net.Bridge.QueueMatrixEvent(net.Bridge.BackgroundCtx, evt)
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *API) accountData(net *Network, room id.RoomID, evtType event.Type, content any) {
	evt := &event.Event{RoomID: room, Sender: me, Type: evtType, Timestamp: time.Now().UnixMilli(), Content: event.Content{Parsed: content}}
	evt.Content.VeryRaw, _ = json.Marshal(content)
	go net.Bridge.QueueMatrixEvent(net.Bridge.BackgroundCtx, evt)
}

func (a *API) markUnread(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	a.store.SetRoom(room.ID, "marked_unread", 1)
	a.accountData(net, room.ID, event.AccountDataMarkedUnread, &event.MarkedUnreadEventContent{Unread: true})
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

// tags sends the room's tags as they now are: pinned is a favourite, archived is low priority.
func (a *API) tags(net *Network, room id.RoomID, pinned, archived bool) {
	tags := event.Tags{}
	if pinned {
		tags[event.RoomTagFavourite] = event.TagMetadata{}
	}
	if archived {
		tags[event.RoomTagLowPriority] = event.TagMetadata{}
	}
	a.accountData(net, room, event.AccountDataRoomTags, &event.TagEventContent{Tags: tags})
}

func (a *API) patchChat(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	var body struct {
		Pinned *bool `json:"isPinned"`
		Muted  *bool `json:"isMuted"`
	}
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Pinned != nil {
		a.store.SetRoom(room.ID, "pinned", boolInt(*body.Pinned))
		a.tags(net, room.ID, *body.Pinned, room.Archived)
	}
	if body.Muted != nil {
		a.store.SetRoom(room.ID, "muted", boolInt(*body.Muted))
		until := int64(0)
		if *body.Muted {
			until = -1
		}
		a.accountData(net, room.ID, event.AccountDataBeeperMute, &event.BeeperMuteEventContent{MutedUntil: until})
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (a *API) archive(w http.ResponseWriter, r *http.Request) {
	room, net := a.chat(w, r)
	if room == nil {
		return
	}
	body := struct {
		Archived *bool `json:"archived"`
	}{}
	_ = readJSON(r, &body)
	archived := body.Archived == nil || *body.Archived
	a.store.SetRoom(room.ID, "archived", boolInt(archived))
	a.tags(net, room.ID, room.Pinned, archived)
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

// MARK: Files

func (a *API) upload(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Content  string `json:"content"`
		FileName string `json:"fileName"`
		MimeType string `json:"mimeType"`
	}
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	data, err := base64.StdEncoding.DecodeString(body.Content)
	if err != nil || len(data) == 0 {
		writeError(w, http.StatusBadRequest, "no file")
		return
	}
	uri, err := a.store.PutMediaBytes(data, body.MimeType, body.FileName)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"uploadID": string(uri), "srcURL": a.mediaURL(string(uri))})
}

func (a *API) download(w http.ResponseWriter, r *http.Request) {
	var body struct {
		URL string `json:"url"`
	}
	if err := readJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	local := a.mediaURL(body.URL)
	if local == "" {
		writeError(w, http.StatusNotFound, "unknown file")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"srcURL": local})
}
