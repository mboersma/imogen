// Package tools registers the imogen MCP tools on a server.
package tools

import "github.com/modelcontextprotocol/go-sdk/mcp"

// Register adds all imogen tools to the MCP server.
func Register(server *mcp.Server) {
	registerListK8sReleases(server)
	registerListGalleryVersions(server)
	registerListReconcilePlan(server)
	registerSubmitBuildJob(server)
	registerGetBuildStatus(server)
	registerValidateImage(server)
	registerGetValidationStatus(server)
	registerPromoteImage(server)
	registerGetPromoteStatus(server)
	registerGcEolImages(server)
	registerNotify(server)
	registerGetAuditLog(server)
}
