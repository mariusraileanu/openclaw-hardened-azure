/**
 * Health check endpoint for monitoring.
 * Returns 200 OK with basic relay status.
 */

import {
  app,
  HttpRequest,
  HttpResponseInit,
  InvocationContext,
} from "@azure/functions";

app.http("health", {
  methods: ["GET"],
  authLevel: "anonymous",
  route: "healthz",
  handler: async (
    _request: HttpRequest,
    _context: InvocationContext
  ): Promise<HttpResponseInit> => {
    const configured = !!process.env.CAE_DEFAULT_DOMAIN;
    return {
      status: configured ? 200 : 503,
      jsonBody: {
        status: configured ? "healthy" : "misconfigured",
        relay: "teams-webhook-relay",
        environment: process.env.ENVIRONMENT ?? "unknown",
        cae_domain: configured ? "(set)" : "(missing)",
      },
    };
  },
});
