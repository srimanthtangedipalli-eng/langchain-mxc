<#
.SYNOPSIS
    Runs the whole langchain-mxc check on a Windows machine and saves one log.

.DESCRIPTION
    Installs the MXC executor and the Python dependencies inside this project
    folder, then runs the unit tests, the integration tests, the policy
    walkthrough and the demo agent. Everything is written to
    windows-test-logs\<timestamp>\ and zipped at the end.

    The script never asks for admin rights and never runs wxc-host-prep.exe.
    It works on Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER MxcVersion
    Version of @microsoft/mxc-sdk to install. 1.0.1 is the version the package
    was built and tested against.

.PARAMETER SkipDemo
    Skip the demo agent (the only step that calls a model).
#>
param(
    [string]$MxcVersion = "1.0.1",
    [switch]$SkipDemo
)

$ErrorActionPreference = "Continue"

$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir = Join-Path $ProjectDir "windows-test-logs\$Stamp"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$SummaryLog = Join-Path $LogDir "00-summary.log"
$Results = New-Object System.Collections.ArrayList

Set-Location $ProjectDir

function Write-Log {
    param([string]$Text, [string]$File = $SummaryLog)
    Write-Host $Text
    Add-Content -Path $File -Value $Text -Encoding UTF8
}

function Test-Tool {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Runs one command line through cmd.exe so stderr is captured as plain text
# (Windows PowerShell 5.1 turns native stderr into error records otherwise).
function Invoke-Step {
    param(
        [string]$Name,
        [string]$Command,
        [string]$LogName,
        [switch]$Informational
    )
    $file = Join-Path $LogDir $LogName
    Write-Log ""
    Write-Log "==== $Name"
    Write-Log "> $Command"
    Add-Content -Path $file -Value "> $Command" -Encoding UTF8
    $started = Get-Date
    # The command goes into a small batch file so paths with spaces and quotes
    # reach cmd.exe exactly as written.
    $batch = Join-Path $LogDir "_step.cmd"
    # `call :main 2>&1` sends stderr of every command on the line to the log.
    Set-Content -Path $batch -Encoding Oem -Value @(
        "@echo off",
        "call :main 2>&1",
        "exit /b %ERRORLEVEL%",
        ":main",
        $Command,
        "exit /b %ERRORLEVEL%"
    )
    & cmd.exe /d /c $batch | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        Add-Content -Path $file -Value $line -Encoding UTF8
    }
    $code = $LASTEXITCODE
    Remove-Item -Path $batch -ErrorAction SilentlyContinue
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    if ($Informational) {
        $status = "info"
    } elseif ($code -eq 0) {
        $status = "PASS"
    } else {
        $status = "FAIL"
    }
    Write-Log "---- $Name finished: $status (exit code $code, $seconds s). Log: $LogName"
    [void]$Results.Add([pscustomobject]@{ Step = $Name; Status = $status; ExitCode = $code; Seconds = $seconds; Log = $LogName })
    return $code
}

function Write-Summary {
    Write-Log ""
    Write-Log "==== Summary"
    foreach ($r in $Results) {
        Write-Log ("{0,-6} {1,-44} exit {2,-4} {3,5} s   {4}" -f $r.Status, $r.Step, $r.ExitCode, $r.Seconds, $r.Log)
    }
    $zip = Join-Path $ProjectDir "windows-test-logs\langchain-mxc-windows-$Stamp.zip"
    try {
        Compress-Archive -Path (Join-Path $LogDir "*") -DestinationPath $zip -Force
        Write-Log ""
        Write-Log "Send this file back: $zip"
    } catch {
        Write-Log ""
        Write-Log "Could not create the zip ($($_.Exception.Message)). Send the folder instead: $LogDir"
    }
}

# ---------------------------------------------------------------------------
# 1. Machine facts
# ---------------------------------------------------------------------------
Write-Log "langchain-mxc Windows test run, $Stamp"
Write-Log "Project folder: $ProjectDir"

$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$build = [int]$cv.CurrentBuild
$ubr = [int]$cv.UBR
$arch = $env:PROCESSOR_ARCHITECTURE
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Log "Windows: $($cv.ProductName) $($cv.DisplayVersion), build $build.$ubr"
Write-Log "Processor architecture: $arch"
Write-Log "Running elevated (admin): $isAdmin"
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"

$buildOk = ($build -gt 26100) -or (($build -eq 26100) -and ($ubr -ge 9278))
if ($buildOk) {
    Write-Log "Windows build check: OK (needs 26100.9278 or newer)"
} else {
    Write-Log "WARNING: Windows build $build.$ubr is older than 26100.9278. MXC process containers may not work. Run Windows Update, then re-run this script. Continuing anyway so the log shows what happens."
}

# ---------------------------------------------------------------------------
# 2. Required tools
# ---------------------------------------------------------------------------
$missing = @()
foreach ($tool in @("node", "npm", "python", "uv", "git")) {
    if (Test-Tool $tool) {
        $where = (Get-Command $tool).Source
        Write-Log "Found $tool at $where"
    } else {
        Write-Log "MISSING: $tool"
        $missing += $tool
    }
}
if ($missing.Count -gt 0) {
    Write-Log ""
    Write-Log "Stopping: install the missing tools listed above (see WINDOWS_SETUP.md), open a new terminal, and run this script again."
    Write-Summary
    exit 2
}

[void](Invoke-Step -Name "Tool versions" -LogName "01-tool-versions.log" -Informational `
    -Command "node --version & call npm --version & python --version & uv --version & git --version")

# ---------------------------------------------------------------------------
# 3. MXC executor
# ---------------------------------------------------------------------------
$code = Invoke-Step -Name "Install MXC executor (npm)" -LogName "02-npm-install.log" `
    -Command "call npm install --no-fund --no-audit @microsoft/mxc-sdk@$MxcVersion"

$binArch = "x64"
if ($arch -eq "ARM64") { $binArch = "arm64" }
$Executor = Join-Path $ProjectDir "node_modules\@microsoft\mxc-sdk\bin\$binArch\wxc-exec.exe"
if (-not (Test-Path $Executor)) {
    Write-Log ""
    Write-Log "Stopping: wxc-exec.exe was not found at $Executor. The npm install log above says why."
    Write-Summary
    exit 3
}
$env:MXC_EXECUTOR_PATH = $Executor
Write-Log "Executor: $Executor"

[void](Invoke-Step -Name "Executor help text" -LogName "03-executor-help.log" -Informational `
    -Command "`"$Executor`" --help")

# ---------------------------------------------------------------------------
# 4. Python environment
# ---------------------------------------------------------------------------
$code = Invoke-Step -Name "Install Python dependencies (uv sync)" -LogName "04-uv-sync.log" `
    -Command "uv sync --group test --group examples"
if ($code -ne 0) {
    Write-Log ""
    Write-Log "Stopping: uv sync failed, so nothing else can run."
    Write-Summary
    exit 4
}

# ---------------------------------------------------------------------------
# 5. Raw executor checks (no Python package logic in the way)
# ---------------------------------------------------------------------------
$RequestFile = Join-Path $LogDir "request.json"
$DumpScript = Join-Path $PSScriptRoot "dump_request.py"
$SampleRepo = Join-Path $ProjectDir "examples\sample_repo"

$code = Invoke-Step -Name "Write the sample MXC request" -LogName "05-request.log" `
    -Command "uv run --group test python `"$DumpScript`" `"$SampleRepo`" `"$RequestFile`""

if ($code -eq 0) {
    [void](Invoke-Step -Name "Executor: validate request (--dry-run)" -LogName "06-executor-dry-run.log" `
        -Command "`"$Executor`" --config `"$RequestFile`" --dry-run")
    [void](Invoke-Step -Name "Executor: host probe (--probe)" -LogName "07-executor-probe.log" -Informational `
        -Command "`"$Executor`" --config `"$RequestFile`" --probe")
    [void](Invoke-Step -Name "Executor: run one sandboxed command" -LogName "08-executor-run.log" `
        -Command "`"$Executor`" --config `"$RequestFile`" --debug")
}

# ---------------------------------------------------------------------------
# 6. Tests
# ---------------------------------------------------------------------------
[void](Invoke-Step -Name "Unit tests" -LogName "09-unit-tests.log" `
    -Command "uv run --group test pytest -vv -rs --disable-socket --allow-unix-socket tests/unit_tests tests/test_import.py")

[void](Invoke-Step -Name "Integration tests (real executor)" -LogName "10-integration-tests.log" `
    -Command "uv run --group test pytest -vv -rs --timeout 120 tests/integration_tests")

# ---------------------------------------------------------------------------
# 7. Policy walkthrough and demo agent
# ---------------------------------------------------------------------------
[void](Invoke-Step -Name "Policy walkthrough (show_policy --exercise)" -LogName "11-show-policy.log" `
    -Command "uv run --group test python examples\show_policy.py `"$SampleRepo`" --exercise")

if ($SkipDemo) {
    Write-Log ""
    Write-Log "Demo agent skipped (-SkipDemo)."
} else {
    $demoArgs = ""
    if (-not $env:ANTHROPIC_API_KEY -and -not $env:OPENAI_API_KEY) {
        Write-Log ""
        Write-Log "No ANTHROPIC_API_KEY or OPENAI_API_KEY is set, so the demo runs in scripted mode: fixed tool calls, no model, real sandbox."
        $demoArgs = " --scripted"
    }
    [void](Invoke-Step -Name "Demo agent" -LogName "12-demo-agent.log" `
        -Command "uv run --group test --group examples python examples\demo_agent.py$demoArgs")
}

Write-Summary
$failed = @($Results | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failed -gt 0) { exit 1 }
exit 0
