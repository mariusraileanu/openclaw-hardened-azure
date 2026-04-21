import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

import { Type } from "@sinclair/typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { readStringParam } from "openclaw/plugin-sdk/param-readers";

type BoardRouterConfig = {
  enabled?: boolean;
  boardIds?: string[];
};

type BoardMeetingResult = {
  decisionPacket: string;
};

type BoardRunnerModule = {
  runBoardMeeting: (argsInput: {
    board: string;
    agenda: string;
    output: string;
    traceOutput: string;
    packetMode: "brief" | "full";
    minAttendees: number;
    maxAttendees: number;
    selectionTimeout: number;
    memberTimeout: number;
    chairmanTimeout: number;
  }) => Promise<BoardMeetingResult>;
};

const DEFAULT_BOARD_RUNNER_CANDIDATES = [
  "/app/scripts/run-board-meeting.mjs",
  path.resolve(process.cwd(), "scripts", "run-board-meeting.mjs"),
];

let boardRunnerPromise: Promise<BoardRunnerModule> | null = null;

function normalizeString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeList(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((item) => normalizeString(item).toLowerCase())
    .filter(Boolean);
}

function buildAgenda(topic: string, context: string, boardId: string) {
  const meetingId = `${boardId}-ui-${Date.now()}`;
  const decisionRequest = [topic, context].filter(Boolean).join("\n\n");
  return {
    meetingId,
    boardId,
    agendaTopic: topic.slice(0, 160),
    agendaSummary: decisionRequest,
    context: [],
    decisionRequest,
  };
}

async function writeJson(filePath: string, value: unknown): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function loadBoardRunner(): Promise<BoardRunnerModule> {
  if (boardRunnerPromise) {
    return boardRunnerPromise;
  }

  boardRunnerPromise = (async () => {
    for (const candidatePath of DEFAULT_BOARD_RUNNER_CANDIDATES) {
      try {
        await fs.access(candidatePath);
        const module = await import(pathToFileURL(candidatePath).href);
        if (typeof module.runBoardMeeting === "function") {
          return module as BoardRunnerModule;
        }
      } catch {
        continue;
      }
    }
    throw new Error("Unable to load board meeting runner module.");
  })();

  return boardRunnerPromise;
}

async function runBoardMeeting(
  boardId: string,
  topic: string,
  context: string
): Promise<string> {
  const meetingId = `${boardId}-ui-${Date.now()}`;
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), `${boardId}-ui-`));
  const agendaPath = path.join(tempDir, `${meetingId}.agenda.json`);
  const outputPath = path.join(tempDir, `${meetingId}.decision.md`);
  const tracePath = path.join(tempDir, `${meetingId}.trace.json`);
  await writeJson(agendaPath, buildAgenda(topic, context, boardId));

  console.log(`[board-router] Starting board meeting: board=${boardId} meetingId=${meetingId}`);

  const runner = await loadBoardRunner();
  const result = await runner.runBoardMeeting({
    board: boardId,
    agenda: agendaPath,
    output: outputPath,
    traceOutput: tracePath,
    packetMode: "brief",
    minAttendees: 3,
    maxAttendees: 3,
    selectionTimeout: 180,
    memberTimeout: 120,
    chairmanTimeout: 180,
  });

  const packet = result.decisionPacket;
  console.log(
    `[board-router] Board meeting completed: board=${boardId} packetLength=${packet?.length ?? 0}`
  );
  return packet;
}

const ConveneBoardMeetingSchema = Type.Object(
  {
    board: Type.String({
      description:
        "Board identifier — must be one of the enabled board IDs (e.g. 'fertility', 'strategic-health').",
    }),
    topic: Type.String({
      description:
        "The decision being requested, stated as a clear question or directive.",
    }),
    context: Type.Optional(
      Type.String({
        description:
          "Background information, constraints, timelines, or relevant history for the board to consider.",
      })
    ),
  },
  { additionalProperties: false }
);

export default definePluginEntry({
  id: "board-router",
  name: "Board Router",
  description:
    "Registers the convene_board_meeting tool for deterministic board decision-making.",
  register(api) {
    const pluginConfig = (api.pluginConfig ?? {}) as BoardRouterConfig;
    const enabled = pluginConfig.enabled !== false;
    const boardIds = normalizeList(pluginConfig.boardIds);

    if (!enabled || boardIds.length === 0) {
      return;
    }

    const boardListDisplay = boardIds.join(", ");

    api.registerTool({
      name: "convene_board_meeting",
      label: "Convene Board Meeting",
      description: [
        "Convene a formal board meeting and return a deterministic decision packet.",
        "This tool runs a full board meeting with multiple specialist attendees,",
        "a chairman, deliberation, and a formal vote. It takes several minutes to complete.",
        `Available boards: ${boardListDisplay}.`,
      ].join(" "),
      parameters: ConveneBoardMeetingSchema,
      execute: async (_toolCallId, rawParams) => {
        const board = readStringParam(rawParams, "board", { required: true }).toLowerCase();
        const topic = readStringParam(rawParams, "topic", { required: true });
        const context = readStringParam(rawParams, "context") ?? "";

        console.log(`[board-router] Tool called: board=${board} topic=${topic.slice(0, 80)}`);

        if (!boardIds.includes(board)) {
          console.log(`[board-router] Unknown board: ${board}`);
          return {
            content: [
              {
                type: "text" as const,
                text: `Unknown board "${board}". Available boards: ${boardListDisplay}.`,
              },
            ],
          };
        }

        try {
          const packet = await runBoardMeeting(board, topic, context);
          console.log(
            `[board-router] Returning decision packet: ${packet.length} chars`
          );
          return {
            content: [{ type: "text" as const, text: packet.trim() }],
          };
        } catch (error) {
          const message =
            error instanceof Error ? error.message : String(error);
          console.error(`[board-router] Tool execution failed: ${message}`);
          return {
            content: [
              {
                type: "text" as const,
                text: `Board meeting execution failed: ${message}`,
              },
            ],
          };
        }
      },
    });
  },
});
