package tools

import (
	"os"
	"reflect"
	"testing"

	"github.com/mboersma/imogen/internal/k8s"
)

func TestDiffFlavor(t *testing.T) {
	releases := []k8s.Release{
		{Minor: "1.36", Version: "v1.36.2"},
		{Minor: "1.35", Version: "v1.35.6"},
		{Minor: "1.34", Version: "v1.34.9"},
	}

	tests := []struct {
		name      string
		staging   map[string]bool
		community map[string]bool
		want      []reconcileWorkItem
	}{
		{
			name:      "all present",
			community: map[string]bool{"1.36.2": true, "1.35.6": true, "1.34.9": true},
			want:      nil,
		},
		{
			name:      "missing everywhere needs build",
			staging:   map[string]bool{},
			community: map[string]bool{},
			want: []reconcileWorkItem{
				{Flavor: "ubuntu-2604", Version: "1.36.2", Minor: "1.36", Action: "build"},
				{Flavor: "ubuntu-2604", Version: "1.35.6", Minor: "1.35", Action: "build"},
				{Flavor: "ubuntu-2604", Version: "1.34.9", Minor: "1.34", Action: "build"},
			},
		},
		{
			name:      "staged but not promoted needs validate-promote",
			staging:   map[string]bool{"1.35.6": true},
			community: map[string]bool{"1.36.2": true},
			want: []reconcileWorkItem{
				{Flavor: "ubuntu-2604", Version: "1.35.6", Minor: "1.35", Action: "validate-promote"},
				{Flavor: "ubuntu-2604", Version: "1.34.9", Minor: "1.34", Action: "build"},
			},
		},
		{
			name:      "community version with v prefix is matched",
			community: map[string]bool{"1.36.2": true, "1.35.6": true, "1.34.9": true},
			want:      nil,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := diffFlavor("ubuntu-2604", releases, tc.staging, tc.community)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("diffFlavor() = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestAnnotateBlocked(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("IMOGEN_VALIDATE_STATE_DIR", dir)
	t.Setenv("IMOGEN_BUILD_MAX_ATTEMPTS", "")
	t.Setenv("IMOGEN_VALIDATE_MAX_ATTEMPTS", "")

	// A build that has given up: run-build-job.sh drops the blocked marker.
	if err := os.WriteFile(buildBlockedPath("ubuntu-2404", "1.34.9"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	// A validation that failed and hit its 3-attempt cap.
	_, donePath := validateStatePaths("ubuntu-2404", "1.35.6")
	if err := os.WriteFile(donePath, []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(validateAttemptsPath("ubuntu-2404", "1.35.6"), []byte("3"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A validation that failed but is still under its cap: not blocked.
	_, donePath2 := validateStatePaths("ubuntu-2404", "1.36.2")
	if err := os.WriteFile(donePath2, []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(validateAttemptsPath("ubuntu-2404", "1.36.2"), []byte("1"), 0o644); err != nil {
		t.Fatal(err)
	}

	work := []reconcileWorkItem{
		{Flavor: "ubuntu-2404", Version: "1.34.9", Minor: "1.34", Action: "build"},
		{Flavor: "ubuntu-2404", Version: "1.35.6", Minor: "1.35", Action: "validate-promote"},
		{Flavor: "ubuntu-2404", Version: "1.36.2", Minor: "1.36", Action: "validate-promote"},
	}
	annotateBlocked(work)

	if !work[0].Blocked || work[0].BlockedReason == "" {
		t.Errorf("build item should be blocked, got %+v", work[0])
	}
	if !work[1].Blocked || work[1].BlockedReason == "" {
		t.Errorf("capped validation should be blocked, got %+v", work[1])
	}
	if work[2].Blocked {
		t.Errorf("under-cap validation should not be blocked, got %+v", work[2])
	}
}

func TestValidateBlockedUnderCap(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("IMOGEN_VALIDATE_STATE_DIR", dir)

	// Failed once, cap 3: still retryable, not blocked.
	_, donePath := validateStatePaths("windows-2022-containerd", "1.34.9")
	if err := os.WriteFile(donePath, []byte("2"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(validateAttemptsPath("windows-2022-containerd", "1.34.9"), []byte("2"), 0o644); err != nil {
		t.Fatal(err)
	}
	if validateBlocked("windows-2022-containerd", "1.34.9") {
		t.Error("validation under cap should not be blocked")
	}

	// A succeeded validation is never blocked even at the cap.
	_, donePath2 := validateStatePaths("windows-2022-containerd", "1.35.6")
	if err := os.WriteFile(donePath2, []byte("0"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(validateAttemptsPath("windows-2022-containerd", "1.35.6"), []byte("3"), 0o644); err != nil {
		t.Fatal(err)
	}
	if validateBlocked("windows-2022-containerd", "1.35.6") {
		t.Error("succeeded validation should never be blocked")
	}
}
