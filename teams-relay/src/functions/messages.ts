/**
 * Teams Webhook Relay — stateless HTTP proxy (shared bot mode).
 *
 * A single Azure Bot registration serves all users. Bot Framework sends every
 * incoming message to one endpoint: POST /api/messages. This relay inspects
 * the Activity payload to determine which per-user Container App should handle
 * the request, then forwards the HTTP POST over the VNet.
 *
 * Routing:
 *   activity.from.aadObjectId  →  MSTEAMS_USER_SLUG_MAP lookup  →  user_slug
 *   → http://{OPENCLAW_HOST_PREFIX}-{env}-{user_slug}.{cae_domain}/api/messages
 *
 * A legacy route (/api/messages/{user_slug}) is retained for direct testing.
 *
 * Environment variables:
 *   CAE_DEFAULT_DOMAIN      — default domain of the Container Apps Environment
 *   ENVIRONMENT             — environment label ("dev", "prod", …)
 *   OPENCLAW_HOST_PREFIX    — per-user app name prefix (default: ca-openclaw)
 *   UPSTREAM_PORT           — port on the container app (default: 3978)
 *   UPSTREAM_HOST_STYLE     — "internal" | "external" (default: internal)
 *   MSTEAMS_USER_SLUG_MAP   — JSON: {"aad-object-id": "user-slug", …}
 */

import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

// ---------------------------------------------------------------------------
// Configuration (read once at cold start)
// ---------------------------------------------------------------------------

const CAE_DEFAULT_DOMAIN = process.env.CAE_DEFAULT_DOMAIN ?? "";
const ENVIRONMENT = process.env.ENVIRONMENT ?? "dev";
const OPENCLAW_HOST_PREFIX = process.env.OPENCLAW_HOST_PREFIX ?? "ca-openclaw";
const UPSTREAM_PORT = process.env.UPSTREAM_PORT ?? "3978";
const UPSTREAM_HOST_STYLE = (process.env.UPSTREAM_HOST_STYLE ?? "internal").toLowerCase();
const REQUEST_TIMEOUT_MS = 15_000;

/** Map of lowercase AAD Object ID → user slug. */
let USER_SLUG_MAP: Record<string, string> = {};
try {
  const raw = JSON.parse(process.env.MSTEAMS_USER_SLUG_MAP ?? "{}");
  // Normalise keys to lowercase for case-insensitive lookup
  for (const [key, value] of Object.entries(raw)) {
    if (typeof value === "string") {
      USER_SLUG_MAP[key.toLowerCase()] = value;
    }
  }
} catch {
  console.error(
    "Failed to parse MSTEAMS_USER_SLUG_MAP — user routing will fail"
  );
}

/** Hop-by-hop headers that must not be forwarded. */
const SKIP_REQUEST_HEADERS = new Set([
  "host",
  "content-length",
  "transfer-encoding",
  "connection",
  "keep-alive",
]);

const SKIP_RESPONSE_HEADERS = new Set([
  "transfer-encoding",
  "content-encoding",
  "connection",
  "keep-alive",
]);

const SLUG_REGEX = /^[a-z][a-z0-9-]{1,18}[a-z0-9]$/;

function buildUpstreamHostnames(appName: string): string[] {
  const internal = `${appName}.internal.${CAE_DEFAULT_DOMAIN}`;
  const external = `${appName}.${CAE_DEFAULT_DOMAIN}`;
  const preferred = UPSTREAM_HOST_STYLE === "external" ? external : internal;
  const fallback = preferred === internal ? external : internal;
  return preferred === fallback ? [preferred] : [preferred, fallback];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Resolve the target user slug from a Bot Framework Activity object. */
function resolveUserSlug(
  activity: Record<string, unknown>
): string | null {
  const from = activity.from as Record<string, unknown> | undefined;
  const aadObjectId = (from?.aadObjectId as string | undefined) ?? "";
  if (aadObjectId) {
    const slug = USER_SLUG_MAP[aadObjectId.toLowerCase()];
    if (slug) return slug;
  }
  return null;
}

/** Forward an HTTP POST to an internal Container App and return the response. */
async function relayToContainer(
  userSlug: string,
  bodyText: string,
  request: HttpRequest,
  context: InvocationContext
): Promise<HttpResponseInit> {
  if (!CAE_DEFAULT_DOMAIN) {
    context.error("CAE_DEFAULT_DOMAIN is not configured");
    return {
      status: 503,
      jsonBody: { error: "Service Unavailable", message: "Relay not configured" },
    };
  }

  if (!SLUG_REGEX.test(userSlug)) {
    context.warn(`Invalid user_slug: ${userSlug}`);
    return {
      status: 400,
      jsonBody: { error: "Bad Request", message: "Invalid user_slug" },
    };
  }

  const appName = `${OPENCLAW_HOST_PREFIX}-${ENVIRONMENT}-${userSlug}`;
  const upstreamHosts = buildUpstreamHostnames(appName);

  // Forward relevant headers
  const headers: Record<string, string> = {};
  for (const [key, value] of request.headers.entries()) {
    if (!SKIP_REQUEST_HEADERS.has(key.toLowerCase())) {
      headers[key] = value;
    }
  }
  if (!headers["content-type"]) {
    headers["content-type"] = "application/json";
  }

  let lastErrorMessage = "Unknown upstream error";

  for (const upstreamHost of upstreamHosts) {
    const upstreamUrl = `http://${upstreamHost}:${UPSTREAM_PORT}/api/messages`;
    context.log(`Relaying to ${appName} (${request.method} ${upstreamUrl})`);

    try {
      const upstream = await fetch(upstreamUrl, {
        method: "POST",
        headers,
        body: bodyText,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });

      const responseBody = await upstream.text();

      const responseHeaders: Record<string, string> = {};
      for (const [key, value] of upstream.headers.entries()) {
        if (!SKIP_RESPONSE_HEADERS.has(key.toLowerCase())) {
          responseHeaders[key] = value;
        }
      }

      return {
        status: upstream.status,
        headers: responseHeaders,
        body: responseBody,
      };
    } catch (err: unknown) {
      lastErrorMessage =
        err instanceof Error ? err.message : "Unknown upstream error";
      context.warn(`Relay attempt failed for ${userSlug} via ${upstreamHost}: ${lastErrorMessage}`);
    }
  }

  context.error(`Relay error for ${userSlug}: ${lastErrorMessage}`);
  return {
    status: 502,
    jsonBody: { error: "Bad Gateway", message: lastErrorMessage },
  };
}

// ---------------------------------------------------------------------------
// Primary route: shared bot — route by Activity payload
// ---------------------------------------------------------------------------

app.http("messages", {
  methods: ["POST"],
  authLevel: "anonymous", // Bot Framework handles its own JWT auth
  route: "api/messages",
  handler: async (
    request: HttpRequest,
    context: InvocationContext
  ): Promise<HttpResponseInit> => {
    const bodyText = await request.text();

    // Parse the Bot Framework Activity to extract the sender identity
    let activity: Record<string, unknown>;
    try {
      activity = JSON.parse(bodyText);
    } catch {
      context.warn("Failed to parse request body as JSON");
      return {
        status: 400,
        jsonBody: { error: "Bad Request", message: "Invalid JSON body" },
      };
    }

    const userSlug = resolveUserSlug(activity);
    if (!userSlug) {
      const from = activity.from as Record<string, unknown> | undefined;
      const aadOid = ((from?.aadObjectId as string | undefined) ?? "unknown").toLowerCase();
      context.warn(`No user mapping for aadObjectId: ${aadOid}`);
      return {
        status: 404,
        jsonBody: {
          error: "Not Found",
          message: "No bot instance configured for this user",
        },
      };
    }

    return relayToContainer(userSlug, bodyText, request, context);
  },
});

// ---------------------------------------------------------------------------
// Legacy route: direct user_slug in path (for testing)
// ---------------------------------------------------------------------------

app.http("messages-legacy", {
  methods: ["POST"],
  authLevel: "anonymous",
  route: "api/messages/{user_slug}",
  handler: async (
    request: HttpRequest,
    context: InvocationContext
  ): Promise<HttpResponseInit> => {
    const userSlug = request.params.user_slug;

    if (!userSlug || !SLUG_REGEX.test(userSlug)) {
      return {
        status: 400,
        jsonBody: { error: "Bad Request", message: "Invalid user_slug" },
      };
    }

    context.log(`[legacy] Direct route for ${userSlug}`);
    const bodyText = await request.text();
    return relayToContainer(userSlug, bodyText, request, context);
  },
});
