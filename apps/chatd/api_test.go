package main

import (
	"regexp"
	"strings"
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

func TestTagNeverMatchesInsideAPill(t *testing.T) {
	// The id of the first pill holds the second name: it must stay a link, not get a second link inside it.
	content := &event.MessageEventContent{MsgType: event.MsgText, Body: "@Anna Bakker @bob:nook"}
	tag(content, []mention{{ID: "@bob:nook", Name: "Anna Bakker"}, {ID: "@evil:nook", Name: "bob:nook"}})
	want := `<a href="https://matrix.to/#/@bob:nook">Anna Bakker</a> <a href="https://matrix.to/#/@evil:nook">bob:nook</a>`
	if content.FormattedBody != want {
		t.Fatalf("formatted body = %q", content.FormattedBody)
	}
}

// pill is the only markup tag writes besides <br>.
var pill = regexp.MustCompile(`<a href="https://matrix\.to/#/[^"<>]*">[^<>]*</a>`)

// FuzzTag checks that no message text, name or id gets markup into the HTML outside the pills tag writes itself.
// CI runs it for a short while on every change to nook-chatd (chatd.yml); run it longer with
// `go test -run=^$ -fuzz=FuzzTag -fuzztime=5m`.
func FuzzTag(f *testing.F) {
	f.Add("Hi @Anna Bakker & @Anna\nbye", "@a:nook.local", "Anna", "@b:nook.local", "Anna Bakker")
	f.Add("@Anna Bakker @bob:nook", "@bob:nook", "Anna Bakker", "@evil:nook", "bob:nook")
	f.Add("<b>@x</b>", "@x\n:nook", "x", "", "")
	f.Fuzz(func(t *testing.T, body, id1, name1, id2, name2 string) {
		content := &event.MessageEventContent{MsgType: event.MsgText, Body: body}
		tag(content, []mention{{ID: id1, Name: name1}, {ID: id2, Name: name2}})
		rest := strings.ReplaceAll(pill.ReplaceAllString(content.FormattedBody, ""), "<br>", "")
		if strings.ContainsAny(rest, "<>") {
			t.Fatalf("markup outside the pills: %q", content.FormattedBody)
		}
	})
}
