package main

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/rs/xid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/status"
)

// A login session walks one account through its network's login steps, the way Nook's Settings › Chats shows them:
// fields to fill in, the app's website to sign in on, or a QR code to scan. One step runs at a time; asking for a
// step that is already running waits for the same result.
type LoginSession struct {
	ID      string
	Network *Network

	mu      sync.Mutex
	process bridgev2.LoginProcess
	step    *bridgev2.LoginStep
	state   string
	problem string
	running chan struct{}
	ctx     context.Context
	cancel  context.CancelFunc
}

type Logins struct {
	mu       sync.Mutex
	sessions map[string]*LoginSession
}

func NewLogins() *Logins { return &Logins{sessions: make(map[string]*LoginSession)} }

func (l *Logins) Get(id string) *LoginSession {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sessions[id]
}

// Start begins a login with the network's best flow and waits for its first step.
func (l *Logins) Start(ctx context.Context, net *Network) (*LoginSession, error) {
	user, err := net.User(ctx)
	if err != nil {
		return nil, err
	}
	flows := net.Connector.GetLoginFlows()
	flow := ""
	for _, wanted := range net.Flows {
		if slices.ContainsFunc(flows, func(f bridgev2.LoginFlow) bool { return f.ID == wanted }) {
			flow = wanted
			break
		}
	}
	if flow == "" {
		return nil, errors.New(net.Name + " offers no login Nook can show")
	}
	process, err := net.Connector.CreateLogin(ctx, user, flow)
	if err != nil {
		return nil, err
	}
	sessionCtx, cancel := context.WithTimeout(net.Bridge.BackgroundCtx, 30*time.Minute)
	session := &LoginSession{ID: xid.New().String(), Network: net, process: process, ctx: sessionCtx, cancel: cancel}
	l.mu.Lock()
	l.sessions[session.ID] = session
	l.mu.Unlock()
	go func() {
		<-sessionCtx.Done()
		time.AfterFunc(10*time.Minute, func() {
			l.mu.Lock()
			delete(l.sessions, session.ID)
			l.mu.Unlock()
		})
	}()
	step, err := process.Start(sessionCtx)
	session.finish(step, err)
	return session, nil
}

// Submit answers the current step (its fields, the cookies the sign-in window collected, or waiting for a scan) and
// returns once the next step is there or `wait` passed; the session then still shows the step it is on.
func (s *LoginSession) Submit(stepID, kind string, fields map[string]string, wait time.Duration) error {
	s.mu.Lock()
	if s.step == nil || s.state == "complete" || s.state == "failed" || s.state == "cancelled" {
		s.mu.Unlock()
		return errors.New("this login is over")
	}
	if s.step.StepID != stepID || string(s.step.Type) != kind {
		s.mu.Unlock()
		return errors.New("this step is not the current one")
	}
	running := s.running
	if running == nil {
		running = make(chan struct{})
		s.running = running
		step := s.step
		go s.run(step, fields, running)
	}
	s.mu.Unlock()
	select {
	case <-running:
	case <-time.After(wait):
	}
	return nil
}

func (s *LoginSession) run(step *bridgev2.LoginStep, fields map[string]string, done chan struct{}) {
	var next *bridgev2.LoginStep
	var err error
	defer func() {
		if recovered := recover(); recovered != nil {
			err = errors.New("the login stopped unexpectedly")
		}
		s.finish(next, err)
		close(done)
	}()
	switch step.Type {
	case bridgev2.LoginStepTypeUserInput:
		next, err = s.process.(bridgev2.LoginProcessUserInput).SubmitUserInput(s.ctx, fields)
	case bridgev2.LoginStepTypeCookies:
		next, err = s.process.(bridgev2.LoginProcessCookies).SubmitCookies(s.ctx, fields)
	case bridgev2.LoginStepTypeDisplayAndWait:
		next, err = s.process.(bridgev2.LoginProcessDisplayAndWait).Wait(s.ctx)
	default:
		err = errors.New("Nook cannot show this login step")
	}
}

func (s *LoginSession) finish(next *bridgev2.LoginStep, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.running = nil
	if s.state == "cancelled" {
		return
	}
	switch {
	case err != nil:
		s.state = "failed"
		s.problem = err.Error()
		s.cancel()
	case next == nil:
		s.state = "failed"
		s.problem = "the login gave no next step"
		s.cancel()
	default:
		s.step = next
		s.problem = ""
		switch next.Type {
		case bridgev2.LoginStepTypeUserInput:
			s.state = "waiting_for_input"
		case bridgev2.LoginStepTypeCookies:
			s.state = "waiting_for_cookies"
		case bridgev2.LoginStepTypeDisplayAndWait:
			s.state = "waiting_for_display"
		case bridgev2.LoginStepTypeComplete:
			s.state = "complete"
			s.cancel()
		default:
			s.state = "failed"
			s.problem = "Nook cannot show this login step"
			s.process.Cancel()
			s.cancel()
		}
	}
}

func (s *LoginSession) Cancel() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == "complete" || s.state == "failed" || s.state == "cancelled" {
		return
	}
	s.state = "cancelled"
	s.process.Cancel()
	s.cancel()
}

// JSON is the session the way Nook reads it (ChatLinkData.session).
func (s *LoginSession) JSON() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]any{"loginSessionID": s.ID, "bridgeID": s.Network.ID, "status": s.state}
	if s.step != nil {
		out["currentStep"] = stepJSON(s.step)
	}
	if s.problem != "" {
		out["error"] = map[string]any{"message": s.problem}
	}
	return out
}

func stepJSON(step *bridgev2.LoginStep) map[string]any {
	out := map[string]any{"type": string(step.Type), "stepID": step.StepID, "instructions": step.Instructions}
	switch {
	case step.UserInputParams != nil:
		fields := make([]map[string]any, 0, len(step.UserInputParams.Fields))
		for _, f := range step.UserInputParams.Fields {
			fields = append(fields, map[string]any{"id": f.ID, "label": f.Name, "placeholder": f.Description,
				"type": string(f.Type), "initialValue": f.DefaultValue, "optional": f.Optional})
		}
		out["fields"] = fields
	case step.CookiesParams != nil:
		params := step.CookiesParams
		fields := make([]map[string]any, 0, len(params.Fields))
		for _, f := range params.Fields {
			if len(f.Sources) == 0 {
				continue
			}
			source := f.Sources[0]
			kind := string(source.Type)
			switch source.Type {
			case bridgev2.LoginCookieTypeRequestHeader:
				kind = "header"
			case bridgev2.LoginCookieTypeSpecial:
				// Found by the step's own script in the page (Slack's token in its local settings), by the field's id.
				kind = "special"
			}
			fields = append(fields, map[string]any{"id": f.ID, "type": kind, "name": source.Name, "domain": source.CookieDomain,
				"requestURLRegex": source.RequestURLRegex, "required": f.Required, "pattern": f.Pattern})
		}
		out["fields"] = fields
		out["url"] = params.URL
		if params.UserAgent != "" {
			out["userAgent"] = params.UserAgent
		}
		if params.WaitForURLPattern != "" {
			out["expectedFinalURLRegex"] = params.WaitForURLPattern
		}
		if params.ExtractJS != "" {
			out["extractJS"] = params.ExtractJS
		}
	case step.DisplayAndWaitParams != nil:
		out["display"] = map[string]any{"type": string(step.DisplayAndWaitParams.Type), "data": step.DisplayAndWaitParams.Data,
			"imageURL": step.DisplayAndWaitParams.ImageURL}
	}
	return out
}

// MARK: Networks and accounts

// bridgesJSON lists the networks and their linked accounts the way Nook reads them (ChatLinkData.networks).
func bridgesJSON(ctx context.Context, nets []*Network) map[string]any {
	items := make([]map[string]any, 0, len(nets))
	for _, net := range nets {
		item := map[string]any{"id": net.ID, "type": net.App, "network": net.App, "displayName": net.Name, "provider": "local",
			"status": "available", "accounts": []map[string]any{}}
		if net.Problem != "" || net.Bridge == nil {
			item["status"] = "unavailable"
			item["statusText"] = net.Problem
			items = append(items, item)
			continue
		}
		var accounts []map[string]any
		if user, err := net.User(ctx); err == nil {
			for _, login := range user.GetUserLogins() {
				accounts = append(accounts, accountJSON(net, login))
			}
		}
		if accounts != nil {
			item["accounts"] = accounts
		}
		items = append(items, item)
	}
	return map[string]any{"items": items}
}

func accountJSON(net *Network, login *bridgev2.UserLogin) map[string]any {
	profile := login.RemoteProfile
	name := profile.Name
	if name == "" {
		name = login.RemoteName
	}
	state, known := net.Matrix.State(login.ID)
	text := strings.ToLower(string(state.StateEvent))
	statusText := state.Message
	switch state.StateEvent {
	case status.StateConnected:
		text = "connected"
	case status.StateConnecting, status.StateBackfilling, status.StateStarting:
		text = "connecting"
	case "":
		text = "connecting"
	}
	if !known {
		text = "connecting"
	}
	return map[string]any{
		"accountID": net.ID + ":" + string(login.ID),
		"loginID":   string(login.ID),
		"network":   net.App,
		"user": map[string]any{"fullName": name, "username": profile.Username, "phoneNumber": profile.Phone,
			"email": profile.Email},
		"status":     text,
		"statusText": statusText,
	}
}
