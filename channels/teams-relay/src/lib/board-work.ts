import { RoutingRecord } from "./routing/types";

const DEFAULT_BOARD_QUEUE_NAME = "teams-board-requests";
const DEFAULT_BOARD_UPSTREAM_TIMEOUT_MS = 10 * 60 * 1000;

export type TeamsActivityEnvelope = {
  id?: string;
  type?: string;
  text?: string;
  locale?: string;
  channelId?: string;
  serviceUrl?: string;
  from?: {
    id?: string;
    name?: string;
    aadObjectId?: string;
  };
  recipient?: {
    id?: string;
    name?: string;
    aadObjectId?: string;
  };
  conversation?: {
    id?: string;
    conversationType?: string;
    tenantId?: string;
    isGroup?: boolean;
    name?: string;
  };
  channelData?: {
    tenant?: {
      id?: string;
    };
  };
};

export type BoardQueueMessage = {
  activity: TeamsActivityEnvelope;
  bodyText: string;
  correlationId: string;
  headers: Record<string, string>;
  boardRequest: BoardMeetingRequest;
  routing: RoutingRecord;
  queuedAt: string;
};

export type BoardMeetingRequest = {
  board: string;
  topic: string;
  context: string;
};

const BOARD_NAME_PATTERNS = [
  /\bconvene\s+the\s+([a-z0-9][a-z0-9\s_-]*?)\s+advisory\s+board\b/i,
  /\bconvene\s+the\s+([a-z0-9][a-z0-9\s_-]*?)\s+board\b/i,
  /\brun\s+(?:a|an|the)?\s*([a-z0-9_-]+)\s+board\s+meeting\b/i,
  /\b([a-z0-9][a-z0-9\s_-]*?)\s+advisory\s+board\b/i,
  /\b([a-z0-9][a-z0-9\s_-]*?)\s+board\b/i,
] as const;

function normalizeBoardSlug(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/advisory/g, " ")
    .replace(/board/g, " ")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-+/g, "-");
}

function extractBoardSlug(text: string): string {
  for (const pattern of BOARD_NAME_PATTERNS) {
    const match = text.match(pattern);
    const candidate = normalizeBoardSlug(match?.[1] ?? "");
    if (candidate) {
      return candidate;
    }
  }
  return "fertility";
}

function extractTopic(text: string): string {
  const topicFromQuestion = text.match(/\bquestion\s*:\s*([\s\S]+?)(?:\n\s*select\b|$)/i);
  if (topicFromQuestion?.[1]?.trim()) {
    return topicFromQuestion[1].trim();
  }

  const topicFromLabel = text.match(/\bon\s+the\s+topic\s*:\s*([\s\S]+)$/i);
  if (topicFromLabel?.[1]?.trim()) {
    return topicFromLabel[1].trim();
  }

  return text.trim();
}

function parsePositiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt((value ?? "").trim(), 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return parsed;
}

export function resolveBoardQueueName(): string {
  return (process.env.MSTEAMS_BOARD_QUEUE_NAME ?? "").trim() || DEFAULT_BOARD_QUEUE_NAME;
}

export function resolveBoardUpstreamTimeoutMs(): number {
  return parsePositiveInteger(
    process.env.MSTEAMS_BOARD_UPSTREAM_TIMEOUT_MS,
    DEFAULT_BOARD_UPSTREAM_TIMEOUT_MS
  );
}

export function isBoardMeetingRequest(activity: TeamsActivityEnvelope): boolean {
  if ((activity.type ?? "message").toLowerCase() !== "message") {
    return false;
  }

  const text = (activity.text ?? "").trim();
  if (!text) {
    return false;
  }

  return (
    /\bboard meeting\b/i.test(text) ||
    /\bconvene\s+the\b/i.test(text) ||
    /\bformal\s+board\s+deliberation\b/i.test(text) ||
    /\bdecision packet\b/i.test(text)
  );
}

export function parseBoardMeetingRequest(activity: TeamsActivityEnvelope): BoardMeetingRequest {
  const text = (activity.text ?? "").trim();
  const board = extractBoardSlug(text);
  const topic = extractTopic(text);

  return {
    board,
    topic,
    context: "",
  };
}
