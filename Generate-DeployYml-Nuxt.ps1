# =============================================================================
# Generate-DeployYml-Nuxt.ps1  (CENTRAL SCRIPT — lives in SDPLaos2023/github-workflows)
#
# PURPOSE
#   Generates .github/workflows/deploy-nuxt.yml inside your Nuxt project repo
#   with safe defaults and overwrite/backup protection.
#
# ONE-LINER (run from inside Nuxt project folder)
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml-Nuxt.ps1' -UseBasicParsing).Content))
# =============================================================================

[CmdletBinding()]
param(
    [string] $AppPool = "",
    [string] $DeployPath = "",
    [string] $BackupPrefix = "",
    [string] $RunnerLabel = "",
    [string] $PackageManager = "",
    [string] $NodeVersion = "20",
    [string] $BuildScript = "build",
    [string] $BuildOutput = "",
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Read-HostWithRetry {
    param(
        [string]      $Prompt,
        [scriptblock] $Validator,
        [string]      $ErrorMessage,
        [string]      $Default = "",
        [int]         $MaxAttempts = 3
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

function Find-RepositoryRoot {
    $dir = (Get-Location).Path
    while ($true) {
        if (Test-Path (Join-Path $dir ".git")) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) {
            Write-Host ""
            Write-Host "  [ERROR] ไม่พบ Git repository (.git folder)" -ForegroundColor Red
            Write-Host "          กรุณา cd ไปที่ root ของ Nuxt project แล้วรันใหม่" -ForegroundColor Yellow
            exit 1
        }
        $dir = $parent
    }
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Generate Nuxt Deploy Workflow" -ForegroundColor Cyan
Write-Host "  (.github/workflows/deploy-nuxt.yml)" -ForegroundColor Cyan
Write-Host "  Machine: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = Find-RepositoryRoot
$repoName = Split-Path $repoRoot -Leaf
$packageJsonPath = Join-Path $repoRoot "package.json"

if (-not (Test-Path $packageJsonPath)) {
    Write-Host "  [ERROR] ไม่พบ package.json ใน repo root: $repoRoot" -ForegroundColor Red
    Write-Host "          สคริปต์นี้ใช้กับ Nuxt/Node project" -ForegroundColor Yellow
    exit 1
}

Write-Host "  [OK] Repo root : $repoRoot" -ForegroundColor Green

if ([string]::IsNullOrEmpty($PackageManager)) {
    if (Test-Path (Join-Path $repoRoot "pnpm-lock.yaml")) {
        $PackageManager = "pnpm"
    } elseif (Test-Path (Join-Path $repoRoot "yarn.lock")) {
        $PackageManager = "yarn"
    } else {
        $PackageManager = "npm"
    }
}

if ([string]::IsNullOrEmpty($BuildOutput)) {
    if (Test-Path (Join-Path $repoRoot ".output\public")) {
        $BuildOutput = ".output/public"
    } elseif (Test-Path (Join-Path $repoRoot "dist")) {
        $BuildOutput = "dist"
    } else {
        $BuildOutput = ".output/public"
    }
}

if ([string]::IsNullOrEmpty($AppPool)) {
    $AppPool = Read-HostWithRetry `
        -Prompt "IIS App Pool name" `
        -Default "${repoName}_Pool" `
        -Validator { param($v) $v -match '^[a-zA-Z0-9_\-\.]+$' } `
        -ErrorMessage "App Pool name ห้ามมีอักขระพิเศษ"
}

if ([string]::IsNullOrEmpty($DeployPath)) {
    $DeployPath = Read-HostWithRetry `
        -Prompt "Deploy path (Windows full path)" `
        -Default "C:\inetpub\wwwroot\$repoName" `
        -Validator { param($v) $v -match '^[a-zA-Z]:\\' } `
        -ErrorMessage "ต้องเป็น Windows path เช่น C:\inetpub\wwwroot\MyNuxtApp"
}

if ([string]::IsNullOrEmpty($BackupPrefix)) {
    $BackupPrefix = Read-HostWithRetry `
        -Prompt "Backup prefix" `
        -Default $repoName `
        -Validator { param($v) $v -match '^[a-zA-Z0-9_\-]+$' } `
        -ErrorMessage "ใช้ได้เฉพาะตัวอักษร ตัวเลข _ และ -"
}

if ([string]::IsNullOrEmpty($RunnerLabel)) {
    $RunnerLabel = Read-HostWithRetry `
        -Prompt "Runner label" `
        -Default $env:COMPUTERNAME `
        -Validator { param($v) $v.Length -gt 0 } `
        -ErrorMessage "กรุณาใส่ runner label"
}

if (-not $Force) {
    $PackageManager = Read-HostWithRetry `
        -Prompt "Package manager (npm/pnpm/yarn)" `
        -Default $PackageManager `
        -Validator { param($v) @('npm','pnpm','yarn') -contains $v.ToLower() } `
        -ErrorMessage "ต้องเป็น npm, pnpm หรือ yarn"

    $NodeVersion = Read-HostWithRetry `
        -Prompt "Node version" `
        -Default $NodeVersion `
        -Validator { param($v) $v -match '^\d+' } `
        -ErrorMessage "ใส่ตัวเลขเวอร์ชัน เช่น 20"

    $BuildScript = Read-HostWithRetry `
        -Prompt "Build script name (from package.json)" `
        -Default $BuildScript `
        -Validator { param($v) $v.Length -gt 0 } `
        -ErrorMessage "กรุณาใส่ script name"

    $BuildOutput = Read-HostWithRetry `
        -Prompt "Build output folder (e.g. .output/public or dist)" `
        -Default $BuildOutput `
        -Validator { param($v) $v.Length -gt 0 } `
        -ErrorMessage "กรุณาใส่ output folder"
}

Write-Host ""
Write-Host "  Preview:" -ForegroundColor Cyan
Write-Host "    app_pool      : $AppPool"
Write-Host "    deploy_path   : $DeployPath"
Write-Host "    backup_prefix : $BackupPrefix"
Write-Host "    runner_label  : $RunnerLabel"
Write-Host "    package_mgr   : $PackageManager"
Write-Host "    node_version  : $NodeVersion"
Write-Host "    build_script  : $BuildScript"
Write-Host "    build_output  : $BuildOutput"
Write-Host "    branch trigger: Deploy (fixed)"
Write-Host ""

if (-not $Force) {
    $confirm = (Read-Host "  ดำเนินการต่อ? สร้าง .github/workflows/deploy-nuxt.yml [Y/n]").Trim().ToLower()
    if ($confirm -eq 'n') {
        Write-Host "  ยกเลิก" -ForegroundColor Yellow
        exit 0
    }
}

$targetDir  = Join-Path $repoRoot ".github\workflows"
$targetFile = Join-Path $targetDir "deploy-nuxt.yml"

if ((Test-Path $targetFile) -and (-not $Force)) {
    Write-Host ""
    Write-Host "  [!!] พบไฟล์ deploy-nuxt.yml อยู่แล้ว:" -ForegroundColor Yellow
    Write-Host "       $targetFile" -ForegroundColor Yellow
    Write-Host "       [Y] Overwrite  [B] Backup+Overwrite  [N] Cancel" -ForegroundColor White
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

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$appPoolYaml      = $AppPool.Replace("'", "''")
$deployPathYaml   = $DeployPath.Replace("'", "''")
$backupPrefixYaml = $BackupPrefix.Replace("'", "''")
$runnerLabelYaml  = $RunnerLabel.Replace("'", "''")
$packageMgrYaml   = $PackageManager.Replace("'", "''")
$nodeVersionYaml  = $NodeVersion.Replace("'", "''")
$buildScriptYaml  = $BuildScript.Replace("'", "''")
$buildOutputYaml  = $BuildOutput.Replace("'", "''")
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$content = @"
# ============================================================
# AUTO-GENERATED by Generate-DeployYml-Nuxt.ps1
# Generated : $timestamp  (Machine: $env:COMPUTERNAME)
#
# To regenerate, run this one-liner from project root:
#   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml-Nuxt.ps1' -UseBasicParsing).Content))
# ============================================================

name: Deploy $repoName (Nuxt) to IIS

on:
  push:
    branches:
      - Deploy

jobs:
  call-deploy:
    uses: SDPLaos2023/github-workflows/.github/workflows/deploy-iis-nuxt.yml@main

    with:
      app_pool: '$appPoolYaml'
      deploy_path: '$deployPathYaml'
      backup_prefix: '$backupPrefixYaml'
      runner_label: '$runnerLabelYaml'
      package_manager: '$packageMgrYaml'
      node_version: '$nodeVersionYaml'
      build_script: '$buildScriptYaml'
      build_output: '$buildOutputYaml'
      backup_keep: 5
"@

[System.IO.File]::WriteAllText($targetFile, $content, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  Nuxt deploy workflow พร้อมใช้งานแล้ว!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  File: $targetFile" -ForegroundColor Green
