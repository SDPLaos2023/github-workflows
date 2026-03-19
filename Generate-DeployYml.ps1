# =============================================================================
# Generate-DeployYml.ps1  (CENTRAL SCRIPT — lives in SDPLaos2023/github-workflows)
#
# PURPOSE
#   Generates .github/workflows/deploy.yml inside your project repository
#   by auto-detecting the .csproj path and prompting for IIS settings.
#   Run this script from inside the root folder of the target project.
#
# ONE-LINER (run from inside target project folder)
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml.ps1' -UseBasicParsing).Content))
#
# PARAMETER MODE (non-interactive / CI)
#   .\Generate-DeployYml.ps1 `
#       -ProjectPath  'src/MyApp/MyApp.csproj' `
#       -AppPool      'MyApp_Pool' `
#       -DeployPath   'C:\inetpub\wwwroot\MyApp' `
#       -BackupPrefix 'MyApp' `
#       -RunnerLabel  'MY-SERVER' `
#       -Force
# =============================================================================

[CmdletBinding()]
param(
    # Relative path to .csproj from repo root — e.g. 'src/MyApp/MyApp.csproj'
    # Leave empty to auto-detect; a list is shown if multiple .csproj files are found
    [string] $ProjectPath   = "",

    # IIS Application Pool name (find it in IIS Manager > Application Pools)
    [string] $AppPool       = "",

    # Full Windows path on the server where IIS serves the app
    # e.g. 'C:\inetpub\wwwroot\MyApp'
    [string] $DeployPath    = "",

    # Short prefix used in backup archive names  e.g. 'MyApp'
    # Allowed characters: letters, digits, hyphens, underscores
    [string] $BackupPrefix  = "",

    # Self-hosted runner label — must match the runner configured at:
    #   GitHub > repo > Settings > Actions > Runners
    # Default: COMPUTERNAME of the machine running this script
    [string] $RunnerLabel   = "",

    # When set: skip all confirmation prompts and overwrite existing deploy.yml
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Helper — retry prompt up to 3 times, with optional default value
# ---------------------------------------------------------------------------
function Read-HostWithRetry {
    param(
        [string]      $Prompt,
        [scriptblock] $Validator,
        [string]      $ErrorMessage,
        [string]      $Default      = "",
        [int]         $MaxAttempts  = 3
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "  [!!] $ErrorMessage  (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
        }
        $displayPrompt = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $raw = (Read-Host "  $displayPrompt").Trim()
        if (-not $raw -and $Default) { $raw = $Default }
        if (& $Validator $raw) { return $raw }
        if ($attempt -eq $MaxAttempts) {
            Write-Host "  [ERROR] เกิน $MaxAttempts ครั้งแล้ว — ออกจาก script" -ForegroundColor Red
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Helper — walk up directory tree to find .git (repo root)
# ---------------------------------------------------------------------------
function Find-RepositoryRoot {
    $dir = (Get-Location).Path
    while ($true) {
        if (Test-Path (Join-Path $dir ".git")) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) {
            Write-Host ""
            Write-Host "  [ERROR] ไม่พบ Git repository (.git folder)" -ForegroundColor Red
            Write-Host "          กรุณา cd ไปที่ root ของ project repo แล้วรัน script ใหม่" -ForegroundColor Yellow
            Write-Host "          เช่น:  cd C:\src\MyProject" -ForegroundColor DarkGray
            exit 1
        }
        $dir = $parent
    }
}

# ===========================================================================
# BANNER
# ===========================================================================
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Generate Deploy Workflow" -ForegroundColor Cyan
Write-Host "  (.github/workflows/deploy.yml)" -ForegroundColor Cyan
Write-Host "  Machine: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# ===========================================================================
# STEP 1 — Find repo root
# ===========================================================================
Write-Host ">>> [1/5] ค้นหา Git repo root..." -ForegroundColor Cyan

$repoRoot = Find-RepositoryRoot

Write-Host "  [OK] Repo root : $repoRoot" -ForegroundColor Green

# ===========================================================================
# STEP 2 — Find / select .csproj
# ===========================================================================
Write-Host ""
Write-Host ">>> [2/5] ค้นหาไฟล์ .csproj..." -ForegroundColor Cyan

if (-not [string]::IsNullOrEmpty($ProjectPath)) {
    # Normalize to forward slashes
    $ProjectPath = $ProjectPath.Replace('\', '/')
    Write-Host "  [OK] project_path (param) : $ProjectPath" -ForegroundColor DarkGray
} else {
    # Scan recursively, skip build output folders
    $csprojFiles = @(
        Get-ChildItem -Path $repoRoot -Recurse -Filter "*.csproj" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch [regex]::Escape('\obj\') -and
                       $_.FullName -notmatch [regex]::Escape('\bin\') } |
        ForEach-Object {
            ($_.FullName.Substring($repoRoot.Length).TrimStart('\', '/')).Replace('\', '/')
        }
    )

    if ($csprojFiles.Count -eq 0) {
        Write-Host "  [!!] ไม่พบไฟล์ .csproj ในโปรเจกต์นี้" -ForegroundColor Yellow
        Write-Host "       กรุณากรอก project_path / relative path ด้วยตนเอง" -ForegroundColor Yellow
        $ProjectPath = Read-HostWithRetry `
            -Prompt       "  project_path (relative, e.g. src/MyApp/MyApp.csproj)" `
            -Validator    { param($v) $v -match '\.csproj$' } `
            -ErrorMessage "ต้องลงท้ายด้วย .csproj และเป็น relative path"
        $ProjectPath = $ProjectPath.Replace('\', '/')

    } elseif ($csprojFiles.Count -eq 1) {
        $ProjectPath = $csprojFiles[0]
        Write-Host "  [OK] พบ .csproj : $ProjectPath" -ForegroundColor Green

    } else {
        Write-Host "  พบ $($csprojFiles.Count) ไฟล์ .csproj — กรุณาเลือก 1 รายการ:" -ForegroundColor Yellow
        Write-Host ""
        for ($i = 0; $i -lt $csprojFiles.Count; $i++) {
            Write-Host ("    [{0}] {1}" -f ($i + 1), $csprojFiles[$i]) -ForegroundColor White
        }
        Write-Host ""
        $pick = Read-HostWithRetry `
            -Prompt       "เลือกหมายเลข [1-$($csprojFiles.Count)]" `
            -Validator    { param($v) $v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le $csprojFiles.Count } `
            -ErrorMessage "กรุณาใส่หมายเลข 1-$($csprojFiles.Count)"
        $ProjectPath = $csprojFiles[[int]$pick - 1]
        Write-Host "  [OK] เลือก : $ProjectPath" -ForegroundColor Green
    }
}

# Derive sensible defaults from the .csproj filename
$projName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)

# ===========================================================================
# STEP 3 — Collect IIS settings
# ===========================================================================
Write-Host ""
Write-Host ">>> [3/5] IIS & Runner Settings..." -ForegroundColor Cyan

if ([string]::IsNullOrEmpty($AppPool)) {
    $AppPool = Read-HostWithRetry `
        -Prompt       "IIS App Pool name" `
        -Default      "${projName}_Pool" `
        -Validator    { param($v) $v -match '^[a-zA-Z0-9_\-\.]+$' } `
        -ErrorMessage "App Pool name ห้ามมีอักขระพิเศษ (ใช้ได้: a-z, 0-9, _, -, .)"
} else {
    Write-Host "  App Pool     : $AppPool" -ForegroundColor DarkGray
}

if ([string]::IsNullOrEmpty($DeployPath)) {
    $DeployPath = Read-HostWithRetry `
        -Prompt       "Deploy path (Windows full path)" `
        -Default      "C:\inetpub\wwwroot\$projName" `
        -Validator    { param($v) $v -match '^[a-zA-Z]:\\' } `
        -ErrorMessage "ต้องเป็น Windows path เช่น C:\inetpub\wwwroot\MyApp"
} else {
    Write-Host "  Deploy path  : $DeployPath" -ForegroundColor DarkGray
}

if ([string]::IsNullOrEmpty($BackupPrefix)) {
    $BackupPrefix = Read-HostWithRetry `
        -Prompt       "Backup prefix" `
        -Default      $projName `
        -Validator    { param($v) $v -match '^[a-zA-Z0-9_\-]+$' } `
        -ErrorMessage "ใช้ได้เฉพาะตัวอักษร ตัวเลข _ และ -"
} else {
    Write-Host "  Backup prefix: $BackupPrefix" -ForegroundColor DarkGray
}

if ([string]::IsNullOrEmpty($RunnerLabel)) {
    $RunnerLabel = Read-HostWithRetry `
        -Prompt       "Runner label (ชื่อเครื่อง server ที่ติดตั้ง Runner ไว้)" `
        -Default      $env:COMPUTERNAME `
        -Validator    { param($v) $v.Length -gt 0 } `
        -ErrorMessage "กรุณาใส่ runner label"
} else {
    Write-Host "  Runner label : $RunnerLabel" -ForegroundColor DarkGray
}

# ===========================================================================
# STEP 4 — Preview & confirm
# ===========================================================================
Write-Host ""
Write-Host ">>> [4/5] Preview..." -ForegroundColor Cyan
Write-Host ""
Write-Host "  project_path  : $ProjectPath"  -ForegroundColor White
Write-Host "  app_pool      : $AppPool"       -ForegroundColor White
Write-Host "  deploy_path   : $DeployPath"    -ForegroundColor White
Write-Host "  backup_prefix : $BackupPrefix"  -ForegroundColor White
Write-Host "  runner_label  : $RunnerLabel"   -ForegroundColor White
Write-Host "  backup_keep   : 5 (default)"    -ForegroundColor DarkGray
Write-Host "  branch trigger: Deploy (fixed)" -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
    $confirm = (Read-Host "  ดำเนินการต่อ? สร้าง .github/workflows/deploy.yml [Y/n]").Trim().ToLower()
    if ($confirm -eq 'n') {
        Write-Host "  ยกเลิก" -ForegroundColor Yellow
        exit 0
    }
}

# ===========================================================================
# STEP 5 — Write deploy.yml
# ===========================================================================
Write-Host ""
Write-Host ">>> [5/5] สร้างไฟล์ deploy.yml..." -ForegroundColor Cyan

$targetDir  = Join-Path $repoRoot ".github\workflows"
$targetFile = Join-Path $targetDir "deploy.yml"

# Handle file already exists
if ((Test-Path $targetFile) -and (-not $Force)) {
    Write-Host ""
    Write-Host "  [!!] พบไฟล์ deploy.yml อยู่แล้วที่:" -ForegroundColor Yellow
    Write-Host "       $targetFile" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "       [Y] Overwrite" -ForegroundColor White
    Write-Host "       [B] Backup ไฟล์เดิมแล้ว Overwrite" -ForegroundColor White
    Write-Host "       [N] ยกเลิก" -ForegroundColor White
    Write-Host ""
    $overwrite = (Read-Host "  เลือก [Y/B/N]").Trim().ToUpper()

    if ($overwrite -eq 'B') {
        $backupFile = "$targetFile.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item $targetFile $backupFile
        Write-Host "  [OK] Backup : $backupFile" -ForegroundColor Green
    } elseif ($overwrite -ne 'Y') {
        Write-Host "  ยกเลิก" -ForegroundColor Yellow
        exit 0
    }
}

# Create .github/workflows/ directory if needed
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Write-Host "  [OK] สร้างโฟลเดอร์ : $targetDir" -ForegroundColor Green
}

# YAML content — single-quoted strings; escape any literal single-quote in values
$deployPathYaml  = $DeployPath.Replace("'", "''")
$appPoolYaml     = $AppPool.Replace("'", "''")
$backupPrefixYaml = $BackupPrefix.Replace("'", "''")
$runnerLabelYaml = $RunnerLabel.Replace("'", "''")
$projPathYaml    = $ProjectPath.Replace("'", "''")

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$content = @"
# ============================================================
# AUTO-GENERATED by Generate-DeployYml.ps1
# Generated : $timestamp  (Machine: $env:COMPUTERNAME)
#
# To regenerate, run this one-liner from the project root:
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml.ps1' -UseBasicParsing).Content))
# ============================================================

name: Deploy $projName to IIS

on:
  push:
    branches:
      - Deploy

jobs:
  call-deploy:
    uses: SDPLaos2023/github-workflows/.github/workflows/deploy-iis-dotnet.yml@main

    with:
      project_path:  '$projPathYaml'
      app_pool:      '$appPoolYaml'
      deploy_path:   '$deployPathYaml'
      backup_prefix: '$backupPrefixYaml'
      runner_label:  '$runnerLabelYaml'
      backup_keep:   5
"@

# Write UTF-8 without BOM (required for GitHub Actions YAML)
[System.IO.File]::WriteAllText($targetFile, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host "  [OK] สร้างไฟล์สำเร็จ : $targetFile" -ForegroundColor Green
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  Deploy workflow พร้อมใช้งานแล้ว!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  ขั้นตอนต่อไป:" -ForegroundColor Cyan
Write-Host "    1. ตรวจสอบไฟล์ที่  : $targetFile" -ForegroundColor White
Write-Host "    2. git add .github/workflows/deploy.yml" -ForegroundColor White
Write-Host "    3. git commit -m 'ci: add deploy workflow'" -ForegroundColor White
Write-Host "    4. git push" -ForegroundColor White
Write-Host "    5. สร้าง branch 'Deploy' ถ้ายังไม่มี" -ForegroundColor White
Write-Host ""
