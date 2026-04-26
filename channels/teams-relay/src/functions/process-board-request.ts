import { app, InvocationContext } from "@azure/functions";

import {
  BoardQueueMessage,
  resolveBoardQueueName,
  resolveBoardUpstreamTimeoutMs,
} from "../lib/board-work";
import { withCorrelationHeader } from "../lib/correlation";
import {
  sendProactiveReply,
  sendTypingActivity,
  updateProactiveReply,
} from "../lib/proactive-reply";
import {
  recordUpstreamFailure,
  recordUpstreamSuccess,
} from "../lib/routing/service";

const BOARD_QUEUE_NAME = resolveBoardQueueName();
const BOARD_UPSTREAM_TIMEOUT_MS = resolveBoardUpstreamTimeoutMs();
const PROGRESS_INTERVAL_MS = 30_000;

type BoardStreamEvent =
  | {
      type: "progress";
      stage: ProgressStage;
      message: string;
      attendees?: Array<{ name: string; topic?: string }>;
    }
  | {
      type: "final";
      text: string;
    }
  | {
      type: "error";
      message: string;
    };

type ProgressStage =
  | "requested"
  | "members_selected"
  | "deliberation"
  | "voting"
  | "decision_packet"
  | "completed";

type ProgressState = {
  board: string;
  stage: ProgressStage;
  statusText: string;
  attendees: Array<{ name: string; topic?: string }>;
};

type StreamParseResult = {
  events: BoardStreamEvent[];
  remainder: string;
};

function appendBoardMeetingPath(baseUrl: string): string {
  return `${baseUrl.replace(/\/$/, "")}/__openclaw__/board-meeting`;
}

function logBoardEvent(context: InvocationContext, payload: Record<string, unknown>): void {
  context.log(`relay_event=${JSON.stringify(payload)}`);
}

function parseBoardQueueMessage(queueItem: unknown): BoardQueueMessage {
  if (typeof queueItem === "string") {
    return JSON.parse(queueItem) as BoardQueueMessage;
  }
  return queueItem as BoardQueueMessage;
}

function isAsyncHandoffError(message: string): boolean {
  const normalized = message.toLowerCase();
  return (
    normalized.includes("socket hang up") ||
    normalized.includes("terminated") ||
    normalized.includes("abort") ||
    normalized.includes("timeout") ||
    normalized.includes("fetch failed")
  );
}

function prettifyBoardName(board: string): string {
  return board.replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function stageLabel(stage: ProgressStage): string {
  switch (stage) {
    case "requested":
      return "Requested";
    case "members_selected":
      return "Members selected";
    case "deliberation":
      return "Deliberation";
    case "voting":
      return "Voting";
    case "decision_packet":
      return "Decision packet";
    case "completed":
      return "Completed";
  }
}

function stageOrder(stage: ProgressStage): number {
  switch (stage) {
    case "requested":
      return 0;
    case "members_selected":
      return 1;
    case "deliberation":
      return 2;
    case "voting":
      return 3;
    case "decision_packet":
      return 4;
    case "completed":
      return 5;
  }
}

function defaultProgressState(board: string): ProgressState {
  return {
    board,
    stage: "requested",
    statusText: "Board request accepted. Convening the board now.",
    attendees: [],
  };
}

function buildProgressMessage(state: ProgressState): string {
  const stages: ProgressStage[] = [
    "requested",
    "members_selected",
    "deliberation",
    "voting",
    "decision_packet",
  ];
  const currentOrder = stageOrder(state.stage);
  const lines = stages.map((stage) => {
    const order = stageOrder(stage);
    const label = stageLabel(stage);
    if (state.stage === "completed" || order < currentOrder) {
      return `- [done] ${label}`;
    }
    if (order === currentOrder) {
      return `- [in progress] ${label}`;
    }
    return `- [pending] ${label}`;
  });

  const attendeeLines =
    state.attendees.length > 0
      ? [
          "",
          "Selected attendees:",
          ...state.attendees.map((attendee) =>
            attendee.topic
              ? `- ${attendee.name} - ${attendee.topic}`
              : `- ${attendee.name}`
          ),
        ]
      : [];

  const title = `${prettifyBoardName(state.board)} Advisory Board`;
  return [
    `**${title}**`,
    "",
    `Status: ${state.statusText}`,
    "",
    ...lines,
    ...attendeeLines,
  ].join("\n");
}

function classifyProgressStage(message: string): ProgressStage {
  const normalized = message.toLowerCase();
  if (normalized.includes("selected attendees")) {
    return "members_selected";
  }
  if (normalized.includes("first-pass") || normalized.includes("rebuttal summary")) {
    return "deliberation";
  }
  if (normalized.includes("final vote")) {
    return "voting";
  }
  if (normalized.includes("decision packet written")) {
    return "decision_packet";
  }
  return "requested";
}

function parseAttendees(message: string): Array<{ name: string; topic?: string }> {
  const marker = "Chairman selected attendees:";
  const index = message.indexOf(marker);
  if (index < 0) {
    return [];
  }

  const raw = message.slice(index + marker.length).trim();
  if (!raw) {
    return [];
  }

  return raw
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .map((value) => {
      const [name, topic] = value.split(" – ");
      return {
        name: name.trim(),
        topic: topic?.trim(),
      };
    });
}

function parseBoardStreamChunk(buffer: string): StreamParseResult {
  const lines = buffer.split("\n");
  const remainder = lines.pop() ?? "";
  const events: BoardStreamEvent[] = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    try {
      const parsed = JSON.parse(trimmed) as BoardStreamEvent;
      if (parsed && typeof parsed === "object" && typeof parsed.type === "string") {
        events.push(parsed);
      }
    } catch {
      // Ignore heartbeat lines and incomplete chunks.
    }
  }

  return { events, remainder };
}

function mergeProgressState(current: ProgressState, event: Extract<BoardStreamEvent, { type: "progress" }>): ProgressState {
  return {
    ...current,
    stage: stageOrder(event.stage) >= stageOrder(current.stage) ? event.stage : current.stage,
    statusText: event.message,
    attendees: event.attendees && event.attendees.length > 0 ? event.attendees : current.attendees,
  };
}

async function updateProgressActivity(params: {
  activityId: string | null;
  workItem: BoardQueueMessage;
  state: ProgressState;
  context: InvocationContext;
}): Promise<string | null> {
  const { activityId, workItem, state, context } = params;
  const text = buildProgressMessage(state);

  if (activityId) {
    try {
      await updateProactiveReply({
        activity: workItem.activity,
        activityId,
        text,
        textFormat: "markdown",
        correlationId: workItem.correlationId,
        context,
      });
      return activityId;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      context.error(
        `Board progress update failed correlationId=${workItem.correlationId}: ${message}`
      );
    }
  }

  return await sendProactiveReply({
    activity: workItem.activity,
    text,
    textFormat: "markdown",
    correlationId: workItem.correlationId,
    context,
  });
}

app.storageQueue("processBoardRequest", {
  queueName: BOARD_QUEUE_NAME,
  connection: "AzureWebJobsStorage",
  handler: async (queueItem: unknown, context: InvocationContext): Promise<void> => {
    const workItem = parseBoardQueueMessage(queueItem);
    const startedAt = Date.now();
    const upstreamUrl = appendBoardMeetingPath(workItem.routing.upstreamUrl);

    logBoardEvent(context, {
      aadObjectId: workItem.routing.aadObjectId,
      userSlug: workItem.routing.userSlug,
      correlationId: workItem.correlationId,
      upstreamUrl,
      result: "board_request_started",
      queuedAt: workItem.queuedAt,
    });

    try {
      await sendTypingActivity({
        activity: workItem.activity,
        correlationId: workItem.correlationId,
        context,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      context.error(
        `Board typing activity failed correlationId=${workItem.correlationId}: ${message}`
      );
    }

    let progressState = defaultProgressState(workItem.boardRequest.board);
    let progressActivityId: string | null = null;

    try {
      progressActivityId = await updateProgressActivity({
        activityId: null,
        workItem,
        state: progressState,
        context,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      context.error(
        `Board acceptance reply failed correlationId=${workItem.correlationId}: ${message}`
      );
    }

    let keepaliveTimer: NodeJS.Timeout | undefined;
    const scheduleKeepalive = () => {
      if (keepaliveTimer) {
        clearTimeout(keepaliveTimer);
      }
      keepaliveTimer = setTimeout(() => {
        void (async () => {
          try {
            progressActivityId = await updateProgressActivity({
              activityId: progressActivityId,
              workItem,
              state: progressState,
              context,
            });
          } catch {
            // Best-effort keepalive update.
          }
          scheduleKeepalive();
        })();
      }, PROGRESS_INTERVAL_MS);
    };
    scheduleKeepalive();

    try {
      const upstream = await fetch(upstreamUrl, {
        method: "POST",
        headers: withCorrelationHeader(
          { "content-type": "application/json" },
          workItem.correlationId
        ),
        body: JSON.stringify(workItem.boardRequest),
        signal: AbortSignal.timeout(BOARD_UPSTREAM_TIMEOUT_MS),
      });

      if (!upstream.ok) {
        const responseBody = await upstream.text();
        recordUpstreamFailure(workItem.routing.aadObjectId);
        throw new Error(
          `Upstream board request failed with status ${upstream.status}: ${
            responseBody || "empty response"
          }`
        );
      }

      const decoder = new TextDecoder();
      let buffer = "";
      let finalReply: string | null = null;
      const reader = upstream.body?.getReader();

      if (!reader) {
        buffer = await upstream.text();
      } else {
        while (true) {
          const { done, value } = await reader.read();
          if (done) {
            break;
          }

          buffer += decoder.decode(value, { stream: true });
          const parsed = parseBoardStreamChunk(buffer);
          buffer = parsed.remainder;

          for (const event of parsed.events) {
            if (event.type === "progress") {
              progressState = mergeProgressState(progressState, event);
              progressActivityId = await updateProgressActivity({
                activityId: progressActivityId,
                workItem,
                state: progressState,
                context,
              });
              scheduleKeepalive();
            } else if (event.type === "final") {
              finalReply = event.text.trim() || null;
            } else if (event.type === "error") {
              throw new Error(event.message);
            }
          }
        }

        buffer += decoder.decode();
      }

      if (!finalReply) {
        const parsed = parseBoardStreamChunk(buffer);
        for (const event of parsed.events) {
          if (event.type === "final") {
            finalReply = event.text.trim() || null;
          }
        }
      }

      recordUpstreamSuccess(workItem.routing.aadObjectId);

      progressState = {
        ...progressState,
        stage: "completed",
        statusText: "Decision packet delivered.",
      };
      progressActivityId = await updateProgressActivity({
        activityId: progressActivityId,
        workItem,
        state: progressState,
        context,
      });

      if (finalReply) {
        await sendProactiveReply({
          activity: workItem.activity,
          text: finalReply,
          textFormat: "markdown",
          correlationId: workItem.correlationId,
          context,
        });
      }

      logBoardEvent(context, {
        aadObjectId: workItem.routing.aadObjectId,
        userSlug: workItem.routing.userSlug,
        correlationId: workItem.correlationId,
        upstreamUrl,
        latencyMs: Date.now() - startedAt,
        result: finalReply ? "board_request_completed" : "board_request_empty_body",
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (isAsyncHandoffError(message)) {
        logBoardEvent(context, {
          aadObjectId: workItem.routing.aadObjectId,
          userSlug: workItem.routing.userSlug,
          correlationId: workItem.correlationId,
          upstreamUrl,
          latencyMs: Date.now() - startedAt,
          result: "board_request_handoff_uncertain",
          error: message,
        });
        return;
      }

      recordUpstreamFailure(workItem.routing.aadObjectId);
      context.error(
        `Board request failure aadObjectId=${workItem.routing.aadObjectId} correlationId=${workItem.correlationId}: ${message}`
      );
      logBoardEvent(context, {
        aadObjectId: workItem.routing.aadObjectId,
        userSlug: workItem.routing.userSlug,
        correlationId: workItem.correlationId,
        upstreamUrl,
        latencyMs: Date.now() - startedAt,
        result: "board_request_failed",
        error: message,
      });

      try {
        progressState = {
          ...progressState,
          statusText: "Board deliberation did not complete successfully.",
        };
        await updateProgressActivity({
          activityId: progressActivityId,
          workItem,
          state: progressState,
          context,
        });

        await sendProactiveReply({
          activity: workItem.activity,
          text:
            "The board meeting request did not complete successfully. Please try again in a few minutes.",
          textFormat: "plain",
          correlationId: workItem.correlationId,
          context,
        });
      } catch (replyError) {
        const replyMessage =
          replyError instanceof Error ? replyError.message : String(replyError);
        context.error(
          `Board failure reply could not be delivered correlationId=${workItem.correlationId}: ${replyMessage}`
        );
      }
    } finally {
      if (keepaliveTimer) {
        clearTimeout(keepaliveTimer);
      }
    }
  },
});
