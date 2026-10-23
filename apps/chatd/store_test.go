package main

import (
	"testing"
	"time"

	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

func TestStoreTimeline(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var changes []string
	store.changed = func(kind string, room id.RoomID) { changes = append(changes, kind) }
	room := id.RoomID("!r:" + serverName)
	friend := id.UserID("@signal_friend:" + serverName)
	start := time.UnixMilli(1_000_000)
	if err = store.CreateRoom(room, "local-signal", "Friend", "", true, start); err != nil {
		t.Fatal(err)
	}
	store.SetMember(room, friend, event.MembershipJoin, "", "")
	name := "Friend Person"
	store.SetProfile(friend, &name, nil)

	text := func(body string) *event.Content {
		return &event.Content{Parsed: &event.MessageEventContent{MsgType: event.MsgText, Body: body}}
	}
	first, _ := store.Add("", room, friend, event.EventMessage, text("hello"), start.Add(time.Second), "")
	_, _ = store.Add("", room, friend, event.EventMessage, text("there"), start.Add(2*time.Second), "")
	mine, _ := store.Add("", room, me, event.EventMessage, text("hi"), start.Add(3*time.Second), string(event.MessageStatusPending))

	r, _ := store.Room(me, room)
	if r.Unread != 2 || r.LastTS != start.Add(3*time.Second).UnixMilli() {
		t.Fatalf("unread %d, last %d", r.Unread, r.LastTS)
	}
	store.MarkRead(room, start.Add(3*time.Second).UnixMilli())
	if r, _ = store.Room(me, room); r.Unread != 0 {
		t.Fatalf("read chat still has %d unread", r.Unread)
	}

	// An edit changes the message it points at and adds nothing to the timeline.
	edit := &event.MessageEventContent{MsgType: event.MsgText, Body: "* hello!", NewContent: &event.MessageEventContent{MsgType: event.MsgText, Body: "hello!"}}
	edit.RelatesTo = (&event.RelatesTo{}).SetReplace(first)
	_, _ = store.Add("", room, friend, event.EventMessage, &event.Content{Parsed: edit}, start.Add(4*time.Second), "")
	list, _ := store.Messages(room, 10)
	if len(list) != 3 {
		t.Fatalf("%d messages, want 3", len(list))
	}
	stored, _ := store.Event(first)
	if stored.Edited == nil || stored.Edited.Body != "hello!" {
		t.Fatalf("edit not applied: %+v", stored.Edited)
	}

	// A reaction belongs to its message; taking it back removes it.
	reaction := &event.ReactionEventContent{RelatesTo: event.RelatesTo{Type: event.RelAnnotation, EventID: first, Key: "👍"}}
	_, _ = store.Add("", room, me, event.EventReaction, &event.Content{Parsed: reaction}, start.Add(5*time.Second), "")
	found, _ := store.Reaction(first, me, "👍")
	if found == nil {
		t.Fatal("reaction not found")
	}
	_, _ = store.Add("", room, me, event.EventRedaction, &event.Content{Parsed: &event.RedactionEventContent{Redacts: found.ID}}, time.Now(), "")
	if reactions, _ := store.Reactions([]id.EventID{first}); len(reactions[first]) != 0 {
		t.Fatal("reaction still there after it was taken back")
	}

	// The send status of your own message follows what the bridge reports.
	store.SetStatus(mine, string(event.MessageStatusSuccess), "")
	if stored, _ = store.Event(mine); stored.Status != string(event.MessageStatusSuccess) {
		t.Fatalf("status %q", stored.Status)
	}

	members, _ := store.Members(room)
	if len(members) != 1 || members[0].Name != "Friend Person" {
		t.Fatalf("members %+v", members)
	}
	if len(changes) == 0 {
		t.Fatal("no change was told to the live line")
	}
}

func TestGhostIDsRoundTrip(t *testing.T) {
	m := NewLocalMatrix(&Network{ID: "local-x", App: "twitter"}, nil)
	for _, user := range []string{"12345", "urn:li:fsd_profile:ABC", "Upper_Case.id"} {
		mxid := m.FormatGhostMXID(networkid.UserID(user))
		back, ok := m.ParseGhostMXID(mxid)
		if !ok || string(back) != user {
			t.Fatalf("%s -> %s -> %s", user, mxid, back)
		}
	}
	if _, ok := m.ParseGhostMXID(me); ok {
		t.Fatal("you are not a ghost")
	}
}
