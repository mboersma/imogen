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
// any required approval is granted. The underlying gallery create is a
// long-running operation that can exceed the MCP client timeout, so promote-image
// submits it and returns immediately; the agent polls get-promote-status.

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
	State           string `json:"state"`
}

func registerPromoteImage(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "promote-image",
		Description: "Start promoting a validated image version from the staging gallery to the community gallery. Call only after validation passes and approval is granted. Returns immediately; poll get-promote-status until the state is Succeeded.",
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

		err = azure.StartImageVersionPromotion(ctx, azure.Promotion{
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
			State:           "Creating",
		}, nil
	})
}

type getPromoteStatusInput struct {
	Flavor        string `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version       string `json:"version" jsonschema:"image version being promoted, such as 1.34.9 or v1.34.9"`
	ResourceGroup string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	TargetGallery string `json:"targetGallery,omitempty" jsonschema:"community gallery (defaults to IMOGEN_COMMUNITY_GALLERY)"`
}

type getPromoteStatusOutput struct {
	ImageDefinition string `json:"imageDefinition"`
	Version         string `json:"version"`
	TargetGallery   string `json:"targetGallery"`
	State           string `json:"state"`
}

func registerGetPromoteStatus(server *mcp.Server) {
	auditedTool(server, &mcp.Tool{
		Name:        "get-promote-status",
		Description: "Report the state of a promotion in the community gallery: Creating, Succeeded, Failed or NotFound. Poll this after promote-image until the state is Succeeded.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in getPromoteStatusInput) (*mcp.CallToolResult, getPromoteStatusOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, getPromoteStatusOutput{}, fmt.Errorf("flavor and version are required")
		}
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		target := envOr(in.TargetGallery, "IMOGEN_COMMUNITY_GALLERY")
		if rg == "" || target == "" {
			return nil, getPromoteStatusOutput{}, fmt.Errorf("resourceGroup and targetGallery are required (set them directly or via IMOGEN_* env vars)")
		}

		version := strings.TrimPrefix(in.Version, "v")
		definition := definitionFor(in.Flavor)

		state, err := azure.ImageVersionProvisioningState(ctx, rg, target, definition, version)
		if err != nil {
			return nil, getPromoteStatusOutput{}, err
		}

		return nil, getPromoteStatusOutput{
			ImageDefinition: definition,
			Version:         version,
			TargetGallery:   target,
			State:           state,
		}, nil
	})
}
