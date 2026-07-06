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
	"bytes"
	"context"
	"io"
	"log"
	"math/rand"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
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

// Retry tuning for upstream throttling. A reconcile fires many model calls in
// bursts, so Azure OpenAI occasionally answers 429 (or a transient 503). kagent
// treats those as fatal and aborts the whole run, so the proxy absorbs them here:
// it waits (honoring Retry-After when present) and replays the request, turning a
// throttle into added latency instead of a failed unattended reconcile.
const (
	maxRetries    = 6
	maxRetryWait  = 30 * time.Second
	baseRetryWait = time.Second
)

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

// retryTransport replays a request when the upstream throttles it (429) or is
// briefly unavailable (503), so a burst of model calls degrades to added latency
// rather than a failed reconcile. It buffers the request body up front so the
// retried attempt can resend it; Azure OpenAI request bodies are small JSON, so
// buffering is cheap.
type retryTransport struct {
	base http.RoundTripper
}

func (rt *retryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	var body []byte
	if req.Body != nil {
		b, err := io.ReadAll(req.Body)
		_ = req.Body.Close()
		if err != nil {
			return nil, err
		}
		body = b
	}

	for attempt := 0; ; attempt++ {
		if body != nil {
			req.Body = io.NopCloser(bytes.NewReader(body))
			req.ContentLength = int64(len(body))
		}
		resp, err := rt.base.RoundTrip(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode != http.StatusTooManyRequests && resp.StatusCode != http.StatusServiceUnavailable {
			return resp, nil
		}
		if attempt >= maxRetries {
			// Out of retries; surface the throttle to the caller.
			return resp, nil
		}
		wait := retryWait(resp, attempt)
		log.Printf("upstream returned %d, retry %d/%d in %s", resp.StatusCode, attempt+1, maxRetries, wait.Round(time.Millisecond))
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		select {
		case <-req.Context().Done():
			return nil, req.Context().Err()
		case <-time.After(wait):
		}
	}
}

// retryWait picks a backoff: the upstream's Retry-After when present (seconds or
// an HTTP date), otherwise exponential backoff with jitter, capped at maxRetryWait.
func retryWait(resp *http.Response, attempt int) time.Duration {
	if ra := resp.Header.Get("Retry-After"); ra != "" {
		if secs, err := strconv.Atoi(ra); err == nil && secs >= 0 {
			return capWait(time.Duration(secs) * time.Second)
		}
		if t, err := http.ParseTime(ra); err == nil {
			if d := time.Until(t); d > 0 {
				return capWait(d)
			}
		}
	}
	backoff := baseRetryWait << attempt
	jitter := time.Duration(rand.Int63n(int64(baseRetryWait)))
	return capWait(backoff + jitter)
}

func capWait(d time.Duration) time.Duration {
	if d > maxRetryWait {
		return maxRetryWait
	}
	return d
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
	// Retry upstream throttles so a burst of model calls never fails the run.
	proxy.Transport = &retryTransport{base: http.DefaultTransport}

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
