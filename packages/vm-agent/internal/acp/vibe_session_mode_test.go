package acp

import (
	"slices"
	"testing"

	acpsdk "github.com/coder/acp-go-sdk"
)

// vibeAdvertisedModes are the agent names mistral-vibe 2.25.8 advertises as ACP
// session modes (vibe/core/agents/models.py BuiltinAgentName, primary agents).
var vibeAdvertisedModes = []string{"ask", "plan", "accept-edits", "auto-approve"}

// Vibe ignores mode ids it does not advertise, so SAM's own permission-mode
// names must be translated to Vibe's agent names. Sending "bypassPermissions"
// verbatim left every session in "ask", and every tool call was then denied.
func TestVibeSessionModeIDsAreVibeAgentNames(t *testing.T) {
	advertised := vibeAdvertisedModes
	for _, tc := range []struct {
		permissionMode string
		want           string
	}{
		{"bypassPermissions", "auto-approve"},
		{"acceptEdits", "accept-edits"},
		{"plan", "plan"},
		{"default", "ask"},
		{"dontAsk", "ask"},
		{"", "ask"},
	} {
		got, ok := acpSessionModeID("mistral-vibe", tc.permissionMode)
		if !ok || got != tc.want {
			t.Errorf("acpSessionModeID(mistral-vibe, %q) = %q, %v; want %q, true", tc.permissionMode, got, ok, tc.want)
		}
		if !slices.Contains(advertised, got) {
			t.Errorf("mode %q for %q is not a Vibe session mode", got, tc.permissionMode)
		}
	}
}

// Drive the real startup path: the mode Vibe receives is its own agent name,
// for new and restored sessions alike.
func TestVibeStartupSendsVibeSessionMode(t *testing.T) {
	for _, session := range []struct {
		name              string
		previousSessionID string
		wantSessionCall   string
	}{
		{name: "new", wantSessionCall: acpsdk.AgentMethodSessionNew},
		{name: "restored", previousSessionID: "vibe-previous", wantSessionCall: acpsdk.AgentMethodSessionLoad},
	} {
		for _, tc := range []struct {
			permissionMode string
			want           []string
		}{
			{permissionMode: "bypassPermissions", want: []string{"auto-approve"}},
			{permissionMode: "acceptEdits", want: []string{"accept-edits"}},
			{permissionMode: "default", want: []string{"ask"}},
		} {
			t.Run(session.name+"/"+tc.permissionMode, func(t *testing.T) {
				got := startFakeAntigravityAgent(t, "mistral-vibe", &fakeAntigravityACP{noAuthRequired: true, acceptedModes: vibeAdvertisedModes}, session.previousSessionID, tc.permissionMode)
				if got.err != nil {
					t.Fatalf("Vibe startup failed: %v", got.err)
				}
				got.fake.mu.Lock()
				defer got.fake.mu.Unlock()
				if !slices.Equal(got.fake.sessionCalls, []string{session.wantSessionCall}) {
					t.Fatalf("session calls = %v, want [%s]", got.fake.sessionCalls, session.wantSessionCall)
				}
				if !slices.Equal(got.fake.modes, tc.want) {
					t.Fatalf("session modes = %v, want %v", got.fake.modes, tc.want)
				}
			})
		}
	}
}

// Agents without a translation table keep receiving SAM's mode names, and
// default still sends nothing.
func TestOtherAgentsKeepSAMSessionModeNames(t *testing.T) {
	if got, ok := acpSessionModeID("claude-code", "bypassPermissions"); !ok || got != "bypassPermissions" {
		t.Fatalf("claude-code bypassPermissions = %q, %v", got, ok)
	}
	if _, ok := acpSessionModeID("claude-code", "default"); ok {
		t.Fatal("claude-code default must not send a session mode")
	}
}
