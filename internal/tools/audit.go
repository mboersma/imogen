package tools

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Audit logging gives insight into how the pipeline runs: every tool action is
// recorded as a structured event. Events go to stderr as JSON (the natural
// Kubernetes observability surface, captured in pod logs and Azure Monitor; and
// stderr stays clear of the stdio MCP transport on stdout), and the most recent
// events are kept in an in-memory ring buffer the agent can read back through
// the get-audit-log tool.

const defaultAuditBufferSize = 200

// auditEvent is one recorded tool action.
type auditEvent struct {
	Seq        int64           `json:"seq"`
	Tool       string          `json:"tool"`
	Time       time.Time       `json:"time"`
	DurationMs int64           `json:"durationMs"`
	Success    bool            `json:"success"`
	Error      string          `json:"error,omitempty"`
	Input      json.RawMessage `json:"input,omitempty"`
}

// auditLog is a fixed-size, thread-safe ring buffer of recent tool actions.
type auditLog struct {
	mu      sync.Mutex
	events  []auditEvent
	next    int
	size    int
	logger  *slog.Logger
	counter atomic.Int64
}

func newAuditLog(size int, logger *slog.Logger) *auditLog {
	if size <= 0 {
		size = defaultAuditBufferSize
	}
	return &auditLog{events: make([]auditEvent, 0, size), size: size, logger: logger}
}

// record appends an event to the ring buffer and emits it to the logger.
func (a *auditLog) record(e auditEvent) {
	a.mu.Lock()
	if len(a.events) < a.size {
		a.events = append(a.events, e)
	} else {
		a.events[a.next] = e
		a.next = (a.next + 1) % a.size
	}
	a.mu.Unlock()

	attrs := []any{
		slog.Int64("seq", e.Seq),
		slog.String("tool", e.Tool),
		slog.Int64("durationMs", e.DurationMs),
		slog.Bool("success", e.Success),
	}
	if e.Error != "" {
		attrs = append(attrs, slog.String("error", e.Error))
	}
	if len(e.Input) > 0 {
		attrs = append(attrs, slog.String("input", string(e.Input)))
	}
	if e.Success {
		a.logger.Info("tool action", attrs...)
	} else {
		a.logger.Error("tool action", attrs...)
	}
}

// snapshot returns up to limit of the most recent events, newest last, filtered
// to one tool name when tool is non-empty.
func (a *auditLog) snapshot(limit int, tool string) []auditEvent {
	a.mu.Lock()
	defer a.mu.Unlock()

	// Walk the ring oldest-to-newest.
	ordered := make([]auditEvent, 0, len(a.events))
	if len(a.events) < a.size {
		ordered = append(ordered, a.events...)
	} else {
		ordered = append(ordered, a.events[a.next:]...)
		ordered = append(ordered, a.events[:a.next]...)
	}

	if tool != "" {
		filtered := ordered[:0:0]
		for _, e := range ordered {
			if e.Tool == tool {
				filtered = append(filtered, e)
			}
		}
		ordered = filtered
	}

	if limit > 0 && len(ordered) > limit {
		ordered = ordered[len(ordered)-limit:]
	}
	return ordered
}

// defaultAuditLog is the process-wide audit log. It is created once and shared
// by every audited tool and by the get-audit-log tool.
var defaultAuditLog = newAuditLog(auditBufferSizeFromEnv(), newAuditLogger())

func auditBufferSizeFromEnv() int {
	if v := os.Getenv("IMOGEN_AUDIT_BUFFER_SIZE"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return defaultAuditBufferSize
}

func newAuditLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
}

// auditedTool registers a tool whose every call is recorded in the audit log.
// It is a drop-in replacement for mcp.AddTool that wraps the handler to capture
// the input, outcome, error and duration of each call.
func auditedTool[In, Out any](
	server *mcp.Server,
	tool *mcp.Tool,
	handler func(context.Context, *mcp.CallToolRequest, In) (*mcp.CallToolResult, Out, error),
) {
	mcp.AddTool(server, tool, func(ctx context.Context, req *mcp.CallToolRequest, in In) (*mcp.CallToolResult, Out, error) {
		start := time.Now()
		res, out, err := handler(ctx, req, in)

		e := auditEvent{
			Seq:        defaultAuditLog.counter.Add(1),
			Tool:       tool.Name,
			Time:       start.UTC(),
			DurationMs: time.Since(start).Milliseconds(),
			Success:    err == nil,
		}
		if raw, mErr := json.Marshal(in); mErr == nil {
			e.Input = raw
		}
		if err != nil {
			e.Error = firstLine(err.Error())
		}
		defaultAuditLog.record(e)

		return res, out, err
	})
}

// firstLine trims an error to its first line so a multi-line tool error (the
// build and validate tools attach command output) stays a one-line audit entry.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

type getAuditLogInput struct {
	Limit int    `json:"limit,omitempty" jsonschema:"how many of the most recent tool actions to return (default 50)"`
	Tool  string `json:"tool,omitempty" jsonschema:"limit to one tool name, such as promote-image; empty returns all tools"`
}

type getAuditLogOutput struct {
	Events []auditEvent `json:"events"`
}

func registerGetAuditLog(server *mcp.Server) {
	// Not audited itself, so reading the log does not flood it with its own
	// reads.
	mcp.AddTool(server, &mcp.Tool{
		Name:        "get-audit-log",
		Description: "Return the most recent tool actions imogen has taken, newest last: tool name, input, success or failure, error and duration. Use it to report what the system has been doing or to diagnose a failed pipeline run.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in getAuditLogInput) (*mcp.CallToolResult, getAuditLogOutput, error) {
		limit := in.Limit
		if limit <= 0 {
			limit = 50
		}
		return nil, getAuditLogOutput{Events: defaultAuditLog.snapshot(limit, in.Tool)}, nil
	})
}
