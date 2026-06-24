package tools

import (
	"context"

	"github.com/mboersma/imogen/internal/k8s"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type listK8sReleasesInput struct {
	MinorCount int `json:"minorCount,omitempty" jsonschema:"how many recent minor versions to return (default 3)"`
}

type listK8sReleasesOutput struct {
	Releases []k8s.Release `json:"releases"`
}

func registerListK8sReleases(server *mcp.Server) {
	mcp.AddTool(server, &mcp.Tool{
		Name:        "list-k8s-releases",
		Description: "List the latest stable patch release for recent Kubernetes minor versions.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in listK8sReleasesInput) (*mcp.CallToolResult, listK8sReleasesOutput, error) {
		releases, err := k8s.LatestStable(ctx, in.MinorCount)
		if err != nil {
			return nil, listK8sReleasesOutput{}, err
		}
		return nil, listK8sReleasesOutput{Releases: releases}, nil
	})
}
