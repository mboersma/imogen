package tools

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type listGalleryVersionsInput struct {
	Stage         string `json:"stage,omitempty" jsonschema:"which gallery to look in by role: staging or community (defaults to community)"`
	Flavor        string `json:"flavor,omitempty" jsonschema:"limit to one image-builder flavor, such as ubuntu-2404; empty lists all"`
	ResourceGroup string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	Gallery       string `json:"gallery,omitempty" jsonschema:"explicit compute gallery name; overrides stage"`
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
		gallery := galleryFor(in.Gallery, in.Stage)
		if rg == "" || gallery == "" {
			return nil, listGalleryVersionsOutput{}, fmt.Errorf("resourceGroup and gallery are required (set them directly or via IMOGEN_RESOURCE_GROUP / IMOGEN_COMMUNITY_GALLERY)")
		}

		var definitions []string
		if in.Flavor != "" {
			definitions = []string{definitionFor(in.Flavor)}
		} else {
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

// galleryFor resolves a gallery name. An explicit name wins; otherwise stage
// selects the staging or community gallery by role, defaulting to community.
func galleryFor(explicit, stage string) string {
	if explicit != "" {
		return explicit
	}
	if strings.EqualFold(stage, "staging") {
		return os.Getenv("IMOGEN_STAGING_GALLERY")
	}
	return os.Getenv("IMOGEN_COMMUNITY_GALLERY")
}

// definitionFor maps an image-builder flavor to its gallery image definition.
// Definitions are named capi-<flavor>; callers may pass either form.
func definitionFor(flavor string) string {
	if strings.HasPrefix(flavor, "capi-") {
		return flavor
	}
	return "capi-" + flavor
}
