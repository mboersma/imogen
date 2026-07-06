package tools

import "testing"

func TestValidateOSType(t *testing.T) {
	cases := map[string]string{
		"ubuntu-2404":             "linux",
		"ubuntu-2604":             "linux",
		"azurelinux-3":            "linux",
		"windows-2022-containerd": "windows",
		"windows-2025-containerd": "windows",
	}
	for flavor, want := range cases {
		if got := validateOSType(flavor); got != want {
			t.Errorf("validateOSType(%q) = %q, want %q", flavor, got, want)
		}
	}
}

// Both OS types must have a lock, since validateOSType only ever returns these.
func TestValidateLocksCoverOSTypes(t *testing.T) {
	for _, os := range []string{"linux", "windows"} {
		if validateLocks[os] == nil {
			t.Errorf("validateLocks missing a lock for %q", os)
		}
	}
}
