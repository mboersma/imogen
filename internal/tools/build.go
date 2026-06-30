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

// submit-build-job runs image-builder as a Kubernetes Job on the CAPZ builder
// cluster, publishing to the staging gallery. It shells out to
// hack/run-build-job.sh, which applies the Job (the pod authenticates with the
// build managed identity on the builder VMSS through IMDS, no stored secret).
// get-build-status reports the Job state. This replaces the earlier standalone
// Azure Container Instances build.

const (
	defaultBuildScript       = "hack/run-build-job.sh"
	defaultBuildStatusScript = "hack/build-status.sh"
)

type submitBuildJobInput struct {
	Flavor  string `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version string `json:"version" jsonschema:"Kubernetes version to build, such as v1.34.9"`
}

type submitBuildJobOutput struct {
	Job             string `json:"job"`
	Flavor          string `json:"flavor"`
	Version         string `json:"version"`
	ImageDefinition string `json:"imageDefinition"`
	ImageVersion    string `json:"imageVersion"`
}

func registerSubmitBuildJob(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "submit-build-job",
		Description: "Build a CAPZ reference image for one flavor and Kubernetes version with image-builder, publishing to the staging gallery. Runs as a Kubernetes Job on the builder cluster and returns immediately; poll get-build-status.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in submitBuildJobInput) (*mcp.CallToolResult, submitBuildJobOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, submitBuildJobOutput{}, fmt.Errorf("flavor and version are required")
		}
		sigVersion := strings.TrimPrefix(in.Version, "v")

		script := os.Getenv("IMOGEN_BUILD_SCRIPT")
		if script == "" {
			script = defaultBuildScript
		}
		out, err := runScript(ctx, script, in.Flavor, sigVersion)
		if err != nil {
			return nil, submitBuildJobOutput{}, fmt.Errorf("submit build failed: %w\n%s", err, lastLines(out, 20))
		}
		job := lastNonEmptyLine(out)

		return nil, submitBuildJobOutput{
			Job:             job,
			Flavor:          in.Flavor,
			Version:         "v" + sigVersion,
			ImageDefinition: definitionFor(in.Flavor),
			ImageVersion:    sigVersion,
		}, nil
	})
}

type getBuildStatusInput struct {
	Job string `json:"job" jsonschema:"the build Job name returned by submit-build-job"`
}

type getBuildStatusOutput struct {
	Job   string `json:"job"`
	State string `json:"state"`
}

func registerGetBuildStatus(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "get-build-status",
		Description: "Report the state of a build Job on the builder cluster: Pending, Running, Succeeded, Failed or NotFound.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in getBuildStatusInput) (*mcp.CallToolResult, getBuildStatusOutput, error) {
		if in.Job == "" {
			return nil, getBuildStatusOutput{}, fmt.Errorf("job is required")
		}
		script := os.Getenv("IMOGEN_BUILD_STATUS_SCRIPT")
		if script == "" {
			script = defaultBuildStatusScript
		}
		out, err := runScript(ctx, script, in.Job)
		if err != nil {
			return nil, getBuildStatusOutput{}, fmt.Errorf("get build status failed: %w\n%s", err, lastLines(out, 20))
		}
		return nil, getBuildStatusOutput{Job: in.Job, State: lastNonEmptyLine(out)}, nil
	})
}

// runScript runs `bash <script> <args...>` and returns the combined output.
func runScript(ctx context.Context, script string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "bash", append([]string{script}, args...)...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	return buf.String(), err
}

// lastNonEmptyLine returns the trailing non-empty line of s, which the build
// scripts use to print the Job name or state.
func lastNonEmptyLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if t := strings.TrimSpace(lines[i]); t != "" {
			return t
		}
	}
	return ""
}
