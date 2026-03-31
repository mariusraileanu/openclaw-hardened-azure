from __future__ import annotations

import os
import subprocess
from pathlib import Path


def run(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> int:
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(command, cwd=cwd, env=run_env)
    return result.returncode


def run_quiet(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> int:
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(
        command,
        cwd=cwd,
        env=run_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode


def run_capture(
    command: list[str], cwd: Path, env: dict[str, str] | None = None
) -> str:
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(
        command,
        cwd=cwd,
        env=run_env,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()
