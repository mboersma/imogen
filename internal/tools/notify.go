package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// notify lets the agent push a status update or approval request out to a
// human-visible channel. The unattended release watcher runs on a schedule with
// nobody watching the A2A stream, so without this the agent's progress and its
// approval requests are invisible. When IMOGEN_NOTIFY_WEBHOOK_URL is set the
// message is POSTed to that webhook in the Slack/Teams incoming-webhook shape
// ({"text": ...}); otherwise it falls back to the log only. Either way the
// message is recorded in the audit log, since notify is an audited tool. notify
// never gates the pipeline: the real approval gate stays in the agent's system
// message, and a delivery failure is reported but not fatal.

const notifyTimeout = 10 * time.Second

type notifyInput struct {
	Message string `json:"message" jsonschema:"the human-readable message to send"`
	Level   string `json:"level,omitempty" jsonschema:"severity: info, warning or approval (default info)"`
	Title   string `json:"title,omitempty" jsonschema:"optional short title or subject line"`
}

type notifyOutput struct {
	Delivered bool   `json:"delivered"`
	Channel   string `json:"channel"`
	Level     string `json:"level"`
}

func registerNotify(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "notify",
		Description: "Send a status update or approval request to the configured human channel (a Slack or Teams webhook), so progress and approval requests are visible when no one is watching the conversation. Use level=approval when you need a human to approve a destructive or publishing step. Does not block: it surfaces the request, it does not wait for a reply.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in notifyInput) (*mcp.CallToolResult, notifyOutput, error) {
		if strings.TrimSpace(in.Message) == "" {
			return nil, notifyOutput{}, fmt.Errorf("message is required")
		}
		level := normalizeLevel(in.Level)
		text := formatNotification(level, in.Title, in.Message)

		webhook := os.Getenv("IMOGEN_NOTIFY_WEBHOOK_URL")
		if webhook == "" {
			// Log-only fallback: the audit record already carries the message,
			// so it is visible in the pod logs without an external channel.
			return nil, notifyOutput{Delivered: true, Channel: "log", Level: level}, nil
		}

		channel := webhookChannel(webhook)
		if err := postWebhook(ctx, webhook, text); err != nil {
			// Delivery failure must not break the pipeline; report it and let
			// the agent continue. The audit log captures that this call ran.
			defaultAuditLog.logger.Error("notify delivery failed",
				"channel", channel, "error", firstLine(err.Error()))
			return nil, notifyOutput{Delivered: false, Channel: channel, Level: level}, nil
		}
		return nil, notifyOutput{Delivered: true, Channel: channel, Level: level}, nil
	})
}

// normalizeLevel lowercases the level and falls back to info for anything it
// does not recognize, so a bad value never blocks a notification.
func normalizeLevel(level string) string {
	switch strings.ToLower(strings.TrimSpace(level)) {
	case "warning", "warn":
		return "warning"
	case "approval":
		return "approval"
	default:
		return "info"
	}
}

// formatNotification renders the level, optional title and message into one
// line of text suitable for a Slack or Teams webhook.
func formatNotification(level, title, message string) string {
	label := map[string]string{
		"info":     "INFO",
		"warning":  "WARNING",
		"approval": "APPROVAL NEEDED",
	}[level]

	var b strings.Builder
	fmt.Fprintf(&b, "[imogen %s]", label)
	if t := strings.TrimSpace(title); t != "" {
		fmt.Fprintf(&b, " %s", t)
	}
	b.WriteString("\n")
	b.WriteString(strings.TrimSpace(message))
	return b.String()
}

// webhookChannel returns the webhook host for reporting, without leaking the
// secret path of the URL.
func webhookChannel(webhook string) string {
	if u, err := url.Parse(webhook); err == nil && u.Host != "" {
		return u.Host
	}
	return "webhook"
}

// postWebhook sends text as a Slack/Teams incoming-webhook payload.
func postWebhook(ctx context.Context, webhook, text string) error {
	body, err := json.Marshal(map[string]string{"text": text})
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, notifyTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhook, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("webhook returned status %d", resp.StatusCode)
	}
	return nil
}
