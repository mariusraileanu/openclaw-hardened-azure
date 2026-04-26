import { InvocationContext } from "@azure/functions";
import { TeamsActivityEnvelope } from "./board-work";

type TextFormat = "plain" | "markdown";

type ConversationContext = {
  serviceUrl: string;
  conversationId: string;
  activity: TeamsActivityEnvelope;
};

type PostActivityResult = {
  activityId: string | null;
};

const BOT_TOKEN_URL =
  process.env.MSTEAMS_BOT_TOKEN_URL?.trim() ||
  `https://login.microsoftonline.com/${
    process.env.MSTEAMS_BOT_TOKEN_TENANT_ID?.trim() ||
    process.env.MSTEAMS_EXPECTED_TENANT_ID?.trim() ||
    "botframework.com"
  }/oauth2/v2.0/token`;
const BOT_TOKEN_SCOPE =
  process.env.MSTEAMS_BOT_TOKEN_SCOPE?.trim() ||
  "https://api.botframework.com/.default";
const BOT_APP_ID = (process.env.MSTEAMS_APP_ID ?? "").trim();
const BOT_APP_SECRET = (process.env.MSTEAMS_APP_SECRET_VALUE ?? "").trim();

let cachedToken = "";
let cachedTokenExpiresAtMs = 0;

async function getBotToken(): Promise<string> {
  if (!BOT_APP_ID || !BOT_APP_SECRET) {
    throw new Error("MSTEAMS_APP_ID and MSTEAMS_APP_SECRET_VALUE are required");
  }

  if (cachedToken && cachedTokenExpiresAtMs > Date.now() + 60_000) {
    return cachedToken;
  }

  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: BOT_APP_ID,
    client_secret: BOT_APP_SECRET,
    scope: BOT_TOKEN_SCOPE,
  });

  const response = await fetch(BOT_TOKEN_URL, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });

  if (!response.ok) {
    throw new Error(`Bot token request failed with status ${response.status}`);
  }

  const payload = (await response.json()) as {
    access_token?: string;
    expires_in?: number;
  };

  const token = payload.access_token?.trim() ?? "";
  if (!token) {
    throw new Error("Bot token response did not include access_token");
  }

  const expiresInSec =
    typeof payload.expires_in === "number" && Number.isFinite(payload.expires_in)
      ? payload.expires_in
      : 300;

  cachedToken = token;
  cachedTokenExpiresAtMs = Date.now() + expiresInSec * 1000;
  return token;
}

function resolveConversationContext(activity: TeamsActivityEnvelope): ConversationContext {
  const serviceUrl = activity.serviceUrl?.trim() ?? "";
  const conversationId = activity.conversation?.id?.trim() ?? "";

  if (!serviceUrl || !conversationId) {
    throw new Error("serviceUrl and conversation.id are required for proactive reply");
  }

  return {
    serviceUrl,
    conversationId,
    activity,
  };
}

function buildBasePayload(activity: TeamsActivityEnvelope) {
  return {
    channelId: activity.channelId ?? "msteams",
    serviceUrl: activity.serviceUrl?.trim() ?? "",
    locale: activity.locale,
    conversation: activity.conversation,
    from: activity.recipient,
    recipient: activity.from,
  };
}

function buildMessagePayload(params: {
  activity: TeamsActivityEnvelope;
  text: string;
  textFormat: TextFormat;
  activityId?: string;
}) {
  const { activity, text, textFormat, activityId } = params;
  return {
    type: "message",
    id: activityId,
    text,
    textFormat,
    replyToId: activity.id,
    ...buildBasePayload(activity),
  };
}

function buildTypingPayload(activity: TeamsActivityEnvelope) {
  return {
    type: "typing",
    replyToId: activity.id,
    ...buildBasePayload(activity),
  };
}

async function postConversationActivity(params: {
  activity: TeamsActivityEnvelope;
  payload: object;
  correlationId: string;
  context: InvocationContext;
}): Promise<PostActivityResult> {
  const { activity, payload, correlationId, context } = params;
  const conversation = resolveConversationContext(activity);
  const token = await getBotToken();
  const endpoint = `${conversation.serviceUrl.replace(/\/$/, "")}/v3/conversations/${encodeURIComponent(
    conversation.conversationId
  )}/activities`;

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "x-correlation-id": correlationId,
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(
      `Proactive activity failed with status ${response.status}: ${responseText || "empty response"}`
    );
  }

  let activityId: string | null = null;
  try {
    const responseJson = (await response.json()) as { id?: string };
    activityId = responseJson.id?.trim() || null;
  } catch {
    activityId = null;
  }

  context.log(
    `relay_event=${JSON.stringify({
      correlationId,
      result: "proactive_activity_posted",
      serviceUrl: conversation.serviceUrl,
      conversationId: conversation.conversationId,
      activityId,
    })}`
  );

  return { activityId };
}

export async function sendTypingActivity(params: {
  activity: TeamsActivityEnvelope;
  correlationId: string;
  context: InvocationContext;
}): Promise<void> {
  const { activity, correlationId, context } = params;
  await postConversationActivity({
    activity,
    payload: buildTypingPayload(activity),
    correlationId,
    context,
  });
}

export async function updateProactiveReply(params: {
  activity: TeamsActivityEnvelope;
  activityId: string;
  text: string;
  textFormat?: TextFormat;
  correlationId: string;
  context: InvocationContext;
}): Promise<void> {
  const { activity, activityId, text, textFormat = "plain", correlationId, context } = params;
  const conversation = resolveConversationContext(activity);
  const token = await getBotToken();
  const endpoint = `${conversation.serviceUrl.replace(/\/$/, "")}/v3/conversations/${encodeURIComponent(
    conversation.conversationId
  )}/activities/${encodeURIComponent(activityId)}`;

  const response = await fetch(endpoint, {
    method: "PUT",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "x-correlation-id": correlationId,
    },
    body: JSON.stringify(
      buildMessagePayload({
        activity,
        activityId,
        text,
        textFormat,
      })
    ),
  });

  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(
      `Proactive update failed with status ${response.status}: ${responseText || "empty response"}`
    );
  }

  context.log(
    `relay_event=${JSON.stringify({
      correlationId,
      result: "proactive_reply_updated",
      serviceUrl: conversation.serviceUrl,
      conversationId: conversation.conversationId,
      activityId,
    })}`
  );
}

export async function sendProactiveReply(params: {
  activity: TeamsActivityEnvelope;
  text: string;
  textFormat?: TextFormat;
  correlationId: string;
  context: InvocationContext;
}): Promise<string | null> {
  const { activity, text, textFormat = "plain", correlationId, context } = params;
  const result = await postConversationActivity({
    activity,
    payload: buildMessagePayload({ activity, text, textFormat }),
    correlationId,
    context,
  });

  return result.activityId;
}
