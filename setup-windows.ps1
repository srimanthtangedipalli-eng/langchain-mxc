<#
.SYNOPSIS
    One command to set up a fresh Windows machine and run the langchain-mxc tests.

.DESCRIPTION
    Installs any of Git, Node.js, Python and uv that are missing (with winget),
    downloads or updates the code in C:\mxc\langchain-mxc, and runs the test
    script. Safe to run again: it skips what is already installed and pulls the
    latest code.

    Windows may show an approval prompt for the Git, Node.js and Python
    installers. The script never runs wxc-host-prep.exe.

    Run it from PowerShell with:
        irm https://raw.githubusercontent.com/srimanthtangedipalli-eng/langchain-mxc/main/setup-windows.ps1 | iex
#>

$ErrorActionPreference = "Continue"
$RepoUrl = "https://github.com/srimanthtangedipalli-eng/langchain-mxc"
$ParentDir = "C:\mxc"
$ProjectDir = Join-Path $ParentDir "langchain-mxc"

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

# A fresh Windows has a fake "python" that only opens the Microsoft Store.
function Test-RealTool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    if ($cmd.Source -like "*\WindowsApps\*") { return $false }
    return $true
}

function Install-Tool {
    param([string]$Name, [string]$WingetId, [string]$Override = "")
    if (Test-RealTool $Name) {
        Write-Host "OK       $Name is already installed"
        return
    }
    Write-Host "INSTALL  $Name ($WingetId)"
    $wingetArgs = @("install", "--exact", "--id", $WingetId, "--silent",
        "--accept-package-agreements", "--accept-source-agreements")
    if ($Override) { $wingetArgs += @("--override", $Override) }
    & winget @wingetArgs
    Update-SessionPath
    if (Test-RealTool $Name) {
        Write-Host "OK       $Name installed"
    } else {
        Write-Host "PROBLEM  $Name is still not on PATH after installing."
        $script:Problems += $Name
    }
}

Write-Host ""
Write-Host "langchain-mxc Windows setup"
Write-Host ""

$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
Write-Host "Windows build $($cv.CurrentBuild).$($cv.UBR), $env:PROCESSOR_ARCHITECTURE (MXC needs 26100.9278 or newer)"
Write-Host ""

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget is not available. Open the Microsoft Store, update 'App Installer', then run this command again."
    return
}

$script:Problems = @()
Update-SessionPath
Install-Tool -Name "git" -WingetId "Git.Git"
Install-Tool -Name "node" -WingetId "OpenJS.NodeJS.LTS"
Install-Tool -Name "python" -WingetId "Python.Python.3.13" -Override "/quiet InstallAllUsers=0 PrependPath=1 Include_test=0"
Install-Tool -Name "uv" -WingetId "astral-sh.uv"

if ($script:Problems.Count -gt 0) {
    Write-Host ""
    Write-Host "Could not finish installing: $($script:Problems -join ', ')."
    Write-Host "Close this window, open a new PowerShell, and run the same command again."
    return
}

Write-Host ""
if (Test-Path (Join-Path $ProjectDir ".git")) {
    Write-Host "Updating the code in $ProjectDir"
    & git -C $ProjectDir pull --ff-only
} else {
    Write-Host "Downloading the code to $ProjectDir"
    New-Item -ItemType Directory -Force -Path $ParentDir | Out-Null
    & git clone $RepoUrl $ProjectDir
}
if (-not (Test-Path (Join-Path $ProjectDir "scripts\windows\run-windows-tests.ps1"))) {
    Write-Host "The code did not download. Check the network connection and run this command again."
    return
}

Write-Host ""
Write-Host "Running the tests"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectDir "scripts\windows\run-windows-tests.ps1")
