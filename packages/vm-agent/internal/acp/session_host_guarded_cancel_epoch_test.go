package acp

import (
	"context"
	"encoding/json"
	"testing"
)

// Regression (FilmKit, 2026-11-21): every guarded interrupt of a long
// control-plane-delivered turn returned turn_changed. The control plane offered
// the receipt's accept time as promptStartedAt, read before AcceptPrompt took
// the attempt's own start. The epoch a caller can learn (the accepted prompt's
// StartedAt, now the receipt's acceptedAt, and the activity report's
// promptStartedAt) must be exactly the one CancelPromptGuarded accepts.
func TestAcceptedPromptEpochIsTheGuardedCancelToken(t *testing.T) {
	host, _ := newPromptRetryTestHost(t, promptRetryScript{})
	host.config.ProjectID = "project-1"
	host.config.NodeID = "node-1"
	host.config.ControlPlaneURL = "http://control-plane.invalid"

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	accepted, ok := host.AcceptPrompt(ctx, json.RawMessage(`1`), promptRetryParams(),
		"control-plane", false, "delivery-1", nil)
	if !ok {
		t.Fatal("prompt was not accepted")
	}
	epoch := accepted.StartedAt()
	if epoch <= 0 {
		t.Fatalf("StartedAt = %d", epoch)
	}

	report, ok := host.prepareActivityReport("prompting")
	if !ok || report.payload.PromptStartedAt == nil || *report.payload.PromptStartedAt != epoch {
		t.Fatalf("activity report promptStartedAt = %v, want %d", report.payload.PromptStartedAt, epoch)
	}

	// An epoch read even one millisecond earlier names no turn on this VM.
	if got := host.CancelPromptGuarded(epoch - 1); got != "turn_changed" {
		t.Fatalf("earlier epoch: got %s, want turn_changed", got)
	}
	if got := host.CancelPromptGuarded(epoch); got != "cancelled" {
		t.Fatalf("reported epoch: got %s, want cancelled", got)
	}
	if accepted.attempt.ctx.Err() == nil {
		t.Fatal("matching prompt context was not cancelled")
	}
	accepted.Abort(context.Canceled)
}
