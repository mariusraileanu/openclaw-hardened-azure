import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { resolveCorrelationId } from "../lib/correlation";
import {
  getUpstreamCircuitSnapshot,
  resolveRouting,
} from "../lib/routing/service";

function getUpstreamHost(upstreamUrl: string): string | null {
  try {
    return new URL(upstreamUrl).host;
  } catch {
    return null;
  }
}

app.http("internal-routing", {
  methods: ["GET"],
  authLevel: "function",
  route: "internal/routing/{aadObjectId}",
  handler: async (
    request: HttpRequest,
    context: InvocationContext
  ): Promise<HttpResponseInit> => {
    const correlationId = resolveCorrelationId(request);
    const aadObjectId = request.params.aadObjectId ?? "";
    const verbose = (request.query.get("verbose") ?? "").toLowerCase() === "true";

    const resolution = await resolveRouting(aadObjectId, context);
    const snapshot = getUpstreamCircuitSnapshot(resolution.aadObjectId);

    const payload: Record<string, unknown> = {
      aad_object_id: resolution.aadObjectId,
      user_slug: resolution.record?.userSlug ?? null,
      status: resolution.record?.status ?? null,
      cache: resolution.cache,
      lookup_result: resolution.lookupResult,
      routing_valid: resolution.routingValid,
      validation_error: resolution.validationError,
      correlation_id: correlationId,
      circuit_state: snapshot.state,
      circuit_until: snapshot.openUntil,
      upstream_host: resolution.record
        ? getUpstreamHost(resolution.record.upstreamUrl)
        : null,
    };

    if (verbose && resolution.record) {
      payload.upstream_url = resolution.record.upstreamUrl;
      payload.updated_at = resolution.record.updatedAt;
    }

    return {
      status: 200,
      headers: {
        "content-type": "application/json",
        "x-correlation-id": correlationId,
      },
      jsonBody: payload,
    };
  },
});
