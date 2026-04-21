import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

import { resolveCorrelationId } from "../lib/correlation";
import { upsertRoutingRecord } from "../lib/routing/table-store";

type UpsertBody = {
  aad_object_id?: string;
  user_slug?: string;
  upstream_url?: string;
  status?: "active" | "provisioning" | "disabled";
};

const ALLOWED_STATUSES = new Set(["active", "provisioning", "disabled"]);

app.http("internal-routing-upsert", {
  methods: ["POST"],
  authLevel: "function",
  route: "internal/routing/upsert",
  handler: async (
    request: HttpRequest,
    context: InvocationContext
  ): Promise<HttpResponseInit> => {
    const correlationId = resolveCorrelationId(request);
    let body: UpsertBody;

    try {
      body = (await request.json()) as UpsertBody;
    } catch {
      return {
        status: 400,
        headers: {
          "content-type": "application/json",
          "x-correlation-id": correlationId,
        },
        jsonBody: {
          error: "invalid_json",
          correlation_id: correlationId,
        },
      };
    }

    const aadObjectId = (body.aad_object_id ?? "").trim();
    const userSlug = (body.user_slug ?? "").trim();
    const upstreamUrl = (body.upstream_url ?? "").trim();
    const status = (body.status ?? "active").trim().toLowerCase();

    if (!aadObjectId || !userSlug || !upstreamUrl || !ALLOWED_STATUSES.has(status)) {
      return {
        status: 400,
        headers: {
          "content-type": "application/json",
          "x-correlation-id": correlationId,
        },
        jsonBody: {
          error: "invalid_request",
          required: ["aad_object_id", "user_slug", "upstream_url", "status"],
          correlation_id: correlationId,
        },
      };
    }

    const validation = await upsertRoutingRecord(
      {
        aadObjectId,
        userSlug,
        upstreamUrl,
        status: status as "active" | "provisioning" | "disabled",
      },
      context
    );

    if (!validation.valid) {
      return {
        status: 400,
        headers: {
          "content-type": "application/json",
          "x-correlation-id": correlationId,
        },
        jsonBody: {
          error: validation.validationError,
          correlation_id: correlationId,
        },
      };
    }

    return {
      status: 200,
      headers: {
        "content-type": "application/json",
        "x-correlation-id": correlationId,
      },
      jsonBody: {
        ok: true,
        correlation_id: correlationId,
        aad_object_id: validation.record.aadObjectId,
        user_slug: validation.record.userSlug,
        upstream_url: validation.record.upstreamUrl,
        status: validation.record.status,
        updated_at: validation.record.updatedAt,
      },
    };
  },
});
