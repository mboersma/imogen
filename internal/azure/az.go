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

// SubscriptionID returns the current az subscription id.
func SubscriptionID(ctx context.Context) (string, error) {
	var id string
	if err := runJSON(ctx, &id, "account", "show", "--query", "id"); err != nil {
		return "", err
	}
	return id, nil
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

// Promotion copies a gallery image version from one gallery to another, in the
// same resource group, by pointing the new version at the source as its image.
type Promotion struct {
	ResourceGroup  string
	SourceGallery  string
	TargetGallery  string
	Definition     string
	Version        string
	SubscriptionID string
	TargetRegions  []string // optional; defaults to the source region
}

// StartImageVersionPromotion begins creating the target gallery image version
// from the source version and returns immediately (az --no-wait). The create is
// a long-running operation that can exceed the MCP client timeout, so callers
// submit here and poll ImageVersionProvisioningState instead of blocking.
func StartImageVersionPromotion(ctx context.Context, p Promotion) error {
	sourceID := fmt.Sprintf(
		"/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/galleries/%s/images/%s/versions/%s",
		p.SubscriptionID, p.ResourceGroup, p.SourceGallery, p.Definition, p.Version)
	args := []string{"sig", "image-version", "create",
		"-g", p.ResourceGroup,
		"--gallery-name", p.TargetGallery,
		"--gallery-image-definition", p.Definition,
		"--gallery-image-version", p.Version,
		"--image-version", sourceID,
		"--no-wait",
	}
	if len(p.TargetRegions) > 0 {
		args = append(args, "--target-regions")
		args = append(args, p.TargetRegions...)
	}
	return runJSON(ctx, nil, args...)
}

// ImageVersionProvisioningState returns the provisioningState of a gallery image
// version, such as Creating, Succeeded or Failed, or "NotFound" if the version
// does not exist yet. Used to poll a promotion started with --no-wait.
func ImageVersionProvisioningState(ctx context.Context, resourceGroup, gallery, definition, version string) (string, error) {
	args := []string{"sig", "image-version", "show",
		"-g", resourceGroup, "-r", gallery, "-i", definition, "-e", version,
		"--query", "provisioningState", "-o", "json"}
	cmd := exec.CommandContext(ctx, "az", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := stderr.String()
		if strings.Contains(msg, "was not found") || strings.Contains(msg, "ResourceNotFound") || strings.Contains(msg, "NotFound") {
			return "NotFound", nil
		}
		return "", fmt.Errorf("az %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(msg))
	}
	var state string
	if err := json.Unmarshal(stdout.Bytes(), &state); err != nil {
		return "", fmt.Errorf("parsing provisioningState: %w", err)
	}
	return state, nil
}

// DeleteImageVersion deletes one image version from a gallery image definition.
// Used by gc-eol-images to retire end-of-life and superseded versions.
func DeleteImageVersion(ctx context.Context, resourceGroup, gallery, definition, version string) error {
	return runJSON(ctx, nil, "sig", "image-version", "delete",
		"-g", resourceGroup, "-r", gallery, "-i", definition, "-e", version)
}

func names(in []named) []string {
	out := make([]string, len(in))
	for i, n := range in {
		out[i] = n.Name
	}
	return out
}
