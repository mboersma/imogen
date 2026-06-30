package tools

import (
	"reflect"
	"testing"
	"time"
)

func date(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return t
}

// Mirrors the endoflife.date Kubernetes data around mid-2026.
var testEOL = map[string]time.Time{
	"1.36": date("2027-06-28"),
	"1.35": date("2027-02-28"),
	"1.34": date("2026-10-27"),
	"1.33": date("2026-06-28"),
	"1.30": date("2025-06-28"),
	"1.29": date("2025-02-28"),
	"1.28": date("2024-10-28"),
}

func TestPlanRetirementsGrace(t *testing.T) {
	now := date("2026-06-30")
	grace := 365 * 24 * time.Hour

	versions := []string{
		"1.28.5",  // eol 2024-10-28: ~20 months past, retire
		"1.29.10", // eol 2025-02-28: ~16 months past, retire
		"1.30.4",  // eol 2025-06-28: ~12 months + 2 days past grace, retire
		"1.33.13", // eol 2026-06-28: just EOL, well within grace, keep
		"1.34.9",  // still supported, keep
		"1.36.2",  // still supported, keep
		"garbage", // unparseable, ignored
	}

	got := planRetirements("capi-ubuntu-2404", versions, testEOL, now, grace)
	want := []retiredImage{
		{Definition: "capi-ubuntu-2404", Version: "1.28.5", Minor: "1.28", UpstreamEOL: "2024-10-28"},
		{Definition: "capi-ubuntu-2404", Version: "1.29.10", Minor: "1.29", UpstreamEOL: "2025-02-28"},
		{Definition: "capi-ubuntu-2404", Version: "1.30.4", Minor: "1.30", UpstreamEOL: "2025-06-28"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("planRetirements:\n got %+v\nwant %+v", got, want)
	}
}

func TestPlanRetirementsKeepsAllPatchesOfLiveMinor(t *testing.T) {
	now := date("2026-06-30")
	grace := 365 * 24 * time.Hour
	// Multiple patches of an in-support minor: none are retired, even superseded
	// ones, because downstream projects pin specific patches.
	versions := []string{"1.34.1", "1.34.5", "1.34.9"}
	if got := planRetirements("capi-ubuntu-2404", versions, testEOL, now, grace); len(got) != 0 {
		t.Errorf("expected no retirements for a live minor, got %+v", got)
	}
}

func TestPlanRetirementsKeepsAllPatchesUntilMinorAgesOut(t *testing.T) {
	now := date("2026-06-30")
	grace := 365 * 24 * time.Hour
	// 1.29 is past EOL+grace, so every patch of it retires together.
	versions := []string{"1.29.1", "1.29.5", "1.29.10"}
	got := planRetirements("capi-ubuntu-2404", versions, testEOL, now, grace)
	if len(got) != 3 {
		t.Fatalf("expected all 3 patches retired, got %+v", got)
	}
}

func TestPlanRetirementsUnknownMinorKept(t *testing.T) {
	now := date("2026-06-30")
	grace := 365 * 24 * time.Hour
	// A minor with no EOL data (newer or unrecognized) is never retired.
	versions := []string{"1.99.0"}
	if got := planRetirements("capi-ubuntu-2404", versions, testEOL, now, grace); len(got) != 0 {
		t.Errorf("expected unknown minor kept, got %+v", got)
	}
}

func TestPlanRetirementsZeroGraceRetiresAtEOL(t *testing.T) {
	now := date("2026-06-30")
	// With no grace, a minor retires as soon as it is past upstream EOL.
	versions := []string{"1.33.13", "1.34.9"}
	got := planRetirements("capi-ubuntu-2404", versions, testEOL, now, 0)
	want := []retiredImage{
		{Definition: "capi-ubuntu-2404", Version: "1.33.13", Minor: "1.33", UpstreamEOL: "2026-06-28"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("planRetirements zero grace:\n got %+v\nwant %+v", got, want)
	}
}
