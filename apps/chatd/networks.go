package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"github.com/rs/zerolog"
	"go.mau.fi/util/dbutil"
	_ "go.mau.fi/util/dbutil/litestream"
	"gopkg.in/yaml.v3"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/bridgeconfig"
	"maunium.net/go/mautrix/bridgev2/commands"
	"maunium.net/go/mautrix/bridgev2/networkid"

	linkedin "go.mau.fi/mautrix-linkedin/pkg/connector"
	meta "go.mau.fi/mautrix-meta/pkg/connector"
	"go.mau.fi/mautrix-meta/pkg/igconnector"
	signal "go.mau.fi/mautrix-signal/pkg/connector"
	telegram "go.mau.fi/mautrix-telegram/pkg/connector"
	twitter "go.mau.fi/mautrix-twitter/pkg/connector"
)

// Network is one chat app the helper links, run by its own bridgev2 bridge with its own database.
type Network struct {
	// ID is how Nook names it ("local-signal"); App is the word Nook knows the app by in a chat's network field.
	ID   string
	App  string
	Name string
	// Flows are the login flows to offer, best first: a QR code or the app's own website, never a password typed
	// into Nook. Telegram is the exception: like on a new phone, your number, its code and your own 2FA password.
	Flows     []string
	Connector bridgev2.NetworkConnector
	// Configure changes the connector's default settings before it starts; its error says why the network cannot.
	Configure func() error
	Bridge    *bridgev2.Bridge
	Matrix    *LocalMatrix
	// Problem says why the network did not start; it is then shown as unavailable.
	Problem string
}

func allNetworks() []*Network {
	tg := &telegram.TelegramConnector{}
	return []*Network{
		{ID: "local-telegram", App: "telegram", Name: "Telegram", Flows: []string{telegram.LoginFlowIDPhone}, Connector: tg,
			Configure: func() error { return telegramSettings(tg) }},
		{ID: "local-signal", App: "signal", Name: "Signal", Flows: []string{"qr"}, Connector: &signal.SignalConnector{}},
		{ID: "local-instagram", App: "instagram", Name: "Instagram", Flows: []string{igconnector.FlowIDCookies},
			Connector: &igconnector.IGConnector{}},
		{ID: "local-messenger", App: "messenger", Name: "Messenger",
			Flows: []string{meta.FlowIDFacebookCookies, meta.FlowIDMessengerCookies}, Connector: &meta.MetaConnector{}},
		{ID: "local-twitter", App: "twitter", Name: "X", Flows: []string{twitter.LoginFlowIDCookies},
			Connector: &twitter.TwitterConnector{}},
		{ID: "local-linkedin", App: "linkedin", Name: "LinkedIn", Flows: []string{linkedin.FlowIDCookies},
			Connector: &linkedin.LinkedInConnector{}},
	}
}

// telegramSettings gives the Telegram connector the app id and hash this build of Nook comes with (its Info.plist
// keys NookTelegramAPIID and NookTelegramAPIHash, or your own from Settings), which Nook passes in the environment.
func telegramSettings(tg *telegram.TelegramConnector) error {
	id, err := strconv.Atoi(os.Getenv("NOOK_TELEGRAM_API_ID"))
	hash := os.Getenv("NOOK_TELEGRAM_API_HASH")
	if err != nil || id <= 0 || hash == "" {
		return errors.New("Telegram needs an app id and hash from my.telegram.org: this build of Nook has none " +
			"(NookTelegramAPIID and NookTelegramAPIHash in Info.plist)")
	}
	tg.Config.APIID, tg.Config.APIHash = id, hash
	tg.Config.DeviceInfo.DeviceModel = "Nook"
	return nil
}

// bridgeConfig is the same for every network: one local user (you) who may do everything, chats named after the
// person in a private chat, some history on the first sync, and the chats of an account removed when you unlink it.
func bridgeConfig() *bridgeconfig.BridgeConfig {
	cleanup := bridgeconfig.CleanupOnLogout{Private: bridgeconfig.CleanupActionDelete, Relayed: bridgeconfig.CleanupActionDelete,
		SharedNoUsers: bridgeconfig.CleanupActionDelete, SharedHasUsers: bridgeconfig.CleanupActionDelete}
	return &bridgeconfig.BridgeConfig{
		// The connectors add their chat commands to the bridge bot; nothing Nook sends ever starts like this.
		CommandPrefix:         "\x00nook",
		PrivateChatPortalMeta: true,
		CleanupOnLogout:       bridgeconfig.CleanupOnLogouts{Enabled: true, Manual: cleanup},
		Permissions: bridgeconfig.PermissionConfig{
			"*": &bridgeconfig.Permissions{SendEvents: true, Login: true, DoublePuppet: true, Admin: true},
		},
		Backfill: bridgeconfig.BackfillConfig{
			Enabled: true, MaxInitialMessages: 50, MaxCatchupMessages: 500, UnreadHoursThreshold: 720,
		},
	}
}

// Start opens the network's database, loads its connector's default settings and starts its linked accounts.
func (n *Network) Start(ctx context.Context, dir string, store *Store, log zerolog.Logger) error {
	log = log.With().Str("network", n.App).Logger()
	if example, data, _ := n.Connector.GetConfig(); data != nil && example != "" {
		if err := yaml.Unmarshal([]byte(example), data); err != nil {
			return fmt.Errorf("default settings: %w", err)
		}
	}
	if n.Configure != nil {
		if err := n.Configure(); err != nil {
			return err
		}
	}
	db, err := dbutil.NewWithDialect("file:"+filepath.Join(dir, n.App+".db")+"?_txlock=immediate", "sqlite3-fk-wal")
	if err != nil {
		return err
	}
	db.Log = dbutil.ZeroLogger(log.With().Str("db", n.App).Logger())
	n.Matrix = NewLocalMatrix(n, store)
	n.Bridge = bridgev2.NewBridge(networkid.BridgeID(n.ID), db, log, bridgeConfig(), n.Matrix, n.Connector,
		func(br *bridgev2.Bridge) bridgev2.CommandProcessor { return commands.NewProcessor(br) })
	return n.Bridge.Start(ctx)
}

// User is you, as this network's bridge knows you.
func (n *Network) User(ctx context.Context) (*bridgev2.User, error) {
	return n.Bridge.GetUserByMXID(ctx, me)
}
