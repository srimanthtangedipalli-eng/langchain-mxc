"""Run a fixed set of commands through MXCSandbox on Windows and print what happens.

Used by `run-windows-tests.ps1`. It answers the open Windows questions in one
pass: which programs need the window system, whether timeouts work, and
whether denied folders are enforced. Nothing here needs admin rights, and
everything it writes goes to a temporary folder that is removed afterwards.

Usage: python diagnose.py
"""

from __future__ import annotations

import glob
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from langchain_mxc import MXCSandbox

SAMPLE_REPO = Path(__file__).resolve().parents[2] / "examples" / "sample_repo"
MAX_SHOWN = 1500


def show(label: str, sandbox: MXCSandbox, command: str, timeout: int = 60) -> None:
    started = time.monotonic()
    response = sandbox.execute(command, timeout=timeout)
    elapsed = time.monotonic() - started
    print(f"\n--- [{label}] $ {command}")
    print(f"exit={response.exit_code} seconds={elapsed:.1f}")
    for line in response.output[:MAX_SHOWN].splitlines():
        print(f"    {line}")


def ui_matrix(root: Path) -> None:
    locked = MXCSandbox(root_dir=root)
    opened = MXCSandbox(root_dir=root, allow_ui=True)
    git_binaries = sorted(glob.glob(r"C:\Program Files\Git\*\bin\git.exe"))
    commands = [
        "where git",
        "git --version",
        *[f'"{path}" --version' for path in git_binaries],
        "git init -q demo-repo && git -C demo-repo status --short --branch",
        "node --version",
        'python -c "import platform; print(platform.system(), platform.version(), platform.machine())"',
        "python -c \"import ctypes; ctypes.WinDLL('user32'); print('user32 loaded')\"",
        "python -c \"import ctypes; ctypes.WinDLL('ole32'); print('ole32 loaded')\"",
        "python -m pytest --version",
        "python -m pytest -q",
        'powershell -NoProfile -Command "Write-Output powershell-ok"',
        "whoami",
    ]
    for command in commands:
        show("ui locked", locked, command)
        show("allow_ui", opened, command)


def timeouts(root: Path) -> None:
    sandbox = MXCSandbox(root_dir=root)
    show("timeout 2s, expect exit 124", sandbox, 'echo start & python -c "import time; time.sleep(30)" & echo end', timeout=2)
    show("after the timeout, expect no python left over", sandbox, 'tasklist /FI "IMAGENAME eq python.exe"')


def network(root: Path) -> None:
    show("network off", MXCSandbox(root_dir=root), "curl.exe -sS --max-time 8 http://example.com -o NUL && echo reached")
    show("allow_network", MXCSandbox(root_dir=root, allow_network=True), "curl.exe -sS --max-time 8 http://example.com -o NUL && echo reached")


def denied_paths(root: Path, shared: Path) -> None:
    """Send `deniedPaths` to the executor directly: a folder inside a readable folder must stay blocked."""
    secret_dir = shared / "secret"
    secret_dir.mkdir()
    (shared / "open.txt").write_text("open-ok", encoding="utf-8")
    (secret_dir / "key.txt").write_text("SECRET-CONTENT", encoding="utf-8")
    sandbox = MXCSandbox(root_dir=root, read_only_paths=[shared])
    for label, target in (("readable file", shared / "open.txt"), ("denied file", secret_dir / "key.txt")):
        request = sandbox.build_request(f'type "{target}"', 30)
        request["filesystem"]["deniedPaths"] = [*request["filesystem"].get("deniedPaths", []), str(secret_dir)]
        config = shared.parent / "denied-request.json"
        config.write_text(json.dumps(request), encoding="utf-8")
        done = subprocess.run(
            [str(sandbox.executor_path), "--config", str(config)], capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL, timeout=60
        )
        print(f"\n--- [deniedPaths, {label}] type {target}")
        print(f"exit={done.returncode}")
        print(f"    stdout: {done.stdout.strip()[:MAX_SHOWN]}")
        print(f"    stderr: {done.stderr.strip()[:MAX_SHOWN]}")


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="mxc-diagnose-"))
    try:
        root = work / "repo"
        shutil.copytree(SAMPLE_REPO, root, ignore=shutil.ignore_patterns(".pytest_cache", "__pycache__"))
        shared = work / "shared"
        shared.mkdir()
        for section in (lambda: ui_matrix(root), lambda: timeouts(root), lambda: network(root), lambda: denied_paths(root, shared)):
            try:
                section()
            except Exception as exc:  # noqa: BLE001 - keep going so one failure does not hide the rest
                print(f"\nSECTION FAILED: {type(exc).__name__}: {exc}")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
