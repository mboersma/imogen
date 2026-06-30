package tools

import (
	"bytes"
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

func TestResolveFormat(t *testing.T) {
	t.Setenv("IMOGEN_NOTIFY_FORMAT", "")
	cases := map[string]string{
		"https://hooks.slack.com/services/T/B/X":                                  "slack",
		"https://example.webhook.office.com/webhookb2/abc":                        "teams",
		"https://x.environment.api.powerplatform.com/powerautomate/automations/y": "teams",
		"https://prod-1.westus.logic.azure.com/workflows/abc/triggers/manual":     "teams",
		"https://example.com/generic":                                             "slack",
	}
	for url, want := range cases {
		if got := resolveFormat(url); got != want {
			t.Errorf("resolveFormat(%q) = %q, want %q", url, got, want)
		}
	}
}

func TestResolveFormatOverride(t *testing.T) {
	t.Setenv("IMOGEN_NOTIFY_FORMAT", "teams")
	if got := resolveFormat("https://hooks.slack.com/services/T/B/X"); got != "teams" {
		t.Errorf("override should force teams, got %q", got)
	}
	t.Setenv("IMOGEN_NOTIFY_FORMAT", "slack")
	if got := resolveFormat("https://x.webhook.office.com/y"); got != "slack" {
		t.Errorf("override should force slack, got %q", got)
	}
}

func TestNotifyPayload(t *testing.T) {
	slack, ok := notifyPayload("slack", "hi").(map[string]string)
	if !ok || slack["text"] != "hi" {
		t.Errorf("slack payload should be {text: hi}, got %#v", slack)
	}

	raw, err := json.Marshal(notifyPayload("teams", "hi"))
	if err != nil {
		t.Fatalf("marshal teams payload: %v", err)
	}
	var env map[string]any
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatal(err)
	}
	if env["type"] != "message" {
		t.Errorf("teams payload type should be message, got %v", env["type"])
	}
	atts, _ := env["attachments"].([]any)
	if len(atts) != 1 {
		t.Fatalf("teams payload should have 1 attachment, got %d", len(atts))
	}
	att, _ := atts[0].(map[string]any)
	if att["contentType"] != "application/vnd.microsoft.card.adaptive" {
		t.Errorf("wrong attachment contentType: %v", att["contentType"])
	}
	if !bytes.Contains(raw, []byte(`"text":"hi"`)) {
		t.Errorf("teams card should carry the message text: %s", raw)
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

	if err := postWebhook(context.Background(), srv.URL, "slack", "hello"); err != nil {
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

	if err := postWebhook(context.Background(), srv.URL, "slack", "x"); err == nil {
		t.Fatal("expected an error for a non-2xx response")
	}
}
