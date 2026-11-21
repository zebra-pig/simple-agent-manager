package persistence

import (
	"database/sql"
	"errors"
	"testing"
)

func TestPromptDeliveryReceiptDuplicateLostResponseAndRestartDurability(t *testing.T) {
	dbPath := tempDBPath(t)
	store, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	receipt, created, conflict, err := store.AcceptPromptDelivery("ws", "session", "delivery-1", 1, "hash-a")
	if err != nil || !created || conflict || receipt.State != PromptReceiptAccepted {
		t.Fatalf("accept = %+v created=%v conflict=%v err=%v", receipt, created, conflict, err)
	}
	claimed, won, err := store.ClaimPromptDelivery("ws", "session", "delivery-1", "runtime-a")
	if err != nil || !won || claimed.State != PromptReceiptInFlight {
		t.Fatalf("claim = %+v won=%v err=%v", claimed, won, err)
	}
	_, won, err = store.ClaimPromptDelivery("ws", "session", "delivery-1", "runtime-a")
	if err != nil || won {
		t.Fatalf("duplicate claim won=%v err=%v", won, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	reconciled, err := reopened.GetPromptDelivery("ws", "session", "delivery-1", "runtime-b")
	if err != nil || reconciled.State != PromptReceiptAmbiguous || reconciled.errorCode != "runtime_changed_after_invocation_claim" {
		t.Fatalf("reconciled = %+v err=%v", reconciled, err)
	}
	_, created, conflict, err = reopened.AcceptPromptDelivery("ws", "session", "delivery-1", 1, "hash-a")
	if err != nil || created || conflict {
		t.Fatalf("same-ID replay created=%v conflict=%v err=%v", created, conflict, err)
	}
	_, created, conflict, err = reopened.AcceptPromptDelivery("ws", "session", "delivery-1", 1, "hash-b")
	if err != nil || created || !conflict {
		t.Fatalf("conflicting replay created=%v conflict=%v err=%v", created, conflict, err)
	}
}

func TestPromptDeliveryCompletedReceiptNeverClaimsAgain(t *testing.T) {
	store, err := Open(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, _, _, _ = store.AcceptPromptDelivery("ws", "session", "delivery", 1, "hash")
	_, won, err := store.ClaimPromptDelivery("ws", "session", "delivery", "runtime")
	if err != nil || !won {
		t.Fatalf("claim won=%v err=%v", won, err)
	}
	if err := store.CompletePromptDelivery("ws", "session", "delivery", "runtime", "end_turn", ""); err != nil {
		t.Fatal(err)
	}
	receipt, err := store.GetPromptDelivery("ws", "session", "delivery", "runtime")
	if err != nil || receipt.State != PromptReceiptCompleted || receipt.stopReason != "end_turn" || receipt.CompletedAt == nil {
		t.Fatalf("receipt = %+v err=%v", receipt, err)
	}
	_, won, err = store.ClaimPromptDelivery("ws", "session", "delivery", "runtime")
	if err != nil || won {
		t.Fatalf("completed receipt claimed again: won=%v err=%v", won, err)
	}
}

func TestCheckpointOperationIsIdempotentAndInterruptedRuntimeFailsExplicitly(t *testing.T) {
	store, err := Open(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	op, created, conflict, err := store.AcceptCheckpointRollover("ws", "session", "op-1", 1, "hash")
	if err != nil || !created || conflict || op.State != RolloverAccepted {
		t.Fatalf("accept = %+v created=%v conflict=%v err=%v", op, created, conflict, err)
	}
	_, started, err := store.StartCheckpointRollover("ws", "session", "op-1", "runtime-a")
	if err != nil || !started {
		t.Fatalf("start=%v err=%v", started, err)
	}
	reconciled, err := store.GetCheckpointRollover("ws", "session", "op-1", "runtime-b")
	if err != nil || reconciled.State != RolloverFailed || reconciled.ErrorCode != "vm_runtime_interrupted" {
		t.Fatalf("reconciled = %+v err=%v", reconciled, err)
	}
	_, created, conflict, err = store.AcceptCheckpointRollover("ws", "session", "op-1", 1, "different")
	if err != nil || created || !conflict {
		t.Fatalf("conflict created=%v conflict=%v err=%v", created, conflict, err)
	}
}

func TestDeleteWorkspaceExecutionProtocolRemovesOnlyTargetWorkspaceLedgers(t *testing.T) {
	store, err := Open(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for _, workspaceID := range []string{"ws-delete", "ws-keep"} {
		if _, _, _, err := store.AcceptPromptDelivery(workspaceID, "session", "delivery", 1, "hash"); err != nil {
			t.Fatal(err)
		}
		if _, _, _, err := store.AcceptCheckpointRollover(workspaceID, "session", "operation", 1, "hash"); err != nil {
			t.Fatal(err)
		}
		if _, _, _, err := store.AcceptSteerDelivery(workspaceID, "session", "steer", 1, "hash", "runtime"); err != nil {
			t.Fatal(err)
		}
	}

	if err := store.DeleteWorkspaceExecutionProtocol("ws-delete"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetPromptDelivery("ws-delete", "session", "delivery", "runtime"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("deleted prompt receipt err = %v, want sql.ErrNoRows", err)
	}
	if _, err := store.GetCheckpointRollover("ws-delete", "session", "operation", "runtime"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("deleted rollover err = %v, want sql.ErrNoRows", err)
	}
	if _, err := store.GetPromptDelivery("ws-keep", "session", "delivery", "runtime"); err != nil {
		t.Fatalf("unrelated prompt receipt removed: %v", err)
	}
	if _, err := store.GetCheckpointRollover("ws-keep", "session", "operation", "runtime"); err != nil {
		t.Fatalf("unrelated rollover removed: %v", err)
	}
	if _, err := store.GetSteerDelivery("ws-delete", "session", "steer", "runtime"); !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("deleted steer receipt err = %v, want sql.ErrNoRows", err)
	}
	if _, err := store.GetSteerDelivery("ws-keep", "session", "steer", "runtime"); err != nil {
		t.Fatalf("unrelated steer receipt removed: %v", err)
	}
}

// The control plane stores a receipt's acceptedAt as the turn's promptStartedAt
// and passes it back to guarded interrupts. The VM compares the attempt's own
// start, so the claim must replace the earlier accept-time clock read with it.
func TestClaimPromptDeliveryAtCarriesPromptEpoch(t *testing.T) {
	store, err := Open(tempDBPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	accepted, _, _, err := store.AcceptPromptDelivery("ws", "session", "delivery-1", 1, "hash")
	if err != nil || accepted.AcceptedAt == nil {
		t.Fatalf("accept = %+v err=%v", accepted, err)
	}
	epoch := *accepted.AcceptedAt + 37
	claimed, won, err := store.ClaimPromptDeliveryAt("ws", "session", "delivery-1", "runtime", epoch)
	if err != nil || !won || claimed.AcceptedAt == nil || *claimed.AcceptedAt != epoch {
		t.Fatalf("claim = %+v won=%v err=%v, want acceptedAt %d", claimed, won, err, epoch)
	}
	reread, err := store.GetPromptDelivery("ws", "session", "delivery-1", "runtime")
	if err != nil || reread.AcceptedAt == nil || *reread.AcceptedAt != epoch {
		t.Fatalf("duplicate lookup = %+v err=%v, want acceptedAt %d", reread, err, epoch)
	}

	// Without an epoch (agent start: the prompt begins after the agent boots),
	// the accept-time value stays.
	first, _, _, err := store.AcceptPromptDelivery("ws", "session", "delivery-2", 1, "hash")
	if err != nil {
		t.Fatal(err)
	}
	claimed, won, err = store.ClaimPromptDelivery("ws", "session", "delivery-2", "runtime")
	if err != nil || !won || claimed.AcceptedAt == nil || *claimed.AcceptedAt != *first.AcceptedAt {
		t.Fatalf("claim without epoch = %+v won=%v err=%v", claimed, won, err)
	}
}
