import { HttpResponseInit } from "@azure/functions";

const FRIENDLY_MESSAGES = {
  noAssistant: "No assistant configured",
  provisioning: "Your assistant is being set up",
  disabled: "Your assistant is currently unavailable",
  temporarilyUnavailable: "Assistant temporarily unavailable",
  invalidRequest: "Unable to process your request",
} as const;

type TeamsMessage = {
  type: "message";
  text: string;
};

function json200(message: string, correlationId: string): HttpResponseInit {
  const payload: TeamsMessage = {
    type: "message",
    text: message,
  };

  return {
    status: 200,
    headers: {
      "content-type": "application/json",
      "x-correlation-id": correlationId,
    },
    jsonBody: payload,
  };
}

export function noAssistantConfigured(correlationId: string): HttpResponseInit {
  return json200(FRIENDLY_MESSAGES.noAssistant, correlationId);
}

export function assistantProvisioning(correlationId: string): HttpResponseInit {
  return json200(FRIENDLY_MESSAGES.provisioning, correlationId);
}

export function assistantDisabled(correlationId: string): HttpResponseInit {
  return json200(FRIENDLY_MESSAGES.disabled, correlationId);
}

export function assistantTemporarilyUnavailable(
  correlationId: string
): HttpResponseInit {
  return json200(FRIENDLY_MESSAGES.temporarilyUnavailable, correlationId);
}

export function invalidRequest(correlationId: string): HttpResponseInit {
  return json200(FRIENDLY_MESSAGES.invalidRequest, correlationId);
}
