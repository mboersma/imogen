// Package k8s looks up upstream Kubernetes release information.
package k8s

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
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

// eolBase is the default source for per-minor Kubernetes end-of-life dates.
const eolBase = "https://endoflife.date/api/kubernetes.json"

// eolEntry mirrors the subset of the endoflife.date Kubernetes schema we use.
// The "eol" field is a date string ("2026-06-28") for known cycles, but the API
// can also return a boolean for some products, so it is parsed leniently.
type eolEntry struct {
	Cycle string          `json:"cycle"` // "1.33"
	EOL   json.RawMessage `json:"eol"`   // "2026-06-28" or false
}

// MinorEOLDates returns the upstream end-of-life date for each Kubernetes minor
// (keyed by "1.33"), fetched from endoflife.date. Cycles without a concrete EOL
// date (still supported, or unknown) are omitted. The source URL is overridable
// with IMOGEN_K8S_EOL_URL so it can be mirrored.
func MinorEOLDates(ctx context.Context) (map[string]time.Time, error) {
	url := os.Getenv("IMOGEN_K8S_EOL_URL")
	if url == "" {
		url = eolBase
	}
	body, err := getBytes(ctx, url)
	if err != nil {
		return nil, err
	}
	return parseEOLDates(body)
}

// parseEOLDates parses the endoflife.date Kubernetes payload into a per-minor
// map of end-of-life dates, skipping cycles whose eol is not a date.
func parseEOLDates(body []byte) (map[string]time.Time, error) {
	var entries []eolEntry
	if err := json.Unmarshal(body, &entries); err != nil {
		return nil, fmt.Errorf("parsing kubernetes eol data: %w", err)
	}
	out := make(map[string]time.Time, len(entries))
	for _, e := range entries {
		var s string
		if json.Unmarshal(e.EOL, &s) != nil {
			continue // eol is a boolean (not yet EOL) or null
		}
		t, err := time.Parse("2006-01-02", s)
		if err != nil {
			continue
		}
		out[e.Cycle] = t
	}
	return out, nil
}

// getBytes fetches the full body of url, capped at 1 MiB.
func getBytes(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}
