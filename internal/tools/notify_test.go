package tools

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNormalizeLevel(t *testing.T) {
	cases := map[string]string{
		"":         "info",
		"info":     "info",
		"INFO":     "info",
		"warn":     "warning",
		"Warning":  "warning",
		"approval": "approval",
		"bogus":    "info",
	}
	for in, want := range cases {
		if got := normalizeLevel(in); got != want {
			t.Errorf("normalizeLevel(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFormatNotification(t *testing.T) {
	got := formatNotification("approval", "Promote 1.36.2", "Validation passed; approve promote?")
	if !strings.HasPrefix(got, "[imogen APPROVAL NEEDED] Promote 1.36.2\n") {
		t.Errorf("unexpected header line: %q", got)
	}
	if !strings.HasSuffix(got, "Validation passed; approve promote?") {
		t.Errorf("message body missing: %q", got)
	}

	noTitle := formatNotification("info", "", "built 1.36.2")
	if noTitle != "[imogen INFO]\nbuilt 1.36.2" {
		t.Errorf("no-title format wrong: %q", noTitle)
	}
}

func TestWebhookChannel(t *testing.T) {
	if got := webhookChannel("https://hooks.slack.com/services/T/B/X"); got != "hooks.slack.com" {
		t.Errorf("got %q, want hooks.slack.com", got)
	}
	if got := webhookChannel("not a url"); got != "webhook" {
		t.Errorf("malformed URL should fall back to webhook, got %q", got)
	}
}

func TestPostWebhook(t *testing.T) {
	var gotText string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("missing JSON content type")
		}
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		if err := json.Unmarshal(body, &payload); err != nil {
			t.Errorf("payload not JSON: %v", err)
		}
		gotText = payload["text"]
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	if err := postWebhook(context.Background(), srv.URL, "hello"); err != nil {
		t.Fatalf("postWebhook: %v", err)
	}
	if gotText != "hello" {
		t.Errorf("webhook got text %q, want hello", gotText)
	}
}

func TestPostWebhookNon2xx(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	if err := postWebhook(context.Background(), srv.URL, "x"); err == nil {
		t.Fatal("expected an error for a non-2xx response")
	}
}
