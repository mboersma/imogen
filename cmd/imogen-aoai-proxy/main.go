// Command imogen-aoai-proxy is a tiny reverse proxy that fronts an Azure OpenAI
// endpoint and injects a fresh Entra ID bearer token on every forwarded request.
//
// It exists to work around this kagent version: its Azure OpenAI client only
// sends a static header, and the token that header must carry (this account is
// Entra-only) lives only ~74 minutes. kagent folds that header into the agent
// Deployment's config-hash, so rotating the token in the ModelConfig rolls the
// agent and kills any in-flight reconcile; letting it go stale instead fails the
// run with 401. Pointing the ModelConfig at this proxy with a fixed placeholder
// header keeps the token out of kagent's config entirely: the proxy holds the
// workload identity, mints and refreshes the token itself, and the agent never
// rolls or expires mid-run.
//
// The proxy authenticates with the pod's workload identity (via
// DefaultAzureCredential) for the cognitiveservices.azure.com audience, caches
// the token, and refreshes it shortly before expiry. It streams responses
// unbuffered so Server-Sent Events (the model's streaming completions) flow
// through immediately.
package main

import (
	"context"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
)

// tokenScope is the Azure OpenAI data-plane audience. The trailing /.default
// requests the identity's assigned application permissions for that resource.
const tokenScope = "https://cognitiveservices.azure.com/.default"

// refreshSkew is how long before expiry a cached token is considered stale, so a
// request never forwards a token that expires while the upstream is handling it.
const refreshSkew = 5 * time.Minute

// tokenSource hands out a valid Entra token, minting a new one from the workload
// identity when the cached one is missing or near expiry.
type tokenSource struct {
	cred azcore.TokenCredential

	mu     sync.Mutex
	token  string
	expiry time.Time
}

func (t *tokenSource) get(ctx context.Context) (string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.token != "" && time.Until(t.expiry) > refreshSkew {
		return t.token, nil
	}

	tok, err := t.cred.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{tokenScope}})
	if err != nil {
		return "", err
	}
	t.token = tok.Token
	t.expiry = tok.ExpiresOn
	return t.token, nil
}

func main() {
	addr := envOr("IMOGEN_AOAI_PROXY_ADDR", ":8080")
	upstream := os.Getenv("IMOGEN_AOAI_UPSTREAM")
	if upstream == "" {
		log.Fatal("IMOGEN_AOAI_UPSTREAM is required (the real Azure OpenAI endpoint, e.g. https://<account>.openai.azure.com/)")
	}
	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("invalid IMOGEN_AOAI_UPSTREAM %q: %v", upstream, err)
	}

	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Fatalf("failed to build Azure credential: %v", err)
	}
	src := &tokenSource{cred: cred}

	// Fail fast if the identity cannot mint a token at all, rather than starting
	// up healthy and 500ing every model call.
	if _, err := src.get(context.Background()); err != nil {
		log.Fatalf("failed to acquire an initial Azure OpenAI token: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	// Stream responses through immediately; the model's completions arrive as
	// Server-Sent Events and must not be buffered.
	proxy.FlushInterval = -1

	base := proxy.Director
	proxy.Director = func(req *http.Request) {
		base(req)
		// Route to the upstream host regardless of the inbound Host header.
		req.Host = target.Host
		// Strip any client-supplied credentials (kagent sends a placeholder
		// header and an unused api-key) and inject the real Entra token.
		req.Header.Del("api-key")
		token, err := src.get(req.Context())
		if err != nil {
			// Clear auth so the upstream 401s rather than forwarding a stale
			// token; log here so the cause is visible in the proxy's own logs.
			log.Printf("token acquisition failed: %v", err)
			req.Header.Del("Authorization")
			return
		}
		req.Header.Set("Authorization", "Bearer "+token)
	}

	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		log.Printf("proxy error: %v", err)
		http.Error(w, "upstream request failed", http.StatusBadGateway)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.Handle("/", proxy)

	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 30 * time.Second,
	}
	log.Printf("imogen-aoai-proxy listening on %s, forwarding to %s", addr, target)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server exited: %v", err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
