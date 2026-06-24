// Package tools registers the imogen MCP tools on a server.
package tools

import "github.com/modelcontextprotocol/go-sdk/mcp"

// Register adds all imogen tools to the MCP server.
func Register(server *mcp.Server) {
	registerListK8sReleases(server)
}
