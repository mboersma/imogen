package tools

import (
	"reflect"
	"testing"

	"github.com/mboersma/imogen/internal/k8s"
)

func TestSupportedWindow(t *testing.T) {
	releases := []k8s.Release{
		{Minor: "1.36", Version: "v1.36.2"},
		{Minor: "1.35", Version: "v1.35.6"},
		{Minor: "1.34", Version: "v1.34.9"},
	}
	oldest, minors, err := supportedWindow(releases)
	if err != nil {
		t.Fatalf("supportedWindow: %v", err)
	}
	if oldest != (minorKey{1, 34}) {
		t.Errorf("oldest = %+v, want {1 34}", oldest)
	}
	want := []string{"1.36", "1.35", "1.34"}
	if !reflect.DeepEqual(minors, want) {
		t.Errorf("minors = %v, want %v", minors, want)
	}
}

func TestSupportedWindowEmpty(t *testing.T) {
	if _, _, err := supportedWindow(nil); err == nil {
		t.Fatal("expected an error for no releases")
	}
}

func TestPlanRetirements(t *testing.T) {
	oldest := minorKey{1, 34} // in scope: 1.34, 1.35, 1.36

	versions := []string{
		"1.33.13", // eol: older minor
		"1.32.4",  // eol: older minor
		"1.34.8",  // superseded by 1.34.9
		"1.34.9",  // keep: highest patch of an in-scope minor
		"1.35.6",  // keep: only patch of its minor
		"1.36.1",  // superseded by 1.36.2
		"1.36.2",  // keep: highest patch
		"garbage", // ignored: unparseable
	}

	got := planRetirements("capi-ubuntu-2404", versions, oldest)
	want := []retiredImage{
		{Definition: "capi-ubuntu-2404", Version: "1.32.4", Reason: reasonEOL},
		{Definition: "capi-ubuntu-2404", Version: "1.33.13", Reason: reasonEOL},
		{Definition: "capi-ubuntu-2404", Version: "1.34.8", Reason: reasonSuperseded},
		{Definition: "capi-ubuntu-2404", Version: "1.36.1", Reason: reasonSuperseded},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("planRetirements:\n got %+v\nwant %+v", got, want)
	}
}

func TestPlanRetirementsNothingToRetire(t *testing.T) {
	oldest := minorKey{1, 34}
	versions := []string{"1.34.9", "1.35.6", "1.36.2"}
	if got := planRetirements("capi-ubuntu-2404", versions, oldest); len(got) != 0 {
		t.Errorf("expected no retirements, got %+v", got)
	}
}

func TestPlanRetirementsKeepsNewerThanScope(t *testing.T) {
	// A minor newer than the in-scope window (built ahead of the stable list)
	// is not end of life and must be kept.
	oldest := minorKey{1, 34}
	versions := []string{"1.37.0"}
	if got := planRetirements("capi-ubuntu-2404", versions, oldest); len(got) != 0 {
		t.Errorf("expected newer-than-scope version kept, got %+v", got)
	}
}
