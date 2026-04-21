import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');

const stopWords = new Set([
  'a', 'an', 'and', 'are', 'as', 'at', 'be', 'by', 'for', 'from', 'how', 'in', 'into',
  'is', 'it', 'of', 'on', 'or', 'that', 'the', 'this', 'to', 'we', 'with',
]);

function tokenize(text) {
  return (String(text).toLowerCase().match(/[a-z0-9]+/g) ?? []).filter(
    (token) => token.length > 2 && !stopWords.has(token)
  );
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function scoreText(queryTokens, sourceText, metadataTokens) {
  const textTokens = new Set([...tokenize(sourceText), ...metadataTokens]);
  let score = 0;
  for (const token of queryTokens) {
    if (textTokens.has(token)) {
      score += 1;
    }
  }
  return score;
}

function splitIntoChunks(text, maxChars = 420) {
  const paragraphs = text
    .split(/\n\s*\n/)
    .map((item) => item.trim())
    .filter(Boolean);

  if (paragraphs.length === 0) {
    return [];
  }

  const chunks = [];
  let current = '';
  for (const paragraph of paragraphs) {
    const candidate = current ? `${current}\n\n${paragraph}` : paragraph;
    if (candidate.length <= maxChars) {
      current = candidate;
      continue;
    }
    if (current) {
      chunks.push(current);
    }
    if (paragraph.length <= maxChars) {
      current = paragraph;
      continue;
    }
    const sentences = paragraph.split(/(?<=[.!?])\s+/).filter(Boolean);
    let sentenceChunk = '';
    for (const sentence of sentences) {
      const sentenceCandidate = sentenceChunk ? `${sentenceChunk} ${sentence}` : sentence;
      if (sentenceCandidate.length <= maxChars) {
        sentenceChunk = sentenceCandidate;
      } else {
        if (sentenceChunk) {
          chunks.push(sentenceChunk);
        }
        sentenceChunk = sentence;
      }
    }
    if (sentenceChunk) {
      current = sentenceChunk;
    } else {
      current = '';
    }
  }
  if (current) {
    chunks.push(current);
  }
  return chunks;
}

export function retrieveMemberEvidence(memberId, agendaText, limit = 3) {
  const metadataPath = path.join(repoRoot, 'config', 'boards', 'members', memberId, 'evidence.json');
  if (!fs.existsSync(metadataPath)) {
    return { memberId, summary: {}, snippets: [] };
  }

  const metadata = readJson(metadataPath);
  const queryTokens = new Set(tokenize(agendaText));
  const snippets = [];

  for (const source of metadata.sources ?? []) {
    const sourcePath = path.join(repoRoot, source.path);
    if (!fs.existsSync(sourcePath)) {
      continue;
    }
    const excerpt = fs.readFileSync(sourcePath, 'utf8').trim();
    const metadataTokens = new Set([
      ...tokenize(source.title ?? ''),
      ...tokenize((source.tags ?? []).join(' ')),
    ]);
    const chunks = splitIntoChunks(excerpt);
    for (const chunk of chunks) {
      const score = scoreText(queryTokens, chunk, metadataTokens);
      snippets.push({
        sourceId: source.id ?? path.basename(sourcePath, path.extname(sourcePath)),
        title: source.title ?? path.basename(sourcePath),
        type: source.type ?? 'public-summary',
        year: source.year,
        path: source.path,
        score,
        excerpt: chunk,
      });
    }
  }

  snippets.sort((a, b) => {
    if (b.score !== a.score) {
      return b.score - a.score;
    }
    return a.title.localeCompare(b.title);
  });

  const selected = [];
  const seenSources = new Set();
  for (const snippet of snippets) {
    if (seenSources.has(snippet.sourceId)) {
      continue;
    }
    selected.push(snippet);
    seenSources.add(snippet.sourceId);
    if (selected.length >= limit) {
      break;
    }
  }

  return {
    memberId,
    summary: metadata.summary ?? {},
    snippets: selected,
  };
}
