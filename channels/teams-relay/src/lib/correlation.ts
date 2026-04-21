import { HttpRequest } from "@azure/functions";
import { randomUUID } from "node:crypto";

export const CORRELATION_HEADER = "x-correlation-id";

export function resolveCorrelationId(request: HttpRequest): string {
  const incoming = request.headers.get(CORRELATION_HEADER)?.trim() ?? "";
  if (incoming && incoming.length <= 128) {
    return incoming;
  }
  return randomUUID();
}

export function withCorrelationHeader(
  headers: Record<string, string>,
  correlationId: string
): Record<string, string> {
  return {
    ...headers,
    [CORRELATION_HEADER]: correlationId,
  };
}
