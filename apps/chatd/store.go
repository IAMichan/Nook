package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/rs/xid"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// Store keeps what a Matrix homeserver would keep for the bridges: the rooms (chats), their members and state, the
// timeline, and uploaded media. It is what Nook reads; the bridges keep their own databases next to it.
type Store struct {
	db       *sql.DB
	mediaDir string
	// changed tells the live line which chat changed ("chat.upserted", "message.upserted", "message.deleted").
	changed func(kind string, room id.RoomID)
}

const storeSchema = `
CREATE TABLE IF NOT EXISTS room (
	id TEXT PRIMARY KEY,
	bridge TEXT NOT NULL,
	name TEXT NOT NULL DEFAULT '',
	avatar TEXT NOT NULL DEFAULT '',
	topic TEXT NOT NULL DEFAULT '',
	is_direct INTEGER NOT NULL DEFAULT 0,
	created INTEGER NOT NULL,
	read_ts INTEGER NOT NULL DEFAULT 0,
	others_read_ts INTEGER NOT NULL DEFAULT 0,
	marked_unread INTEGER NOT NULL DEFAULT 0,
	pinned INTEGER NOT NULL DEFAULT 0,
	muted INTEGER NOT NULL DEFAULT 0,
	archived INTEGER NOT NULL DEFAULT 0,
	deleted INTEGER NOT NULL DEFAULT 0,
	power_levels TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS member (
	room TEXT NOT NULL,
	user TEXT NOT NULL,
	membership TEXT NOT NULL,
	name TEXT NOT NULL DEFAULT '',
	avatar TEXT NOT NULL DEFAULT '',
	PRIMARY KEY (room, user)
);
CREATE TABLE IF NOT EXISTS profile (
	user TEXT PRIMARY KEY,
	name TEXT NOT NULL DEFAULT '',
	avatar TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS timeline (
	id TEXT PRIMARY KEY,
	room TEXT NOT NULL,
	sender TEXT NOT NULL,
	type TEXT NOT NULL,
	ts INTEGER NOT NULL,
	content TEXT NOT NULL,
	target TEXT NOT NULL DEFAULT '',
	edited TEXT NOT NULL DEFAULT '',
	deleted INTEGER NOT NULL DEFAULT 0,
	status TEXT NOT NULL DEFAULT '',
	status_text TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS timeline_room_ts ON timeline (room, ts);
CREATE INDEX IF NOT EXISTS timeline_target ON timeline (target);
CREATE TABLE IF NOT EXISTS media (
	id TEXT PRIMARY KEY,
	path TEXT NOT NULL,
	mime TEXT NOT NULL DEFAULT '',
	name TEXT NOT NULL DEFAULT ''
);
`

func OpenStore(dir string) (*Store, error) {
	mediaDir := filepath.Join(dir, "media")
	if err := os.MkdirAll(mediaDir, 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite3-fk-wal", "file:"+filepath.Join(dir, "chats.db")+"?_txlock=immediate")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(storeSchema); err != nil {
		return nil, err
	}
	return &Store{db: db, mediaDir: mediaDir, changed: func(string, id.RoomID) {}}, nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// MARK: Rooms

func (s *Store) CreateRoom(room id.RoomID, bridge, name, topic string, direct bool, ts time.Time) error {
	_, err := s.db.Exec(`INSERT INTO room (id, bridge, name, topic, is_direct, created) VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET deleted=0`, room, bridge, name, topic, boolInt(direct), ts.UnixMilli())
	s.changed("chat.upserted", room)
	return err
}

func (s *Store) RoomBridge(room id.RoomID) string {
	var bridge string
	_ = s.db.QueryRow(`SELECT bridge FROM room WHERE id=?`, room).Scan(&bridge)
	return bridge
}

// SetRoom changes one column of a room; only the columns below are ever named.
func (s *Store) SetRoom(room id.RoomID, column string, value any) {
	switch column {
	case "name", "avatar", "topic", "marked_unread", "pinned", "muted", "archived", "deleted", "power_levels", "is_direct":
	default:
		return
	}
	_, _ = s.db.Exec(`UPDATE room SET `+column+`=? WHERE id=?`, value, room)
	s.changed("chat.upserted", room)
}

func (s *Store) RoomColumn(room id.RoomID, column string) string {
	if column != "power_levels" && column != "name" && column != "avatar" && column != "topic" {
		return ""
	}
	var value string
	_ = s.db.QueryRow(`SELECT `+column+` FROM room WHERE id=?`, room).Scan(&value)
	return value
}

// MarkOthersRead moves how far the other side read the chat, never back.
func (s *Store) MarkOthersRead(room id.RoomID, ts int64) {
	_, _ = s.db.Exec(`UPDATE room SET others_read_ts=MAX(others_read_ts, ?) WHERE id=?`, ts, room)
	s.changed("chat.upserted", room)
}

// MarkRead marks the chat read up to ts and takes away a "marked unread".
func (s *Store) MarkRead(room id.RoomID, ts int64) {
	_, _ = s.db.Exec(`UPDATE room SET read_ts=MAX(read_ts, ?), marked_unread=0 WHERE id=?`, ts, room)
	s.changed("chat.upserted", room)
}

type Room struct {
	ID           id.RoomID
	Bridge       string
	Name         string
	Avatar       string
	Topic        string
	IsDirect     bool
	Created      int64
	ReadTS       int64
	OthersReadTS int64
	MarkedUnread bool
	Pinned       bool
	Muted        bool
	Archived     bool
	LastTS       int64
	Unread       int
}

const roomColumns = `r.id, r.bridge, r.name, r.avatar, r.topic, r.is_direct, r.created, r.read_ts, r.others_read_ts,
	r.marked_unread, r.pinned, r.muted, r.archived,
	COALESCE((SELECT MAX(ts) FROM timeline t WHERE t.room=r.id AND t.type IN ('m.room.message','m.sticker')), r.created) AS last_ts,
	(SELECT COUNT(*) FROM timeline t WHERE t.room=r.id AND t.type IN ('m.room.message','m.sticker') AND t.deleted=0
		AND t.ts>r.read_ts AND t.sender<>?)`

func scanRoom(row interface{ Scan(...any) error }) (*Room, error) {
	var r Room
	var direct, unread, pinned, muted, archived int
	err := row.Scan(&r.ID, &r.Bridge, &r.Name, &r.Avatar, &r.Topic, &direct, &r.Created, &r.ReadTS, &r.OthersReadTS,
		&unread, &pinned, &muted, &archived, &r.LastTS, &r.Unread)
	r.IsDirect, r.MarkedUnread, r.Pinned, r.Muted, r.Archived = direct == 1, unread == 1, pinned == 1, muted == 1, archived == 1
	if r.MarkedUnread && r.Unread == 0 {
		r.Unread = 1
	}
	return &r, err
}

// Rooms are the chats, the most recently active first.
func (s *Store) Rooms(me id.UserID, limit int) ([]*Room, error) {
	rows, err := s.db.Query(`SELECT `+roomColumns+` FROM room r WHERE r.deleted=0 ORDER BY last_ts DESC LIMIT ?`, me, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var rooms []*Room
	for rows.Next() {
		room, err := scanRoom(rows)
		if err != nil {
			return nil, err
		}
		rooms = append(rooms, room)
	}
	return rooms, rows.Err()
}

func (s *Store) Room(me id.UserID, room id.RoomID) (*Room, error) {
	r, err := scanRoom(s.db.QueryRow(`SELECT `+roomColumns+` FROM room r WHERE r.id=? AND r.deleted=0`, me, room))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return r, err
}

// MARK: Members and profiles

type Member struct {
	User       id.UserID
	Membership event.Membership
	Name       string
	Avatar     string
}

func (s *Store) SetMember(room id.RoomID, user id.UserID, membership event.Membership, name, avatar string) {
	_, _ = s.db.Exec(`INSERT INTO member (room, user, membership, name, avatar) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (room, user) DO UPDATE SET membership=excluded.membership,
			name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE member.name END,
			avatar=CASE WHEN excluded.avatar<>'' THEN excluded.avatar ELSE member.avatar END`,
		room, user, string(membership), name, avatar)
	s.changed("chat.upserted", room)
}

// Members are the people in a room with their names: the room's own, else their profile.
func (s *Store) Members(room id.RoomID) ([]Member, error) {
	rows, err := s.db.Query(`SELECT m.user, m.membership,
		CASE WHEN m.name<>'' THEN m.name ELSE COALESCE(p.name, '') END,
		CASE WHEN m.avatar<>'' THEN m.avatar ELSE COALESCE(p.avatar, '') END
		FROM member m LEFT JOIN profile p ON p.user=m.user WHERE m.room=?`, room)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var members []Member
	for rows.Next() {
		var m Member
		var membership string
		if err = rows.Scan(&m.User, &membership, &m.Name, &m.Avatar); err != nil {
			return nil, err
		}
		m.Membership = event.Membership(membership)
		members = append(members, m)
	}
	return members, rows.Err()
}

func (s *Store) SetProfile(user id.UserID, name, avatar *string) {
	_, _ = s.db.Exec(`INSERT INTO profile (user) VALUES (?) ON CONFLICT DO NOTHING`, user)
	if name != nil {
		_, _ = s.db.Exec(`UPDATE profile SET name=? WHERE user=?`, *name, user)
	}
	if avatar != nil {
		_, _ = s.db.Exec(`UPDATE profile SET avatar=? WHERE user=?`, *avatar, user)
	}
	rows, err := s.db.Query(`SELECT room FROM member WHERE user=?`, user)
	if err != nil {
		return
	}
	var rooms []id.RoomID
	for rows.Next() {
		var room id.RoomID
		if rows.Scan(&room) == nil {
			rooms = append(rooms, room)
		}
	}
	rows.Close()
	for _, room := range rooms {
		s.changed("chat.upserted", room)
	}
}

func (s *Store) Profile(user id.UserID) (name, avatar string) {
	_ = s.db.QueryRow(`SELECT name, avatar FROM profile WHERE user=?`, user).Scan(&name, &avatar)
	return
}

// MARK: Timeline

type Stored struct {
	ID         id.EventID
	Room       id.RoomID
	Sender     id.UserID
	Type       string
	TS         int64
	Content    event.Content
	Target     id.EventID
	Edited     *event.MessageEventContent
	Deleted    bool
	Status     string
	StatusText string
}

func newEventID() id.EventID {
	return id.EventID("$" + xid.New().String() + ":" + serverName)
}

// Add puts an event in the timeline; an edit or a redaction changes the message it points at instead.
func (s *Store) Add(evtID id.EventID, room id.RoomID, sender id.UserID, evtType event.Type, content *event.Content, ts time.Time,
	status string) (id.EventID, error) {
	if evtID == "" {
		evtID = newEventID()
	}
	if content.Parsed == nil {
		if content.VeryRaw == nil && content.Raw != nil {
			content.VeryRaw, _ = json.Marshal(content.Raw)
		}
		if content.VeryRaw != nil {
			_ = content.ParseRaw(evtType)
		}
	}
	raw, err := json.Marshal(content)
	if err != nil {
		return "", err
	}
	var target id.EventID
	switch evtType {
	case event.EventRedaction:
		redaction, _ := content.Parsed.(*event.RedactionEventContent)
		if redaction == nil || redaction.Redacts == "" {
			return evtID, nil
		}
		_, err = s.db.Exec(`UPDATE timeline SET deleted=1 WHERE id=?`, redaction.Redacts)
		s.changed("message.deleted", room)
		return evtID, err
	case event.EventReaction:
		if reaction, ok := content.Parsed.(*event.ReactionEventContent); ok {
			target = reaction.RelatesTo.EventID
		}
	case event.EventMessage:
		if message, ok := content.Parsed.(*event.MessageEventContent); ok && message.RelatesTo.GetReplaceID() != "" {
			replacement := message.NewContent
			if replacement == nil {
				replacement = message
			}
			edited, _ := json.Marshal(replacement)
			_, err = s.db.Exec(`UPDATE timeline SET edited=? WHERE id=?`, string(edited), message.RelatesTo.GetReplaceID())
			s.changed("message.upserted", room)
			return evtID, err
		}
	}
	_, err = s.db.Exec(`INSERT INTO timeline (id, room, sender, type, ts, content, target, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (id) DO NOTHING`, evtID, room, sender, evtType.Type, ts.UnixMilli(), string(raw), target, status)
	s.changed("message.upserted", room)
	return evtID, err
}

// SetStatus records how far a message sent from Nook got (PENDING, SUCCESS, FAIL_RETRIABLE, FAIL_PERMANENT).
func (s *Store) SetStatus(evtID id.EventID, status, text string) {
	var room id.RoomID
	if s.db.QueryRow(`SELECT room FROM timeline WHERE id=?`, evtID).Scan(&room) != nil {
		return
	}
	_, _ = s.db.Exec(`UPDATE timeline SET status=?, status_text=? WHERE id=?`, status, text, evtID)
	s.changed("message.upserted", room)
}

func scanStored(row interface{ Scan(...any) error }) (*Stored, error) {
	var e Stored
	var raw, edited string
	var deleted int
	if err := row.Scan(&e.ID, &e.Room, &e.Sender, &e.Type, &e.TS, &raw, &e.Target, &edited, &deleted, &e.Status, &e.StatusText); err != nil {
		return nil, err
	}
	e.Deleted = deleted == 1
	e.Content.VeryRaw = json.RawMessage(raw)
	_ = e.Content.ParseRaw(event.Type{Type: e.Type, Class: event.MessageEventType})
	if edited != "" {
		var content event.MessageEventContent
		if json.Unmarshal([]byte(edited), &content) == nil {
			e.Edited = &content
		}
	}
	return &e, nil
}

const storedColumns = `id, room, sender, type, ts, content, target, edited, deleted, status, status_text`

func (s *Store) Event(evtID id.EventID) (*Stored, error) {
	e, err := scanStored(s.db.QueryRow(`SELECT `+storedColumns+` FROM timeline WHERE id=?`, evtID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return e, err
}

// Messages are the newest messages of a room, newest first.
func (s *Store) Messages(room id.RoomID, limit int) ([]*Stored, error) {
	return s.list(`SELECT `+storedColumns+` FROM timeline WHERE room=? AND type IN ('m.room.message','m.sticker')
		ORDER BY ts DESC LIMIT ?`, room, limit)
}

// Reactions are the emoji on these messages that were not taken back.
func (s *Store) Reactions(targets []id.EventID) (map[id.EventID][]*Stored, error) {
	result := make(map[id.EventID][]*Stored)
	if len(targets) == 0 {
		return result, nil
	}
	args := make([]any, len(targets))
	for i, t := range targets {
		args[i] = t
	}
	list, err := s.list(`SELECT `+storedColumns+` FROM timeline WHERE type='m.reaction' AND deleted=0 AND target IN (?`+
		strings.Repeat(",?", len(targets)-1)+`) ORDER BY ts`, args...)
	for _, e := range list {
		result[e.Target] = append(result[e.Target], e)
	}
	return result, err
}

// Reaction is your own emoji `key` on a message, to take it back.
func (s *Store) Reaction(target id.EventID, sender id.UserID, key string) (*Stored, error) {
	list, err := s.list(`SELECT `+storedColumns+` FROM timeline WHERE type='m.reaction' AND deleted=0 AND target=? AND sender=?`,
		target, sender)
	for _, e := range list {
		if r, ok := e.Content.Parsed.(*event.ReactionEventContent); ok && r.RelatesTo.Key == key {
			return e, err
		}
	}
	return nil, err
}

// NewestMessage is the newest message in a room, to mark it read up to there.
func (s *Store) NewestMessage(room id.RoomID) *Stored {
	list, _ := s.Messages(room, 1)
	if len(list) == 0 {
		return nil
	}
	return list[0]
}

func (s *Store) list(query string, args ...any) ([]*Stored, error) {
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []*Stored
	for rows.Next() {
		e, err := scanStored(rows)
		if err != nil {
			return nil, err
		}
		list = append(list, e)
	}
	return list, rows.Err()
}

// MARK: Media

// PutMedia moves a file into the media folder and gives its mxc:// address.
func (s *Store) PutMedia(from, mime, name string) (id.ContentURIString, error) {
	mediaID := xid.New().String()
	dest := filepath.Join(s.mediaDir, mediaID+mediaExtension(mime, name))
	if err := os.Rename(from, dest); err != nil {
		data, readErr := os.ReadFile(from)
		if readErr != nil {
			return "", err
		}
		if err = os.WriteFile(dest, data, 0o600); err != nil {
			return "", err
		}
		_ = os.Remove(from)
	}
	_, err := s.db.Exec(`INSERT INTO media (id, path, mime, name) VALUES (?, ?, ?, ?)`, mediaID, dest, mime, name)
	return id.ContentURIString("mxc://" + serverName + "/" + mediaID), err
}

func (s *Store) PutMediaBytes(data []byte, mime, name string) (id.ContentURIString, error) {
	tmp, err := os.CreateTemp(s.mediaDir, "upload-*")
	if err != nil {
		return "", err
	}
	_, err = tmp.Write(data)
	tmp.Close()
	if err != nil {
		_ = os.Remove(tmp.Name())
		return "", err
	}
	return s.PutMedia(tmp.Name(), mime, name)
}

// MediaPath is where an mxc:// address of this store is on disk; empty for any other address.
func (s *Store) MediaPath(uri id.ContentURIString) (path, mime, name string) {
	parsed, err := uri.Parse()
	if err != nil || parsed.Homeserver != serverName {
		return "", "", ""
	}
	_ = s.db.QueryRow(`SELECT path, mime, name FROM media WHERE id=?`, parsed.FileID).Scan(&path, &mime, &name)
	return
}

func mediaExtension(mime, name string) string {
	if ext := filepath.Ext(name); ext != "" && len(ext) <= 6 {
		return strings.ToLower(ext)
	}
	switch mime {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "audio/ogg":
		return ".ogg"
	case "audio/mp4", "audio/m4a", "audio/x-m4a":
		return ".m4a"
	case "audio/mpeg":
		return ".mp3"
	}
	return ""
}
