#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
STOP_WORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "at",
    "be",
    "by",
    "for",
    "from",
    "how",
    "in",
    "into",
    "is",
    "it",
    "of",
    "on",
    "or",
    "that",
    "the",
    "this",
    "to",
    "we",
    "with",
}


def _tokenize(text: str) -> list[str]:
    return [
        token
        for token in re.findall(r"[a-z0-9]+", text.lower())
        if token not in STOP_WORDS and len(token) > 2
    ]


def _score_text(
    query_tokens: set[str], source_text: str, metadata_tokens: set[str]
) -> int:
    text_tokens = set(_tokenize(source_text)) | metadata_tokens
    return len(query_tokens & text_tokens)


def _read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def retrieve_member_evidence(member_id: str, agenda_text: str, limit: int = 3) -> dict:
    metadata_path = REPO_ROOT / "config" / "member-evidence" / f"{member_id}.json"
    if not metadata_path.exists():
        return {"memberId": member_id, "summary": {}, "snippets": []}

    metadata = _read_json(metadata_path)
    query_tokens = set(_tokenize(agenda_text))
    snippets: list[dict] = []

    for source in metadata.get("sources", []):
        source_path = REPO_ROOT / source["path"]
        if not source_path.exists():
            continue
        source_text = source_path.read_text(encoding="utf-8").strip()
        metadata_tokens = set(_tokenize(source.get("title", ""))) | set(
            _tokenize(" ".join(source.get("tags", [])))
        )
        score = _score_text(query_tokens, source_text, metadata_tokens)
        snippets.append(
            {
                "sourceId": source.get("id", source_path.stem),
                "title": source.get("title", source_path.stem),
                "type": source.get("type", "public-summary"),
                "year": source.get("year"),
                "path": source.get("path"),
                "score": score,
                "excerpt": source_text,
            }
        )

    snippets.sort(key=lambda item: (-item["score"], item["title"]))
    return {
        "memberId": member_id,
        "summary": metadata.get("summary", {}),
        "snippets": snippets[:limit],
    }
