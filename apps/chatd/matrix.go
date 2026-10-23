package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/rs/xid"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// The bridges think they talk to a Matrix homeserver. There is none: LocalMatrix answers in its place and keeps the
// rooms and messages in the Store, on this Mac only. Every network has its own LocalMatrix, sharing one Store.
const serverName = "nook.local"

// me is the one local user: you. The bridges see it as a double puppet, so your own messages are sent as you.
var me = id.UserID("@me:" + serverName)

type LocalMatrix struct {
	net   *Network
	store *Store
	br    *bridgev2.Bridge

	mu     sync.Mutex
	states map[networkid.UserLoginID]status.BridgeState
}

var _ bridgev2.MatrixConnector = (*LocalMatrix)(nil)

func NewLocalMatrix(net *Network, store *Store) *LocalMatrix {
	return &LocalMatrix{net: net, store: store, states: make(map[networkid.UserLoginID]status.BridgeState)}
}

func (m *LocalMatrix) Init(br *bridgev2.Bridge)        { m.br = br }
func (m *LocalMatrix) Start(ctx context.Context) error { return nil }
func (m *LocalMatrix) PreStop()                        {}
func (m *LocalMatrix) Stop()                           {}
func (m *LocalMatrix) ServerName() string              { return serverName }

func (m *LocalMatrix) GetCapabilities() *bridgev2.MatrixCapabilities {
	return &bridgev2.MatrixCapabilities{AutoJoinInvites: true, BatchSending: true, ArbitraryMemberChange: true}
}

func (m *LocalMatrix) ghostPrefix() string { return "@" + m.net.App + "_" }

func (m *LocalMatrix) ParseGhostMXID(userID id.UserID) (networkid.UserID, bool) {
	text := string(userID)
	suffix := ":" + serverName
	if !strings.HasPrefix(text, m.ghostPrefix()) || !strings.HasSuffix(text, suffix) {
		return "", false
	}
	decoded, err := id.DecodeUserLocalpart(strings.TrimSuffix(strings.TrimPrefix(text, m.ghostPrefix()), suffix))
	if err != nil {
		return "", false
	}
	return networkid.UserID(decoded), true
}

func (m *LocalMatrix) FormatGhostMXID(userID networkid.UserID) id.UserID {
	return id.UserID(m.ghostPrefix() + id.EncodeUserLocalpart(string(userID)) + ":" + serverName)
}

func (m *LocalMatrix) GhostIntent(userID networkid.UserID) bridgev2.MatrixAPI {
	return &intent{m: m, user: m.FormatGhostMXID(userID)}
}

func (m *LocalMatrix) NewUserIntent(ctx context.Context, userID id.UserID, accessToken string) (bridgev2.MatrixAPI, string, error) {
	if userID != me {
		return nil, "", fmt.Errorf("no such local user %s", userID)
	}
	return &intent{m: m, user: me, double: true}, "local", nil
}

func (m *LocalMatrix) BotIntent() bridgev2.MatrixAPI {
	return &intent{m: m, user: m.botMXID()}
}

func (m *LocalMatrix) botMXID() id.UserID { return id.UserID("@" + m.net.App + "bot:" + serverName) }

// SendBridgeStatus keeps how each linked account is doing, for Settings › Chats.
func (m *LocalMatrix) SendBridgeStatus(ctx context.Context, state *status.BridgeState) error {
	if state.RemoteID == "" {
		return nil
	}
	m.mu.Lock()
	m.states[state.RemoteID] = *state
	m.mu.Unlock()
	return nil
}

func (m *LocalMatrix) State(login networkid.UserLoginID) (status.BridgeState, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	state, ok := m.states[login]
	return state, ok
}

// SendMessageStatus records whether a message sent from Nook reached the network.
func (m *LocalMatrix) SendMessageStatus(ctx context.Context, st *bridgev2.MessageStatus, info *bridgev2.MessageStatusEventInfo) {
	if st == nil || info == nil || st.Status == "" {
		return
	}
	text := st.Message
	if text == "" && st.Status != event.MessageStatusSuccess {
		text = string(st.ErrorReason)
	}
	m.store.SetStatus(info.SourceEventID, string(st.Status), text)
}

func (m *LocalMatrix) GenerateContentURI(ctx context.Context, mediaID networkid.MediaID) (id.ContentURIString, error) {
	return "", errors.New("direct media is not used here")
}

func (m *LocalMatrix) ParseContentURI(ctx context.Context, uri id.ContentURIString) (networkid.MediaID, error) {
	return nil, errors.New("direct media is not used here")
}

func (m *LocalMatrix) GetPowerLevels(ctx context.Context, roomID id.RoomID) (*event.PowerLevelsEventContent, error) {
	levels := &event.PowerLevelsEventContent{}
	if raw := m.store.RoomColumn(roomID, "power_levels"); raw != "" {
		_ = json.Unmarshal([]byte(raw), levels)
	}
	if levels.Users == nil {
		levels.Users = map[id.UserID]int{m.botMXID(): 100, me: 100}
	}
	return levels, nil
}

func (m *LocalMatrix) GetMembers(ctx context.Context, roomID id.RoomID) (map[id.UserID]*event.MemberEventContent, error) {
	members, err := m.store.Members(roomID)
	if err != nil {
		return nil, err
	}
	result := make(map[id.UserID]*event.MemberEventContent, len(members))
	for _, member := range members {
		result[member.User] = &event.MemberEventContent{Membership: member.Membership, Displayname: member.Name,
			AvatarURL: id.ContentURIString(member.Avatar)}
	}
	return result, nil
}

func (m *LocalMatrix) GetMemberInfo(ctx context.Context, roomID id.RoomID, userID id.UserID) (*event.MemberEventContent, error) {
	members, err := m.GetMembers(ctx, roomID)
	if err != nil {
		return nil, err
	}
	if member, ok := members[userID]; ok {
		return member, nil
	}
	return &event.MemberEventContent{Membership: event.MembershipLeave}, nil
}

func (m *LocalMatrix) BatchSend(ctx context.Context, roomID id.RoomID, req *mautrix.ReqBeeperBatchSend, extras []*bridgev2.MatrixSendExtra) (*mautrix.RespBeeperBatchSend, error) {
	resp := &mautrix.RespBeeperBatchSend{EventIDs: make([]id.EventID, len(req.Events))}
	var newest int64
	for i, evt := range req.Events {
		ts := time.UnixMilli(evt.Timestamp)
		if evt.Timestamp == 0 {
			ts = time.Now()
		}
		evtID, err := m.store.Add(evt.ID, roomID, evt.Sender, evt.Type, &evt.Content, ts, "")
		if err != nil {
			return nil, err
		}
		resp.EventIDs[i] = evtID
		newest = max(newest, ts.UnixMilli())
	}
	if req.MarkReadBy == me && newest > 0 {
		m.store.MarkRead(roomID, newest)
	}
	return resp, nil
}

func hashID(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return base64.RawURLEncoding.EncodeToString(sum[:18])
}

func (m *LocalMatrix) GenerateDeterministicRoomID(key networkid.PortalKey) id.RoomID {
	return id.RoomID("!" + hashID(m.net.ID, string(key.ID), string(key.Receiver)) + ":" + serverName)
}

func (m *LocalMatrix) GenerateDeterministicEventID(roomID id.RoomID, key networkid.PortalKey, messageID networkid.MessageID, partID networkid.PartID) id.EventID {
	return id.EventID("$" + hashID(string(roomID), string(messageID), string(partID)) + ":" + serverName)
}

func (m *LocalMatrix) GenerateReactionEventID(roomID id.RoomID, target *database.Message, sender networkid.UserID, emojiID networkid.EmojiID) id.EventID {
	return id.EventID("$" + hashID(string(roomID), string(target.ID), string(target.PartID), string(sender), string(emojiID)) + ":" + serverName)
}

// MARK: Intents

// intent is one user acting in the rooms: a ghost (someone on the network), the bridge bot, or you.
type intent struct {
	m      *LocalMatrix
	user   id.UserID
	double bool
}

var _ bridgev2.MatrixAPI = (*intent)(nil)

func (in *intent) GetMXID() id.UserID   { return in.user }
func (in *intent) IsDoublePuppet() bool { return in.double }

func parsed(content *event.Content, evtType event.Type) {
	if content.Parsed != nil {
		return
	}
	if content.VeryRaw == nil && content.Raw != nil {
		content.VeryRaw, _ = json.Marshal(content.Raw)
	}
	if content.VeryRaw != nil {
		_ = content.ParseRaw(evtType)
	}
}

func (in *intent) SendMessage(ctx context.Context, roomID id.RoomID, evtType event.Type, content *event.Content, extra *bridgev2.MatrixSendExtra) (*mautrix.RespSendEvent, error) {
	ts := time.Now()
	if extra != nil && !extra.Timestamp.IsZero() {
		ts = extra.Timestamp
	}
	if evtType.IsState() {
		return in.SendState(ctx, roomID, evtType, "", content, ts)
	}
	evtID, err := in.m.store.Add("", roomID, in.user, evtType, content, ts, "")
	if err != nil {
		return nil, err
	}
	// What you send yourself (from your phone, say) means you read the chat up to there.
	if in.double && (evtType == event.EventMessage || evtType == event.EventSticker) {
		in.m.store.MarkRead(roomID, ts.UnixMilli())
	}
	return &mautrix.RespSendEvent{EventID: evtID}, nil
}

func (in *intent) SendState(ctx context.Context, roomID id.RoomID, evtType event.Type, stateKey string, content *event.Content, ts time.Time) (*mautrix.RespSendEvent, error) {
	in.m.applyState(roomID, evtType, stateKey, content)
	return &mautrix.RespSendEvent{EventID: newEventID()}, nil
}

// applyState keeps the room state Nook shows: the name, picture, topic, people and power levels.
func (m *LocalMatrix) applyState(roomID id.RoomID, evtType event.Type, stateKey string, content *event.Content) {
	evtType.Class = event.StateEventType
	parsed(content, evtType)
	switch c := content.Parsed.(type) {
	case *event.RoomNameEventContent:
		m.store.SetRoom(roomID, "name", c.Name)
	case *event.RoomAvatarEventContent:
		m.store.SetRoom(roomID, "avatar", string(c.URL))
	case *event.TopicEventContent:
		m.store.SetRoom(roomID, "topic", c.Topic)
	case *event.MemberEventContent:
		membership := c.Membership
		if membership == event.MembershipInvite {
			membership = event.MembershipJoin
		}
		m.store.SetMember(roomID, id.UserID(stateKey), membership, c.Displayname, string(c.AvatarURL))
	case *event.PowerLevelsEventContent:
		raw, _ := json.Marshal(c)
		m.store.SetRoom(roomID, "power_levels", string(raw))
	}
}

func (in *intent) MarkRead(ctx context.Context, roomID id.RoomID, eventID id.EventID, ts time.Time) error {
	at := ts.UnixMilli()
	if stored, _ := in.m.store.Event(eventID); stored != nil {
		at = max(at, stored.TS)
	}
	if in.double {
		in.m.store.MarkRead(roomID, at)
	} else {
		in.m.store.MarkOthersRead(roomID, at)
	}
	return nil
}

func (in *intent) MarkUnread(ctx context.Context, roomID id.RoomID, unread bool) error {
	if in.double {
		in.m.store.SetRoom(roomID, "marked_unread", boolInt(unread))
	}
	return nil
}

func (in *intent) MarkTyping(ctx context.Context, roomID id.RoomID, typingType bridgev2.TypingType, timeout time.Duration) error {
	return nil
}

func (in *intent) DownloadMedia(ctx context.Context, uri id.ContentURIString, file *event.EncryptedFileInfo) ([]byte, error) {
	if file != nil {
		uri = file.URL
	}
	path, _, _ := in.m.store.MediaPath(uri)
	if path == "" {
		return nil, fmt.Errorf("unknown media %s", uri)
	}
	return os.ReadFile(path)
}

func (in *intent) DownloadMediaToFile(ctx context.Context, uri id.ContentURIString, file *event.EncryptedFileInfo, writable bool, callback func(*os.File) error) error {
	if file != nil {
		uri = file.URL
	}
	path, _, _ := in.m.store.MediaPath(uri)
	if path == "" {
		return fmt.Errorf("unknown media %s", uri)
	}
	if !writable {
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		return callback(f)
	}
	// A writable copy, so the network may change it without touching the stored file.
	src, err := os.Open(path)
	if err != nil {
		return err
	}
	defer src.Close()
	tmp, err := os.CreateTemp("", "nook-chatd-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	if _, err = io.Copy(tmp, src); err != nil {
		return err
	}
	if _, err = tmp.Seek(0, io.SeekStart); err != nil {
		return err
	}
	return callback(tmp)
}

func (in *intent) UploadMedia(ctx context.Context, roomID id.RoomID, data []byte, fileName, mimeType string) (id.ContentURIString, *event.EncryptedFileInfo, error) {
	uri, err := in.m.store.PutMediaBytes(data, mimeType, fileName)
	return uri, nil, err
}

func (in *intent) UploadMediaStream(ctx context.Context, roomID id.RoomID, size int64, requireFile bool, cb bridgev2.FileStreamCallback) (id.ContentURIString, *event.EncryptedFileInfo, error) {
	tmp, err := os.CreateTemp(in.m.store.mediaDir, "stream-*")
	if err != nil {
		return "", nil, err
	}
	res, err := cb(tmp)
	tmp.Close()
	if err != nil {
		_ = os.Remove(tmp.Name())
		return "", nil, err
	}
	path := tmp.Name()
	if res.ReplacementFile != "" {
		_ = os.Remove(path)
		path = res.ReplacementFile
	}
	uri, err := in.m.store.PutMedia(path, res.MimeType, res.FileName)
	return uri, nil, err
}

func (in *intent) SetDisplayName(ctx context.Context, name string) error {
	in.m.store.SetProfile(in.user, &name, nil)
	return nil
}

func (in *intent) SetAvatarURL(ctx context.Context, avatarURL id.ContentURIString) error {
	avatar := string(avatarURL)
	in.m.store.SetProfile(in.user, nil, &avatar)
	return nil
}

func (in *intent) SetExtraProfileMeta(ctx context.Context, data any) error { return nil }
func (in *intent) SetProfile(ctx context.Context, data any) error          { return nil }

func (in *intent) CreateRoom(ctx context.Context, req *mautrix.ReqCreateRoom) (id.RoomID, error) {
	roomID := req.BeeperLocalRoomID
	if roomID == "" {
		roomID = req.MeowRoomID
	}
	if roomID == "" {
		roomID = id.RoomID("!" + xid.New().String() + ":" + serverName)
	}
	if err := in.m.store.CreateRoom(roomID, in.m.net.ID, req.Name, req.Topic, req.IsDirect, time.Now()); err != nil {
		return "", err
	}
	if req.PowerLevelOverride != nil {
		raw, _ := json.Marshal(req.PowerLevelOverride)
		in.m.store.SetRoom(roomID, "power_levels", string(raw))
	}
	for _, evt := range req.InitialState {
		stateKey := ""
		if evt.StateKey != nil {
			stateKey = *evt.StateKey
		}
		in.m.applyState(roomID, evt.Type, stateKey, &evt.Content)
	}
	in.m.store.SetMember(roomID, in.user, event.MembershipJoin, "", "")
	for _, user := range append(append([]id.UserID{}, req.Invite...), req.BeeperInitialMembers...) {
		in.m.store.SetMember(roomID, user, event.MembershipJoin, "", "")
	}
	return roomID, nil
}

func (in *intent) DeleteRoom(ctx context.Context, roomID id.RoomID, puppetsOnly bool) error {
	in.m.store.SetRoom(roomID, "deleted", 1)
	return nil
}

func (in *intent) EnsureJoined(ctx context.Context, roomID id.RoomID, params ...bridgev2.EnsureJoinedParams) error {
	in.m.store.SetMember(roomID, in.user, event.MembershipJoin, "", "")
	return nil
}

func (in *intent) EnsureInvited(ctx context.Context, roomID id.RoomID, userID id.UserID) error {
	in.m.store.SetMember(roomID, userID, event.MembershipJoin, "", "")
	return nil
}

func (in *intent) TagRoom(ctx context.Context, roomID id.RoomID, tag event.RoomTag, isTagged bool) error {
	switch tag {
	case event.RoomTagFavourite:
		in.m.store.SetRoom(roomID, "pinned", boolInt(isTagged))
	case event.RoomTagLowPriority:
		in.m.store.SetRoom(roomID, "archived", boolInt(isTagged))
	}
	return nil
}

func (in *intent) MuteRoom(ctx context.Context, roomID id.RoomID, until time.Time) error {
	in.m.store.SetRoom(roomID, "muted", boolInt(until.After(time.Now())))
	return nil
}

func (in *intent) GetEvent(ctx context.Context, roomID id.RoomID, eventID id.EventID) (*event.Event, error) {
	stored, err := in.m.store.Event(eventID)
	if err != nil {
		return nil, err
	} else if stored == nil {
		return nil, mautrix.MNotFound
	}
	return &event.Event{
		ID: stored.ID, RoomID: stored.Room, Sender: stored.Sender, Timestamp: stored.TS,
		Type: event.Type{Type: stored.Type, Class: event.MessageEventType}, Content: stored.Content,
	}, nil
}
