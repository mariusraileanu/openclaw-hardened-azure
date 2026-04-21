// loopback-proxy.mjs — HTTP path-based reverse proxy for Docker deployments.
//
// Listens on 0.0.0.0:<PROXY_PORT> and routes requests:
//   POST /api/messages  →  127.0.0.1:<TEAMS_PORT>  (Teams webhook, own JWT auth)
//   Everything else     →  127.0.0.1:<GATEWAY_PORT> (OpenClaw gateway on loopback)
//
// This replaces the old raw TCP proxy. The gateway sees all traffic as
// originating from loopback, satisfying isLocalClient / isLocalDirectRequest
// checks for Control UI scopes. Teams webhook traffic is routed directly to
// the Bot Framework SDK listener on its native port.
//
// Usage:  node loopback-proxy.mjs [proxyPort] [gatewayPort] [teamsPort]
//         Defaults: proxyPort=18789  gatewayPort=18790  teamsPort=3978

import { createServer, request as httpRequest } from "node:http";
import { createConnection } from "node:net";

const PROXY_PORT   = parseInt(process.argv[2] || "18789", 10);
const GATEWAY_PORT = parseInt(process.argv[3] || "18790", 10);
const TEAMS_PORT   = parseInt(process.argv[4] || "3978", 10);

/**
 * Determine which backend port to route to based on method + path.
 * Only POST /api/messages goes to the Teams webhook; everything else
 * (Control UI, API, WebSocket upgrades, etc.) goes to the gateway.
 */
function targetPort(method, url) {
  if (method === "POST" && url === "/api/messages") {
    return TEAMS_PORT;
  }
  return GATEWAY_PORT;
}

// Retry config for Teams backend (port 3978) which may not be ready at startup.
// Exponential backoff: 500ms, 1s, 2s, 4s — total ~7.5s of retry window.
const TEAMS_RETRY_COUNT = 4;
const TEAMS_RETRY_BASE_MS = 500;

/**
 * Forward a buffered request to a backend port.
 * For Teams requests, retries on ECONNREFUSED with exponential backoff.
 */
function forwardRequest(clientReq, clientRes, port, body, attempt = 0) {
  const proxyOpts = {
    hostname: "127.0.0.1",
    port,
    path: clientReq.url,
    method: clientReq.method,
    headers: clientReq.headers,
  };

  const proxyReq = httpRequest(proxyOpts, (proxyRes) => {
    clientRes.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(clientRes, { end: true });
  });

  proxyReq.on("error", (err) => {
    const dest = port === TEAMS_PORT ? "teams" : "gateway";

    // Retry ECONNREFUSED for Teams backend during startup
    if (port === TEAMS_PORT && err.code === "ECONNREFUSED" && attempt < TEAMS_RETRY_COUNT) {
      const delay = TEAMS_RETRY_BASE_MS * Math.pow(2, attempt);
      console.log(`[loopback-proxy] teams(${port}) not ready, retry ${attempt + 1}/${TEAMS_RETRY_COUNT} in ${delay}ms`);
      setTimeout(() => forwardRequest(clientReq, clientRes, port, body, attempt + 1), delay);
      return;
    }

    console.error(`[loopback-proxy] ${dest}(${port}) error: ${err.message}`);
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { "content-type": "application/json" });
      clientRes.end(JSON.stringify({ error: "Bad Gateway", message: err.message }));
    } else {
      clientRes.destroy();
    }
  });

  proxyReq.end(body);
}

const server = createServer((clientReq, clientRes) => {
  const port = targetPort(clientReq.method, clientReq.url);

  // Buffer the request body so we can replay it on retries.
  const chunks = [];
  clientReq.on("data", (chunk) => chunks.push(chunk));
  clientReq.on("end", () => {
    const body = Buffer.concat(chunks);
    forwardRequest(clientReq, clientRes, port, body);
  });
});

// Handle WebSocket upgrade requests (used by Control UI).
// These always go to the gateway, never to the Teams webhook.
server.on("upgrade", (clientReq, clientSocket, head) => {
  const upstream = createConnection({ host: "127.0.0.1", port: GATEWAY_PORT }, () => {
    // Reconstruct the raw HTTP upgrade request to send to the gateway
    const reqLine = `${clientReq.method} ${clientReq.url} HTTP/1.1\r\n`;
    const headers = Object.entries(clientReq.headers)
      .map(([k, v]) => `${k}: ${v}`)
      .join("\r\n");
    upstream.write(reqLine + headers + "\r\n\r\n");
    if (head.length > 0) upstream.write(head);
    clientSocket.pipe(upstream);
    upstream.pipe(clientSocket);
  });
  upstream.on("error", () => clientSocket.destroy());
  clientSocket.on("error", () => upstream.destroy());
});

server.listen(PROXY_PORT, "0.0.0.0", () => {
  console.log(
    `[loopback-proxy] listening on 0.0.0.0:${PROXY_PORT}\n` +
    `  POST /api/messages → 127.0.0.1:${TEAMS_PORT} (teams)\n` +
    `  everything else    → 127.0.0.1:${GATEWAY_PORT} (gateway)`
  );
});
