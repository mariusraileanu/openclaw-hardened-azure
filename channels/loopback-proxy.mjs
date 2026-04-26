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
import fs from "node:fs/promises";
import { createConnection } from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const PROXY_PORT   = parseInt(process.argv[2] || "18789", 10);
const GATEWAY_PORT = parseInt(process.argv[3] || "18790", 10);
const TEAMS_PORT   = parseInt(process.argv[4] || "3978", 10);
const BOARD_ENDPOINT = "/__openclaw__/board-meeting";
const BOARD_HEARTBEAT_MS = 10_000;

function boardEvent(payload) {
  return `${JSON.stringify(payload)}\n`;
}

function classifyBoardStage(message) {
  const normalized = message.toLowerCase();
  if (normalized.includes('selected attendees')) {
    return 'members_selected';
  }
  if (normalized.includes('first-pass') || normalized.includes('rebuttal summary')) {
    return 'deliberation';
  }
  if (normalized.includes('final vote')) {
    return 'voting';
  }
  if (normalized.includes('decision packet written')) {
    return 'decision_packet';
  }
  return 'requested';
}

function parseSelectedAttendees(message) {
  const marker = 'Chairman selected attendees:';
  const index = message.indexOf(marker);
  if (index < 0) {
    return [];
  }

  const raw = message.slice(index + marker.length).trim();
  if (!raw) {
    return [];
  }

  return raw
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
    .map((value) => ({ id: value }));
}

async function loadBoardMembers(board) {
  const boardPath = path.join('/app/config/boards', `${board}.json`);
  const payload = JSON.parse(await fs.readFile(boardPath, 'utf8'));
  return new Map(
    (payload.members || []).map((member) => [member.id, {
      name: member.name,
      topic: member.topic,
    }])
  );
}

function jsonResponse(clientRes, statusCode, payload) {
  clientRes.writeHead(statusCode, { "content-type": "application/json" });
  clientRes.end(JSON.stringify(payload));
}

function textResponse(clientRes, statusCode, text) {
  clientRes.writeHead(statusCode, { "content-type": "text/plain; charset=utf-8" });
  clientRes.end(text);
}

function parseRequestPath(url) {
  try {
    return new URL(url, "http://127.0.0.1").pathname;
  } catch {
    return url;
  }
}

/**
 * Determine which backend port to route to based on method + path.
 * Only POST /api/messages goes to the Teams webhook; everything else
 * (Control UI, API, WebSocket upgrades, etc.) goes to the gateway.
 */
function targetPort(method, url) {
  if (method === "POST" && parseRequestPath(url) === "/api/messages") {
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
  const headers = { ...clientReq.headers };
  if (port === GATEWAY_PORT && process.env.OPENCLAW_GATEWAY_TOKEN) {
    headers.authorization = `Bearer ${process.env.OPENCLAW_GATEWAY_TOKEN}`;
  }

  const proxyOpts = {
    hostname: "127.0.0.1",
    port,
    path: clientReq.url,
    method: clientReq.method,
    headers,
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

async function runInternalBoardMeeting(body, emit) {
  const payload = JSON.parse(body.toString("utf8") || "{}");
  const board = typeof payload.board === "string" ? payload.board.trim().toLowerCase() : "";
  const topic = typeof payload.topic === "string" ? payload.topic.trim() : "";
  const context = typeof payload.context === "string" ? payload.context.trim() : "";

  if (!board || !topic) {
    const error = new Error("board and topic are required");
    error.statusCode = 400;
    throw error;
  }

  const meetingId = `${board}-relay-${Date.now()}`;
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), `${board}-relay-`));
  const agendaPath = path.join(tempDir, `${meetingId}.agenda.json`);
  const outputPath = path.join(tempDir, `${meetingId}.decision.md`);
  const tracePath = path.join(tempDir, `${meetingId}.trace.json`);
  const decisionRequest = [topic, context].filter(Boolean).join("\n\n");
  const boardMembers = await loadBoardMembers(board);

  await fs.writeFile(
    agendaPath,
    `${JSON.stringify(
      {
        meetingId,
        boardId: board,
        agendaTopic: topic.slice(0, 160),
        agendaSummary: decisionRequest,
        context: [],
        decisionRequest,
      },
      null,
      2
    )}\n`,
    "utf8"
  );

  return await new Promise((resolve, reject) => {
    const child = spawn(
      "node",
      [
        "/app/platform/scripts/run_board_meeting.mjs",
        "--board",
        board,
        "--agenda",
        agendaPath,
        "--output",
        outputPath,
        "--trace-output",
        tracePath,
        "--packet-mode",
        "brief",
        "--min-attendees",
        "3",
        "--max-attendees",
        "3",
        "--selection-timeout",
        "90",
        "--member-timeout",
        "75",
        "--chairman-timeout",
        "120",
      ],
      {
        cwd: "/app",
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      }
    );

    let stdout = "";
    let stderr = "";
    let stderrBuffer = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderr += text;
      stderrBuffer += text;

      const lines = stderrBuffer.split("\n");
      stderrBuffer = lines.pop() ?? "";
      for (const line of lines) {
        const match = line.match(/\[board-meeting\]\s+(.*)$/);
        if (!match) {
          continue;
        }
        const message = match[1].trim();
        const attendees = parseSelectedAttendees(message).map((attendee) => {
          const resolved = boardMembers.get(attendee.id);
          return resolved
            ? { name: resolved.name, topic: resolved.topic }
            : { name: attendee.id };
        });

        emit(boardEvent({
          type: 'progress',
          stage: classifyBoardStage(message),
          message,
          attendees,
        }));
      }
    });
    child.on("error", reject);
    child.on("close", async (exitCode) => {
      if (exitCode !== 0) {
        reject(new Error(stderr || stdout || `board runner failed with exit code ${exitCode}`));
        return;
      }

      const packet = stdout.trim() || (await fs.readFile(outputPath, "utf8")).trim();
      emit(boardEvent({ type: 'final', text: packet }));
      resolve();
    });
  });
}

const server = createServer((clientReq, clientRes) => {
  // Buffer the request body so we can replay it on retries.
  const chunks = [];
  clientReq.on("data", (chunk) => chunks.push(chunk));
  clientReq.on("end", async () => {
    const body = Buffer.concat(chunks);
    if (clientReq.method === "POST" && parseRequestPath(clientReq.url) === BOARD_ENDPOINT) {
      clientRes.writeHead(200, {
        "content-type": "application/x-ndjson; charset=utf-8",
        "cache-control": "no-store",
      });

      const heartbeat = setInterval(() => {
        if (!clientRes.writableEnded && !clientRes.destroyed) {
          clientRes.write("\n");
        }
      }, BOARD_HEARTBEAT_MS);

      try {
        await runInternalBoardMeeting(body, (chunk) => {
          clientRes.write(chunk);
        });
        clearInterval(heartbeat);
        clientRes.end();
      } catch (error) {
        clearInterval(heartbeat);
        const statusCode = Number.isInteger(error?.statusCode) ? error.statusCode : 500;
        console.error(`[loopback-proxy] internal board endpoint error: ${error?.message ?? String(error)}`);
        if (!clientRes.headersSent) {
          jsonResponse(clientRes, statusCode, {
            error: "board_meeting_failed",
            message: error?.message ?? String(error),
          });
        } else {
          clientRes.end(
            boardEvent({
              type: 'error',
              message: error?.message ?? String(error),
            })
          );
        }
      }
      return;
    }

    const port = targetPort(clientReq.method, clientReq.url);
    forwardRequest(clientReq, clientRes, port, body);
  });
});

// Handle WebSocket upgrade requests (used by Control UI).
// These always go to the gateway, never to the Teams webhook.
server.on("upgrade", (clientReq, clientSocket, head) => {
  const upstream = createConnection({ host: "127.0.0.1", port: GATEWAY_PORT }, () => {
    // Reconstruct the raw HTTP upgrade request to send to the gateway
    const reqLine = `${clientReq.method} ${clientReq.url} HTTP/1.1\r\n`;
    const upgradeHeaders = { ...clientReq.headers };
    if (process.env.OPENCLAW_GATEWAY_TOKEN) {
      upgradeHeaders.authorization = `Bearer ${process.env.OPENCLAW_GATEWAY_TOKEN}`;
    }
    const headers = Object.entries(upgradeHeaders)
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
    `  POST ${BOARD_ENDPOINT} → internal board runner\n` +
    `  everything else    → 127.0.0.1:${GATEWAY_PORT} (gateway)`
  );
});
