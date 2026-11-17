# Windows setup for testing langchain-mxc

What a Windows machine needs before `run-windows-tests.cmd` can run, written so it can be handed to IT. The machine can be x64 or ARM64; the MXC package ships executors for both.

## Quick start

On a fresh Windows 11 machine, open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/srimanthtangedipalli-eng/langchain-mxc/main/setup-windows.ps1 | iex
```

It installs Git, Node.js, Python and uv if they are missing, downloads the code to `C:\mxc\langchain-mxc`, and runs the tests. Run the same command again to pull the latest code and re-test. The rest of this page explains what that command needs and does.

## What IT needs to provide

| Item | Requirement | How to check |
| --- | --- | --- |
| Windows | Windows 11 24H2, build 26100.9278 or newer | Run `winver`. If the build is older, run Windows Update until it is current. |
| Node.js | 24 or newer, with npm (only used to download the MXC package) | `node --version` |
| Python | 3.11 or newer, with "Add python.exe to PATH" ticked in the installer | `python --version` |
| uv | Any current version | `uv --version` |
| Git for Windows | Any current version | `git --version` |
| Network access | `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, and `api.anthropic.com` only if the demo uses a real model | The script reports which download failed. |
| Local admin | Needed to install the tools above. May be needed once more for MXC host preparation, described below. | |

Install commands, if `winget` is available:

```powershell
winget install OpenJS.NodeJS.LTS
winget install Python.Python.3.13
winget install astral-sh.uv
winget install Git.Git
```

Open a new terminal after installing so the tools are on `PATH`.

## What gets installed, and where

Everything the test installs stays inside the `langchain-mxc` folder:

- `node_modules\` holds `@microsoft/mxc-sdk` 1.0.1, Microsoft's package that contains the sandbox executor `wxc-exec.exe`.
- `.venv\` holds the Python dependencies.
- `windows-test-logs\` holds the output of each run.

Nothing is installed system-wide, no services are created, and the test script does not ask for admin rights. Deleting the folder removes everything.

## Things IT may ask about

- **Unsigned script.** `run-windows-tests.cmd` starts PowerShell with `-ExecutionPolicy Bypass` for that one script. If policy forbids that, run the steps in `scripts\windows\run-windows-tests.ps1` by hand.
- **Endpoint protection.** `wxc-exec.exe` creates AppContainer sandboxes and starts `cmd.exe` inside them. Security software may flag or block that. If the integration tests fail to start, check the security software's log for `wxc-exec.exe`.
- **Model API key.** None is needed. Without a key the demo runs in scripted mode: fixed tool calls instead of a model, with the real sandbox. To use a real model, set `ANTHROPIC_API_KEY` in the terminal first.

## MXC host preparation (may need admin)

The MXC package includes `wxc-host-prep.exe`, a one-time setup tool that only runs elevated. It has two operations:

- `prepare-system-drive` grants the AppContainer identities the minimum rights to see the root of the system drive (`C:\`). It can be undone with `unprepare-system-drive`.
- `prepare-null-device` resets the security descriptor on `\Device\Null` to the documented value. `verify-null-device` only checks it.

We do not know yet whether a fully updated 24H2 machine needs either step. The test script never runs this tool. If the log shows sandboxed commands failing to start, send the log first; if host preparation turns out to be the fix, it is one elevated command, so it helps if IT is reachable or the account has local admin.

## Running the test

1. Copy `langchain-mxc-windows-kit.zip` to the machine and extract it to a short path with no spaces, for example `C:\mxc\langchain-mxc`.
2. Optional, to run the demo with a real model: open a terminal in that folder and run `set ANTHROPIC_API_KEY=...`.
3. Run `run-windows-tests.cmd` from that terminal, or double-click it.
4. Wait for the summary. A full run takes roughly 5 to 10 minutes, most of it downloads.
5. Send back the zip named in the last line: `windows-test-logs\langchain-mxc-windows-<timestamp>.zip`.

To skip the demo agent: `run-windows-tests.cmd -SkipDemo`.

## What the script does

| Step | Log file | What it tells us |
| --- | --- | --- |
| Machine facts | `00-summary.log` | Windows build, architecture, whether the terminal is elevated |
| Tool versions | `01-tool-versions.log` | Node, npm, Python, uv, Git |
| Install MXC | `02-npm-install.log` | Whether `wxc-exec.exe` could be downloaded |
| Executor help | `03-executor-help.log` | The flags this executor version accepts |
| Install Python packages | `04-uv-sync.log` | Dependency install |
| Sample request | `05-request.log`, `request.json` | The exact policy sent to MXC on this machine |
| Executor dry run | `06-executor-dry-run.log` | Whether MXC accepts the policy |
| Executor probe | `07-executor-probe.log` | What MXC reports about this host |
| One sandboxed command | `08-executor-run.log` | Whether a sandbox can start at all |
| Unit tests | `09-unit-tests.log` | Package logic, no sandbox needed |
| Integration tests | `10-integration-tests.log` | Real sandbox: allowed and blocked writes, reads, network, timeouts |
| Policy walkthrough | `11-show-policy.log` | Sample allowed and blocked commands with the text the agent sees |
| Demo agent | `12-demo-agent.log` | A Deep Agent fixing a failing test inside the sandbox |

The logs contain folder paths and the Windows user name, and no API keys.
