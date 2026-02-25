# =============================================================================
# Install-GitHubRunner.ps1  (CENTRAL SCRIPT — lives in SDPLaos2023/github-workflows)
#
# PURPOSE
#   Reusable script for installing a GitHub Actions self-hosted runner on any
#   Windows / IIS server in the SDPLaos2023 organisation.
#
# USAGE
#   Run this one-liner in an elevated PowerShell on the target server.
#   Script will prompt for all values interactively — no file to copy or edit:
#
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
#
# PROMPTS (3 sections)
#   [1/3] Project Configuration  — RepoUrl, AppPool, DeployPath  (same across servers)
#   [2/3] Server Configuration   — Windows service account + password  (per-server)
#   [3/3] GitHub Credentials     — PAT Token  (hidden input)
#
# UPDATING THE RUNNER VERSION
#   1. Find the new version + SHA-256 hash at:
#      https://github.com/actions/runner/releases
#   2. Update $RunnerVersion and $RunnerHash defaults below.
#   3. All servers pick up the change automatically on their next install.
# =============================================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # -------------------------------------------------------------------------
    # REQUIRED
    # -------------------------------------------------------------------------

    # Full HTTPS URL to the target GitHub repository
    # e.g. "https://github.com/SDPLaos2023/MyProject"
    # Leave empty to be prompted interactively at runtime
    [string] $RepoUrl = "",

    # Name shown in GitHub Settings → Actions → Runners
    # Default: COMPUTERNAME of this server (e.g. SERVER01)
    # Override if you need a custom name or run multiple runners on the same machine
    [string] $RunnerName   = "",

    # Comma-separated label(s) — must match runner_label in deploy.yml
    # Default: same as RunnerName (resolved to COMPUTERNAME)
    # Override only if you need a label different from the runner name
    [string] $RunnerLabels = "",

    # Domain service account used to run the Windows service  e.g. "sdplao\github-runner"
    # Leave empty to be prompted interactively at runtime
    [string] $ServiceAccount = "",

    # IIS Application Pool this runner will manage during deployments
    # Leave empty to be prompted interactively at runtime
    [string] $AppPool = "",

    # Full path on this server where IIS serves the application
    # Leave empty to be prompted interactively at runtime
    [string] $DeployPath = "",

    # -------------------------------------------------------------------------
    # OPTIONAL — defaults match the latest tested runner version
    # Override only when you need a specific version
    # -------------------------------------------------------------------------

    # GitHub Actions runner version to install
    [string] $RunnerVersion = "2.331.0",

    # SHA-256 hash of the runner zip (verify at https://github.com/actions/runner/releases)
    [string] $RunnerHash    = "473e74b86cd826e073f1c1f2c004d3fb9e6c9665d0d51710a23e5084a601c78a",

    # Directory on this server where the runner files will be extracted
    [string] $RunnerRoot    = "",   # defaults to C:\actions-runner\<repo-name> if left empty

    # Directory on this server where deploy backups are stored
    [string] $BackupPath    = "C:\BackupIIS"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Force TLS 1.2 — required by GitHub API and download servers.
# Windows PowerShell 5.1 defaults to TLS 1.0 which GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Interactive prompts — ask for any value not supplied via parameter
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== [1/3] Project Configuration (same for every server of this project)" -ForegroundColor Cyan

if ([string]::IsNullOrEmpty($RepoUrl)) {
    $RepoUrl = Read-Host "  GitHub Repo URL (e.g. https://github.com/SDPLaos2023/MyProject)"
} else {
    Write-Host "  Repo URL   : $RepoUrl" -ForegroundColor DarkGray
}
if ([string]::IsNullOrEmpty($AppPool)) {
    $AppPool = Read-Host "  IIS App Pool name"
} else {
    Write-Host "  AppPool    : $AppPool" -ForegroundColor DarkGray
}
if ([string]::IsNullOrEmpty($DeployPath)) {
    $DeployPath = Read-Host "  Deploy path (e.g. C:\inetpub\wwwroot\MyProject)"
} else {
    Write-Host "  DeployPath : $DeployPath" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== [2/3] Server Configuration (specific to THIS machine: $env:COMPUTERNAME)" -ForegroundColor Cyan
Write-Host "  This is the Windows account that will RUN the runner service on this server." -ForegroundColor DarkGray
Write-Host "  It must have 'Log on as a service' rights and permission to manage IIS App Pools." -ForegroundColor DarkGray
Write-Host ""

if ([string]::IsNullOrEmpty($ServiceAccount)) {
    $ServiceAccount = Read-Host "  Windows service account (e.g. sdplao\github-runner)"
} else {
    Write-Host "  ServiceAccount: $ServiceAccount" -ForegroundColor DarkGray
}
$ServicePwdSecure = Read-Host "  Password for '$ServiceAccount' (hidden)" -AsSecureString
$ServicePassword  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePwdSecure))

# ---------------------------------------------------------------------------
# Derive defaults that depend on other parameters
# ---------------------------------------------------------------------------
$repoName = $RepoUrl.Split('/')[-1]   # e.g. "PPB_WEB_LeaveOnline"

if ([string]::IsNullOrEmpty($RunnerName))   { $RunnerName   = $env:COMPUTERNAME }
if ([string]::IsNullOrEmpty($RunnerLabels)) { $RunnerLabels = $RunnerName }

if ([string]::IsNullOrEmpty($RunnerRoot)) {
    $RunnerRoot = "C:\actions-runner\$repoName"
}

$RunnerZip         = "actions-runner-win-x64-$RunnerVersion.zip"
$RunnerDownloadUrl = "https://github.com/actions/runner/releases/download/v$RunnerVersion/$RunnerZip"

Write-Host ""
Write-Host "=== [3/3] GitHub Credentials (hidden)" -ForegroundColor Cyan
$PatTokenSecure      = Read-Host "  GitHub PAT Token (repo + workflow scope)" -AsSecureString
$PatToken            = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                           [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PatTokenSecure))

# ---------------------------------------------------------------------------
# Auto-fetch Registration Token via PAT (avoids 1-hour manual expiry)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Fetching fresh runner registration token via PAT..." -ForegroundColor Cyan
$repoOwner    = $RepoUrl.Split('/')[-2]
$apiUrl       = "https://api.github.com/repos/$repoOwner/$repoName/actions/runners/registration-token"
$apiHeaders   = @{
    Authorization = "token $PatToken"
    Accept        = "application/vnd.github.v3+json"
    "User-Agent"  = "PowerShell-RunnerInstaller"
}

# Verify PAT identity first — confirms the token is valid and shows who it belongs to
try {
    $whoami = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $apiHeaders -Method GET
    Write-Host "[OK] PAT belongs to GitHub user: $($whoami.login)" -ForegroundColor Green
} catch {
    throw "PAT Token is invalid or expired. Please generate a new token at:`n  https://github.com/settings/tokens`nRequired scopes: repo, workflow"
}

# Fetch registration token — requires repo Admin permission
try {
    $tokenResponse     = Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $apiHeaders
    $RegistrationToken = $tokenResponse.token
    Write-Host "[OK] Registration token obtained (expires: $($tokenResponse.expires_at))." -ForegroundColor Green
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-Host ""
    Write-Host "  ERROR: Could not get registration token (HTTP $statusCode)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Common causes:" -ForegroundColor Yellow
    Write-Host "    1) PAT owner is not an Admin of repo '$repoOwner/$repoName'" -ForegroundColor Yellow
    Write-Host "       -> Go to: https://github.com/$repoOwner/$repoName/settings/access" -ForegroundColor Yellow
    Write-Host "    2) Classic PAT is missing 'repo' scope" -ForegroundColor Yellow
    Write-Host "       -> Go to: https://github.com/settings/tokens" -ForegroundColor Yellow
    Write-Host "    3) Fine-grained PAT is missing 'Administration: Read & Write' permission" -ForegroundColor Yellow
    Write-Host "       -> Go to: https://github.com/settings/personal-access-tokens" -ForegroundColor Yellow
    Write-Host "    4) Repo '$repoOwner/$repoName' does not exist or is misspelled" -ForegroundColor Yellow
    throw "Failed to obtain runner registration token."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$msg)    { Write-Host ""; Write-Host ">>> $msg" -ForegroundColor Cyan }
function Write-Success([string]$msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)    { Write-Host "[!!] $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Step 1 : Verify Administrator
# ---------------------------------------------------------------------------
Write-Step "Checking Administrator privileges..."
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Script must be run as Administrator. Right-click PowerShell > Run as administrator."
}
Write-Success "Running as Administrator."

# ---------------------------------------------------------------------------
# Step 2 : Verify domain user exists & grant folder permissions
# ---------------------------------------------------------------------------
Write-Step "Verifying domain account '$ServiceAccount'..."
$localUser = $ServiceAccount.Split('\')[-1]

try {
    $adUser = ([adsisearcher]"(samaccountname=$localUser)").FindOne()
    if ($null -ne $adUser) {
        Write-Success "Domain account '$ServiceAccount' found in AD."
    } else {
        Write-Warn "Domain account '$ServiceAccount' not found in AD -- make sure it exists before running config."
    }
} catch {
    Write-Warn "Could not query AD: $_ -- continuing anyway."
}

try {
    $alreadyMember = & net localgroup Administrators 2>&1 | Select-String -Pattern $localUser -Quiet
    if (-not $alreadyMember) {
        Write-Host ""
        Write-Host "  [PRD SAFETY] About to add '$ServiceAccount' to local Administrators group." -ForegroundColor Yellow
        Write-Host "  This is a system-wide change that affects all services on this machine." -ForegroundColor Yellow
        Write-Host "  Required so the runner service can manage IIS App Pools." -ForegroundColor Yellow
        $confirmAdmin = Read-Host "  Proceed? [y/N]"
        if ($confirmAdmin -notmatch '^[Yy]$') {
            throw "Aborted by user -- '$ServiceAccount' was NOT added to Administrators."
        }
        & net localgroup Administrators $ServiceAccount /add 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Added '$ServiceAccount' to Administrators group."
        } else {
            Write-Warn "Could not add '$ServiceAccount' to Administrators (may be a DC -- continuing anyway)."
        }
    } else {
        Write-Warn "'$ServiceAccount' is already in Administrators group -- skipped."
    }
} catch {
    Write-Warn "Skipping group membership check: $_"
}

# ---------------------------------------------------------------------------
# Step 3 : Create required directories
# ---------------------------------------------------------------------------
Write-Step "Creating required directories..."
foreach ($dir in @($RunnerRoot, $BackupPath)) {
    if (Test-Path $dir) {
        Write-Warn "$dir already exists -- skipped."
    } else {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Write-Success "Created $dir"
    }
}

foreach ($dir in @($RunnerRoot, $DeployPath, $BackupPath)) {
    if (Test-Path $dir) {
        $acl  = Get-Acl $dir
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $ServiceAccount, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -Path $dir -AclObject $acl
        Write-Success "Granted FullControl to '$ServiceAccount' on $dir"
    }
}

# ---------------------------------------------------------------------------
# Step 4 : Download runner
# ---------------------------------------------------------------------------
$ZipPath = Join-Path $RunnerRoot $RunnerZip
if (Test-Path $ZipPath) {
    Write-Warn "Runner zip already downloaded -- skipping."
} else {
    Write-Step "Downloading runner v$RunnerVersion..."
    Invoke-WebRequest -Uri $RunnerDownloadUrl -OutFile $ZipPath -UseBasicParsing
    if (-not (Test-Path $ZipPath)) { throw "Download failed -- file not found after request." }
    Write-Success "Downloaded: $ZipPath"
}

# ---------------------------------------------------------------------------
# Step 5 : Validate SHA-256 hash
# ---------------------------------------------------------------------------
Write-Step "Validating SHA-256 hash..."
$actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToUpper()
if ($actualHash -ne $RunnerHash.ToUpper()) {
    Remove-Item $ZipPath -Force
    throw "Hash mismatch!`n  Expected : $RunnerHash`n  Got      : $actualHash`n  (Zip deleted, please retry.)"
}
Write-Success "Hash validated."

# ---------------------------------------------------------------------------
# Step 6 : Extract
# ---------------------------------------------------------------------------
Write-Step "Extracting runner archive..."
$configCmd = Join-Path $RunnerRoot "config.cmd"
$svcCmd    = Join-Path $RunnerRoot "svc.cmd"
if ((Test-Path $configCmd) -and (Test-Path $svcCmd)) {
    Write-Warn "Runner already extracted -- skipping."
} else {
    if (Test-Path $configCmd) {
        Write-Warn "config.cmd found but svc.cmd is missing -- re-extracting to restore runner files."
        Get-ChildItem $RunnerRoot -Exclude ".runner",".credentials",".credentials_rsaparams","_work","_diag",$RunnerZip |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $RunnerRoot)
    Write-Success "Extracted to $RunnerRoot"
}

# ---------------------------------------------------------------------------
# Step 7 : Configure runner
# ---------------------------------------------------------------------------
Write-Step "Configuring runner '$RunnerName' with label '$RunnerLabels'..."
Write-Host "  - URL  : $RepoUrl"
Write-Host "  - Name : $RunnerName"
Write-Host "  - User : $ServiceAccount"

$runnerConfigFile = Join-Path $RunnerRoot ".runner"
if (Test-Path $runnerConfigFile) {
    # Read existing runner info to show the user what was found
    try {
        $existingConfig = Get-Content $runnerConfigFile -Raw | ConvertFrom-Json
        $existingName   = $existingConfig.agentName
        $existingUrl    = $existingConfig.gitHubUrl
    } catch {
        $existingName = "(unknown)"
        $existingUrl  = "(unknown)"
    }

    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Yellow
    Write-Host "  │  Existing runner found in $RunnerRoot" -ForegroundColor Yellow
    Write-Host "  │  Name : $existingName" -ForegroundColor Yellow
    Write-Host "  │  URL  : $existingUrl" -ForegroundColor Yellow
    Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Remove this runner and reinstall? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host ""
        Write-Host "[Cancelled] Installation aborted -- existing runner was not changed." -ForegroundColor Cyan
        exit 0
    }

    Write-Warn "Removing existing runner config..."
    Set-Location $RunnerRoot
    & $configCmd remove --unattended --token $RegistrationToken
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "config.cmd remove exited with $LASTEXITCODE -- attempting to continue anyway."
    } else {
        Write-Success "Existing runner config removed."
    }
}

# ---------------------------------------------------------------------------
# Pre-flight: verify no name collision with runners from OTHER repos on GitHub
# ---------------------------------------------------------------------------
Write-Step "Checking for runner name conflicts on GitHub..."
try {
    $listUrl     = "https://api.github.com/repos/$repoOwner/$repoName/actions/runners"
    $listResp    = Invoke-RestMethod -Uri $listUrl -Method GET -Headers $apiHeaders
    $ghRunners   = $listResp.runners | Where-Object { $_.name -eq $RunnerName }
    if ($ghRunners) {
        Write-Warn "Runner named '$RunnerName' is already registered for this repo on GitHub."
        Write-Warn "It will be replaced during configuration (this is expected for reinstall)."
    } else {
        Write-Success "No name conflict found -- '$RunnerName' is available."
    }
} catch {
    Write-Warn "Could not check existing runners via API: $_ -- continuing anyway."
}

$configArgs = @(
    "--url",                  $RepoUrl,
    "--token",                $RegistrationToken,
    "--name",                 $RunnerName,
    "--labels",               $RunnerLabels,
    "--runasservice",
    "--windowslogonaccount",  $ServiceAccount,
    "--windowslogonpassword", $ServicePassword,
    "--unattended"
    # NOTE: --replace intentionally omitted.
    # If config.cmd finds a duplicate name and requires --replace,
    # it will fail here with a clear error rather than silently
    # deregistering another runner.
)

Set-Location $RunnerRoot
& $configCmd @configArgs

if ($LASTEXITCODE -ne 0) {
    throw "config.cmd failed (exit code: $LASTEXITCODE). Check the output above for details."
}
Write-Success "Runner configured and service installed successfully."

# ---------------------------------------------------------------------------
# Step 8 : Start service — target ONLY this runner's service
# ---------------------------------------------------------------------------
Write-Step "Starting GitHub Actions runner service..."

$expectedSvcPattern = "actions.runner.$repoOwner-$repoName.$RunnerName"
$svc = Get-Service -Name $expectedSvcPattern -ErrorAction SilentlyContinue

if ($null -eq $svc) {
    $allRunners = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue
    Write-Warn "Could not find service '$expectedSvcPattern'."
    if ($allRunners) {
        Write-Warn "Found these runner services on this machine (NOT starting any of them):"
        $allRunners | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Yellow }
    }
    throw "Runner service '$expectedSvcPattern' not found. Configuration may have failed."
}

Write-Host "  Service: $($svc.Name)"
Write-Host "  Status : $($svc.Status)"
if ($svc.Status -eq "Running") {
    Write-Success "Service '$($svc.Name)' is already running (started by config.cmd)."
} else {
    Start-Service -Name $svc.Name
    Start-Sleep -Seconds 3
    $svc.Refresh()
    Write-Success "Service '$($svc.Name)' started -- status: $($svc.Status)"
}
Write-Success "Only this runner's service was touched -- all other services on this machine are untouched."

# ---------------------------------------------------------------------------
# Step 9 : Verify IIS App Pool
# ---------------------------------------------------------------------------
Write-Step "Verifying IIS App Pool '$AppPool'..."
Import-Module WebAdministration -ErrorAction SilentlyContinue
$pool = Get-Item "IIS:\AppPools\$AppPool" -ErrorAction SilentlyContinue
if ($null -ne $pool) {
    Write-Success "App Pool '$AppPool' found -- state: $($pool.state)"
} else {
    Write-Warn "App Pool '$AppPool' not found -- please create it in IIS Manager before first deploy."
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " GitHub Actions Runner installed successfully!" -ForegroundColor Green
Write-Host " Runner '$RunnerName' should now appear as [Idle] in GitHub:" -ForegroundColor Green
Write-Host " $RepoUrl/settings/actions/runners" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host " NOTE: Workflow will Stop/Start App Pool '$AppPool' only." -ForegroundColor Yellow
Write-Host "       No iisreset or restart of other sites." -ForegroundColor Yellow
Write-Host ""
