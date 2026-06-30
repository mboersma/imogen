package tools

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/mboersma/imogen/internal/k8s"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// gc-eol-images retires image versions whose Kubernetes minor has been out of
// upstream support long enough. The contract is deliberately conservative:
// downstream projects (cloud-provider-azure, cluster-autoscaler) keep testing
// against out-of-support releases and pin specific patches, so we only retire a
// whole minor once it has been past its upstream end-of-life date by a grace
// period (default one year), and we never delete a patch just because a newer
// one exists. It is destructive, so it defaults to a dry run that only reports
// the candidates; the agent (or an operator) calls it again with apply=true.

const defaultGraceDays = 365

type gcEolImagesInput struct {
	Stage         string `json:"stage,omitempty" jsonschema:"which gallery to clean by role: staging or community (defaults to community)"`
	Flavor        string `json:"flavor,omitempty" jsonschema:"limit to one image-builder flavor, such as ubuntu-2404; empty cleans all"`
	ResourceGroup string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	Gallery       string `json:"gallery,omitempty" jsonschema:"explicit compute gallery name; overrides stage"`
	GraceDays     int    `json:"graceDays,omitempty" jsonschema:"days a minor must be past its upstream end-of-life before retiring (default 365)"`
	Apply         bool   `json:"apply,omitempty" jsonschema:"actually delete the retired versions; default false only reports the candidates"`
}

type retiredImage struct {
	Definition  string `json:"definition"`
	Version     string `json:"version"`
	Minor       string `json:"minor"`
	UpstreamEOL string `json:"upstreamEol"`
}

type gcEolImagesOutput struct {
	ResourceGroup string         `json:"resourceGroup"`
	Gallery       string         `json:"gallery"`
	GraceDays     int            `json:"graceDays"`
	Applied       bool           `json:"applied"`
	Images        []retiredImage `json:"images"`
}

func registerGcEolImages(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "gc-eol-images",
		Description: "Find and optionally delete image versions whose Kubernetes minor has been out of upstream support for longer than graceDays (default 365). It retires whole minors only, never individual patches, so pinned patch releases stay until their minor ages out. Defaults to a dry run that only reports candidates; call with apply=true to delete them.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in gcEolImagesInput) (*mcp.CallToolResult, gcEolImagesOutput, error) {
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		gallery := galleryFor(in.Gallery, in.Stage)
		if rg == "" || gallery == "" {
			return nil, gcEolImagesOutput{}, fmt.Errorf("resourceGroup and gallery are required (set them directly or via IMOGEN_RESOURCE_GROUP / IMOGEN_COMMUNITY_GALLERY)")
		}

		graceDays := in.GraceDays
		if graceDays <= 0 {
			graceDays = defaultGraceDays
		}
		grace := time.Duration(graceDays) * 24 * time.Hour

		eolByMinor, err := k8s.MinorEOLDates(ctx)
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

		now := time.Now()
		images := []retiredImage{}
		for _, def := range definitions {
			versions, err := azure.ListImageVersions(ctx, rg, gallery, def)
			if err != nil {
				return nil, gcEolImagesOutput{}, err
			}
			images = append(images, planRetirements(def, versions, eolByMinor, now, grace)...)
		}

		if in.Apply {
			for _, img := range images {
				if err := azure.DeleteImageVersion(ctx, rg, gallery, img.Definition, img.Version); err != nil {
					return nil, gcEolImagesOutput{}, fmt.Errorf("deleting %s/%s: %w", img.Definition, img.Version, err)
				}
			}
		}

		return nil, gcEolImagesOutput{
			ResourceGroup: rg,
			Gallery:       gallery,
			GraceDays:     graceDays,
			Applied:       in.Apply,
			Images:        images,
		}, nil
	})
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

// planRetirements decides which versions of one definition to retire. A version
// is retired only when its Kubernetes minor has a known upstream end-of-life
// date and that date is more than grace in the past. Minors that are still
// supported, within the grace window, or have no known EOL date (newer or
// unrecognized) are kept, as are unparseable versions. Patches are never
// retired on their own: a whole minor ages out together. Results are ordered
// oldest version first for stable output.
func planRetirements(definition string, versions []string, eolByMinor map[string]time.Time, now time.Time, grace time.Duration) []retiredImage {
	parsed := make(map[string]semver, len(versions))
	for _, v := range versions {
		if sv, ok := parseGalleryVersion(v); ok {
			parsed[v] = sv
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
		minor := fmt.Sprintf("%d.%d", sv.major, sv.minor)
		eol, known := eolByMinor[minor]
		if !known || now.Sub(eol) < grace {
			continue
		}
		out = append(out, retiredImage{
			Definition:  definition,
			Version:     v,
			Minor:       minor,
			UpstreamEOL: eol.Format("2006-01-02"),
		})
	}
	return out
}
