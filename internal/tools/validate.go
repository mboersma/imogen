package tools

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// validate-image boots a node from a staging gallery image on the builder
// cluster and checks it joins, runs the expected kubelet, and can schedule a
// pod. It shells out to hack/validate-image.sh, which needs a kubeconfig for
// the management cluster and az credentials.
//
// Validation runs for several minutes (it boots a VM, waits for Ready, runs a
// smoke pod, then tears down), which exceeds the MCP client timeout. So like
// submit-build-job and promote-image, validate-image starts the run in the
// background and returns immediately; the agent polls get-validation-status
// until it reports Succeeded or Failed. The run writes its output to a log file
// and its exit code to a done file under IMOGEN_VALIDATE_STATE_DIR (default the
// system temp dir), which get-validation-status reads back.
//
// Each validation reuses one fixed-name MachineDeployment per OS type on the
// builder cluster (imogen-builder-validate for Linux, imogen-builder-vwin for
// Windows), so two validations of the same OS type cannot run at once without
// stomping on each other's node. The reconcile agent kicks off many validations
// in parallel, so validateLocks serializes them per OS type: a queued run holds
// its log file (reported as Running) until the one ahead of it finishes.

const defaultValidateScript = "hack/validate-image.sh"

// validateLocks serializes validation runs per OS type, since each reuses a
// single shared MachineDeployment on the builder cluster.
var validateLocks = map[string]*sync.Mutex{
	"linux":   {},
	"windows": {},
}

// validateOSType maps an image-builder flavor to the OS type whose validation
// resources it shares (and therefore the lock it must serialize on).
func validateOSType(flavor string) string {
	if strings.HasPrefix(flavor, "windows") {
		return "windows"
	}
	return "linux"
}

type validateImageInput struct {
	Flavor  string `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version string `json:"version" jsonschema:"image version to validate, such as 1.34.9 or v1.34.9"`
}

type validateImageOutput struct {
	Flavor  string `json:"flavor"`
	Version string `json:"version"`
	State   string `json:"state"`
}

func registerValidateImage(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "validate-image",
		Description: "Start validating a staging gallery image by booting a node from it on the builder cluster, checking the kubelet version and runtime, and running a smoke pod. Tears the node down when done. Returns immediately; poll get-validation-status until the state is Succeeded or Failed.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in validateImageInput) (*mcp.CallToolResult, validateImageOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, validateImageOutput{}, fmt.Errorf("flavor and version are required")
		}
		version := strings.TrimPrefix(in.Version, "v")

		logPath, donePath := validateStatePaths(in.Flavor, version)

		// If a run is already in flight (queued or running), do not start a second.
		if fileExists(logPath) && !fileExists(donePath) {
			return nil, validateImageOutput{Flavor: in.Flavor, Version: version, State: "Running"}, nil
		}
		_ = os.Remove(donePath)

		script := os.Getenv("IMOGEN_VALIDATE_SCRIPT")
		if script == "" {
			script = defaultValidateScript
		}

		// Create the log up front so a queued run (waiting on the per-OS-type
		// lock) still reports Running and blocks a duplicate submission, before
		// the script itself starts writing to it.
		if err := os.WriteFile(logPath, []byte("Queued for validation\n"), 0o644); err != nil {
			return nil, validateImageOutput{}, fmt.Errorf("failed to create validation log: %w", err)
		}

		// Append (not truncate) so the queue marker is kept and the script's
		// output follows it; the done file holds the exit code.
		shell := fmt.Sprintf(
			"bash %q %q %q >>%q 2>&1; echo $? >%q",
			script, in.Flavor, version, logPath, donePath,
		)

		// Serialize per OS type: two validations of the same OS type share one
		// MachineDeployment on the builder cluster, so they must not run at once.
		// The goroutine (not the request) owns the run, so validate-image still
		// returns immediately; a queued run waits here until the one ahead exits.
		lock := validateLocks[validateOSType(in.Flavor)]
		go func() {
			lock.Lock()
			defer lock.Unlock()
			cmd := exec.Command("bash", "-c", shell)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			_ = cmd.Run()
		}()

		return nil, validateImageOutput{Flavor: in.Flavor, Version: version, State: "Running"}, nil
	})
}

type getValidationStatusInput struct {
	Flavor  string `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version string `json:"version" jsonschema:"image version being validated, such as 1.34.9 or v1.34.9"`
}

type getValidationStatusOutput struct {
	Flavor  string `json:"flavor"`
	Version string `json:"version"`
	State   string `json:"state"`
	Summary string `json:"summary"`
}

func registerGetValidationStatus(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "get-validation-status",
		Description: "Report the state of an image validation started by validate-image: Running, Succeeded, Failed or NotFound. Poll this until the state is Succeeded or Failed.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in getValidationStatusInput) (*mcp.CallToolResult, getValidationStatusOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, getValidationStatusOutput{}, fmt.Errorf("flavor and version are required")
		}
		throttlePoll(ctx)
		version := strings.TrimPrefix(in.Version, "v")
		logPath, donePath := validateStatePaths(in.Flavor, version)

		out := getValidationStatusOutput{Flavor: in.Flavor, Version: version}

		code, done := readDone(donePath)
		if !done {
			if !fileExists(logPath) {
				out.State = "NotFound"
				return nil, out, nil
			}
			out.State = "Running"
			out.Summary = lastLines(readFile(logPath), 20)
			return nil, out, nil
		}

		out.Summary = lastLines(readFile(logPath), 20)
		if code == 0 {
			out.State = "Succeeded"
		} else {
			out.State = "Failed"
		}
		return nil, out, nil
	})
}

var validateKeyUnsafe = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

// validateStatePaths returns the log and done file paths for a flavor/version run.
func validateStatePaths(flavor, version string) (logPath, donePath string) {
	dir := os.Getenv("IMOGEN_VALIDATE_STATE_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	key := validateKeyUnsafe.ReplaceAllString(flavor+"-"+version, "-")
	base := filepath.Join(dir, "imogen-validate-"+key)
	return base + ".log", base + ".done"
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func readFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

// readDone reports whether the done file exists and, if so, the exit code it holds.
func readDone(path string) (code int, done bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	code, err = strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		// The file exists but has no parseable code yet; treat as still running.
		return 0, false
	}
	return code, true
}

// lastLines returns the trailing n non-empty lines of s, joined by newlines.
func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
