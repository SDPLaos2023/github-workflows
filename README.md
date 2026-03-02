# SDPLaos2023 / github-workflows

Centralized GitHub Actions reusable workflows for the **SDPLaos2023** organization.

---

## Table of Contents

1. [Deploy Flow Diagram](#deploy-flow-diagram)
2. [Installing a Self-Hosted Runner on a New Server](#installing-a-self-hosted-runner-on-a-new-server)
3. [Creating a deploy.yml for a New Project](#creating-a-deployyml-for-a-new-project)
   - [วิธีที่ 1 — ให้ AI สร้างให้อัตโนมัติ](#วิธีที่-1--ให้-ai-สร้างให้อัตโนมัติ-แนะนำ)
   - [วิธีที่ 2 — แก้เองจาก template](#วิธีที่-2--แก้เองจาก-template)
4. [Inputs Reference](#inputs-reference)
5. [Real-World Example](#real-world-example)
6. [Backup Policy](#backup-policy)
7. [Troubleshooting](#troubleshooting)

---

## Deploy Flow Diagram

```
Developer pushes to "Deploy" branch
           │
           ▼
  GitHub Actions triggered
  (project repo deploy.yml)
           │
           ▼
  calls: SDPLaos2023/github-workflows
         deploy-iis-dotnet.yml@main
           │
           ▼
  ┌─────────────────────────────┐
  │  1. Checkout source code    │
  │  2. Setup .NET SDK          │
  │  3. dotnet restore          │
  │  4. dotnet publish          │
  │  5. Backup current deploy   │
  │     → C:\BackupIIS\*.zip    │
  │  6. Stop IIS App Pool       │
  │  7. robocopy (deploy files) │
  │  8. Start IIS App Pool      │
  │  9. Verify (pool + dll)     │
  └─────────────────────────────┘
           │
           ▼
     Deployment complete
```

---

## Installing a Self-Hosted Runner on a New Server

> Updating the runner version only requires changing `$RunnerVersion` and `$RunnerHash` in
> [`Install-GitHubRunner.ps1`](Install-GitHubRunner.ps1) — all projects pick up the change automatically.

**Script URL (raw):**
```
https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1
```

เปิด **PowerShell as Administrator** บน server แล้วรันบรรทัดนี้บรรทัดเดียว:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
```

Script จะถามค่าต่างๆ แบบ interactive ทีละขั้น:

```
Project Configuration
  GitHub Repo URL (e.g. https://github.com/SDPLaos2023/MyProject): _
  Service account (e.g. sdplao\github-runner): _
  IIS App Pool name: _
  Deploy path (e.g. C:\inetpub\wwwroot\MyProject): _

Enter credentials (input is hidden)
  GitHub PAT Token (repo + workflow scope): ****
  Service account password for 'sdplao\github-runner': ****
```

Script จะ auto-fetch registration token ผ่าน PAT แล้ว download, verify, extract, configure และ start runner service อัตโนมัติ

> **Per-project template:** สำหรับโปรเจกต์ที่มีค่า config ซ้ำๆ กัน สามารถดูตัวอย่าง pre-filled script ได้ที่
> [`TEMPLATE-Install-Runner.md`](TEMPLATE-Install-Runner.md) — copy ไปแก้ค่าตามโปรเจกต์แล้วรันได้เลยโดยไม่ต้อง interactive prompt

ตรวจสอบว่า runner ขึ้น **Idle** ที่:
`https://github.com/<org>/<repo>/settings/actions/runners`

### Runner Inputs Reference

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `RepoUrl` | ✅ | — | Full HTTPS URL of the target GitHub repo |
| `ServiceAccount` | ✅ | — | Domain user that runs the service (e.g. `sdplao\github-runner`) |
| `AppPool` | ✅ | — | IIS Application Pool name |
| `DeployPath` | ✅ | — | Full server path where the app is served |
| `RunnerName` | ❌ | `COMPUTERNAME` | Name shown in GitHub Settings → Actions → Runners |
| `RunnerLabels` | ❌ | `= RunnerName` | Comma-separated label(s); must match `runner_label` in `deploy.yml` |
| `RunnerVersion` | ❌ | `2.331.0` | GitHub Actions runner version to install |
| `RunnerHash` | ❌ | *(matches version)* | SHA-256 of the runner zip — auto-matches `RunnerVersion` default |
| `RunnerRoot` | ❌ | `C:\actions-runner\<repo-name>` | Directory where runner files are extracted |
| `BackupPath` | ❌ | `C:\BackupIIS` | Directory where deploy backup ZIPs are stored |

---

## Creating a deploy.yml for a New Project

**Template URL (raw):**
```
https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Deploy-YML-TEMPLATE.yml
```

### วิธีที่ 1 — ให้ AI สร้างให้อัตโนมัติ (แนะนำ)

Copy prompt ด้านล่างไปวางใน GitHub Copilot / ChatGPT แล้วเติมข้อมูลโปรเจกต์:

```
ช่วยสร้างไฟล์ deploy.yml สำหรับ GitHub Actions ให้หน่อย โดย:

1. ดึง template จาก URL นี้:
   https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Deploy-YML-TEMPLATE.yml

2. แทนที่ค่า <-- CHANGE THIS ทุกจุด ด้วยข้อมูลโปรเจกต์ต่อไปนี้:
   - ชื่อโปรเจกต์ (name):          [เช่น Deploy MyApp to IIS]
   - project_path (.csproj):        [เช่น src/MyApp/MyApp.csproj]
   - app_pool (IIS App Pool):       [เช่น MyApp_Pool]
   - deploy_path (path บน server): [เช่น C:\inetpub\wwwroot\MyApp]
   - backup_prefix:                 [เช่น MyApp]
   - runner_label:                  [เช่น my-server-runner]

3. Output เฉพาะ YAML content เท่านั้น พร้อมบันทึกที่ .github/workflows/deploy.yml
```

### วิธีที่ 2 — แก้เองจาก template

1. Copy [`Deploy-YML-TEMPLATE.yml`](Deploy-YML-TEMPLATE.yml) from this repository to your project repository at:

   ```
   .github/workflows/deploy.yml
   ```

2. Edit **only** the values marked `# <-- CHANGE THIS`:

   | Line | What to change |
   |------|----------------|
   | `name:` | Display name shown in the Actions tab |
   | `project_path` | Relative path to your `.csproj` |
   | `app_pool` | IIS Application Pool name |
   | `deploy_path` | Full path on the server |
   | `backup_prefix` | Short identifier for backup files |
   | `runner_label` | Label of the self-hosted runner |

3. Commit and push to the **Deploy** branch to trigger the workflow.

> **Tip:** You do not need to change `dotnet_version` or `backup_keep` unless your project requires it — the defaults (`8.0.x` and `5`) will be used automatically.

---

## Inputs Reference

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `project_path` | ✅ | — | Relative path to `.csproj` from repo root<br>e.g. `src/MyApp/MyApp.csproj` |
| `app_pool` | ✅ | — | IIS Application Pool name<br>e.g. `MyApp_Pool` |
| `deploy_path` | ✅ | — | Full destination path on the server<br>e.g. `C:\inetpub\wwwroot\MyApp` |
| `backup_prefix` | ✅ | — | Prefix for backup archive names<br>e.g. `MyApp` → `MyApp_20260224_153000.zip` |
| `runner_label` | ✅ | — | Label of the self-hosted runner<br>Must match a label in Organization Settings → Runners |
| `dotnet_version` | ❌ | `8.0.x` | .NET SDK version (supports wildcards)<br>e.g. `9.0.x`, `8.0.x` |
| `backup_keep` | ❌ | `5` | Maximum number of backup archives to retain per project |

---

## Real-World Example

Deploy **MyHRApp** (an ASP.NET Core 8 project) to a server whose runner is labelled `hr-server`:

```yaml
# .github/workflows/deploy.yml  (inside the MyHRApp project repository)

name: Deploy MyHRApp to IIS

on:
  push:
    branches:
      - Deploy

jobs:
  call-deploy:
    uses: SDPLaos2023/github-workflows/.github/workflows/deploy-iis-dotnet.yml@main
    with:
      project_path:   'src/MyHRApp/MyHRApp.csproj'
      app_pool:       'MyHRApp_Pool'
      deploy_path:    'C:\inetpub\wwwroot\MyHRApp'
      backup_prefix:  'MyHRApp'
      runner_label:   'hr-server'
      dotnet_version: '8.0.x'
      backup_keep:    7
```

---

## Backup Policy

| Item | Detail |
|------|--------|
| Storage location | `C:\BackupIIS\` on the target server |
| Archive format | ZIP (created with `Compress-Archive`) |
| Naming convention | `<backup_prefix>_YYYYMMDD_HHmmss.zip` |
| Retention | Maximum `backup_keep` files per project (default **5**) |
| Pruning | Oldest archives beyond the limit are deleted automatically after each deploy |
| First deploy | If `deploy_path` does not exist yet, the backup step is skipped (no error) |

Archives are stored locally on the server — they are **not** uploaded to GitHub or any cloud storage.

---

## Troubleshooting

### App Pool does not stop within 30 s

Check for long-running requests or locked files.  Kill worker processes manually in IIS Manager, then re-trigger the workflow.

### robocopy exit code 8+

Exit codes ≥ 8 indicate a copy error (e.g., access denied, disk full).  Review the workflow log for the specific file that failed and verify the runner service account has write permissions to `deploy_path`.

### Verification fails — DLL not found

Ensure `project_path` points to the correct `.csproj` and that `dotnet publish` succeeded.  The DLL name is derived from the `.csproj` filename (e.g., `MyApp.csproj` → `MyApp.dll`).

### Runner offline

On the server, check the runner service:

```powershell
Get-Service actions.runner.*
Start-Service actions.runner.*   # if stopped
```
