// Command imogen-toolserver runs the imogen MCP tool server.
//
// It exposes the imogen pipeline actions (image build, validation, promotion,
// cleanup) as MCP tools that a kagent Agent can call. Tools are added in the
// tools package.
//
// By default the server speaks MCP over stdio. Set IMOGEN_TOOLSERVER_ADDR to a
// listen address (for example ":8080") to serve MCP over streamable HTTP
// instead, which is how kagent's RemoteMCPServer connects to it in cluster.
package main

import (
	"context"
	"log"
	"net/http"
	"os"

	"github.com/mboersma/imogen/internal/tools"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func newServer() *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "imogen-toolserver",
		Version: "v0.1.0",
	}, nil)
	tools.Register(server)
	return server
}

func main() {
	server := newServer()

	addr := os.Getenv("IMOGEN_TOOLSERVER_ADDR")
	if addr == "" {
		if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
			log.Fatal(err)
		}
		return
	}

	// DNS rebinding protection rejects non-localhost Host headers that arrive
	// over a localhost address. That blocks the local-dev path where the agent
	// in kind reaches this server on the host through host.containers.internal,
	// so allow opting out. In cluster requests do not arrive over localhost, so
	// the default protection stays on.
	var opts *mcp.StreamableHTTPOptions
	if os.Getenv("IMOGEN_TOOLSERVER_ALLOW_REMOTE_HOST") == "1" {
		opts = &mcp.StreamableHTTPOptions{DisableLocalhostProtection: true}
	}
	handler := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server {
		return server
	}, opts)
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.Handle("/", handler)

	log.Printf("imogen-toolserver serving MCP over HTTP on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
