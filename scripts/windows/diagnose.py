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


def file_operations(label: str, root: Path) -> None:
    """Delete, rename and overwrite inside the read-write project folder."""
    (root / "host-made.txt").write_text("made by the host", encoding="utf-8")
    locked = MXCSandbox(root_dir=root)
    opened = MXCSandbox(root_dir=root, allow_ui=True)
    for command in (
        "echo a> made.txt && del made.txt && echo del-ok",
        "echo a> ren1.txt && ren ren1.txt ren2.txt && echo ren-ok",
        "echo a> over.txt && echo b> over.txt && type over.txt",
        "mkdir newdir && rmdir newdir && echo rmdir-ok",
        "del host-made.txt && echo del-host-file-ok",
        "python -c \"import os; open('p.txt','w').write('x'); os.remove('p.txt'); print('py-remove-ok')\"",
        "python -c \"import os; open('p.txt','w').write('x'); os.replace('p.txt','q.txt'); print('py-replace-ok')\"",
        'echo a> "%TEMP%\\scratch.txt" && del "%TEMP%\\scratch.txt" && echo scratch-del-ok',
    ):
        show(f"{label}, ui locked", locked, command)
    show(f"{label}, allow_ui", opened, "echo a> made2.txt && del made2.txt && echo del-ok")
    show(f"{label}, allow_ui", opened, "echo a> acl-check.txt && icacls . && icacls acl-check.txt")
    for target in (root, root / "acl-check.txt"):
        done = subprocess.run(["icacls", str(target)], capture_output=True, text=True, check=False, stdin=subprocess.DEVNULL, timeout=30)
        print(f"\n--- [{label}, host view] icacls {target}")
        print("    " + done.stdout.strip().replace("\n", "\n    ")[:MAX_SHOWN])
    print(f"\n--- [{label}] left in the folder: {sorted(p.name for p in root.iterdir())}")


def delete_matrix(root: Path) -> None:
    """Which ways of deleting a file work inside the read-write project folder.

    Run 3 showed cmd's `del` denied everywhere while Python's `os.remove`,
    `ren` and `rmdir` work. This narrows down which tools are affected.
    """
    (root / "host-made.txt").write_text("made by the host", encoding="utf-8")
    locked = MXCSandbox(root_dir=root)
    opened = MXCSandbox(root_dir=root, allow_ui=True)
    for command in (
        "echo a> d1.txt && del /f /q d1.txt && echo del-f-ok",
        "echo a> d2.txt && erase d2.txt && echo erase-ok",
        'echo a> d3.txt && del "%CD%\\d3.txt" && echo del-fullpath-ok',
        "echo a> d4.tmp && del *.tmp && echo del-wildcard-ok",
        "echo a> d5.txt && attrib d5.txt",
        "mkdir sub && echo a> sub\\f.txt && rmdir /s /q sub && if not exist sub echo rmdir-s-ok",
        "echo a> m1.txt && echo b> m2.txt && move /y m1.txt m2.txt && type m2.txt",
        "python -c \"import os; os.remove('host-made.txt'); print('py-remove-host-file-ok')\"",
        "python -c \"import os, shutil; os.makedirs('t/x'); open('t/x/f', 'w').close(); shutil.rmtree('t'); print('py-rmtree-ok')\"",
    ):
        show("delete, ui locked", locked, command)
    for command in (
        "echo a> d6.txt && del d6.txt && echo del-ok",
        "node -e \"const fs=require('fs'); fs.writeFileSync('n.txt','x'); fs.unlinkSync('n.txt'); console.log('node-unlink-ok')\"",
        "powershell -NoProfile -Command \"Set-Content x.txt a; Remove-Item x.txt; 'ps-remove-ok'\"",
        (
            "git init -q g && cd g && echo a> f.txt && git add f.txt && git -c user.email=t@example.com -c user.name=t commit -qm m"
            " && git rm -q f.txt && if not exist f.txt echo git-rm-ok"
        ),
        "cd g && echo b> junk.txt && git clean -fq && if not exist junk.txt echo git-clean-ok",
    ):
        show("delete, allow_ui", opened, command)
    print(f"\n--- [delete] left in the folder: {sorted(p.name for p in root.iterdir())}")


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="mxc-diagnose-"))
    in_project = SAMPLE_REPO.parent / ".mxc-diagnose-root"
    try:
        root = work / "repo"
        shutil.copytree(SAMPLE_REPO, root, ignore=shutil.ignore_patterns(".pytest_cache", "__pycache__"))
        shared = work / "shared"
        shared.mkdir()
        in_temp = work / "fileops"
        in_temp.mkdir()
        in_project.mkdir(exist_ok=True)
        deletes = work / "deletes"
        deletes.mkdir()
        sections = (
            lambda: delete_matrix(deletes),
            lambda: file_operations("temp folder", in_temp),
            lambda: file_operations("folder inside the project", in_project),
            lambda: ui_matrix(root),
            lambda: timeouts(root),
            lambda: network(root),
            lambda: denied_paths(root, shared),
        )
        for section in sections:
            try:
                section()
            except Exception as exc:  # noqa: BLE001 - keep going so one failure does not hide the rest
                print(f"\nSECTION FAILED: {type(exc).__name__}: {exc}")
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(in_project, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
