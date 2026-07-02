package tools

import (
	"context"
	"os"
	"strconv"
	"time"
)

// defaultPollDelaySeconds throttles the status-polling tools. The agent polls
// get-build-status, get-validation-status and get-promote-status in a tight
// loop while a long-running build, validation or promotion is in flight, and
// each poll is a full LLM turn that resends the growing conversation. Left
// unthrottled that loop can exhaust the Azure OpenAI deployment's tokens-per-
// minute quota and fail the run with a 429. The model cannot pace itself (it
// has no way to sleep and just calls again immediately), so the pacing lives
// here: each status poll blocks for this many seconds before returning, which
// caps the loop rate deterministically. It is kept well under the MCP client
// timeout, and overridable with IMOGEN_POLL_DELAY_SECONDS (0 disables it, which
// the tests rely on).
const defaultPollDelaySeconds = 15

// throttlePoll blocks for the configured status-poll delay, or until the
// context is cancelled, so a status tool cannot return faster than that.
func throttlePoll(ctx context.Context) {
	seconds := defaultPollDelaySeconds
	if v := os.Getenv("IMOGEN_POLL_DELAY_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			seconds = n
		}
	}
	if seconds <= 0 {
		return
	}
	select {
	case <-time.After(time.Duration(seconds) * time.Second):
	case <-ctx.Done():
	}
}
