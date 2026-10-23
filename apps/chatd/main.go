// nook-chatd links Telegram, Signal, Messenger, Instagram, X and LinkedIn for Nook, on this Mac, without Beeper. It runs
// the mautrix bridgev2 network connectors with no Matrix server behind them: their rooms and messages are kept in a local
// database, and Nook reads them through a small API on 127.0.0.1 (see api.go). Nook starts it as a child process and it
// stops when Nook does. See docs/ADR-CHAT-LINKS.md.
//
// Copyright (c) 2026 Michan van der Hoek. Licensed under the GNU Affero General Public License v3.0 (see LICENSE),
// because it is built on the mautrix connectors, which are under that license.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/rs/zerolog"
)

var version = "dev"

func main() {
	addr := flag.String("addr", "127.0.0.1:29373", "where the API listens (loopback only)")
	dataDir := flag.String("data", "", "where the chats and the linked accounts are kept")
	showVersion := flag.Bool("version", false, "print the version and stop")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	log := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, NoColor: true, TimeFormat: time.RFC3339}).With().Timestamp().Logger()
	if os.Getenv("NOOK_CHATD_DEBUG") == "" {
		log = log.Level(zerolog.InfoLevel)
	}
	token := os.Getenv("NOOK_CHATD_TOKEN")
	if len(token) < 24 {
		log.Fatal().Msg("NOOK_CHATD_TOKEN is missing or too short")
	}
	host, _, err := net.SplitHostPort(*addr)
	if err != nil || (host != "127.0.0.1" && host != "::1" && host != "localhost") {
		log.Fatal().Str("addr", *addr).Msg("the API only listens on this Mac (127.0.0.1)")
	}
	if *dataDir == "" {
		home, _ := os.UserHomeDir()
		*dataDir = filepath.Join(home, "Library", "Application Support", "Nook", "ChatHelper")
	}
	if err = os.MkdirAll(*dataDir, 0o700); err != nil {
		log.Fatal().Err(err).Msg("cannot create the data folder")
	}

	store, err := OpenStore(*dataDir)
	if err != nil {
		log.Fatal().Err(err).Msg("cannot open the chats database")
	}
	live := NewHub()
	store.changed = live.Changed

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go watchParent(stop)

	nets := allNetworks()
	var starting sync.WaitGroup
	for _, n := range nets {
		starting.Add(1)
		go func() {
			defer starting.Done()
			if err := n.Start(ctx, *dataDir, store, log); err != nil {
				n.Problem = err.Error()
				log.Err(err).Str("network", n.App).Msg("network did not start")
			}
		}()
	}
	starting.Wait()

	api := NewAPI(token, store, nets, live, log, version)
	server := &http.Server{Addr: *addr, Handler: api.Handler(), ReadHeaderTimeout: 10 * time.Second}
	listener, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal().Err(err).Msg("cannot listen")
	}
	log.Info().Str("addr", *addr).Str("version", version).Msg("nook-chatd ready")
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Err(err).Msg("API stopped")
			stop()
		}
	}()

	<-ctx.Done()
	log.Info().Msg("stopping")
	shutdown, done := context.WithTimeout(context.Background(), 5*time.Second)
	defer done()
	_ = server.Shutdown(shutdown)
	for _, n := range nets {
		if n.Bridge != nil {
			n.Bridge.StopWithTimeout(5 * time.Second)
		}
	}
}

// watchParent stops the helper once Nook, which started it, is gone.
func watchParent(stop func()) {
	parent := os.Getppid()
	for range time.Tick(2 * time.Second) {
		if os.Getppid() != parent {
			stop()
			return
		}
	}
}
