package main

import (
	"testing"

	"maunium.net/go/mautrix/event"
)

func TestTagMakesPillsOfMentions(t *testing.T) {
	content := &event.MessageEventContent{MsgType: event.MsgText, Body: "Hi @Anna Bakker & @Anna\nbye"}
	tag(content, []mention{{ID: "@whatsapp_31611111111:nook.local", Name: "Anna"},
		{ID: "@whatsapp_31622222222:nook.local", Name: "Anna Bakker"}, {ID: "@x:nook.local", Name: "Bob"}})
	want := `Hi <a href="https://matrix.to/#/@whatsapp_31622222222:nook.local">Anna Bakker</a> &amp; ` +
		`<a href="https://matrix.to/#/@whatsapp_31611111111:nook.local">Anna</a><br>bye`
	if content.FormattedBody != want || content.Format != event.FormatHTML {
		t.Fatalf("formatted body = %q", content.FormattedBody)
	}
	if content.Mentions == nil || len(content.Mentions.UserIDs) != 2 {
		t.Fatalf("mentions = %v", content.Mentions)
	}

	plain := &event.MessageEventContent{MsgType: event.MsgText, Body: "no tags"}
	tag(plain, []mention{{ID: "@x:nook.local", Name: "Bob"}})
	if plain.FormattedBody != "" || plain.Mentions != nil {
		t.Fatal("a text without tags stays plain")
	}
}
