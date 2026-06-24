// Package azure wraps the az CLI for the operations imogen needs.
//
// The tool server shells out to az so it can reuse whatever credentials are in
// the environment: a developer's az login locally, or Workload Identity in
// cluster. All resource names are passed in by callers, never hardcoded.
package azure

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

// runJSON runs `az <args...> -o json` and unmarshals stdout into v.
func runJSON(ctx context.Context, v any, args ...string) error {
	args = append(args, "-o", "json")
	cmd := exec.CommandContext(ctx, "az", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("az %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	if v == nil {
		return nil
	}
	return json.Unmarshal(stdout.Bytes(), v)
}

type named struct {
	Name string `json:"name"`
}

// ListImageDefinitions returns the image definition names in a gallery.
func ListImageDefinitions(ctx context.Context, resourceGroup, gallery string) ([]string, error) {
	var defs []named
	if err := runJSON(ctx, &defs, "sig", "image-definition", "list",
		"-g", resourceGroup, "-r", gallery); err != nil {
		return nil, err
	}
	return names(defs), nil
}

// ListImageVersions returns the version names for one image definition.
func ListImageVersions(ctx context.Context, resourceGroup, gallery, definition string) ([]string, error) {
	var versions []named
	if err := runJSON(ctx, &versions, "sig", "image-version", "list",
		"-g", resourceGroup, "-r", gallery, "-i", definition); err != nil {
		return nil, err
	}
	return names(versions), nil
}

func names(in []named) []string {
	out := make([]string, len(in))
	for i, n := range in {
		out[i] = n.Name
	}
	return out
}
