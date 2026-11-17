# langchain-mxc

Microsoft Execution Containers (MXC) sandbox backend for [Deep Agents](https://github.com/langchain-ai/deepagents).

> **Private preview.** Built for the Microsoft Ignite preview. Verified on macOS (Seatbelt) and on Linux (bubblewrap, in a privileged Debian container). The Windows path is implemented from MXC's contract but has not been run yet; see [Status](#status).

## What it is

`MXCSandbox` is a Deep Agents backend. When a Deep Agent running on your machine calls its `execute` tool, the shell command runs inside an MXC process sandbox and the operating system limits what the command can touch: writes go only to your project folder and a scratch directory, reads are limited to those plus the toolchain, and the network is off unless you turn it on.

```python
from deepagents import create_deep_agent
from langchain_mxc import MXCSandbox

agent = create_deep_agent(model="anthropic:claude-opus-5-5", backend=MXCSandbox(root_dir="./my-project"))
```

The agent loop and model calls run on the host as usual. Only shell commands go through MXC. The file tools (`ls`, `read`, `write`, `edit`, `glob`, `grep`) run in the host process and are limited to `root_dir` by Deep Agents' own path checks. **Those path checks are not OS-enforced; only `execute` is.** GitHub Copilot uses the same split in its MXC integration.

MXC uses one sandbox per command (process isolation), torn down when the command exits. Files persist between commands because the sandbox runs over your real project folder.

## Requirements

| OS | Minimum | Enforcement mechanism |
| --- | --- | --- |
| Windows 11 | 24H2, build 26100.9278 or newer | Process container (AppContainer) |
| macOS | 15 or newer | Seatbelt (`sandbox_init`) |
| Linux | bubblewrap 0.5+ with unprivileged user namespaces enabled. `allow_network=True` also needs `slirp4netns` and `ip` (iproute2) on `PATH` | bubblewrap |

Plus:

- Python 3.11 or newer, `deepagents` 0.7.x.
- Node.js 24 or newer, to install the `@microsoft/mxc-sdk` npm package that ships the native executor. Node is not used at runtime; the package only needs the binary.

## Installing MXC

There is no Python SDK for MXC yet. The package drives the command-line executor bundled in the npm package:

```bash
npm install @microsoft/mxc-sdk        # in your project, or
npm install -g @microsoft/mxc-sdk     # globally
```

`MXCSandbox` looks for the executor in this order:

1. the `executor_path` constructor argument;
2. the `MXC_EXECUTOR_PATH` environment variable (full path to the binary), or `MXC_BIN_DIR` (the `bin/` folder, as the Node SDK uses it);
3. `node_modules/@microsoft/mxc-sdk/bin/<arch>/` in the working directory and each parent directory;
4. common global `node_modules` locations (npm prefix, Homebrew, nvm, fnm, volta, `%APPDATA%\npm`), then `npm root -g`;
5. `PATH`.

The executor names are `wxc-exec.exe` (Windows), `mxc-exec-mac` (macOS, arm64 only in the npm bundle) and `lxc-exec` (Linux). If none is found, the constructor raises `MXCExecutorNotFoundError` with these instructions and the list of paths searched.

## Installing the package

Not on PyPI yet. From this directory:

```bash
uv pip install -e .            # or: pip install -e .
```

## Usage

```python
from langchain_mxc import MXCSandbox

backend = MXCSandbox(
    root_dir="./my-project",
    read_only_paths=["~/datasets"],      # extra folders the commands may read
    read_write_paths=[],                 # extra folders the commands may write
    allow_network=False,                 # outbound network, off by default
    allow_ui=False,                      # windows / GUI for commands, off by default
    clipboard="none",                    # "none", "read", "write" or "all"
    allow_input_injection=False,         # synthetic keyboard/mouse input, off by default
    env={"PYTHONUNBUFFERED": "1"},       # layered on the minimal sandbox environment
    timeout=120,                         # seconds per command
    max_output_bytes=100_000,
    executor_path=None,                  # auto-discovered
)

result = backend.execute("python -m pytest -q")
print(result.output, result.exit_code)
```

`MXCSandbox` implements `SandboxBackendProtocol`, so it plugs into `create_deep_agent(backend=...)` directly. `execute` keeps `LocalShellBackend`'s output format: stdout and stderr combined, stderr lines prefixed with `[stderr]`, a trailing `Exit code: N` when non-zero, truncation at `max_output_bytes`, and exit code 124 on timeout.

## Default policy

Every command runs with this MXC policy (contract version 1.0.0, containment `process`):

| Area | Default | Notes |
| --- | --- | --- |
| Working directory | `root_dir` | Resolved to a real path. |
| Read-write | `root_dir`, a per-instance scratch directory, `read_write_paths` | Scratch lives in the system temp dir, outside the workspace, and is deleted when the backend is garbage-collected. |
| Read-only | OS toolchain + `read_only_paths` | macOS: `/bin`, `/sbin`, `/usr`, `/System`, `/Library`, `/private/etc`, `/opt/homebrew`, `/opt/local`. Linux: `/bin`, `/sbin`, `/usr`, `/lib*`, `/etc`, `/opt`, `/snap`, `/nix/store`. Windows: `%SystemRoot%\System32`. Plus, for each of `python`, `python3`, `git`, `node` found on `PATH`: its directory, the install prefix of its symlink target, the agent interpreter's `sys.prefix` and `sys.base_prefix`, and the whole Homebrew / `/usr/local` / linuxbrew / nix root when the tool lives there. Only paths that exist are sent. `~` is expanded. |
| Denied | `~/.ssh`, `~/.aws`, `~/.azure`, `~/.gnupg`, `~/.kube`, `~/.docker`, `~/.config/gcloud`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.pypirc` | Only those that exist. A deny beats a broader read-only grant (for example `read_only_paths=["~"]`). An explicit grant of one of these paths removes it from the deny list. |
| Network | Egress deny, ingress deny, host loopback deny | `allow_network=True` sets egress to allow and leaves inbound denied, the one shape all three backends accept. There is no finer control in v0: MXC has no hostname allow-lists. |
| UI | No GUI, clipboard `none`, no input injection | These are MXC's own default-deny values. `allow_ui=True`, `clipboard="read"|"write"|"all"` and `allow_input_injection=True` loosen them per backend instance, for example for GUI app tests. Enforced on Windows and macOS; Linux bubblewrap ignores the section. On Windows the clipboard and injection settings only take effect together with `allow_ui=True`. On macOS with mxc-sdk 1.0.1, allowing the clipboard adds the pasteboard rule to the Seatbelt profile, but `pbpaste` still returns nothing because other Apple services stay blocked; see `EXECUTOR_CONTRACT.md`. |
| Environment | `PATH` (toolchain dirs first, then system dirs), `HOME`, `TMPDIR`, `TEMP`, `TMP` pointing at the scratch directory, `LANG` | Windows: `SYSTEMROOT`, `SYSTEMDRIVE`, `LOCALAPPDATA` (host value), `TEMP`/`TMP`/`USERPROFILE` at scratch, `PATH`, `PATHEXT`, `COMSPEC`. The host environment is not inherited. `env` entries are merged on top. |
| Shell | `/bin/sh -c <command>` on POSIX, `cmd.exe /d /s /c "<command>"` on Windows | |
| Timeout | 120 s per command | Passed to MXC as `process.timeout`, which kills the whole process tree. The host waits 5 s longer, then kills the executor and every descendant itself. |

`backend.build_request("echo hi")` returns the exact JSON sent to the executor if you want to inspect it.

## Security model

**OS-enforced:** everything a command does through `execute`. Writes outside the allowed paths fail with `Operation not permitted` (macOS), reads of unlisted or denied paths fail the same way, and with the network off DNS and sockets fail. These denials come from the kernel, not from this package.

**Host-checked, not OS-enforced:** the file tools. `FilesystemBackend` runs in your Python process with `virtual_mode=True`, which maps every tool path under `root_dir` and rejects `..` and `~`. This is the same protection `LocalShellBackend` offers for file tools. It is a path check in Python, so a bug in it, or a symlink inside `root_dir` that points elsewhere, is not stopped by the operating system. Keep `root_dir` free of symlinks to sensitive locations.

**Fail closed.** On the first `execute`, the backend probes the host once: it validates the real policy with the executor's `--dry-run`, then runs a canary command that tries to read a file created outside every allowed path. If the executor rejects the policy, cannot start a sandbox, or the canary content comes back, every `execute` call returns an error response and nothing runs. The backend never falls back to running commands unsandboxed. The same applies at runtime: if MXC rejects a request or the backend for this OS is unavailable, the response says so and the command was not run.

**No enforcement-off modes.** MXC has learning, permissive and `--audit` modes that disable enforcement. The package has no code path that emits them, and the unit tests check that no request ever contains them.

**What is not covered.** Commands run as your user, not a separate account. The sandbox cannot stop a command from consuming CPU, memory or disk inside `root_dir`. With `allow_network=True` commands have full outbound network access, including to your LAN. Model prompts and tool results still travel to your model provider as usual.

## What the model sees when something is blocked

MXC itself adds nothing to the output when the OS blocks an access; the command's own error text is all there is. The backend recognises the observed denial patterns (`Operation not permitted`, `Permission denied`, `Access is denied`, Python's `PermissionError`, DNS and socket failures) and, when the path involved is outside the policy, appends one line the model can act on:

```
[stderr] cat: /Users/me/.ssh/config: Operation not permitted

Exit code: 1
Blocked by sandbox policy: /Users/me/.ssh/config. Ask the user to grant access if this is needed.
```

For a network failure with the network off the line names `network`. Ordinary permission errors inside allowed paths (for example a `chmod 000` file in the project) do not get the line.

## Tests

```bash
uv sync --group test
make test                 # unit tests, no MXC needed
make integration_tests    # needs the executor; skipped with a reason otherwise
```

Unit tests cover the policy JSON for Windows, macOS and Linux with the host mocked, executor discovery, the output and denial mapping driven by the cases recorded in [`EXECUTOR_CONTRACT.md`](EXECUTOR_CONTRACT.md), and timeout handling including the host-side kill of a hung process tree.

Integration tests run against the real executor: writes inside and outside `root_dir`, reading `~/.ssh`, network off and on, the 124 timeout, and the shared `SandboxIntegrationTests` suite from `langchain-tests`. Sixteen shared-suite cases are skipped with reasons; all of them are `FilesystemBackend` behaviours that deepagents' own `LocalShellBackend` fails identically (relative-path handling, the 500 KiB binary preview limit, absolute paths from `glob` in non-virtual mode, overwrite on `write`, wording of the `edit` error, trailing slash in `ls`, trailing newline in paged reads). The shared suite is skipped as a whole on Windows because it uses POSIX commands.

## Demo

```bash
uv sync --group test --group examples
export ANTHROPIC_API_KEY=...                       # or OPENAI_API_KEY with MXC_DEMO_MODEL=openai:<model>
uv run python examples/demo_agent.py
```

The demo gives a Deep Agent a tiny repo under `examples/sample_repo/` with one failing test, asks it to fix the test, and also asks it to read `examples/outside_the_repo.txt`, which is outside `root_dir`. The read is blocked by the sandbox and the agent explains why. Without an API key the script still builds the agent and the backend and then exits, so it doubles as a smoke test for the installation.

To run the whole demo with no API key, add `--scripted`. A scripted stand-in replaces the model and issues the same tool calls in a fixed order; the agent loop, the tools and the MXC sandbox all run for real.

To inspect the policy without a model or API key:

```bash
uv run python examples/show_policy.py path/to/project --exercise
```

This prints the resolved read-write, read-only and denied paths plus the exact request sent to the executor, then runs a few allowed and blocked commands (toolchain, write inside, write outside, read `~/.ssh`, network) so you can see what the agent gets back for each. Add `--network` to see the policy with outbound network allowed.

## Status

Verified on macOS 26.7 (Apple Silicon, Seatbelt) and on Linux (Debian 12 in a privileged Docker container, arm64, bubblewrap 0.8) with `@microsoft/mxc-sdk` 1.0.1. Everything observed about the executors is in [`EXECUTOR_CONTRACT.md`](EXECUTOR_CONTRACT.md), including the places where they differ from MXC's documentation.

Not yet verified: Windows (`wxc-exec.exe`, including `deniedPaths` enforcement and the error text for blocked actions), and Linux outside a container or on x64. The Windows policy is unit-tested with a mocked host, but a real run is needed before the preview ships there. bubblewrap cannot start inside a default Docker container; the backend reports that and runs nothing.

The public API (`MXCSandbox` and its constructor) is fixed so the executor-based internals can be swapped for an official MXC Python SDK later without breaking users.

## License

MIT.
