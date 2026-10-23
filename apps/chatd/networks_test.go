package main

import (
	"testing"

	telegram "go.mau.fi/mautrix-telegram/pkg/connector"
)

func TestTelegramSettings(t *testing.T) {
	t.Setenv("NOOK_TELEGRAM_API_ID", "")
	t.Setenv("NOOK_TELEGRAM_API_HASH", "")
	if err := telegramSettings(&telegram.TelegramConnector{}); err == nil {
		t.Fatal("no app id and hash should make Telegram unavailable")
	}
	t.Setenv("NOOK_TELEGRAM_API_ID", "123")
	t.Setenv("NOOK_TELEGRAM_API_HASH", "abc")
	tg := &telegram.TelegramConnector{}
	if err := telegramSettings(tg); err != nil {
		t.Fatal(err)
	}
	if tg.Config.APIID != 123 || tg.Config.APIHash != "abc" {
		t.Fatalf("got %d %q", tg.Config.APIID, tg.Config.APIHash)
	}
}
