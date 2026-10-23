package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"maunium.net/go/mautrix/id"
)

// Hub is the live line (/v1/ws): it tells every connected Nook which chat changed, the moment it changes. Nook then
// reads that chat again. Like Beeper's: "ready" first, then events once Nook subscribed.
type Hub struct {
	mu      sync.Mutex
	clients map[*client]struct{}
}

type client struct {
	out        chan []byte
	subscribed bool
}

func NewHub() *Hub { return &Hub{clients: make(map[*client]struct{})} }

// Changed is called by the store for every change; a burst on one chat goes out once per short moment.
func (h *Hub) Changed(kind string, room id.RoomID) {
	message, _ := json.Marshal(map[string]any{"type": kind, "chatID": string(room)})
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		if !c.subscribed {
			continue
		}
		select {
		case c.out <- message:
		default:
			// A Nook that cannot keep up reads everything again when its line drops.
		}
	}
}

func (h *Hub) Serve(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	c := &client{out: make(chan []byte, 256)}
	h.mu.Lock()
	h.clients[c] = struct{}{}
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.clients, c)
		h.mu.Unlock()
	}()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		defer cancel()
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var request struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(data, &request) == nil && request.Type == "subscriptions.set" {
				h.mu.Lock()
				c.subscribed = true
				h.mu.Unlock()
				c.out <- []byte(`{"type":"subscriptions.updated"}`)
			}
		}
	}()
	if conn.Write(ctx, websocket.MessageText, []byte(`{"type":"ready"}`)) != nil {
		return
	}
	for {
		select {
		case <-ctx.Done():
			return
		case message := <-c.out:
			writeCtx, done := context.WithTimeout(ctx, 10*time.Second)
			err := conn.Write(writeCtx, websocket.MessageText, message)
			done()
			if err != nil {
				return
			}
		}
	}
}
