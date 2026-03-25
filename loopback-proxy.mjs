// loopback-proxy.mjs — Transparent TCP proxy for Docker deployments.
//
// Listens on 0.0.0.0:<PROXY_PORT> and forwards every connection to
// 127.0.0.1:<TARGET_PORT>.  This makes the gateway see all inbound
// traffic as originating from loopback, which satisfies the
// isLocalClient / isLocalDirectRequest checks for Control UI scopes.
//
// Usage:  node loopback-proxy.mjs [proxyPort] [targetPort]
//         Defaults: proxyPort=18789  targetPort=18790

import { createServer, createConnection } from "node:net";

const PROXY_PORT = parseInt(process.argv[2] || "18789", 10);
const TARGET_PORT = parseInt(process.argv[3] || "18790", 10);

const server = createServer((client) => {
  const upstream = createConnection({ host: "127.0.0.1", port: TARGET_PORT }, () => {
    client.pipe(upstream);
    upstream.pipe(client);
  });
  upstream.on("error", () => client.destroy());
  client.on("error", () => upstream.destroy());
});

server.listen(PROXY_PORT, "0.0.0.0", () => {
  console.log(`[loopback-proxy] forwarding 0.0.0.0:${PROXY_PORT} -> 127.0.0.1:${TARGET_PORT}`);
});
