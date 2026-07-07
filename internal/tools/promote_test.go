package tools

import (
	"os"
	"testing"
)

// validationState is the gate promote-image uses to refuse promoting an image
// that did not pass validation. It must map the recorded state files exactly.
func TestValidationState(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("IMOGEN_VALIDATE_STATE_DIR", dir)

	write := func(flavor, version, log, done string) {
		logPath, donePath := validateStatePaths(flavor, version)
		if log != "" {
			if err := os.WriteFile(logPath, []byte(log), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if done != "" {
			if err := os.WriteFile(donePath, []byte(done), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}

	// No files at all.
	if got := validationState("ubuntu-2404", "1.34.9"); got != "NotFound" {
		t.Errorf("no state: got %q, want NotFound", got)
	}

	// Log but no done: still running (or queued).
	write("ubuntu-2404", "1.35.6", "Queued for validation\n", "")
	if got := validationState("ubuntu-2404", "1.35.6"); got != "Running" {
		t.Errorf("running: got %q, want Running", got)
	}

	// Done with exit 0: succeeded.
	write("ubuntu-2404", "1.36.2", "ok\n", "0\n")
	if got := validationState("ubuntu-2404", "1.36.2"); got != "Succeeded" {
		t.Errorf("succeeded: got %q, want Succeeded", got)
	}

	// Done with nonzero exit: failed (the promote gate must block this).
	write("windows-2022-containerd", "1.34.9", "FAIL\n", "1\n")
	if got := validationState("windows-2022-containerd", "1.34.9"); got != "Failed" {
		t.Errorf("failed: got %q, want Failed", got)
	}
}
