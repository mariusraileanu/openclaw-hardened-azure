#!/usr/bin/env node

import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { retrieveMemberEvidence } from './member-evidence.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const runningInsideContainer = process.env.OPENCLAW_CONFIG_FILE?.startsWith('/app/') ?? false;

function usage() {
  console.error(
    'Usage: node scripts/run-board-meeting.mjs --board fertility --agenda board-meetings/fertility-sample-agenda.json [--output /tmp/result.md] [--trace-output /tmp/result.trace.json] [--packet-mode full|brief] [--min-attendees 3] [--max-attendees 5] [--selection-timeout 300] [--member-timeout 180] [--chairman-timeout 300]'
  );
  process.exit(1);
}

function parseArgs(argv) {
  const args = {
    board: '',
    agenda: '',
    output: '',
    traceOutput: '',
    packetMode: 'full',
    minAttendees: '3',
    maxAttendees: '5',
    selectionTimeout: '300',
    memberTimeout: '180',
    chairmanTimeout: '300',
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--board') {
      args.board = argv[++i] ?? '';
    } else if (arg === '--agenda') {
      args.agenda = argv[++i] ?? '';
    } else if (arg === '--output') {
      args.output = argv[++i] ?? '';
    } else if (arg === '--trace-output') {
      args.traceOutput = argv[++i] ?? '';
    } else if (arg === '--packet-mode') {
      args.packetMode = argv[++i] ?? '';
    } else if (arg === '--min-attendees') {
      args.minAttendees = argv[++i] ?? '';
    } else if (arg === '--max-attendees') {
      args.maxAttendees = argv[++i] ?? '';
    } else if (arg === '--selection-timeout') {
      args.selectionTimeout = argv[++i] ?? '';
    } else if (arg === '--member-timeout') {
      args.memberTimeout = argv[++i] ?? '';
    } else if (arg === '--chairman-timeout') {
      args.chairmanTimeout = argv[++i] ?? '';
    } else {
      usage();
    }
  }

  if (!args.board || !args.agenda) {
    usage();
  }

  return args;
}

function toPositiveInt(name, value) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer. Received: ${value}`);
  }
  return parsed;
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function jsString(value) {
  return JSON.stringify(value);
}

function logProgress(message) {
  console.error(`[board-meeting] ${message}`);
}

function normalizeJsonArray(text) {
  const trimmed = text.trim();
  const start = trimmed.indexOf('[');
  const end = trimmed.lastIndexOf(']');
  if (start < 0 || end <= start) {
    throw new Error(`Expected JSON array in response. Raw: ${trimmed}`);
  }
  const parsed = JSON.parse(trimmed.slice(start, end + 1));
  if (!Array.isArray(parsed)) {
    throw new Error(`Expected JSON array response. Raw: ${trimmed}`);
  }
  return parsed;
}

function dedupe(items) {
  return [...new Set(items)];
}

function normalizeAgenda(agenda) {
  const normalizedContext = Array.isArray(agenda.context)
    ? agenda.context.filter((item) => typeof item === 'string' && item.trim())
    : typeof agenda.context === 'string' && agenda.context.trim()
      ? [agenda.context.trim()]
      : [];

  return {
    ...agenda,
    context: normalizedContext,
  };
}

function assertPacketMode(value) {
  if (value !== 'full' && value !== 'brief') {
    throw new Error(`packetMode must be either "full" or "brief". Received: ${value}`);
  }
  return value;
}

function memberAgentId(boardId, memberId) {
  return `${boardId}-${memberId}`;
}

function meetingSessionKey(agentId, meetingId, runId) {
  return `agent:${agentId}:meeting-${meetingId}:run-${runId}`;
}

async function runCommand(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.workdir ?? repoRoot,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';

  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });

  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });

  const exitCodePromise = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });

  if (options.input) {
    child.stdin.write(options.input);
  }
  child.stdin.end();

  const exitCode = await exitCodePromise;
  return { stdout, stderr, exitCode };
}

async function runDockerNode(scriptSource, options = {}) {
  if (runningInsideContainer) {
    const previousEnv = new Map();
    for (const [key, value] of Object.entries(options.env ?? {})) {
      previousEnv.set(key, process.env[key]);
      process.env[key] = value;
    }

    try {
      return await runLocalNode(scriptSource, options.timeoutSeconds);
    } finally {
      for (const [key, value] of previousEnv.entries()) {
        if (value === undefined) {
          delete process.env[key];
        } else {
          process.env[key] = value;
        }
      }
    }
  }

  const envPrefix = Object.entries(options.env ?? {})
    .map(([key, value]) => `${key}=${shellQuote(value)}`)
    .join(' ');
  const timeoutPrefix = options.timeoutSeconds
    ? `timeout --preserve-status -k 5s ${String(options.timeoutSeconds)}s `
    : '';
  const shellCommand = `${envPrefix ? `env ${envPrefix} ` : ''}${timeoutPrefix}node --input-type=module`;

  const { stdout, stderr, exitCode } = await runCommand(
    'docker',
    ['compose', 'exec', '-T', 'openclaw', 'sh', '-lc', shellCommand],
    { input: scriptSource }
  );

  if (exitCode !== 0) {
    throw new Error(stderr || stdout || `docker compose exec failed with exit code ${String(exitCode)}`);
  }

  return stdout;
}

async function runLocalNode(scriptSource, timeoutSeconds = 0) {
  const child = spawn('node', ['--input-type=module'], {
    cwd: repoRoot,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  let timedOut = false;
  let timeoutId = null;

  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });

  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });

  if (timeoutSeconds > 0) {
    timeoutId = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 5000).unref();
    }, timeoutSeconds * 1000);
  }

  const exitCode = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
    child.stdin.end(scriptSource);
  });

  if (timeoutId) {
    clearTimeout(timeoutId);
  }

  if (timedOut) {
    throw new Error(stderr || stdout || `local node execution timed out after ${String(timeoutSeconds)} seconds`);
  }

  if (exitCode !== 0) {
    throw new Error(stderr || stdout || `local node execution failed with exit code ${String(exitCode)}`);
  }

  return stdout;
}

async function createMeetingRuntime(runId) {
  const setupScript = `
import fs from 'node:fs';

const sourceConfigPath = process.env.OPENCLAW_CONFIG_FILE;
const sourceStateDir = process.env.OPENCLAW_STATE_DIR;
if (!sourceConfigPath || !sourceStateDir) {
  throw new Error('OPENCLAW_CONFIG_FILE and OPENCLAW_STATE_DIR must be set inside the container.');
}

const tempStateDir = ${jsString(`/tmp/openclaw-board-state-${runId}`)};
const tempConfigPath = tempStateDir + '/openclaw.json';
fs.mkdirSync(tempStateDir, { recursive: true });

const config = JSON.parse(fs.readFileSync(sourceConfigPath, 'utf8'));
if (config.memory?.qmd?.sessions) {
  config.memory.qmd.sessions.enabled = false;
}
for (const pluginId of ['active-memory', 'memory-core', 'memory-wiki']) {
  if (config.plugins?.entries?.[pluginId]) {
    config.plugins.entries[pluginId].enabled = false;
  }
}
for (const agent of config.agents?.list || []) {
  const sourceAgentDir = agent.agentDir;
  const relativeAgentDir = sourceAgentDir.startsWith(sourceStateDir)
    ? sourceAgentDir.slice(sourceStateDir.length)
    : '/agents/' + agent.id + '/agent';
  const tempAgentDir = tempStateDir + relativeAgentDir;
  fs.mkdirSync(tempAgentDir, { recursive: true });

  const sourceModelsPath = sourceAgentDir + '/models.json';
  const tempModelsPath = tempAgentDir + '/models.json';
  if (fs.existsSync(sourceModelsPath)) {
    fs.copyFileSync(sourceModelsPath, tempModelsPath);
  }

  agent.agentDir = tempAgentDir;
}

fs.writeFileSync(tempConfigPath, JSON.stringify(config));
process.stdout.write(JSON.stringify({ tempStateDir, tempConfigPath }));
`;

  const stdout = await runDockerNode(setupScript);
  return JSON.parse(stdout.trim());
}

async function callAgent(runtime, options) {
  const callScript = `
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const distDir = '/app/dist';
const agentCommandFile = fs.readdirSync(distDir).find(f => f.startsWith('agent-command-') && f.endsWith('.js'));
if (!agentCommandFile) throw new Error('agent-command-*.js not found in ' + distDir);
const { n: agentCommand } = await import(pathToFileURL(distDir + '/' + agentCommandFile).href);

function normalizeText(result) {
  return result?.meta?.finalAssistantVisibleText
    ?? result?.payloads?.map((payload) => payload?.text ?? '').filter(Boolean).join(${jsString('\n\n')})
    ?? '';
}

const result = await agentCommand({
  agentId: ${jsString(options.agentId)},
  sessionKey: ${jsString(options.sessionKey)},
  message: ${jsString(options.message)},
  timeout: ${jsString(String(options.timeoutSeconds))},
});

process.stdout.write(JSON.stringify({
  agentId: ${jsString(options.agentId)},
  sessionKey: ${jsString(options.sessionKey)},
  text: normalizeText(result).trim(),
}));
`;

  const stdout = await runDockerNode(callScript, {
    env: {
      OPENCLAW_CONFIG_FILE: runtime.tempConfigPath,
      OPENCLAW_STATE_DIR: runtime.tempStateDir,
    },
    timeoutSeconds: options.timeoutSeconds + 15,
  });

  const lines = stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const jsonLine = [...lines].reverse().find((line) => line.startsWith('{') && line.endsWith('}'));
  if (!jsonLine) {
    throw new Error(`No JSON payload found in agent output. Raw output: ${stdout}`);
  }

  return JSON.parse(jsonLine);
}

async function callAgentWithRetry(runtime, options, label, attempts = 2) {
  let lastError = null;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await callAgent(runtime, options);
    } catch (error) {
      lastError = error;
      logProgress(`${label} failed on attempt ${String(attempt)}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}

function buildAttendeeSelectionPrompt(agenda, boardPayload, minAttendees, maxAttendees) {
  return [
    'You are chairing a formal advisory board meeting.',
    'Select the most relevant board members for this agenda.',
    'Return only a JSON array of member ids from the board roster.',
    `Choose between ${String(minAttendees)} and ${String(maxAttendees)} attendees.`,
    'Prefer core members unless a specialist is directly relevant to the agenda.',
    '',
    'Meeting ID: ' + agenda.meetingId,
    'Agenda Topic: ' + agenda.agendaTopic,
    'Agenda Summary: ' + agenda.agendaSummary,
    'Decision Request: ' + agenda.decisionRequest,
    '',
    'Board roster:',
    ...boardPayload.members.map(
      (member) => `- ${member.id} | ${member.name} | ${member.topic} | attendance=${member.attendance}`
    ),
    '',
    'Context:',
    ...(agenda.context || []).map((item) => '- ' + item),
  ].join('\n');
}

function buildReplacementPrompt(agenda, boardPayload, count, excludedIds) {
  return [
    'One or more previously selected attendees were unavailable to respond in time for this local board run.',
    `Return only a JSON array of ${String(count)} replacement member ids from the board roster.`,
    'Do not include any excluded member ids.',
    'Prefer core members unless a specialist is directly relevant to the agenda.',
    '',
    'Meeting ID: ' + agenda.meetingId,
    'Agenda Topic: ' + agenda.agendaTopic,
    'Agenda Summary: ' + agenda.agendaSummary,
    '',
    'Excluded member ids:',
    excludedIds.length > 0 ? JSON.stringify(excludedIds) : '[]',
    '',
    'Board roster:',
    ...boardPayload.members.map(
      (member) => `- ${member.id} | ${member.name} | ${member.topic} | attendance=${member.attendance}`
    ),
    '',
    'Context:',
    ...(agenda.context || []).map((item) => '- ' + item),
  ].join('\n');
}

function buildFirstPassPrompt(agenda) {
  return [
    'This is the independent first-pass round of a formal board meeting.',
    'Do not assume consensus. Give only your own view.',
    'Keep the response concise and decision-oriented.',
    'Limit yourself to 4 short bullets max.',
    '',
    'Meeting ID: ' + agenda.meetingId,
    'Agenda Topic: ' + agenda.agendaTopic,
    'Agenda Summary: ' + agenda.agendaSummary,
    'Decision Request: ' + agenda.decisionRequest,
    '',
    'Context:',
    ...(agenda.context || []).map((item) => '- ' + item),
  ].join('\n');
}

function formatEvidenceBlock(evidence) {
  const themes = evidence?.summary?.coreThemes ?? [];
  const style = evidence?.summary?.argumentStyle ?? [];
  const snippets = evidence?.snippets ?? [];
  if (themes.length === 0 && style.length === 0 && snippets.length === 0) {
    return '';
  }

  return [
    'Public-source grounding for this member:',
    ...(themes.length > 0 ? ['Core themes:', ...themes.map((item) => '- ' + item)] : []),
    ...(style.length > 0 ? ['Argument style:', ...style.map((item) => '- ' + item)] : []),
    ...(snippets.length > 0
      ? [
          'Relevant excerpts:',
          ...snippets.map(
            (snippet, index) =>
              `${String(index + 1)}. ${snippet.title}${snippet.year ? ` (${String(snippet.year)})` : ''}\n${snippet.excerpt}`
          ),
        ]
      : []),
    'Use these as soft grounding for likely priorities and objections. Do not claim private knowledge or current real-world endorsement.',
  ].join('\n\n');
}

function buildVotePrompt(agenda, firstPassText, rebuttalText) {
  return [
    'This is the final-vote round of a formal board meeting.',
    "You have your independent first-pass view and the chairman's rebuttal summary.",
    'Return your final vote in the required board-member final-vote format.',
    'Keep the response concise and focused on the final vote, rationale, risks, and conditions.',
    'Limit yourself to 5 short bullets max.',
    '',
    'Meeting ID: ' + agenda.meetingId,
    'Agenda Topic: ' + agenda.agendaTopic,
    'Agenda Summary: ' + agenda.agendaSummary,
    '',
    'Your first-pass view:',
    firstPassText,
    '',
    'Chairman rebuttal summary:',
    rebuttalText,
  ].join('\n');
}

function fallbackVoteText(member) {
  return [
    `- Member: ${member.name}`,
    '- Vote: abstain',
    '- Reason: no final vote was returned within the local execution timeout after retries.',
  ].join('\n');
}

function buildFinalDecisionPrompt({
  agenda,
  attendees,
  firstPasses,
  rebuttalText,
  finalVotes,
  packetMode,
}) {
  const brevityInstruction =
    packetMode === 'brief'
      ? 'Output a brief UI-safe decision packet. Keep attendees to one line each, limit key risks to 3, open questions to 3, and next actions to 5.'
      : 'Output a full decision packet in markdown.';

  return [
    'Issue the final formal decision packet for this board meeting.',
    'Use the selected attendees, independent first-pass views, rebuttal summary, and final votes below.',
    brevityInstruction,
    'Output only the final decision packet in markdown.',
    'Keep it concise and operationally actionable.',
    '',
    'Meeting ID: ' + agenda.meetingId,
    'Agenda Topic: ' + agenda.agendaTopic,
    'Agenda Summary: ' + agenda.agendaSummary,
    'Decision Request: ' + agenda.decisionRequest,
    '',
    'Selected attendees:',
    ...attendees.map((member) => `- ${member.name} | ${member.topic}`),
    '',
    'Independent first-pass views:',
    ...firstPasses.map(({ member, text }) => `## ${member.name}\n${text}`),
    '',
    'Chairman rebuttal summary:',
    rebuttalText,
    '',
    'Final votes:',
    ...finalVotes.map(({ member, text }) => `## ${member.name}\n${text}`),
  ].join('\n\n');
}

export async function runBoardMeeting(argsInput) {
  const args = typeof argsInput?.board === 'string' && typeof argsInput?.agenda === 'string'
    ? {
        board: argsInput.board,
        agenda: argsInput.agenda,
        output: argsInput.output ?? '',
        traceOutput: argsInput.traceOutput ?? '',
        packetMode: argsInput.packetMode ?? 'full',
        minAttendees: String(argsInput.minAttendees ?? '3'),
        maxAttendees: String(argsInput.maxAttendees ?? '5'),
        selectionTimeout: String(argsInput.selectionTimeout ?? '300'),
        memberTimeout: String(argsInput.memberTimeout ?? '180'),
        chairmanTimeout: String(argsInput.chairmanTimeout ?? '300'),
      }
    : parseArgs(process.argv.slice(2));
  const minAttendees = toPositiveInt('minAttendees', args.minAttendees);
  const maxAttendees = toPositiveInt('maxAttendees', args.maxAttendees);
  const packetMode = assertPacketMode(args.packetMode);
  const selectionTimeout = toPositiveInt('selectionTimeout', args.selectionTimeout);
  const memberTimeout = toPositiveInt('memberTimeout', args.memberTimeout);
  const chairmanTimeout = toPositiveInt('chairmanTimeout', args.chairmanTimeout);

  if (minAttendees > maxAttendees) {
    throw new Error('minAttendees cannot be greater than maxAttendees.');
  }

  const boardPath = path.resolve(repoRoot, 'config', 'boards', `${args.board}.json`);
  const agendaPath = path.resolve(process.cwd(), args.agenda);
  const boardPayload = JSON.parse(await fs.readFile(boardPath, 'utf8'));
  const agendaPayload = normalizeAgenda(JSON.parse(await fs.readFile(agendaPath, 'utf8')));
  const outputPath = args.output
    ? path.resolve(process.cwd(), args.output)
    : path.resolve(repoRoot, 'board-meetings', `${agendaPayload.meetingId}.result.md`);
  const traceOutputPath = args.traceOutput
    ? path.resolve(process.cwd(), args.traceOutput)
    : path.resolve(repoRoot, 'board-meetings', `${agendaPayload.meetingId}.trace.json`);

  const runId = `${Date.now()}`;
  const runtime = await createMeetingRuntime(runId);
  const chairmanAgentId = `${args.board}-chairman`;
  const chairmanSessionKey = meetingSessionKey(chairmanAgentId, agendaPayload.meetingId, runId);
  const memberById = new Map(boardPayload.members.map((member) => [member.id, member]));

  logProgress(`Created isolated runtime at ${runtime.tempStateDir}`);

  const selectionPrompt = buildAttendeeSelectionPrompt(
    agendaPayload,
    boardPayload,
    minAttendees,
    maxAttendees
  );
  const selectionResponse = await callAgentWithRetry(
    runtime,
    {
      agentId: chairmanAgentId,
      sessionKey: chairmanSessionKey,
      message: selectionPrompt,
      timeoutSeconds: selectionTimeout,
    },
    'chairman attendee selection'
  );

  const initialSelectedIds = dedupe(normalizeJsonArray(selectionResponse.text))
    .filter((memberId) => typeof memberId === 'string')
    .filter((memberId) => memberById.has(memberId))
    .slice(0, maxAttendees);
  if (initialSelectedIds.length === 0) {
    throw new Error(`Chairman selected no valid attendees. Raw: ${selectionResponse.text}`);
  }

  let targetAttendeeCount = Math.max(minAttendees, initialSelectedIds.length);
  targetAttendeeCount = Math.min(targetAttendeeCount, maxAttendees);
  logProgress(`Chairman selected attendees: ${initialSelectedIds.join(', ')}`);

  const firstPasses = [];
  const activeAttendeeIds = [];
  const unavailableIds = new Set();
  let pendingIds = [...initialSelectedIds];
  const firstPassPrompt = buildFirstPassPrompt(agendaPayload);
  const agendaGroundingText = [agendaPayload.agendaTopic, agendaPayload.agendaSummary, agendaPayload.decisionRequest, ...(agendaPayload.context || [])].join('\n');
  const memberEvidence = new Map();

  while (firstPasses.length < targetAttendeeCount) {
    const batchIds = pendingIds.splice(0, targetAttendeeCount - firstPasses.length);
    if (batchIds.length === 0) {
      const replacementCount = targetAttendeeCount - firstPasses.length;
      const replacementPrompt = buildReplacementPrompt(
        agendaPayload,
        boardPayload,
        replacementCount,
        [...new Set([...activeAttendeeIds, ...unavailableIds])]
      );
      const replacementResponse = await callAgentWithRetry(
        runtime,
        {
          agentId: chairmanAgentId,
          sessionKey: chairmanSessionKey,
          message: replacementPrompt,
          timeoutSeconds: chairmanTimeout,
        },
        'chairman replacement selection'
      );

      const replacementIds = dedupe(normalizeJsonArray(replacementResponse.text))
        .filter((memberId) => typeof memberId === 'string')
        .filter((memberId) => memberById.has(memberId))
        .filter((memberId) => !activeAttendeeIds.includes(memberId))
        .filter((memberId) => !unavailableIds.has(memberId))
        .slice(0, replacementCount);

      if (replacementIds.length === 0) {
        break;
      }

      logProgress(`Chairman selected replacement attendees: ${replacementIds.join(', ')}`);
      pendingIds.push(...replacementIds);
      continue;
    }

    const batchResults = await Promise.all(
      batchIds.map(async (memberId) => {
        const member = memberById.get(memberId);
        if (!member) {
          return { memberId, member: null, ok: false, error: new Error(`Unknown member id: ${memberId}`) };
        }

        try {
          const evidence = retrieveMemberEvidence(member.id, agendaGroundingText, 3);
          memberEvidence.set(member.id, evidence);
          const response = await callAgentWithRetry(
            runtime,
            {
              agentId: memberAgentId(args.board, member.id),
              sessionKey: meetingSessionKey(memberAgentId(args.board, member.id), agendaPayload.meetingId, runId),
              message: [firstPassPrompt, formatEvidenceBlock(evidence)].filter(Boolean).join('\n\n'),
              timeoutSeconds: memberTimeout,
            },
            `first-pass from ${member.name}`
          );

          return { memberId, member, ok: true, text: response.text };
        } catch (error) {
          return { memberId, member, ok: false, error };
        }
      })
    );

    for (const result of batchResults) {
      if (result.ok && result.member) {
        activeAttendeeIds.push(result.member.id);
        firstPasses.push({ member: result.member, text: result.text.trim() });
        logProgress(`Collected first-pass from ${result.member.name}`);
      } else if (result.member) {
        unavailableIds.add(result.member.id);
        logProgress(
          `Member unavailable for first-pass: ${result.member.name} (${result.error instanceof Error ? result.error.message : String(result.error)})`
        );
      }
    }
  }

  if (firstPasses.length < minAttendees) {
    throw new Error(`Only ${String(firstPasses.length)} attendees responded in time; need at least ${String(minAttendees)}.`);
  }

  const attendees = firstPasses.map(({ member }) => member);
  logProgress(`Active attendees: ${attendees.map((member) => member.id).join(', ')}`);

  const rebuttalSummaryPrompt = [
    'Summarize the independent first-pass views from the selected attendees.',
    'Group areas of agreement, disagreement, and unresolved risks.',
    'Output concise markdown bullets only.',
    '',
    ...firstPasses.map(({ member, text }) => `## ${member.name}\n${text}`),
  ].join('\n\n');

  const rebuttalResponse = await callAgentWithRetry(
    runtime,
    {
      agentId: chairmanAgentId,
      sessionKey: chairmanSessionKey,
      message: rebuttalSummaryPrompt,
      timeoutSeconds: chairmanTimeout,
    },
    'chairman rebuttal summary'
  );
  const rebuttalText = rebuttalResponse.text.trim();
  logProgress('Collected chairman rebuttal summary');

  const finalVotes = await Promise.all(
    firstPasses.map(async ({ member, text }) => {
      try {
        const response = await callAgentWithRetry(
          runtime,
          {
            agentId: memberAgentId(args.board, member.id),
            sessionKey: meetingSessionKey(memberAgentId(args.board, member.id), agendaPayload.meetingId, runId),
            message: [
              buildVotePrompt(agendaPayload, text, rebuttalText),
              formatEvidenceBlock(memberEvidence.get(member.id) ?? retrieveMemberEvidence(member.id, agendaGroundingText, 3)),
            ]
              .filter(Boolean)
              .join('\n\n'),
            timeoutSeconds: memberTimeout,
          },
          `final vote from ${member.name}`
        );

        logProgress(`Collected final vote from ${member.name}`);
        return { member, text: response.text.trim() };
      } catch (error) {
        logProgress(
          `Final vote unavailable from ${member.name}; recording abstention (${error instanceof Error ? error.message : String(error)})`
        );
        return { member, text: fallbackVoteText(member) };
      }
    })
  );

  const finalDecisionPrompt = buildFinalDecisionPrompt({
    agenda: agendaPayload,
    attendees,
    firstPasses,
    rebuttalText,
    finalVotes,
    packetMode,
  });

  const finalDecisionResponse = await callAgentWithRetry(
    runtime,
    {
      agentId: chairmanAgentId,
      sessionKey: chairmanSessionKey,
      message: finalDecisionPrompt,
      timeoutSeconds: chairmanTimeout,
    },
    'chairman final decision packet'
  );

  const decisionPacket = finalDecisionResponse.text.trim();
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.writeFile(outputPath, decisionPacket, 'utf8');

  const trace = {
    runId,
    boardId: args.board,
    meetingId: agendaPayload.meetingId,
    packetMode,
    outputPath,
    runtime,
    chairman: {
      agentId: chairmanAgentId,
      sessionKey: chairmanSessionKey,
    },
    attendees: attendees.map((member) => ({
      id: member.id,
      name: member.name,
      agentId: memberAgentId(args.board, member.id),
      sessionKey: meetingSessionKey(memberAgentId(args.board, member.id), agendaPayload.meetingId, runId),
      evidenceSources: (memberEvidence.get(member.id)?.snippets ?? []).map((snippet) => ({
        sourceId: snippet.sourceId,
        title: snippet.title,
        path: snippet.path,
      })),
    })),
    unavailableMemberIds: [...unavailableIds],
  };
  await fs.mkdir(path.dirname(traceOutputPath), { recursive: true });
  await fs.writeFile(traceOutputPath, `${JSON.stringify(trace, null, 2)}\n`, 'utf8');

  logProgress(`Decision packet written to ${outputPath}`);
  logProgress(`Trace written to ${traceOutputPath}`);
  logProgress(`Meeting runtime preserved at ${runtime.tempStateDir}`);
  return { decisionPacket, trace, outputPath, traceOutputPath, runtime };
}

async function main() {
  const result = await runBoardMeeting(parseArgs(process.argv.slice(2)));
  process.stdout.write(result.decisionPacket);
}

const invokedAsMain = (() => {
  const entry = process.argv[1];
  if (!entry) {
    return false;
  }
  return import.meta.url === pathToFileURL(path.resolve(entry)).href;
})();

if (invokedAsMain) {
  main().catch((error) => {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
  });
}
