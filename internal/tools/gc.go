package tools

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/mboersma/imogen/internal/k8s"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// gc-eol-images retires image versions that have aged out of support: those
// whose Kubernetes minor is older than the most recent minorCount minors
// (end of life), and older patches of an in-scope minor that a newer patch has
// superseded. It is destructive, so it defaults to a dry run that only reports
// the candidates; the agent (or an operator) calls it again with apply=true to
// actually delete them.

const (
	reasonEOL        = "eol-minor"
	reasonSuperseded = "superseded-patch"
)

type gcEolImagesInput struct {
	Stage         string `json:"stage,omitempty" jsonschema:"which gallery to clean by role: staging or community (defaults to community)"`
	Flavor        string `json:"flavor,omitempty" jsonschema:"limit to one image-builder flavor, such as ubuntu-2404; empty cleans all"`
	ResourceGroup string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	Gallery       string `json:"gallery,omitempty" jsonschema:"explicit compute gallery name; overrides stage"`
	MinorCount    int    `json:"minorCount,omitempty" jsonschema:"how many recent Kubernetes minors stay in scope (default 3); older minors are end of life"`
	Apply         bool   `json:"apply,omitempty" jsonschema:"actually delete the retired versions; default false only reports the candidates"`
}

type retiredImage struct {
	Definition string `json:"definition"`
	Version    string `json:"version"`
	Reason     string `json:"reason"`
}

type gcEolImagesOutput struct {
	ResourceGroup   string         `json:"resourceGroup"`
	Gallery         string         `json:"gallery"`
	SupportedMinors []string       `json:"supportedMinors"`
	Applied         bool           `json:"applied"`
	Images          []retiredImage `json:"images"`
}

func registerGcEolImages(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "gc-eol-images",
		Description: "Find and optionally delete end-of-life and superseded image versions in a gallery. Versions whose Kubernetes minor is older than the most recent minorCount minors are end of life; older patches of an in-scope minor are superseded. Defaults to a dry run that only reports candidates; call with apply=true to delete them.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in gcEolImagesInput) (*mcp.CallToolResult, gcEolImagesOutput, error) {
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		gallery := galleryFor(in.Gallery, in.Stage)
		if rg == "" || gallery == "" {
			return nil, gcEolImagesOutput{}, fmt.Errorf("resourceGroup and gallery are required (set them directly or via IMOGEN_RESOURCE_GROUP / IMOGEN_COMMUNITY_GALLERY)")
		}

		releases, err := k8s.LatestStable(ctx, in.MinorCount)
		if err != nil {
			return nil, gcEolImagesOutput{}, err
		}
		oldest, supportedMinors, err := supportedWindow(releases)
		if err != nil {
			return nil, gcEolImagesOutput{}, err
		}

		var definitions []string
		if in.Flavor != "" {
			definitions = []string{definitionFor(in.Flavor)}
		} else {
			definitions, err = azure.ListImageDefinitions(ctx, rg, gallery)
			if err != nil {
				return nil, gcEolImagesOutput{}, err
			}
		}

		images := []retiredImage{}
		for _, def := range definitions {
			versions, err := azure.ListImageVersions(ctx, rg, gallery, def)
			if err != nil {
				return nil, gcEolImagesOutput{}, err
			}
			images = append(images, planRetirements(def, versions, oldest)...)
		}

		if in.Apply {
			for _, img := range images {
				if err := azure.DeleteImageVersion(ctx, rg, gallery, img.Definition, img.Version); err != nil {
					return nil, gcEolImagesOutput{}, fmt.Errorf("deleting %s/%s: %w", img.Definition, img.Version, err)
				}
			}
		}

		return nil, gcEolImagesOutput{
			ResourceGroup:   rg,
			Gallery:         gallery,
			SupportedMinors: supportedMinors,
			Applied:         in.Apply,
			Images:          images,
		}, nil
	})
}

type minorKey struct {
	major int
	minor int
}

// older reports whether k is an older minor than other.
func (k minorKey) older(other minorKey) bool {
	if k.major != other.major {
		return k.major < other.major
	}
	return k.minor < other.minor
}

type semver struct {
	major int
	minor int
	patch int
}

// parseGalleryVersion parses a gallery version like "1.34.9" or "v1.34.9".
// Gallery versions are always three numeric parts.
func parseGalleryVersion(v string) (semver, bool) {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(v), "v"), ".")
	if len(parts) != 3 {
		return semver{}, false
	}
	maj, err1 := strconv.Atoi(parts[0])
	min, err2 := strconv.Atoi(parts[1])
	pat, err3 := strconv.Atoi(parts[2])
	if err1 != nil || err2 != nil || err3 != nil {
		return semver{}, false
	}
	return semver{maj, min, pat}, true
}

// supportedWindow returns the oldest in-scope minor and the supported minor
// strings from the upstream releases in scope.
func supportedWindow(releases []k8s.Release) (minorKey, []string, error) {
	if len(releases) == 0 {
		return minorKey{}, nil, fmt.Errorf("no in-scope Kubernetes releases")
	}
	var oldest minorKey
	first := true
	minors := make([]string, 0, len(releases))
	for _, r := range releases {
		parts := strings.Split(r.Minor, ".")
		if len(parts) != 2 {
			return minorKey{}, nil, fmt.Errorf("invalid minor %q", r.Minor)
		}
		maj, err1 := strconv.Atoi(parts[0])
		min, err2 := strconv.Atoi(parts[1])
		if err1 != nil || err2 != nil {
			return minorKey{}, nil, fmt.Errorf("invalid minor %q", r.Minor)
		}
		minors = append(minors, r.Minor)
		k := minorKey{maj, min}
		if first || k.older(oldest) {
			oldest = k
			first = false
		}
	}
	return oldest, minors, nil
}

// planRetirements decides which versions of one definition to retire. A version
// is end of life if its minor is older than oldest, the oldest in-scope minor.
// Among in-scope minors, any patch below the highest patch present for that
// minor is superseded. Unparseable versions are left alone. Results are ordered
// oldest version first for stable output.
func planRetirements(definition string, versions []string, oldest minorKey) []retiredImage {
	parsed := make(map[string]semver, len(versions))
	highestPatch := map[minorKey]int{}
	for _, v := range versions {
		sv, ok := parseGalleryVersion(v)
		if !ok {
			continue
		}
		parsed[v] = sv
		k := minorKey{sv.major, sv.minor}
		if p, seen := highestPatch[k]; !seen || sv.patch > p {
			highestPatch[k] = sv.patch
		}
	}

	ordered := make([]string, 0, len(parsed))
	for v := range parsed {
		ordered = append(ordered, v)
	}
	sort.Slice(ordered, func(i, j int) bool {
		a, b := parsed[ordered[i]], parsed[ordered[j]]
		if a.major != b.major {
			return a.major < b.major
		}
		if a.minor != b.minor {
			return a.minor < b.minor
		}
		return a.patch < b.patch
	})

	var out []retiredImage
	for _, v := range ordered {
		sv := parsed[v]
		k := minorKey{sv.major, sv.minor}
		switch {
		case k.older(oldest):
			out = append(out, retiredImage{Definition: definition, Version: v, Reason: reasonEOL})
		case sv.patch < highestPatch[k]:
			out = append(out, retiredImage{Definition: definition, Version: v, Reason: reasonSuperseded})
		}
	}
	return out
}
