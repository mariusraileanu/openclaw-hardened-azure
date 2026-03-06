package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// subscriber represents a single downstream SSE client filtered by phone number.
type subscriber struct {
	phone string
	ch    chan []byte   // raw SSE event bytes (already formatted as "event:...\ndata:...\n\n")
	done  chan struct{} // closed when subscriber disconnects; senders check this to avoid panic
}

var (
	mu          sync.RWMutex
	subscribers = make(map[string][]*subscriber) // phone -> active subscribers
	upstreamOK  atomic.Bool
)

// maskPhone redacts the middle digits of a phone number for log safety.
// "+15551234567" → "+155***567", short numbers pass through as-is.
// The result is also sanitized to prevent log forging via control characters.
func maskPhone(phone string) string {
	clean := sanitizeLog(phone)
	if len(clean) <= 6 {
		return clean
	}
	return clean[:4] + "***" + clean[len(clean)-3:]
}

// sanitizeLog strips control characters (newlines, carriage returns, tabs) from
// a string before it is written to logs. This prevents log forging attacks where
// user-controlled input (e.g. phone numbers from URL paths) could inject fake
// log entries via embedded newline characters.
func sanitizeLog(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return '_'
		}
		return r
	}, s)
}

// authMiddleware validates a bearer token on every request except health checks.
// The token can be supplied via (checked in order):
//  1. Path segment:        /user/{phone}/{token}/api/v1/...  (primary — works with any client)
//  2. Query parameter:     ?token=<secret>
//  3. HTTP Basic Auth:     http://token:x@host/...
//  4. Authorization header: Bearer <secret>
//
// Method 1 is the primary mechanism: OpenClaw's signal client treats httpUrl as
// a base URL and appends sub-paths (e.g. /api/v1/events). Embedding the token
// as a path segment ensures it survives URL construction by any client.
//
// Health-check paths (/healthz, /api/v1/check) are exempt so that Azure
// Container Apps probes and signal-cli passthrough continue to work.
func authMiddleware(next http.Handler, token string) http.Handler {
	tokenBytes := []byte(token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Skip auth for health-check endpoints (probes must remain unauthenticated)
		if r.URL.Path == "/healthz" || r.URL.Path == "/api/v1/check" {
			next.ServeHTTP(w, r)
			return
		}

		var candidate string

		// 1. Path-embedded token: /user/{phone}/{token}/api/v1/...
		//    The token is the segment between the phone and /api/.
		if strings.HasPrefix(r.URL.Path, "/user/") {
			candidate = extractPathToken(r.URL.Path)
		}

		// 2. Query parameter ?token=...
		if candidate == "" {
			candidate = r.URL.Query().Get("token")
		}

		// 3. HTTP Basic Auth (username carries the token, password is ignored)
		if candidate == "" {
			if user, _, ok := r.BasicAuth(); ok {
				candidate = user
			}
		}

		// 4. Authorization: Bearer <token>
		if candidate == "" {
			if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
				candidate = strings.TrimPrefix(h, "Bearer ")
			}
		}

		if subtle.ConstantTimeCompare([]byte(candidate), tokenBytes) != 1 {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		// Strip token from query string before forwarding to handlers
		q := r.URL.Query()
		q.Del("token")
		r.URL.RawQuery = q.Encode()

		next.ServeHTTP(w, r)
	})
}

// extractPathToken extracts the token segment from a /user/{phone}/{token}/... path.
// Returns "" if the path doesn't match the expected format.
func extractPathToken(path string) string {
	// Path: /user/{phone}/{token}/api/v1/...
	// After stripping "/user/": {phone}/{token}/api/v1/...
	rest := strings.TrimPrefix(path, "/user/")
	parts := strings.SplitN(rest, "/", 3) // [phone, token, api/v1/...]
	if len(parts) < 2 {
		return ""
	}
	// parts[0] = phone (starts with "+"), parts[1] = token candidate
	// Validate that it's not a known API path segment (backwards compat)
	token := parts[1]
	if token == "api" || token == "" {
		return "" // old format /user/{phone}/api/v1/... — no embedded token
	}
	return token
}

// securityHeadersMiddleware adds standard security headers to all responses.
// HSTS (Strict-Transport-Security) instructs clients to use HTTPS exclusively.
// While signal-proxy runs behind an internal load balancer with no browser
// traffic, the header satisfies SAST scanners and follows defense-in-depth.
func securityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func main() {
	upstreamURL := os.Getenv("SIGNAL_CLI_URL")
	if upstreamURL == "" {
		log.Fatal("SIGNAL_CLI_URL env var is required")
	}
	upstreamURL = strings.TrimRight(upstreamURL, "/")

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8080"
	}

	authToken := os.Getenv("AUTH_TOKEN")
	if authToken == "" {
		log.Println("WARNING: AUTH_TOKEN not set — proxy is running WITHOUT authentication")
	} else {
		log.Println("AUTH_TOKEN is set — token authentication enabled")
	}

	parsed, err := url.Parse(upstreamURL)
	if err != nil {
		log.Fatalf("invalid SIGNAL_CLI_URL: %v", err)
	}
	rpcProxy := httputil.NewSingleHostReverseProxy(parsed)

	// Start upstream SSE reader
	go connectUpstream(upstreamURL)

	mux := http.NewServeMux()

	// Per-user SSE endpoint: /user/+PHONE/{token}/api/v1/events
	// Per-user RPC endpoint: /user/+PHONE/{token}/api/v1/rpc
	// Per-user check:        /user/+PHONE/{token}/api/v1/check
	// Also supports legacy:  /user/+PHONE/api/v1/...  (no embedded token)
	// We use a catch-all and parse the path manually for Go 1.21 compat.
	mux.HandleFunc("/user/", func(w http.ResponseWriter, r *http.Request) {
		// Path format: /user/{phone}/{token?}/api/v1/{events|rpc|check}
		// Extract phone and remaining path, skipping the token segment if present.
		path := strings.TrimPrefix(r.URL.Path, "/user/")
		parts := strings.SplitN(path, "/", 2)
		if len(parts) < 2 {
			http.Error(w, "invalid path: expected /user/{phone}/...", http.StatusBadRequest)
			return
		}

		phone, err := url.PathUnescape(parts[0])
		if err != nil {
			http.Error(w, "invalid phone in path", http.StatusBadRequest)
			return
		}
		if !strings.HasPrefix(phone, "+") {
			http.Error(w, "phone must start with +", http.StatusBadRequest)
			return
		}

		// remainder is everything after the phone: could be
		//   {token}/api/v1/events  (new format with path-embedded token)
		//   api/v1/events          (legacy format without token)
		remainder := parts[1]

		// If the next segment is NOT "api", it's the token — skip it
		if !strings.HasPrefix(remainder, "api") {
			// Strip the token segment: {token}/api/v1/... → api/v1/...
			idx := strings.Index(remainder, "/")
			if idx < 0 {
				http.Error(w, "invalid path: missing /api/v1/...", http.StatusBadRequest)
				return
			}
			remainder = remainder[idx+1:]
		}

		apiPath := "/" + remainder // e.g. /api/v1/events or /api/v1/rpc or /api/v1/check

		switch {
		case apiPath == "/api/v1/events" && r.Method == http.MethodGet:
			handleSSE(w, r, phone)
		case apiPath == "/api/v1/rpc" && r.Method == http.MethodPost:
			// Rewrite path to upstream /api/v1/rpc and proxy (with write timeout — not SSE)
			ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
			defer cancel()
			r = r.WithContext(ctx)
			r.URL.Path = "/api/v1/rpc"
			r.Host = parsed.Host
			rpcProxy.ServeHTTP(w, r)
		case apiPath == "/api/v1/check":
			// Readiness check: proxy to upstream /api/v1/check so OpenClaw can verify the daemon is up.
			ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
			defer cancel()
			r = r.WithContext(ctx)
			r.URL.Path = "/api/v1/check"
			r.Host = parsed.Host
			rpcProxy.ServeHTTP(w, r)
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	})

	// Pass-through health check (with write timeout — not SSE)
	mux.Handle("/api/v1/check", http.TimeoutHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Host = parsed.Host
		rpcProxy.ServeHTTP(w, r)
	}), 30*time.Second, "request timeout"))

	// Proxy's own health endpoint (with write timeout — not SSE)
	mux.Handle("/healthz", http.TimeoutHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if upstreamOK.Load() {
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, "ok")
		} else {
			w.WriteHeader(http.StatusServiceUnavailable)
			fmt.Fprint(w, "upstream disconnected")
		}
	}), 5*time.Second, "request timeout"))

	// Optional TLS: when TLS_CERT_FILE and TLS_KEY_FILE are set, the server
	// terminates TLS itself. In the default Azure Container Apps deployment,
	// these are left empty — the Envoy sidecar handles TLS termination at the
	// ingress layer, and the container runs plain HTTP inside the private VNet.
	tlsCert := os.Getenv("TLS_CERT_FILE")
	tlsKey := os.Getenv("TLS_KEY_FILE")
	tlsEnabled := tlsCert != "" && tlsKey != ""

	if tlsEnabled {
		log.Printf("signal-proxy starting HTTPS on %s, upstream=%s", listenAddr, upstreamURL)
	} else {
		log.Printf("signal-proxy starting HTTP on %s, upstream=%s (TLS not configured — expects TLS termination at ingress layer)", listenAddr, upstreamURL)
	}

	// Wrap mux with auth middleware (skips /healthz for health probes).
	// When AUTH_TOKEN is empty, all requests are allowed (backward-compatible).
	var handler http.Handler = mux
	if authToken != "" {
		handler = authMiddleware(mux, authToken)
	}

	// Add security headers (HSTS, etc.) to all responses.
	handler = securityHeadersMiddleware(handler)

	srv := &http.Server{
		Addr:        listenAddr,
		Handler:     handler,
		ReadTimeout: 10 * time.Second,
		// WriteTimeout must be 0 for SSE (long-lived streaming responses).
		// Per-route timeouts can be added via middleware if needed.
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown on SIGTERM/SIGINT (Azure Container Apps sends SIGTERM on revision swap)
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
		sig := <-sigCh
		log.Printf("received %s, shutting down gracefully...", sig)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("graceful shutdown error: %v", err)
		}
	}()

	if tlsEnabled {
		err = srv.ListenAndServeTLS(tlsCert, tlsKey)
	} else {
		err = srv.ListenAndServe()
	}
	if err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
	log.Println("signal-proxy stopped")
}

// handleSSE registers a subscriber for the given phone and streams filtered SSE events.
func handleSSE(w http.ResponseWriter, r *http.Request, phone string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	sub := &subscriber{
		phone: phone,
		ch:    make(chan []byte, 64),
		done:  make(chan struct{}),
	}

	mu.Lock()
	subscribers[phone] = append(subscribers[phone], sub)
	count := len(subscribers[phone])
	mu.Unlock()
	log.Printf("subscriber added: phone=%s total=%d", maskPhone(phone), count)

	// Cleanup on disconnect
	defer func() {
		mu.Lock()
		subs := subscribers[phone]
		for i, s := range subs {
			if s == sub {
				subscribers[phone] = append(subs[:i], subs[i+1:]...)
				break
			}
		}
		if len(subscribers[phone]) == 0 {
			delete(subscribers, phone)
		}
		mu.Unlock()
		close(sub.done) // signal senders to skip this subscriber; ch is left open to avoid send-on-closed panic
		log.Printf("subscriber removed: phone=%s", maskPhone(phone))
	}()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher.Flush()

	// Send SSE keepalive comments every 30s to prevent Azure Container Apps
	// ingress from killing the idle connection (default idle timeout ~4 min).
	keepalive := time.NewTicker(30 * time.Second)
	defer keepalive.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case <-keepalive.C:
			if _, err := w.Write([]byte(":keepalive\n\n")); err != nil {
				return
			}
			flusher.Flush()
		case event, ok := <-sub.ch:
			if !ok {
				return
			}
			if _, err := w.Write(event); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// connectUpstream maintains a persistent SSE connection to signal-cli and fans out events.
func connectUpstream(baseURL string) {
	backoff := time.Second
	maxBackoff := 30 * time.Second

	for {
		start := time.Now()
		err := readUpstreamSSE(baseURL + "/api/v1/events")
		upstreamOK.Store(false)
		connDuration := time.Since(start)

		if err != nil {
			log.Printf("upstream SSE disconnected: %v (was up %v, reconnecting in %v)", err, connDuration.Round(time.Second), backoff)
		} else {
			log.Printf("upstream SSE closed cleanly (was up %v, reconnecting in %v)", connDuration.Round(time.Second), backoff)
		}

		time.Sleep(backoff)

		// Reset backoff after a stable connection (>60s uptime),
		// otherwise keep growing for rapid consecutive failures.
		if connDuration > 60*time.Second {
			backoff = time.Second
		} else {
			backoff = min(backoff*2, maxBackoff)
		}
	}
}

// noRedirectClient is an HTTP client that refuses to follow redirects.
// This ensures we connect directly via http:// and don't silently end up on
// an HTTPS connection that Envoy may buffer differently.
var noRedirectClient = &http.Client{
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	},
	Timeout: 0, // no timeout — SSE is a long-lived stream
}

// readUpstreamSSE connects to the SSE endpoint and processes events until error/disconnect.
func readUpstreamSSE(sseURL string) error {
	req, err := http.NewRequest(http.MethodGet, sseURL, nil)
	if err != nil {
		return fmt.Errorf("creating request: %w", err)
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("Connection", "keep-alive")

	log.Printf("upstream SSE: dialing %s ...", sseURL)
	resp, err := noRedirectClient.Do(req)
	if err != nil {
		return fmt.Errorf("connecting: %w", err)
	}
	defer resp.Body.Close()

	// Log full response details for debugging
	log.Printf("upstream SSE: status=%d, contentType=%q, finalURL=%s",
		resp.StatusCode, resp.Header.Get("Content-Type"), resp.Request.URL.String())
	if resp.StatusCode == http.StatusMovedPermanently || resp.StatusCode == http.StatusFound ||
		resp.StatusCode == http.StatusTemporaryRedirect || resp.StatusCode == http.StatusPermanentRedirect {
		location := resp.Header.Get("Location")
		return fmt.Errorf("got redirect %d to %s — refusing to follow (check allowInsecure on signal-cli ingress)", resp.StatusCode, location)
	}

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("unexpected status %d: %s", resp.StatusCode, body)
	}

	log.Printf("upstream SSE connected to %s (content-type: %s)", sseURL, resp.Header.Get("Content-Type"))
	upstreamOK.Store(true)

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 256*1024), 256*1024) // 256KB line buffer

	var eventType string
	var dataBuf bytes.Buffer
	lineCount := 0

	for scanner.Scan() {
		line := scanner.Text()
		lineCount++

		// Log first few lines (protocol negotiation) and then periodic progress (count only)
		if lineCount <= 5 {
			log.Printf("upstream SSE line #%d: [%d bytes]", lineCount, len(line))
		} else if lineCount%100 == 0 {
			log.Printf("upstream SSE progress: %d lines received", lineCount)
		}

		if line == "" {
			// Empty line = end of event
			if dataBuf.Len() > 0 {
				log.Printf("upstream SSE: dispatching event type=%q dataLen=%d", eventType, dataBuf.Len())
				dispatchEvent(eventType, dataBuf.Bytes())
				eventType = ""
				dataBuf.Reset()
			}
			continue
		}

		if strings.HasPrefix(line, "event:") {
			eventType = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		} else if strings.HasPrefix(line, "data:") {
			if dataBuf.Len() > 0 {
				dataBuf.WriteByte('\n')
			}
			dataBuf.WriteString(strings.TrimPrefix(line, "data:"))
		}
		// Ignore "id:", "retry:", comments (":")
	}

	log.Printf("upstream SSE: scanner stopped after %d lines, err=%v", lineCount, scanner.Err())
	return scanner.Err()
}

// dispatchEvent extracts sourceNumber from a signal-cli SSE event and fans out to matching subscribers.
func dispatchEvent(eventType string, data []byte) {
	sourceNumber := extractSourceNumber(data)
	log.Printf("dispatch: eventType=%q sourceNumber=%s dataLen=%d", eventType, maskPhone(sourceNumber), len(data))

	// Build the raw SSE frame to send downstream
	var frame bytes.Buffer
	if eventType != "" {
		fmt.Fprintf(&frame, "event:%s\n", eventType)
	}
	fmt.Fprintf(&frame, "data:%s\n\n", data)
	frameBytes := frame.Bytes()

	if sourceNumber == "" {
		// Drop events without a sourceNumber (typing indicators, delivery receipts).
		// Broadcasting these to all subscribers would leak activity across tenants.
		log.Printf("dispatch: dropping event with empty sourceNumber (type=%q, dataLen=%d)", eventType, len(data))
		return
	}

	mu.RLock()
	subs, exists := subscribers[sourceNumber]
	if !exists {
		mu.RUnlock()
		mu.RLock()
		knownCount := len(subscribers)
		mu.RUnlock()
		log.Printf("no subscriber for source=%s, known_count=%d, dropping event", maskPhone(sourceNumber), knownCount)
		return
	}
	// Copy slice under read lock to avoid holding lock during channel sends
	subsCopy := make([]*subscriber, len(subs))
	copy(subsCopy, subs)
	mu.RUnlock()

	for _, sub := range subsCopy {
		select {
		case <-sub.done:
			// subscriber is shutting down, skip
		case sub.ch <- frameBytes:
			log.Printf("dispatch: sent event to subscriber phone=%s", maskPhone(sub.phone))
		default:
			log.Printf("subscriber channel full, dropping event for phone=%s", maskPhone(sub.phone))
		}
	}
}

// extractSourceNumber parses a signal-cli SSE event to get the sender's phone number.
// signal-cli daemon SSE format: {"envelope":{"sourceNumber":"+xxx",...},"account":"+bot",...}
// JSON-RPC notification format: {"jsonrpc":"2.0","method":"receive","params":{"envelope":{"sourceNumber":"+xxx",...},...}}
func extractSourceNumber(data []byte) string {
	log.Printf("extractSourceNumber: dataLen=%d", len(data))

	// First try: signal-cli daemon SSE format (direct envelope at top level)
	var directMsg struct {
		Envelope struct {
			SourceNumber string `json:"sourceNumber"`
			Source       string `json:"source"`
		} `json:"envelope"`
		Account string `json:"account"`
	}
	if err := json.Unmarshal(data, &directMsg); err == nil {
		if num := directMsg.Envelope.SourceNumber; num != "" {
			return num
		}
		if num := directMsg.Envelope.Source; num != "" {
			return num
		}
	}

	// Second try: JSON-RPC notification format
	var rpcMsg struct {
		Params struct {
			Envelope struct {
				SourceNumber string `json:"sourceNumber"`
			} `json:"envelope"`
			Result struct {
				Envelope struct {
					SourceNumber string `json:"sourceNumber"`
				} `json:"envelope"`
			} `json:"result"`
		} `json:"params"`
	}

	if err := json.Unmarshal(data, &rpcMsg); err != nil {
		log.Printf("failed to parse SSE event JSON: %v", err)
		return ""
	}

	if num := rpcMsg.Params.Envelope.SourceNumber; num != "" {
		return num
	}
	return rpcMsg.Params.Result.Envelope.SourceNumber
}
