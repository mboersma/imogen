package tools

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// validate-image boots a node from a staging gallery image on the builder
// cluster and checks it joins, runs the expected kubelet, and can schedule a
// pod. It shells out to hack/validate-image.sh, which needs a kubeconfig for
// the management cluster and az credentials. This runs on the host for now and
// moves in-cluster with the rest of the tool server later.

const defaultValidateScript = "hack/validate-image.sh"

type validateImageInput struct {
	Flavor  string `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version string `json:"version" jsonschema:"image version to validate, such as 1.34.9 or v1.34.9"`
}

type validateImageOutput struct {
	Flavor  string `json:"flavor"`
	Version string `json:"version"`
	Passed  bool   `json:"passed"`
	Summary string `json:"summary"`
}

func registerValidateImage(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "validate-image",
		Description: "Validate a staging gallery image by booting a node from it on the builder cluster, checking the kubelet version and runtime, and running a smoke pod. Tears the node down when done. Takes a few minutes.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in validateImageInput) (*mcp.CallToolResult, validateImageOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, validateImageOutput{}, fmt.Errorf("flavor and version are required")
		}
		version := strings.TrimPrefix(in.Version, "v")

		script := os.Getenv("IMOGEN_VALIDATE_SCRIPT")
		if script == "" {
			script = defaultValidateScript
		}

		cmd := exec.CommandContext(ctx, "bash", script, in.Flavor, version)
		var out bytes.Buffer
		cmd.Stdout = &out
		cmd.Stderr = &out
		err := cmd.Run()
		summary := lastLines(out.String(), 20)
		if err != nil {
			return nil, validateImageOutput{
				Flavor:  in.Flavor,
				Version: version,
				Passed:  false,
				Summary: summary,
			}, fmt.Errorf("validation failed: %w\n%s", err, summary)
		}

		return nil, validateImageOutput{
			Flavor:  in.Flavor,
			Version: version,
			Passed:  true,
			Summary: summary,
		}, nil
	})
}

// lastLines returns the trailing n non-empty lines of s, joined by newlines.
func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
