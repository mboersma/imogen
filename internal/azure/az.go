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

// PromoteImageVersion creates the target gallery image version from the source
// version. It blocks until the long-running create finishes.
func PromoteImageVersion(ctx context.Context, p Promotion) error {
	sourceID := fmt.Sprintf(
		"/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Compute/galleries/%s/images/%s/versions/%s",
		p.SubscriptionID, p.ResourceGroup, p.SourceGallery, p.Definition, p.Version)
	args := []string{"sig", "image-version", "create",
		"-g", p.ResourceGroup,
		"--gallery-name", p.TargetGallery,
		"--gallery-image-definition", p.Definition,
		"--gallery-image-version", p.Version,
		"--image-version", sourceID,
	}
	if len(p.TargetRegions) > 0 {
		args = append(args, "--target-regions")
		args = append(args, p.TargetRegions...)
	}
	return runJSON(ctx, nil, args...)
}

func names(in []named) []string {
	out := make([]string, len(in))
	for i, n := range in {
		out[i] = n.Name
	}
	return out
}

// BuildContainer describes a standalone image-builder run on Azure Container
// Instances. This is the temporary build path; it moves to a Kubernetes Job on
// the CAPZ builder cluster later.
type BuildContainer struct {
	ResourceGroup  string
	Name           string
	Image          string
	Location       string
	IdentityID     string
	ClientID       string
	SubscriptionID string
	Gallery        string
	Target         string
	PackerFlags    string
}

// StartBuildContainer creates an ACI container group that authenticates with a
// user-assigned managed identity and runs the image-builder make target.
func StartBuildContainer(ctx context.Context, b BuildContainer) error {
	command := fmt.Sprintf(
		"az login --identity --client-id %s && export USE_AZURE_CLI_AUTH=True && make %s",
		b.ClientID, b.Target)
	return runJSON(ctx, nil, "container", "create",
		"-g", b.ResourceGroup,
		"-n", b.Name,
		"--image", b.Image,
		"--location", b.Location,
		"--os-type", "Linux",
		"--cpu", "2", "--memory", "4",
		"--restart-policy", "Never",
		"--assign-identity", b.IdentityID,
		"--command-line", "/bin/bash -c \""+command+"\"",
		"--environment-variables",
		"AZURE_SUBSCRIPTION_ID="+b.SubscriptionID,
		"AZURE_LOCATION="+b.Location,
		"AZURE_CLIENT_ID="+b.ClientID,
		"RESOURCE_GROUP_NAME="+b.ResourceGroup,
		"GALLERY_NAME="+b.Gallery,
		"PACKER_FLAGS="+b.PackerFlags,
	)
}

// ContainerState returns the current state of an ACI container group, such as
// Running, Succeeded or Failed.
func ContainerState(ctx context.Context, resourceGroup, name string) (string, error) {
	var state string
	if err := runJSON(ctx, &state, "container", "show",
		"-g", resourceGroup, "-n", name,
		"--query", "containers[0].instanceView.currentState.state"); err != nil {
		return "", err
	}
	return state, nil
}
