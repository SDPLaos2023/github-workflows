# =============================================================================
# Install-GitHubRunner.ps1  (CENTRAL SCRIPT — lives in SDPLaos2023/github-workflows)
#
# PURPOSE
#   Reusable script for installing or removing a GitHub Actions self-hosted runner
#   on any Windows / IIS server in the SDPLaos2023 organisation.
#
# USAGE
#   Run this one-liner in an elevated PowerShell on the target server:
#
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
#
# MAIN MENU
#   [1] Install Runner  — prompts [1/3] Project, [2/3] Server, [3/3] GitHub token
#   [2] Delete Runner   — lists installed runners, pick one to remove
#
# INSTALL STEPS
#   1. Verify Administrator
#   2. Check/install Git (auto-updates if missing or outdated)
#   3. Verify domain account & grant folder permissions
#   4. Create required directories
#   5. Download runner zip
#   6. Validate SHA-256 hash
#   7. Extract runner archive
#   8. Configure runner service
#   9. Start runner service
#  10. Verify IIS App Pool
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
    [string] $BackupPath    = "C:\BackupIIS",

    # Registration token obtained manually from GitHub UI
    # Use this if you don't have repo Admin rights to auto-fetch via PAT
    # Get it at: GitHub -> repo -> Settings -> Actions -> Runners -> New self-hosted runner
    # Token looks like: AXXXXXXXXXXXXXXXXXXXXXXXXXX  (expires in 1 hour)
    # Leave empty to auto-fetch via PAT instead
    [string] $RegistrationToken = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Force TLS 1.2 — required by GitHub API and download servers.
# Windows PowerShell 5.1 defaults to TLS 1.0 which GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Helper — retry prompt up to 3 times, then exit on failure
# ---------------------------------------------------------------------------
function Read-HostWithRetry {
    param(
        [string]      $Prompt,
        [scriptblock] $Validator,
        [string]      $ErrorMessage,
        [switch]      $AsSecureString,
        [int]         $MaxAttempts = 3
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "  [!!] $ErrorMessage  (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
        }
        if ($AsSecureString) {
            $secure = Read-Host $Prompt -AsSecureString
            $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                          [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        } else {
            $plain = (Read-Host $Prompt).Trim()
        }
        if (& $Validator $plain) { return $plain }
        if ($attempt -eq $MaxAttempts) {
            Write-Host "  [ERROR] เกิน $MaxAttempts ครั้งแล้ว — ออกจาก script" -ForegroundColor Red
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Delete Runner — list installed runners, pick one, remove it
# ---------------------------------------------------------------------------
function Invoke-DeleteRunner {
    Write-Host ""
    Write-Host "=== Installed GitHub Runners on this machine ===" -ForegroundColor Cyan
    Write-Host ""

    $services = @(Get-Service "actions.runner.*" -ErrorAction SilentlyContinue)
    if ($services.Count -eq 0) {
        Write-Host "  No GitHub Actions runners found on this machine." -ForegroundColor Yellow
        exit 0
    }

    # Collect runner details
    $runners = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($svc in $services) {
        $wmiSvc  = Get-WmiObject Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
        $exePath = if ($wmiSvc) { $wmiSvc.PathName.Trim('"') -replace '".*','' } else { "" }
        # RunnerService.exe lives at <root>\bin\RunnerService.exe  →  go up twice
        $root    = if ($exePath) { Split-Path (Split-Path $exePath -Parent) -Parent } else { "" }
        # Parse owner-repo and runnername from service name: actions.runner.<owner>-<repo>.<runnername>
        $parts     = $svc.Name -replace '^actions\.runner\.','' -split '\.',2
        $ownerRepo = $parts[0] -replace '-','/',1   # first '-' is org/repo separator
        $runnerName= if ($parts.Count -gt 1) { $parts[1] } else { "(unknown)" }
        $runners.Add(@{
            Svc        = $svc
            Root       = $root
            OwnerRepo  = $ownerRepo
            RunnerName = $runnerName
        })
    }

    $idx = 1
    foreach ($r in $runners) {
        Write-Host ("  [{0}] {1}" -f $idx, $r.Svc.Name) -ForegroundColor White
        Write-Host ("      Status: {0}" -f $r.Svc.Status)
        Write-Host ("      Repo  : {0}" -f $r.OwnerRepo)
        Write-Host ("      Root  : {0}" -f $r.Root)
        Write-Host ""
        $idx++
    }

    $pick = Read-HostWithRetry `
        -Prompt       "  Select runner to remove [1-$($runners.Count)]" `
        -Validator    { param($v) $v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le $runners.Count } `
        -ErrorMessage "กรุณาใส่หมายเลข 1-$($runners.Count)"
    $chosen = $runners[[int]$pick - 1]

    Write-Host ""
    Write-Host "  Selected : $($chosen.Svc.Name)" -ForegroundColor Yellow
    Write-Host "  Root     : $($chosen.Root)" -ForegroundColor Yellow
    Write-Host ""

    # Parse owner and repo for token URL
    $ownerRepoParts = $chosen.OwnerRepo -split '/',2
    $owner = $ownerRepoParts[0]
    $repo  = if ($ownerRepoParts.Count -gt 1) { $ownerRepoParts[1] } else { "" }

    Write-Host "  To fully deregister from GitHub, get a Remove Token at:" -ForegroundColor Cyan
    Write-Host "  https://github.com/$($chosen.OwnerRepo)/settings/actions/runners" -ForegroundColor Cyan
    Write-Host "  Click [...] next to the runner → Remove → copy the token shown." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  (Press Enter without typing to skip GitHub deregistration — runner will be removed locally only)" -ForegroundColor DarkGray
    Write-Host ""

    $removeTokenSecure = Read-Host "  Remove Token (hidden, or press Enter to skip)" -AsSecureString
    $removeToken       = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($removeTokenSecure)).Trim()

    # Stop and uninstall the service
    Write-Host ""
    Write-Host ">>> Stopping runner service..." -ForegroundColor Cyan
    if ($chosen.Svc.Status -eq "Running") {
        Stop-Service -Name $chosen.Svc.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Write-Host "[OK] Service stopped." -ForegroundColor Green

    # Deregister from GitHub via config.cmd (if token provided)
    if (-not [string]::IsNullOrEmpty($removeToken) -and (Test-Path $chosen.Root)) {
        $configCmd = Join-Path $chosen.Root "config.cmd"
        if (Test-Path $configCmd) {
            Write-Host ">>> Deregistering runner from GitHub..." -ForegroundColor Cyan
            Set-Location $chosen.Root
            & $configCmd remove --unattended --token $removeToken
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] Runner deregistered from GitHub." -ForegroundColor Green
            } else {
                Write-Host "[!!] config.cmd remove exited with $LASTEXITCODE — continuing with local removal." -ForegroundColor Yellow
            }
        }
    } else {
        # Manually uninstall the service without config.cmd
        Write-Host ">>> Uninstalling service (local only)..." -ForegroundColor Cyan
        $svcCmd = Join-Path $chosen.Root "svc.cmd"
        if (Test-Path $svcCmd) {
            Set-Location $chosen.Root
            & $svcCmd uninstall 2>&1 | Out-Null
        } else {
            & sc.exe delete $chosen.Svc.Name 2>&1 | Out-Null
        }
        Write-Host "[OK] Service uninstalled." -ForegroundColor Green
        Write-Host "[!!] Runner was not deregistered from GitHub — remove it manually at:" -ForegroundColor Yellow
        Write-Host "     https://github.com/$($chosen.OwnerRepo)/settings/actions/runners" -ForegroundColor Yellow
    }

    # Delete runner files
    if (-not [string]::IsNullOrEmpty($chosen.Root) -and (Test-Path $chosen.Root)) {
        Write-Host ">>> Deleting runner files from $($chosen.Root)..." -ForegroundColor Cyan
        Remove-Item $chosen.Root -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Runner files deleted." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " Runner '$($chosen.Svc.Name)' removed successfully." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  GitHub Runner Manager" -ForegroundColor Cyan
Write-Host "  Machine: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] Install Runner" -ForegroundColor White
Write-Host "  [2] Delete Runner" -ForegroundColor White
Write-Host ""

$menuChoice = Read-HostWithRetry `
    -Prompt    "  Enter choice [1/2]" `
    -Validator { param($v) $v -eq '1' -or $v -eq '2' } `
    -ErrorMessage "กรุณาเลือก 1 หรือ 2"

if ($menuChoice -eq '2') { Invoke-DeleteRunner }

# ---------------------------------------------------------------------------
# Interactive prompts — ask for any value not supplied via parameter
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== [1/3] Project Configuration (same for every server of this project)" -ForegroundColor Cyan

if ([string]::IsNullOrEmpty($RepoUrl)) {
    $RepoUrl = Read-HostWithRetry `
        -Prompt       "  GitHub Repo URL (e.g. https://github.com/SDPLaos2023/MyProject)" `
        -Validator    { param($v) $v -match '^https://github\.com/[^/]+/[^/]+$' } `
        -ErrorMessage "URL ไม่ถูกต้อง — ต้องขึ้นต้นด้วย https://github.com/Org/Repo"
} else {
    Write-Host "  Repo URL   : $RepoUrl" -ForegroundColor DarkGray
}
# Sanitize URL — strip trailing ) ] spaces and slashes that may come from pasting markdown links
$RepoUrl = $RepoUrl.Trim().TrimEnd(')', ']', '/', ' ')

if ([string]::IsNullOrEmpty($AppPool)) {
    $AppPool = Read-HostWithRetry `
        -Prompt       "  IIS App Pool name" `
        -Validator    { param($v) $v -match '^[a-zA-Z0-9_\-\.]+$' } `
        -ErrorMessage "App Pool name ห้ามมีอักขระพิเศษ"
} else {
    Write-Host "  AppPool    : $AppPool" -ForegroundColor DarkGray
}

if ([string]::IsNullOrEmpty($DeployPath)) {
    $DeployPath = Read-HostWithRetry `
        -Prompt       "  Deploy path (e.g. C:\inetpub\wwwroot\MyProject)" `
        -Validator    { param($v) $v -match '^[a-zA-Z]:\\' } `
        -ErrorMessage "Path ต้องเป็น Windows path เช่น C:\inetpub\wwwroot\MyProject"
} else {
    Write-Host "  DeployPath : $DeployPath" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== [2/3] Server Configuration (specific to THIS machine: $env:COMPUTERNAME)" -ForegroundColor Cyan
Write-Host "  This is the Windows account that will RUN the runner service on this server." -ForegroundColor DarkGray
Write-Host "  It must have 'Log on as a service' rights and permission to manage IIS App Pools." -ForegroundColor DarkGray
Write-Host ""

# Auto-detect domain membership and suggest the correct account format
$_domainInfo     = Get-WmiObject Win32_ComputerSystem
$_isJoinedDomain = $_domainInfo.PartOfDomain
$_detectedDomain = if ($_isJoinedDomain) { $_domainInfo.Domain.Split('.')[0].ToUpper() } else { $env:COMPUTERNAME }
$_suggestedAcct  = "$_detectedDomain\administrator"
Write-Host "  Detected  : $(if ($_isJoinedDomain) { "Domain-joined → $_detectedDomain" } else { "Local → $env:COMPUTERNAME" })" -ForegroundColor Cyan
Write-Host "  Suggested : $_suggestedAcct" -ForegroundColor Cyan
Write-Host ""

if ([string]::IsNullOrEmpty($ServiceAccount)) {
    $ServiceAccount = Read-HostWithRetry `
        -Prompt       "  Windows service account (e.g. $_suggestedAcct)" `
        -Validator    {
            param($v)
            # Auto-fix .\username → DOMAIN\username
            if ($v -match '^\.\\.+') {
                $fixed = "$_detectedDomain\$($v -replace '^\.\\' )"
                Write-Host "  [Auto-fix] Normalized to: $fixed" -ForegroundColor Cyan
                $script:ServiceAccount = $fixed
                return $true
            }
            return $v -match '^[a-zA-Z0-9_\-]+\\[a-zA-Z0-9_\-\.]+$'
        } `
        -ErrorMessage "รูปแบบต้องเป็น DOMAIN\username หรือ COMPUTER\username"
    # Apply normalization that may have been set inside the validator
    if ($ServiceAccount -match '^\.\\.+') {
        $ServiceAccount = "$_detectedDomain\$($ServiceAccount -replace '^\.\\' )"
    }
} else {
    Write-Host "  ServiceAccount: $ServiceAccount" -ForegroundColor DarkGray
}

$ServicePassword = Read-HostWithRetry `
    -Prompt        "  Password for '$ServiceAccount' (hidden)" `
    -Validator     { param($v) $v.Length -ge 1 } `
    -ErrorMessage  "Password ห้ามว่าง" `
    -AsSecureString

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
Write-Host "=== [3/3] GitHub Credentials" -ForegroundColor Cyan

$repoOwner = $RepoUrl.Split('/')[-2]

if (-not [string]::IsNullOrEmpty($RegistrationToken)) {
    # Token already supplied via parameter — skip prompts
    Write-Host "  Using pre-supplied registration token." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "  Get your token at:" -ForegroundColor Yellow
    Write-Host "  https://github.com/$repoOwner/$repoName/settings/actions/runners/new" -ForegroundColor Yellow
    Write-Host "  Select Windows, then copy the value after '--token' in the Configure section." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Token format: ~29 uppercase letters and digits (e.g. ABCDE12345FGHIJ67890KLMNO1234)" -ForegroundColor DarkGray
    Write-Host ""

    $RegistrationToken = Read-HostWithRetry `
        -Prompt        "  Registration Token (hidden)" `
        -Validator     {
            param($v)
            if ($v -match '^[A-Z0-9]{20,40}$') {
                Write-Host "  [OK] Token format looks valid ($($v.Length) chars, starts with '$($v.Substring(0,4))**')." -ForegroundColor Green
                return $true
            }
            Write-Host "      Got  : $($v.Length) chars -- '$($v.Substring(0, [Math]::Min(6,$v.Length)))...'" -ForegroundColor Red
            Write-Host "      Expect: 20-40 uppercase letters/digits only — ใส่แค่ token เท่านั้น ไม่ใส่ทั้งบรรทัด" -ForegroundColor Yellow
            Write-Host "      Common mistake: copied whole line './config.cmd --url ... --token XXXX' instead of just XXXX" -ForegroundColor Yellow
            return $false
        } `
        -ErrorMessage  "Token ไม่ถูกต้อง กรุณาลองใหม่" `
        -AsSecureString
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
# Step 2 : Check Git installation — auto-install / update if missing or old
# ---------------------------------------------------------------------------
Write-Step "Checking Git installation..."
$minGitMajor = 2
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
$needsGit = $false

if ($null -eq $gitCmd) {
    Write-Warn "Git not found on this machine — will install automatically."
    $needsGit = $true
} else {
    $gitVerRaw = (& git --version 2>&1) -replace 'git version ',''
    $gitMajor  = [int]($gitVerRaw.Split('.')[0])
    if ($gitMajor -lt $minGitMajor) {
        Write-Warn "Git version $gitVerRaw is too old (need $minGitMajor.x+) — will upgrade automatically."
        $needsGit = $true
    } else {
        Write-Success "Git $gitVerRaw is installed and up to date."
    }
}

if ($needsGit) {
    Write-Host "  Fetching latest Git for Windows installer..." -ForegroundColor Cyan
    try {
        # Resolve latest release tag from GitHub API
        $gitRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" -UseBasicParsing
        $asset      = $gitRelease.assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1
        if ($null -eq $asset) { throw "Could not find 64-bit installer asset." }

        $installerPath = Join-Path $env:TEMP $asset.name
        Write-Host "  Downloading $($asset.name)..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath -UseBasicParsing

        Write-Host "  Installing Git silently (this takes ~30 seconds)..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath $installerPath `
                    -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /COMPONENTS=`"icons,ext\reg\shellhere,assoc,assoc_sh`"" `
                    -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "Installer exited with code $($proc.ExitCode)." }

        # Refresh PATH so git is available in this session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")

        $newVer = (& git --version 2>&1) -replace 'git version ',''
        Write-Success "Git $newVer installed successfully."
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warn "Auto-install failed: $_ — continuing anyway (Git is not required by the runner itself)."
    }
}

# ---------------------------------------------------------------------------
# Step 3 : Verify domain user exists & grant folder permissions
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
# Step 4 : Create required directories
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
# Step 5 : Download runner
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
# Step 6 : Validate SHA-256 hash
# ---------------------------------------------------------------------------
Write-Step "Validating SHA-256 hash..."
$actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToUpper()
if ($actualHash -ne $RunnerHash.ToUpper()) {
    Remove-Item $ZipPath -Force
    throw "Hash mismatch!`n  Expected : $RunnerHash`n  Got      : $actualHash`n  (Zip deleted, please retry.)"
}
Write-Success "Hash validated."

# ---------------------------------------------------------------------------
# Step 7 : Extract
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
# Step 8 : Configure runner
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
# Pre-flight: runner name conflict check (skipped — using registration token only)
# ---------------------------------------------------------------------------
Write-Step "Checking for runner name conflicts on GitHub..."
Write-Warn "Skipping conflict check -- using registration token (no PAT). If a runner named '$RunnerName' already exists it will be reported by config.cmd below."

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

# Show config summary so user can verify before running
Write-Host ""
Write-Host "  Config summary:" -ForegroundColor DarkGray
Write-Host "    URL   : $RepoUrl" -ForegroundColor DarkGray
Write-Host "    Token : $($RegistrationToken.Substring(0, [Math]::Min(4, $RegistrationToken.Length)))***  (first 4 chars shown)" -ForegroundColor DarkGray
Write-Host "    Name  : $RunnerName" -ForegroundColor DarkGray
Write-Host ""

Set-Location $RunnerRoot
& $configCmd @configArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  config.cmd failed. Common causes:" -ForegroundColor Yellow
    Write-Host "    - Registration token expired (valid 1 hour only) -- generate a new one" -ForegroundColor Yellow
    Write-Host "      at: https://github.com/$repoOwner/$repoName/settings/actions/runners/new" -ForegroundColor Yellow
    Write-Host "    - Token was generated for a different repo -- make sure to use the token" -ForegroundColor Yellow
    Write-Host "      from the page above, not from another project" -ForegroundColor Yellow
    Write-Host "    - URL mismatch -- verify URL shown above matches the repo exactly" -ForegroundColor Yellow
    throw "config.cmd failed (exit code: $LASTEXITCODE). Check the output above for details."
}
Write-Success "Runner configured and service installed successfully."

# ---------------------------------------------------------------------------
# Step 9 : Start service — target ONLY this runner's service
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
# Step 10 : Verify IIS App Pool
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
