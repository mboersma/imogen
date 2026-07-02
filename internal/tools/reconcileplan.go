package tools

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/mboersma/imogen/internal/k8s"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// list-reconcile-plan computes, deterministically, exactly which (flavor,
// version) pairs the community gallery is missing and how to close each gap.
// The release-watcher agent reliably mis-derives this set difference once more
// than one flavor is in scope (it lists the galleries correctly, then declares
// everything present and does nothing), so this tool does the diff in Go and
// hands the agent an explicit work list to execute rather than a set-difference
// problem to reason about.
//
// For each in-scope upstream version (the latest stable patch of each recent
// minor) and each flavor, it reports one of three states:
//   - present:          already in the community gallery, nothing to do
//   - validate-promote: already built into staging, needs validate + promote
//   - build:            missing from both galleries, needs a build first
//
// Only the versions needing action are returned in Work; upToDate is true when
// Work is empty.

type listReconcilePlanInput struct {
	Flavors       []string `json:"flavors,omitempty" jsonschema:"image-builder flavors to reconcile, such as ubuntu-2404; empty uses every definition in the community gallery"`
	MinorCount    int      `json:"minorCount,omitempty" jsonschema:"how many recent Kubernetes minor versions to track (default 3)"`
	ResourceGroup string   `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
}

type reconcileWorkItem struct {
	Flavor  string `json:"flavor"`
	Version string `json:"version"`
	Minor   string `json:"minor"`
	Action  string `json:"action"` // "build" or "validate-promote"
}

type listReconcilePlanOutput struct {
	ResourceGroup    string              `json:"resourceGroup"`
	StagingGallery   string              `json:"stagingGallery"`
	CommunityGallery string              `json:"communityGallery"`
	MinorCount       int                 `json:"minorCount"`
	Flavors          []string            `json:"flavors"`
	UpToDate         bool                `json:"upToDate"`
	Work             []reconcileWorkItem `json:"work"`
}

func registerListReconcilePlan(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "list-reconcile-plan",
		Description: "Compute exactly which image versions the community gallery is missing and how to close each gap. For every recent Kubernetes minor's latest stable patch and every flavor, it diffs the staging and community galleries and returns an explicit work list: action=build for versions missing from both galleries, action=validate-promote for versions already in staging but not community. Versions already in the community gallery are omitted, and upToDate is true when there is no work. Use this instead of computing the gap by hand.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in listReconcilePlanInput) (*mcp.CallToolResult, listReconcilePlanOutput, error) {
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		staging := galleryFor("", "staging")
		community := galleryFor("", "community")
		if rg == "" || staging == "" || community == "" {
			return nil, listReconcilePlanOutput{}, fmt.Errorf("resourceGroup, staging and community galleries are required (set IMOGEN_RESOURCE_GROUP, IMOGEN_STAGING_GALLERY, IMOGEN_COMMUNITY_GALLERY)")
		}

		minorCount := in.MinorCount
		if minorCount <= 0 {
			minorCount = 3
		}

		releases, err := k8s.LatestStable(ctx, minorCount)
		if err != nil {
			return nil, listReconcilePlanOutput{}, err
		}

		flavors, err := resolveFlavors(ctx, in.Flavors, rg, community)
		if err != nil {
			return nil, listReconcilePlanOutput{}, err
		}

		work := []reconcileWorkItem{}
		for _, flavor := range flavors {
			def := definitionFor(flavor)
			stagingVersions, err := versionSet(ctx, rg, staging, def)
			if err != nil {
				return nil, listReconcilePlanOutput{}, err
			}
			communityVersions, err := versionSet(ctx, rg, community, def)
			if err != nil {
				return nil, listReconcilePlanOutput{}, err
			}
			work = append(work, diffFlavor(flavor, releases, stagingVersions, communityVersions)...)
		}

		return nil, listReconcilePlanOutput{
			ResourceGroup:    rg,
			StagingGallery:   staging,
			CommunityGallery: community,
			MinorCount:       minorCount,
			Flavors:          flavors,
			UpToDate:         len(work) == 0,
			Work:             work,
		}, nil
	})
}

// diffFlavor returns the work needed to bring one flavor's community-gallery
// state up to the in-scope upstream releases. A version already in community is
// skipped; one only in staging needs validate-promote; one in neither needs a
// build first.
func diffFlavor(flavor string, releases []k8s.Release, staging, community map[string]bool) []reconcileWorkItem {
	var out []reconcileWorkItem
	for _, r := range releases {
		version := strings.TrimPrefix(r.Version, "v")
		if community[version] {
			continue // already published
		}
		action := "build"
		if staging[version] {
			action = "validate-promote"
		}
		out = append(out, reconcileWorkItem{
			Flavor:  flavor,
			Version: version,
			Minor:   r.Minor,
			Action:  action,
		})
	}
	return out
}

// resolveFlavors returns the requested flavors, or every definition in the
// community gallery (mapped back to flavor names) when none are given.
func resolveFlavors(ctx context.Context, requested []string, rg, gallery string) ([]string, error) {
	if len(requested) > 0 {
		out := make([]string, 0, len(requested))
		for _, f := range requested {
			out = append(out, strings.TrimPrefix(f, "capi-"))
		}
		return out, nil
	}
	defs, err := azure.ListImageDefinitions(ctx, rg, gallery)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(defs))
	for _, d := range defs {
		out = append(out, strings.TrimPrefix(d, "capi-"))
	}
	sort.Strings(out)
	return out, nil
}

// versionSet lists the versions of one definition in a gallery as a set keyed
// by the bare "1.34.9" form. A missing definition yields an empty set.
func versionSet(ctx context.Context, rg, gallery, def string) (map[string]bool, error) {
	versions, err := azure.ListImageVersions(ctx, rg, gallery, def)
	if err != nil {
		return nil, err
	}
	set := make(map[string]bool, len(versions))
	for _, v := range versions {
		set[strings.TrimPrefix(strings.TrimSpace(v), "v")] = true
	}
	return set, nil
}
