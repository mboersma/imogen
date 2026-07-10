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
// its log file (reported as Running) until the one ahead of it finishes. A run
// that already succeeded is not repeated, so the reconcile loop can re-invoke
// validate-image for a validated-but-not-yet-promoted version cheaply.

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
		// If a prior run already succeeded, do not re-validate. The reconcile
		// loop re-invokes validate-image for versions that validated but were not
		// yet promoted, and re-running a passed validation would waste minutes on
		// the shared MachineDeployment. A failed run is retried, since a node join
		// (especially Windows) can flake.
		if code, done := readDone(donePath); done && code == 0 {
			return nil, validateImageOutput{Flavor: in.Flavor, Version: version, State: "Succeeded"}, nil
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

// validationState reports the recorded validation outcome for a flavor/version,
// matching get-validation-status: "Succeeded", "Failed", "Running" or "NotFound".
func validationState(flavor, version string) string {
	logPath, donePath := validateStatePaths(flavor, version)
	code, done := readDone(donePath)
	if !done {
		if !fileExists(logPath) {
			return "NotFound"
		}
		return "Running"
	}
	if code == 0 {
		return "Succeeded"
	}
	return "Failed"
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
		logPath, _ := validateStatePaths(in.Flavor, version)

		out := getValidationStatusOutput{Flavor: in.Flavor, Version: version}
		out.State = validationState(in.Flavor, version)
		if out.State != "NotFound" {
			out.Summary = lastLines(readFile(logPath), 20)
		}
		return nil, out, nil
	})
}

var validateKeyUnsafe = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

// stateDir is the directory the tools keep their small run-state files in (the
// validation log/done/attempts files and the build "blocked" marker). It matches
// the default the hack scripts use (IMOGEN_VALIDATE_STATE_DIR, else the system
// temp dir), so Go and the scripts read and write the same paths.
func stateDir() string {
	dir := os.Getenv("IMOGEN_VALIDATE_STATE_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	return dir
}

// validateStateKey sanitizes a flavor/version into the file-name stem the tools
// and hack/validate-image.sh both use.
func validateStateKey(flavor, version string) string {
	return validateKeyUnsafe.ReplaceAllString(flavor+"-"+version, "-")
}

// validateStatePaths returns the log and done file paths for a flavor/version run.
func validateStatePaths(flavor, version string) (logPath, donePath string) {
	base := filepath.Join(stateDir(), "imogen-validate-"+validateStateKey(flavor, version))
	return base + ".log", base + ".done"
}

// validateAttemptsPath is the counter file hack/validate-image.sh increments per
// attempt (imogen-validate-<key>.attempts); it caps retries at that count.
func validateAttemptsPath(flavor, version string) string {
	return filepath.Join(stateDir(), "imogen-validate-"+validateStateKey(flavor, version)+".attempts")
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

// readIntFile reads a small file holding a single integer (such as the
// validation attempts counter), returning 0 when it is missing or unparseable.
func readIntFile(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return 0
	}
	return n
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
