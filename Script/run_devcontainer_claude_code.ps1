<#
.SYNOPSIS
    Automates the setup and connection to a DevContainer environment using either Docker or Podman on Windows.

.DESCRIPTION
    This script automates the process of initializing, starting, and connecting to a DevContainer
    using either Docker or Podman as the container backend. It must be executed from the root
    directory of your project and assumes the script is located in a 'Script' subdirectory.

.PARAMETER Backend
    Specifies the container backend to use. Valid values are 'docker' or 'podman'.

.EXAMPLE
    .\Script\run_devcontainer_claude_code.ps1 -Backend docker
    Uses Docker as the container backend.

.EXAMPLE
    .\Script\run_devcontainer_claude_code.ps1 -Backend podman
    Uses Podman as the container backend.

.NOTES
    Project Structure:
    Project/
    ├── .devcontainer/
    └── Script/
        └── run_devcontainer_claude_code.ps1

    External programs (docker, podman, devcontainer) do not throw on failure in PowerShell;
    they only set $LASTEXITCODE. Every call below therefore checks $LASTEXITCODE explicitly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('docker','podman')]
    [string]$Backend
)

# Notify script start
Write-Host "--- DevContainer Startup & Connection Script ---"
Write-Host "Using backend: $($Backend)"

# --- Prerequisite Check ---
Write-Host "Checking for required commands..."
try {
    if (-not (Get-Command $Backend -ErrorAction SilentlyContinue)) {
        throw "Required command '$($Backend)' not found."
    }
    Write-Host "- $($Backend) command found."
    if (-not (Get-Command devcontainer -ErrorAction SilentlyContinue)) {
        throw "Required command 'devcontainer' not found."
    }
    Write-Host "- devcontainer command found."
}
catch {
    Write-Error "A required command is not installed or not in your PATH. $($_.Exception.Message)"
    Write-Error "Please ensure both '$Backend' and 'devcontainer' are installed and accessible in your system's PATH."
    exit 1
}

# --- Project Folder Check ---
# 'devcontainer up --workspace-folder .' uses the current folder, so it must be the project root.
if (-not (Test-Path -LiteralPath (Join-Path (Get-Location).Path '.devcontainer'))) {
    Write-Error "No '.devcontainer' folder in the current directory ('$((Get-Location).Path)')."
    Write-Error "Run this script from the project root, e.g. .\Script\run_devcontainer_claude_code.ps1 -Backend $Backend"
    exit 1
}


# --- Backend-Specific Initialization ---
if ($Backend -eq 'podman') {
    Write-Host "--- Podman Backend Initialization ---"

    # --- Step 1a: Initialize Podman machine ---
    # 'podman machine init' exits non-zero when the machine already exists, which is fine.
    Write-Host "Initializing Podman machine 'claudeVM'..."
    & podman machine init claudeVM
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "'podman machine init' exited with code $LASTEXITCODE (the machine may already exist). Continuing."
    } else {
        Write-Host "Podman machine 'claudeVM' initialized."
    }

    # --- Step 1b: Start Podman machine ---
    # 'podman machine start' exits non-zero when the machine is already running, which is fine.
    # The connectivity check after the default connection is set catches real failures.
    Write-Host "Starting Podman machine 'claudeVM'..."
    & podman machine start claudeVM -q
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "'podman machine start' exited with code $LASTEXITCODE (the machine may already be running). Continuing."
    } else {
        Write-Host "Podman machine started."
    }

    # --- Step 2: Set default connection ---
    Write-Host "Setting default Podman connection to 'claudeVM'..."
    & podman system connection default claudeVM
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to set default Podman connection (exit code $LASTEXITCODE; may be already set or machine issue)."
    } else {
        Write-Host "Default connection set."
    }

    # --- Step 2b: Verify Podman is reachable ---
    & podman info | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Podman is not reachable (exit code $LASTEXITCODE). Check that the machine 'claudeVM' is running ('podman machine list')."
        exit 1
    }
    Write-Host "Podman is reachable."

} elseif ($Backend -eq 'docker') {
    Write-Host "--- Docker Backend Initialization ---"

    # --- Step 1 & 2: Check Docker Desktop ---
    Write-Host "Checking if Docker Desktop is running and docker command is available..."
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker Desktop is not running or the Docker daemon is not reachable (exit code $LASTEXITCODE)."
        Write-Error "Please ensure Docker Desktop is running."
        exit 1
    }
    Write-Host "Docker Desktop (daemon) is running."
}

# --- Step 3: Bring up DevContainer ---
Write-Host "Bringing up DevContainer in the current folder..."
$arguments = @('up', '--workspace-folder', '.')
if ($Backend -eq 'podman') {
    $arguments += '--docker-path', 'podman'
}
& devcontainer @arguments
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to bring up DevContainer ('devcontainer $($arguments -join ' ')' exited with code $LASTEXITCODE)."
    exit 1
}
Write-Host "DevContainer startup process completed."

# --- Step 4: Get DevContainer ID ---
Write-Host "Finding the DevContainer ID..."
$currentFolder = (Get-Location).Path
$displayCommand = "$Backend ps --filter `"label=devcontainer.local_folder=$currentFolder`" --format '{{.ID}}'"

$psOutput = & $Backend ps --filter "label=devcontainer.local_folder=$currentFolder" --format '{{.ID}}'
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get container ID (Command: $displayCommand) - exit code $LASTEXITCODE."
    exit 1
}

# 'ps' can return nothing, one ID, or several (e.g. leftover containers after a rebuild).
$containerIds = @($psOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

if ($containerIds.Count -eq 0) {
    Write-Error "Could not find DevContainer ID for the current folder ('$currentFolder')."
    Write-Error "Please check if 'devcontainer up' was successful and the container is running."
    exit 1
}
if ($containerIds.Count -gt 1) {
    Write-Warning "Found $($containerIds.Count) running containers for this folder ($($containerIds -join ', ')). Using the first one."
}
$containerId = $containerIds[0]
Write-Host "Found container ID: $containerId"

# --- Step 5 & 6: Execute command and enter interactive shell inside container ---
# The exit code of this interactive session is the last command of the user's shell, not an error
# of the script itself, so it is not treated as a failure.
Write-Host "Executing 'claude' command and then starting zsh session inside container $($containerId)..."
& $Backend exec -it $containerId zsh -c 'claude; exec zsh'
Write-Host "Interactive session ended."

# Notify script completion
Write-Host "--- Script completed ---"
