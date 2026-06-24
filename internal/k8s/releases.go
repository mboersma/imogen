// Package k8s looks up upstream Kubernetes release information.
package k8s

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// Release is the latest stable patch for a Kubernetes minor version.
type Release struct {
	Minor   string `json:"minor"`   // "1.34"
	Version string `json:"version"` // "v1.34.1"
}

const stableBase = "https://dl.k8s.io/release"

// parseMinor pulls the minor number out of a version like "v1.34.1".
func parseMinor(version string) (int, error) {
	v := strings.TrimPrefix(strings.TrimSpace(version), "v")
	parts := strings.Split(v, ".")
	if len(parts) < 2 {
		return 0, fmt.Errorf("invalid version %q", version)
	}
	return strconv.Atoi(parts[1])
}

// recentMinors returns the n most recent minor numbers, counting down from latest.
func recentMinors(latestMinor, n int) []int {
	out := make([]int, 0, n)
	for i := 0; i < n && latestMinor-i >= 0; i++ {
		out = append(out, latestMinor-i)
	}
	return out
}

func get(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

// LatestStable fetches the latest stable patch for the n most recent minors.
// If n <= 0 it defaults to 3.
func LatestStable(ctx context.Context, n int) ([]Release, error) {
	if n <= 0 {
		n = 3
	}
	latest, err := get(ctx, stableBase+"/stable.txt")
	if err != nil {
		return nil, err
	}
	latestMinor, err := parseMinor(latest)
	if err != nil {
		return nil, err
	}
	var releases []Release
	for _, m := range recentMinors(latestMinor, n) {
		minor := fmt.Sprintf("1.%d", m)
		v, err := get(ctx, fmt.Sprintf("%s/stable-%s.txt", stableBase, minor))
		if err != nil {
			return nil, err
		}
		releases = append(releases, Release{Minor: minor, Version: v})
	}
	return releases, nil
}
