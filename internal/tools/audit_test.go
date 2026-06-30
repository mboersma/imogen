package tools

import (
	"io"
	"log/slog"
	"testing"
)

func testAuditLog(size int) *auditLog {
	return newAuditLog(size, slog.New(slog.NewJSONHandler(io.Discard, nil)))
}

func TestAuditLogSnapshotOrderAndLimit(t *testing.T) {
	a := testAuditLog(10)
	for i := 1; i <= 5; i++ {
		a.record(auditEvent{Seq: int64(i), Tool: "t"})
	}

	got := a.snapshot(0, "")
	if len(got) != 5 {
		t.Fatalf("want 5 events, got %d", len(got))
	}
	// Newest last.
	if got[0].Seq != 1 || got[4].Seq != 5 {
		t.Fatalf("unexpected order: first=%d last=%d", got[0].Seq, got[4].Seq)
	}

	limited := a.snapshot(2, "")
	if len(limited) != 2 || limited[0].Seq != 4 || limited[1].Seq != 5 {
		t.Fatalf("limit should return the 2 newest, got %+v", limited)
	}
}

func TestAuditLogRingWraps(t *testing.T) {
	a := testAuditLog(3)
	for i := 1; i <= 5; i++ {
		a.record(auditEvent{Seq: int64(i), Tool: "t"})
	}

	got := a.snapshot(0, "")
	if len(got) != 3 {
		t.Fatalf("ring of 3 should hold 3 events, got %d", len(got))
	}
	// Oldest two (1,2) evicted; 3,4,5 remain oldest-to-newest.
	if got[0].Seq != 3 || got[1].Seq != 4 || got[2].Seq != 5 {
		t.Fatalf("unexpected wrapped contents: %+v", got)
	}
}

func TestAuditLogToolFilter(t *testing.T) {
	a := testAuditLog(10)
	a.record(auditEvent{Seq: 1, Tool: "build"})
	a.record(auditEvent{Seq: 2, Tool: "promote"})
	a.record(auditEvent{Seq: 3, Tool: "build"})

	got := a.snapshot(0, "build")
	if len(got) != 2 || got[0].Seq != 1 || got[1].Seq != 3 {
		t.Fatalf("tool filter should return only build events, got %+v", got)
	}
	if none := a.snapshot(0, "missing"); len(none) != 0 {
		t.Fatalf("unknown tool should return no events, got %d", len(none))
	}
}

func TestFirstLine(t *testing.T) {
	cases := map[string]string{
		"single line":          "single line",
		"first\nsecond\nthird": "first",
		"":                     "",
	}
	for in, want := range cases {
		if got := firstLine(in); got != want {
			t.Errorf("firstLine(%q) = %q, want %q", in, got, want)
		}
	}
}
