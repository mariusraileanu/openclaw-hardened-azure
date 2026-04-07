import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import {
  resolveCorrelationId,
  withCorrelationHeader,
} from "../lib/correlation";
import {
  getUpstreamCircuitSnapshot,
  isUpstreamCircuitOpen,
  recordUpstreamFailure,
  recordUpstreamSuccess,
  resolveRouting,
} from "../lib/routing/service";
import { RoutingRecord } from "../lib/routing/types";
import {
  assistantDisabled,
  assistantProvisioning,
  assistantTemporarilyUnavailable,
  invalidRequest,
  noAssistantConfigured,
} from "../lib/teams-response";

const REQUEST_TIMEOUT_MS = 15_000;
const EXPECTED_TENANT_ID = (process.env.MSTEAMS_EXPECTED_TENANT_ID ?? "").trim().toLowerCase();

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

type ActivityEnvelope = {
  from?: {
    aadObjectId?: string;
  };
  channelData?: {
    tenant?: {
      id?: string;
    };
  };
};

function appendMessagesPath(baseUrl: string): string {
  return `${baseUrl.replace(/\/$/, "")}/api/messages`;
}

function summarizeResultLabel(statusCode: number): string {
  if (statusCode >= 200 && statusCode < 300) {
    return "upstream_ok";
  }
  if (statusCode >= 500) {
    return "upstream_server_error";
  }
  if (statusCode >= 400) {
    return "upstream_client_error";
  }
  return "upstream_other";
}

function logRoutingResult(context: InvocationContext, payload: Record<string, unknown>): void {
  context.log(`relay_event=${JSON.stringify(payload)}`);
}

async function relayToUpstream(
  routing: RoutingRecord,
  bodyText: string,
  request: HttpRequest,
  correlationId: string,
  context: InvocationContext
): Promise<HttpResponseInit> {
  const upstreamUrl = appendMessagesPath(routing.upstreamUrl);
  const startedAt = Date.now();

  const headers: Record<string, string> = {};
  for (const [key, value] of request.headers.entries()) {
    if (!SKIP_REQUEST_HEADERS.has(key.toLowerCase())) {
      headers[key] = value;
    }
  }
  if (!headers["content-type"]) {
    headers["content-type"] = "application/json";
  }

  const forwardHeaders = withCorrelationHeader(headers, correlationId);

  try {
    const upstream = await fetch(upstreamUrl, {
      method: "POST",
      headers: forwardHeaders,
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

    responseHeaders["x-correlation-id"] = correlationId;

    if (upstream.status >= 500) {
      recordUpstreamFailure(routing.aadObjectId);
      logRoutingResult(context, {
        aadObjectId: routing.aadObjectId,
        userSlug: routing.userSlug,
        upstreamUrl,
        correlationId,
        latencyMs: Date.now() - startedAt,
        result: "upstream_5xx",
        upstreamStatus: upstream.status,
      });
      return assistantTemporarilyUnavailable(correlationId);
    }

    recordUpstreamSuccess(routing.aadObjectId);
    logRoutingResult(context, {
      aadObjectId: routing.aadObjectId,
      userSlug: routing.userSlug,
      upstreamUrl,
      correlationId,
      latencyMs: Date.now() - startedAt,
      result: summarizeResultLabel(upstream.status),
      upstreamStatus: upstream.status,
    });

    return {
      status: upstream.status,
      headers: responseHeaders,
      body: responseBody,
    };
  } catch (error) {
    recordUpstreamFailure(routing.aadObjectId);
    const message = error instanceof Error ? error.message : String(error);
    context.error(
      `Upstream relay failure aadObjectId=${routing.aadObjectId} correlationId=${correlationId}: ${message}`
    );
    logRoutingResult(context, {
      aadObjectId: routing.aadObjectId,
      userSlug: routing.userSlug,
      upstreamUrl,
      correlationId,
      latencyMs: Date.now() - startedAt,
      result: "upstream_failure",
    });
    return assistantTemporarilyUnavailable(correlationId);
  }
}

app.http("messages", {
  methods: ["POST"],
  authLevel: "anonymous",
  route: "api/messages",
  handler: async (
    request: HttpRequest,
    context: InvocationContext
  ): Promise<HttpResponseInit> => {
    const requestStartedAt = Date.now();
    const correlationId = resolveCorrelationId(request);

    const bodyText = await request.text();
    let activity: ActivityEnvelope;
    try {
      activity = JSON.parse(bodyText) as ActivityEnvelope;
    } catch {
      logRoutingResult(context, {
        aadObjectId: "unknown",
        userSlug: "unknown",
        upstreamUrl: "unknown",
        correlationId,
        latencyMs: Date.now() - requestStartedAt,
        result: "invalid_json",
      });
      return invalidRequest(correlationId);
    }

    const aadObjectId = activity.from?.aadObjectId ?? "";
    if (!aadObjectId) {
      logRoutingResult(context, {
        aadObjectId: "missing",
        userSlug: "unknown",
        upstreamUrl: "unknown",
        correlationId,
        latencyMs: Date.now() - requestStartedAt,
        result: "missing_aad_object_id",
      });
      return noAssistantConfigured(correlationId);
    }

    if (EXPECTED_TENANT_ID) {
      const tenantId = (activity.channelData?.tenant?.id ?? "").trim().toLowerCase();
      if (tenantId && tenantId !== EXPECTED_TENANT_ID) {
        logRoutingResult(context, {
          aadObjectId,
          userSlug: "unknown",
          upstreamUrl: "unknown",
          correlationId,
          latencyMs: Date.now() - requestStartedAt,
          result: "tenant_mismatch",
        });
        return noAssistantConfigured(correlationId);
      }
    }

    const resolution = await resolveRouting(aadObjectId, context);
    if (!resolution.record || !resolution.routingValid) {
      logRoutingResult(context, {
        aadObjectId: resolution.aadObjectId,
        userSlug: "unknown",
        upstreamUrl: "unknown",
        correlationId,
        latencyMs: Date.now() - requestStartedAt,
        result: resolution.lookupResult,
      });

      if (resolution.lookupResult === "store_error") {
        return assistantTemporarilyUnavailable(correlationId);
      }
      return noAssistantConfigured(correlationId);
    }

    if (isUpstreamCircuitOpen(resolution.record.aadObjectId)) {
      const snapshot = getUpstreamCircuitSnapshot(resolution.record.aadObjectId);
      logRoutingResult(context, {
        aadObjectId: resolution.record.aadObjectId,
        userSlug: resolution.record.userSlug,
        upstreamUrl: resolution.record.upstreamUrl,
        correlationId,
        latencyMs: Date.now() - requestStartedAt,
        result: "circuit_open",
        circuitUntil: snapshot.openUntil,
      });
      return assistantTemporarilyUnavailable(correlationId);
    }

    if (resolution.record.status === "provisioning") {
      logRoutingResult(context, {
        aadObjectId: resolution.record.aadObjectId,
        userSlug: resolution.record.userSlug,
        upstreamUrl: resolution.record.upstreamUrl,
        correlationId,
        latencyMs: Date.now() - requestStartedAt,
        result: "status_provisioning",
      });
      return assistantProvisioning(correlationId);
    }

    if (resolution.record.status === "disabled") {
      logRoutingResult(context, {
        aadObjectId: resolution.record.aadObjectId,
        userSlug: resolution.record.userSlug,
        upstreamUrl: resolution.record.upstreamUrl,
        correlationId,
        latencyMs: Date.now() - requestStartedAt,
        result: "status_disabled",
      });
      return assistantDisabled(correlationId);
    }

    return relayToUpstream(
      resolution.record,
      bodyText,
      request,
      correlationId,
      context
    );
  },
});
