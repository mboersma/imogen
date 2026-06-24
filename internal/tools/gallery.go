package tools

import (
	"context"
	"fmt"
	"os"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type listGalleryVersionsInput struct {
	ResourceGroup   string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	Gallery         string `json:"gallery,omitempty" jsonschema:"compute gallery name (defaults to IMOGEN_COMMUNITY_GALLERY)"`
	ImageDefinition string `json:"imageDefinition,omitempty" jsonschema:"limit to one image definition; empty lists all"`
}

type galleryImage struct {
	Definition string `json:"definition"`
	Version    string `json:"version"`
}

type listGalleryVersionsOutput struct {
	ResourceGroup string         `json:"resourceGroup"`
	Gallery       string         `json:"gallery"`
	Images        []galleryImage `json:"images"`
}

func registerListGalleryVersions(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "list-gallery-versions",
		Description: "List the image versions present in an Azure compute gallery, by image definition.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in listGalleryVersionsInput) (*mcp.CallToolResult, listGalleryVersionsOutput, error) {
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		gallery := envOr(in.Gallery, "IMOGEN_COMMUNITY_GALLERY")
		if rg == "" || gallery == "" {
			return nil, listGalleryVersionsOutput{}, fmt.Errorf("resourceGroup and gallery are required (set them directly or via IMOGEN_RESOURCE_GROUP / IMOGEN_COMMUNITY_GALLERY)")
		}

		definitions := []string{in.ImageDefinition}
		if in.ImageDefinition == "" {
			var err error
			definitions, err = azure.ListImageDefinitions(ctx, rg, gallery)
			if err != nil {
				return nil, listGalleryVersionsOutput{}, err
			}
		}

		images := []galleryImage{}
		for _, def := range definitions {
			versions, err := azure.ListImageVersions(ctx, rg, gallery, def)
			if err != nil {
				return nil, listGalleryVersionsOutput{}, err
			}
			for _, v := range versions {
				images = append(images, galleryImage{Definition: def, Version: v})
			}
		}

		return nil, listGalleryVersionsOutput{ResourceGroup: rg, Gallery: gallery, Images: images}, nil
	})
}

// envOr returns val if non-empty, otherwise the named environment variable.
func envOr(val, key string) string {
	if val != "" {
		return val
	}
	return os.Getenv(key)
}
