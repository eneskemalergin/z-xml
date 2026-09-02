"""Share the process boundary used by the Zebrac measurement commands.

The A/A and matrix commands keep their own qualification, result validation,
failure reporting, and publication contracts. This module does not decide
correctness or publish results.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path

MAX_CONTROL_BYTES = 16 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024


def resolve_zebrac(explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit.resolve()
    command = shutil.which("zebrac")
    return Path(command).resolve() if command is not None else None


def file_information(path: Path) -> dict[str, object]:
    stat = path.stat()
    return {"path": str(path), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def read_limited(path: Path, limit: int = MAX_CONTROL_BYTES) -> bytes:
    if not path.is_file():
        raise ValueError(f"{path}: expected a regular file")
    with path.open("rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{path}: exceeds the {limit}-byte protocol limit")
    return data


def persistent_arguments(arguments: list[str]) -> tuple[dict[str, str], list[str]]:
    options = {
        "--input": "input",
        "--consumer": "consumer",
        "--chunk-bytes": "chunk_bytes",
        "--iterations": "iterations",
    }
    values: dict[str, str] = {}
    extra: list[str] = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        for option, field in options.items():
            if argument == option:
                if index + 1 >= len(arguments):
                    raise ValueError(f"missing value for {option}")
                value = arguments[index + 1]
                index += 2
                break
            if argument.startswith(option + "="):
                value = argument.removeprefix(option + "=")
                index += 1
                break
        else:
            extra.append(argument)
            index += 1
            continue
        if field in values or not value:
            raise ValueError(f"invalid or duplicate {option}")
        values[field] = value
    return values, extra


def run_process(
    command: list[str], timeout: float, max_output_bytes: int
) -> tuple[int, str, str, bool, bool]:
    prlimit = shutil.which("prlimit")
    if prlimit is None:
        raise ValueError("prlimit from util-linux is required")
    limited_command = [prlimit, f"--fsize={max_output_bytes}", "--", *command]
    with (
        tempfile.TemporaryFile() as stdout_file,
        tempfile.TemporaryFile() as stderr_file,
    ):
        process = subprocess.Popen(
            limited_command,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
            start_new_session=True,
        )
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        except KeyboardInterrupt:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        stdout_file.seek(0)
        stderr_file.seek(0)
        stdout = stdout_file.read(max_output_bytes + 1)
        stderr = stderr_file.read(max_output_bytes + 1)
    overflow = len(stdout) > max_output_bytes or len(stderr) > max_output_bytes
    return (
        process.returncode,
        stdout[:max_output_bytes].decode("utf-8", errors="replace"),
        stderr[:max_output_bytes].decode("utf-8", errors="replace"),
        timed_out,
        overflow,
    )


def source_information(root: Path) -> dict[str, object]:
    try:
        revision = run_process(["git", "-C", str(root), "rev-parse", "HEAD"], 5, 4096)
        status = run_process(
            [
                "git",
                "-C",
                str(root),
                "status",
                "--porcelain",
                "--untracked-files=no",
            ],
            5,
            MAX_CONTROL_BYTES,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"revision": None, "tracked_dirty": None}
    revision_valid = revision[0] == 0 and not revision[3] and not revision[4]
    status_valid = status[0] == 0 and not status[3] and not status[4]
    return {
        "revision": revision[1].strip() if revision_valid else None,
        "tracked_dirty": bool(status[1]) if status_valid else None,
    }
