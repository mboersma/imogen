package tools

import (
	"context"
	"fmt"
	"strings"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// promote-image copies a validated image version from the staging gallery to
// the community gallery. The agent calls this only after validation passes and
// any required approval is granted.

type promoteImageInput struct {
	Flavor        string   `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version       string   `json:"version" jsonschema:"image version to promote, such as 1.34.9 or v1.34.9"`
	ResourceGroup string   `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	SourceGallery string   `json:"sourceGallery,omitempty" jsonschema:"staging gallery (defaults to IMOGEN_STAGING_GALLERY)"`
	TargetGallery string   `json:"targetGallery,omitempty" jsonschema:"community gallery (defaults to IMOGEN_COMMUNITY_GALLERY)"`
	TargetRegions []string `json:"targetRegions,omitempty" jsonschema:"regions to replicate to; defaults to the source region"`
}

type promoteImageOutput struct {
	ImageDefinition string `json:"imageDefinition"`
	Version         string `json:"version"`
	SourceGallery   string `json:"sourceGallery"`
	TargetGallery   string `json:"targetGallery"`
}

func registerPromoteImage(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "promote-image",
		Description: "Promote a validated image version from the staging gallery to the community gallery. Call only after validation passes and approval is granted.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in promoteImageInput) (*mcp.CallToolResult, promoteImageOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, promoteImageOutput{}, fmt.Errorf("flavor and version are required")
		}
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		source := envOr(in.SourceGallery, "IMOGEN_STAGING_GALLERY")
		target := envOr(in.TargetGallery, "IMOGEN_COMMUNITY_GALLERY")
		if rg == "" || source == "" || target == "" {
			return nil, promoteImageOutput{}, fmt.Errorf("resourceGroup, sourceGallery and targetGallery are required (set them directly or via IMOGEN_* env vars)")
		}

		version := strings.TrimPrefix(in.Version, "v")
		definition := definitionFor(in.Flavor)

		subscriptionID, err := azure.SubscriptionID(ctx)
		if err != nil {
			return nil, promoteImageOutput{}, err
		}

		err = azure.PromoteImageVersion(ctx, azure.Promotion{
			ResourceGroup:  rg,
			SourceGallery:  source,
			TargetGallery:  target,
			Definition:     definition,
			Version:        version,
			SubscriptionID: subscriptionID,
			TargetRegions:  in.TargetRegions,
		})
		if err != nil {
			return nil, promoteImageOutput{}, err
		}

		return nil, promoteImageOutput{
			ImageDefinition: definition,
			Version:         version,
			SourceGallery:   source,
			TargetGallery:   target,
		}, nil
	})
}
