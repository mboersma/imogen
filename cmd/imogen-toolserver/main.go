// Command imogen-toolserver runs the imogen MCP tool server.
//
// It exposes the imogen pipeline actions (image build, validation, promotion,
// cleanup) as MCP tools that a kagent Agent can call. Tools are added in the
// tools package; this entrypoint just wires them up and serves over stdio.
package main

import (
	"context"
	"log"

	"github.com/mboersma/imogen/internal/tools"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "imogen-toolserver",
		Version: "v0.1.0",
	}, nil)

	tools.Register(server)

	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		log.Fatal(err)
	}
}
