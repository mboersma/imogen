package tools

import "testing"

// buildJobName must match run-build-job.sh's NAME="imogen-build-${FLAVOR}-${SIG_VERSION//./-}",
// since get-build-status derives the Job name rather than trusting the caller.
func TestBuildJobName(t *testing.T) {
	cases := []struct {
		flavor, version, want string
	}{
		{"ubuntu-2404", "1.34.9", "imogen-build-ubuntu-2404-1-34-9"},
		{"windows-2022-containerd", "1.36.2", "imogen-build-windows-2022-containerd-1-36-2"},
		{"windows-2025-containerd", "v1.35.6", "imogen-build-windows-2025-containerd-1-35-6"},
	}
	for _, c := range cases {
		if got := buildJobName(c.flavor, c.version); got != c.want {
			t.Errorf("buildJobName(%q, %q) = %q, want %q", c.flavor, c.version, got, c.want)
		}
	}
}
