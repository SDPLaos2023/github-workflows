# =============================================================================
# Auto Install GitHub Actions Self-Hosted Runner
# Repository : PPB_WEB_LeaveOnline
# Runner Name: Dev  |  Label: Dev
# App Pool   : PPB_Leave
# Deploy Path: C:\inetpub\wwwroot\Hrms_leave_PPB
#
# NOTE: Registration Token expires within 1 hour after creation.
#       If token expired, generate a new one at:
#       GitHub -> Settings -> Actions -> Runners -> New self-hosted runner
#       OR run: .\get-runner-token.ps1 (uses PAT to auto-generate)
# =============================================================================

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Force TLS 1.2 -- required by GitHub API and download servers.
# Windows PowerShell 5.1 defaults to TLS 1.0 which GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$RunnerVersion     = "2.331.0"
$RunnerHash        = "473e74b86cd826e073f1c1f2c004d3fb9e6c9665d0d51710a23e5084a601c78a"
$RunnerZip         = "actions-runner-win-x64-$RunnerVersion.zip"
$RunnerDownloadUrl = "https://github.com/actions/runner/releases/download/v$RunnerVersion/$RunnerZip"
$RunnerRoot        = "C:\actions-runner\ppb-leave"

$RepoUrl           = "https://github.com/SDPLaos2023/PPB_WEB_LeaveOnline"
$RunnerName        = "Dev"
$RunnerLabels      = "Dev"

$ServiceAccount    = "sdplao\github-runner"   # domain user -- must already exist in Active Directory

$AppPool           = "PPB_Leave"
$DeployPath        = "C:\inetpub\wwwroot\Hrms_leave_PPB"
$BackupPath        = "C:\BackupIIS"

# ---------------------------------------------------------------------------
# Prompt for secrets -- never hardcode credentials in this file
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Enter credentials (input is hidden)" -ForegroundColor Cyan
$PatToken        = Read-Host "GitHub PAT Token (repo + workflow scope)" -AsSecureString
$PatToken        = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PatToken))
$ServicePassword = Read-Host "Service account password for '$ServiceAccount'" -AsSecureString
$ServicePassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                       [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePassword))

# ---------------------------------------------------------------------------
# Auto-fetch Registration Token via PAT (avoids 1-hour expiry problem)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Fetching fresh runner registration token via PAT..." -ForegroundColor Cyan
$apiUrl  = "https://api.github.com/repos/SDPLaos2023/PPB_WEB_LeaveOnline/actions/runners/registration-token"
$headers = @{
    Authorization = "token $PatToken"
    Accept        = "application/vnd.github.v3+json"
    "User-Agent"  = "PowerShell-RunnerInstaller"
}
$tokenResponse     = Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $headers
$RegistrationToken = $tokenResponse.token
Write-Host "[OK] Registration token obtained (expires: $($tokenResponse.expires_at))." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host ">>> $msg" -ForegroundColor Cyan
}
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
$localUser = $ServiceAccount.Split('\')[-1]   # extract 'github-runner' for ACL rules

# Verify domain account is reachable (non-fatal -- continue even if check fails)
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

# Add to local Administrators -- non-fatal on Domain Controllers
try {
    $alreadyMember = & net localgroup Administrators 2>&1 | Select-String -Pattern $localUser -Quiet
    if (-not $alreadyMember) {
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

# Grant FullControl to service account on relevant paths
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
    throw "Hash mismatch! Expected: $RunnerHash  Got: $actualHash  (Zip deleted, please retry.)"
}
Write-Success "Hash validated."

# ---------------------------------------------------------------------------
# Step 6 : Extract
# ---------------------------------------------------------------------------
Write-Step "Extracting runner archive..."
if ((Test-Path (Join-Path $RunnerRoot "config.cmd")) -and (Test-Path (Join-Path $RunnerRoot "svc.cmd"))) {
    Write-Warn "Runner already extracted -- skipping."
} else {
    if (Test-Path (Join-Path $RunnerRoot "config.cmd")) {
        Write-Warn "config.cmd found but svc.cmd is missing -- re-extracting to restore runner files."
        # Exclude the zip file so it is NOT deleted and can be used for extraction below.
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

# If runner is already configured locally, remove it first before reconfiguring
$runnerConfigFile = Join-Path $RunnerRoot ".runner"
if (Test-Path $runnerConfigFile) {
    Write-Warn "Existing runner config found -- removing local config before reconfiguring..."
    $removeExe = Join-Path $RunnerRoot "config.cmd"
    Set-Location $RunnerRoot
    & $removeExe remove --unattended --token $RegistrationToken
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "config.cmd remove exited with $LASTEXITCODE -- attempting to continue anyway."
    } else {
        Write-Success "Existing runner config removed."
    }
}

$configArgs = @(
    "--url",                  $RepoUrl,
    "--token",                $RegistrationToken,
    "--name",                 $RunnerName,
    "--labels",               $RunnerLabels,
    "--runasservice",
    "--windowslogonaccount",  $ServiceAccount,
    "--windowslogonpassword", $ServicePassword,
    "--unattended",
    "--replace"   # overwrite if runner name already registered on GitHub
)

$configExe = Join-Path $RunnerRoot "config.cmd"
Set-Location $RunnerRoot
& $configExe @configArgs

if ($LASTEXITCODE -ne 0) {
    throw "config.cmd failed (exit code: $LASTEXITCODE). Check the output above for details."
}
Write-Success "Runner configured and service installed successfully."

# ---------------------------------------------------------------------------
# Step 8 : Start service -- target ONLY this runner's service
# ---------------------------------------------------------------------------
Write-Step "Starting GitHub Actions runner service..."

# Target ONLY this runner's service -- never touch other runners on this machine
# Service name format: actions.runner.<owner>-<repo>.<runnerName>
$repoOwner          = $RepoUrl.Split('/')[-2]
$repoName           = $RepoUrl.Split('/')[-1]
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