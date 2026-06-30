package tools

import (
	"context"
	"errors"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type auditTestInput struct {
	Fail bool `json:"fail,omitempty"`
}

type auditTestOutput struct {
	OK bool `json:"ok"`
}

// TestAuditedToolRecordsCalls drives an audited tool through a real MCP
// client/server session and confirms each call lands in the shared audit log
// with the right outcome, input and tool name.
func TestAuditedToolRecordsCalls(t *testing.T) {
	ctx := context.Background()
	server := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "v0"}, nil)

	const toolName = "audit-self-test"
	auditedTool(server, &mcp.Tool{Name: toolName, Description: "test tool"},
		func(_ context.Context, _ *mcp.CallToolRequest, in auditTestInput) (*mcp.CallToolResult, auditTestOutput, error) {
			if in.Fail {
				return nil, auditTestOutput{}, errors.New("boom\nsecond line")
			}
			return nil, auditTestOutput{OK: true}, nil
		})

	st, ct := mcp.NewInMemoryTransports()
	ss, err := server.Connect(ctx, st, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ss.Close()
	client := mcp.NewClient(&mcp.Implementation{Name: "c", Version: "v0"}, nil)
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()

	if _, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: toolName, Arguments: auditTestInput{}}); err != nil {
		t.Fatalf("successful call: %v", err)
	}
	// A tool that returns an error surfaces as an error result, not a transport error.
	if _, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: toolName, Arguments: auditTestInput{Fail: true}}); err != nil {
		t.Fatalf("failing call transport error: %v", err)
	}

	events := defaultAuditLog.snapshot(0, toolName)
	if len(events) != 2 {
		t.Fatalf("want 2 recorded events, got %d", len(events))
	}

	ok, bad := events[0], events[1]
	if !ok.Success || ok.Error != "" {
		t.Errorf("first call should be a success: %+v", ok)
	}
	if string(ok.Input) != `{}` {
		t.Errorf("input should be captured as JSON, got %q", ok.Input)
	}
	if bad.Success {
		t.Errorf("second call should be a failure: %+v", bad)
	}
	if bad.Error != "boom" {
		t.Errorf("error should be trimmed to its first line, got %q", bad.Error)
	}
	if bad.Seq <= ok.Seq {
		t.Errorf("sequence should increase: %d then %d", ok.Seq, bad.Seq)
	}
}
