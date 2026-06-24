package tools

import (
	"context"
	"fmt"
	"strings"

	"github.com/mboersma/imogen/internal/azure"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Temporary standalone build path. submit-build-job runs the image-builder
// container on Azure Container Instances, publishing to the staging gallery.
// This moves to a Kubernetes Job on the CAPZ builder cluster later.

const defaultBuilderImage = "registry.k8s.io/scl-image-builder/cluster-node-image-builder-amd64:v0.1.52"

type submitBuildJobInput struct {
	Flavor        string `json:"flavor" jsonschema:"image-builder flavor, such as ubuntu-2404"`
	Version       string `json:"version" jsonschema:"Kubernetes version to build, such as v1.34.9"`
	ResourceGroup string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
	Gallery       string `json:"gallery,omitempty" jsonschema:"staging gallery name (defaults to IMOGEN_STAGING_GALLERY)"`
	Location      string `json:"location,omitempty" jsonschema:"Azure region (defaults to IMOGEN_LOCATION)"`
	BuilderImage  string `json:"builderImage,omitempty" jsonschema:"image-builder container (defaults to IMOGEN_BUILDER_IMAGE)"`
	ClientID      string `json:"clientId,omitempty" jsonschema:"managed identity client id (defaults to IMOGEN_BUILDER_CLIENT_ID)"`
	IdentityID    string `json:"identityId,omitempty" jsonschema:"managed identity resource id (defaults to IMOGEN_BUILDER_IDENTITY_ID)"`
}

type submitBuildJobOutput struct {
	ContainerGroup  string `json:"containerGroup"`
	Flavor          string `json:"flavor"`
	Version         string `json:"version"`
	Gallery         string `json:"gallery"`
	ImageDefinition string `json:"imageDefinition"`
	ImageVersion    string `json:"imageVersion"`
}

func registerSubmitBuildJob(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "submit-build-job",
		Description: "Build a CAPZ reference image for one flavor and Kubernetes version with image-builder, publishing to the staging gallery. Runs as a standalone container.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in submitBuildJobInput) (*mcp.CallToolResult, submitBuildJobOutput, error) {
		if in.Flavor == "" || in.Version == "" {
			return nil, submitBuildJobOutput{}, fmt.Errorf("flavor and version are required")
		}
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		gallery := envOr(in.Gallery, "IMOGEN_STAGING_GALLERY")
		location := envOr(in.Location, "IMOGEN_LOCATION")
		image := envOr(in.BuilderImage, "IMOGEN_BUILDER_IMAGE")
		if image == "" {
			image = defaultBuilderImage
		}
		clientID := envOr(in.ClientID, "IMOGEN_BUILDER_CLIENT_ID")
		identityID := envOr(in.IdentityID, "IMOGEN_BUILDER_IDENTITY_ID")
		if rg == "" || gallery == "" || location == "" || clientID == "" || identityID == "" {
			return nil, submitBuildJobOutput{}, fmt.Errorf("resourceGroup, gallery, location, clientId and identityId are required (set them directly or via IMOGEN_* env vars)")
		}

		sigVersion := strings.TrimPrefix(in.Version, "v")
		series := "v" + sigVersion[:strings.LastIndex(sigVersion, ".")]
		semver := "v" + sigVersion
		packerFlags := strings.Join([]string{
			"--var sig_image_version=" + sigVersion,
			"--var kubernetes_semver=" + semver,
			"--var kubernetes_series=" + series,
			"--var kubernetes_deb_version=" + sigVersion + "-1.1",
			"--var kubernetes_rpm_version=" + sigVersion,
		}, " ")

		subscriptionID, err := azure.SubscriptionID(ctx)
		if err != nil {
			return nil, submitBuildJobOutput{}, err
		}

		name := fmt.Sprintf("imogen-build-%s-%s", in.Flavor, strings.ReplaceAll(sigVersion, ".", "-"))
		err = azure.StartBuildContainer(ctx, azure.BuildContainer{
			ResourceGroup:  rg,
			Name:           name,
			Image:          image,
			Location:       location,
			IdentityID:     identityID,
			ClientID:       clientID,
			SubscriptionID: subscriptionID,
			Gallery:        gallery,
			Target:         "build-azure-sig-" + in.Flavor,
			PackerFlags:    packerFlags,
		})
		if err != nil {
			return nil, submitBuildJobOutput{}, err
		}

		return nil, submitBuildJobOutput{
			ContainerGroup:  name,
			Flavor:          in.Flavor,
			Version:         semver,
			Gallery:         gallery,
			ImageDefinition: "capi-" + in.Flavor,
			ImageVersion:    sigVersion,
		}, nil
	})
}

type getBuildStatusInput struct {
	ContainerGroup string `json:"containerGroup" jsonschema:"the build container group name returned by submit-build-job"`
	ResourceGroup  string `json:"resourceGroup,omitempty" jsonschema:"Azure resource group (defaults to IMOGEN_RESOURCE_GROUP)"`
}

type getBuildStatusOutput struct {
	ContainerGroup string `json:"containerGroup"`
	State          string `json:"state"`
}

func registerGetBuildStatus(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "get-build-status",
		Description: "Report the state of a build container group, such as Running, Succeeded or Failed.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in getBuildStatusInput) (*mcp.CallToolResult, getBuildStatusOutput, error) {
		if in.ContainerGroup == "" {
			return nil, getBuildStatusOutput{}, fmt.Errorf("containerGroup is required")
		}
		rg := envOr(in.ResourceGroup, "IMOGEN_RESOURCE_GROUP")
		if rg == "" {
			return nil, getBuildStatusOutput{}, fmt.Errorf("resourceGroup is required (set it directly or via IMOGEN_RESOURCE_GROUP)")
		}
		state, err := azure.ContainerState(ctx, rg, in.ContainerGroup)
		if err != nil {
			return nil, getBuildStatusOutput{}, err
		}
		return nil, getBuildStatusOutput{ContainerGroup: in.ContainerGroup, State: state}, nil
	})
}
