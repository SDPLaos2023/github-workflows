# SDPLaos2023 / github-workflows

Centralized GitHub Actions reusable workflows and runner management scripts for the **SDPLaos2023** organization.

---

## สารบัญ

- [ติดตั้ง Runner บน Server ใหม่](#ติดตั้ง-runner-บน-server-ใหม่) ← **เริ่มต้นที่นี่ (ครั้งแรก)**
- [สร้าง deploy.yml อัตโนมัติ (สคริปต์)](#สร้าง-deployyml-อัตโนมัติ-สคริปต์) ← **ทำต่อในทุกโปรเจกต์**
- [ลบ Runner](#ลบ-runner)
- [สร้าง deploy.yml สำหรับโปรเจกต์ใหม่ (manual)](#สร้าง-deployyml-สำหรับโปรเจกต์ใหม่-manual)
- [Deploy Flow](#deploy-flow)
- [Troubleshooting](#troubleshooting)

---

## ติดตั้ง Runner บน Server ใหม่

เปิด **PowerShell as Administrator** บน server แล้วรันบรรทัดเดียว:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
```

Script จะแสดงเมนู:

```
========================================
  GitHub Runner Manager
  Machine: YOUR-SERVER
========================================

  [1] Install Runner
  [2] Delete Runner

  Enter choice [1/2]:
```

เลือก **1** แล้วกรอกข้อมูลตามที่ถาม:

```
=== [1/3] Project Configuration ===
  GitHub Repo URL   : https://github.com/SDPLaos2023/MyProject
  IIS App Pool name : MyProject
  Deploy path       : C:\inetpub\wwwroot\MyProject

=== [2/3] Server Configuration ===
  Detected  : Domain-joined → SDPLAO
  Suggested : SDPLAO\administrator
  Windows service account : SDPLAO\administrator
  Password for 'SDPLAO\administrator' : ****

=== [3/3] GitHub Credentials ===
  Get your token at: https://github.com/SDPLaos2023/MyProject/settings/actions/runners/new
  Select Windows → copy the value after '--token'
  Registration Token : ****
```

Script จะดำเนินการให้อัตโนมัติ:
1. ตรวจสอบ Administrator
2. เช็ค / อัปเดต Git อัตโนมัติ
3. ตรวจสอบ domain account
4. สร้าง folder (`C:\actions-runner\<repo>`, `C:\BackupIIS`)
5. Download + verify runner
6. Extract + configure + start service

หลังเสร็จ ตรวจสอบ runner สถานะ **Idle** ที่:
```
https://github.com/SDPLaos2023/<repo>/settings/actions/runners
```

### ข้อควรรู้

| หัวข้อ | รายละเอียด |
|---|---|
| Service account | ต้องเป็น `DOMAIN\username` — script detect และแนะนำให้อัตโนมัติ ถ้าใส่ `.\xxx` จะ auto-fix ให้ |
| Registration Token | หมดอายุ 1 ชั่วโมง — ถ้า script หยุดกลางทาง ให้ generate token ใหม่ก่อนรันใหม่ |
| รัน script ซ้ำ | ถ้า runner มีอยู่แล้ว script จะถามว่าจะ reinstall ไหม |
| Git | ถ้าไม่มีหรือเวอร์ชันเก่า script จะ download และ install ให้อัตโนมัติ |

---

## สร้าง deploy.yml อัตโนมัติ (สคริปต์)

> **แนะนำวิธีนี้** — Script จะหา `.csproj` ให้เอง ตั้งค่า default ให้เกือบทั้งหมด และสร้างไฟล์ให้เลยโดยไม่ต้อง copy-paste

### วิธีใช้ (One-Liner)

เปิด **PowerShell** ใน **root folder ของ project** (โฟลเดอร์ที่มี `.git`) แล้วรันบรรทัดนี้:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml.ps1' -UseBasicParsing).Content))
```

Script จะดำเนินการให้อัตโนมัติ:

```
========================================================
  Generate Deploy Workflow
  (.github/workflows/deploy.yml)
  Machine: YOUR-SERVER
========================================================

>>> [1/5] ค้นหา Git repo root...
  [OK] Repo root : C:\src\MyProject

>>> [2/5] ค้นหาไฟล์ .csproj...
  [OK] พบ .csproj : src/MyApp/MyApp.csproj

>>> [3/5] IIS & Runner Settings...
  IIS App Pool name [MyApp_Pool] :
  Deploy path (Windows full path) [C:\inetpub\wwwroot\MyApp] :
  Backup prefix [MyApp] :
  Runner label (ชื่อเครื่อง server ที่ติดตั้ง Runner ไว้) [YOUR-SERVER] :

>>> [4/5] Preview...
  project_path  : src/MyApp/MyApp.csproj
  app_pool      : MyApp_Pool
  deploy_path   : C:\inetpub\wwwroot\MyApp
  backup_prefix : MyApp
  runner_label  : YOUR-SERVER
  backup_keep   : 5 (default)
  branch trigger: Deploy (fixed)

  ดำเนินการต่อ? สร้าง .github/workflows/deploy.yml [Y/n] :

>>> [5/5] สร้างไฟล์ deploy.yml...
  [OK] สร้างไฟล์สำเร็จ : C:\src\MyProject\.github\workflows\deploy.yml
```

### ข้อควรรู้

| หัวข้อ | รายละเอียด |
|---|---|
| รันจากไหน | ต้องรันจาก **root folder ของ project** (ที่มีโฟลเดอร์ `.git`) |
| หลาย .csproj | Script จะแสดงรายการให้เลือก 1 รายการ |
| ค่า default | ทุกค่าจะ suggest อัตโนมัติ — กด Enter เพื่อใช้ค่านั้นทันที |
| deploy.yml มีอยู่แล้ว | Script จะถาม Overwrite / Backup / Cancel |
| Script นี้ vs Runner installer | คนละตัวกัน — **Script นี้สร้าง workflow เท่านั้น** ไม่ติดตั้ง Runner |

### Parameter Mode (ไม่ต้องกรอกทีละช่อง)

```powershell
.\Generate-DeployYml.ps1 `
    -ProjectPath  'src/MyApp/MyApp.csproj' `
    -AppPool      'MyApp_Pool' `
    -DeployPath   'C:\inetpub\wwwroot\MyApp' `
    -BackupPrefix 'MyApp' `
    -RunnerLabel  'MY-SERVER' `
    -Force
```

---

## ลบ Runner

รัน script เดิม แล้วเลือก **[2] Delete Runner**:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
```

```
=== Installed GitHub Runners on this machine ===

  [1] actions.runner.SDPLaos2023-SDP_WEB_AUTOBACKUP.TDP-IMMIGRATION
      Status: Running
      Repo  : SDPLaos2023/SDP_WEB_AUTOBACKUP
      Root  : C:\actions-runner\SDP_WEB_AUTOBACKUP

Select runner to remove [1-1]: 1
```

Script จะถามหา Remove Token เพื่อ deregister จาก GitHub:

```
  Get token at: https://github.com/SDPLaos2023/SDP_WEB_AUTOBACKUP/settings/actions/runners
  Click [...] next to the runner → Remove → copy the token

  Remove Token (press Enter to skip = local removal only): ****
```

- **ใส่ token** → ลบออกจาก GitHub + ลบ service + ลบ files
- **กด Enter ข้าม** → ลบ service + ลบ files เฉยๆ (ต้องไปลบเองที่ GitHub Settings)

---

## สร้าง deploy.yml สำหรับโปรเจกต์ใหม่ (manual)

> วิธีนี้ใช้ในกรณีที่ต้องการ copy template ด้วยตนเอง — ถ้าต้องการให้สร้างให้อัตโนมัติ ดูหัวข้อ [สร้าง deploy.yml อัตโนมัติ (สคริปต์)](#สร้าง-deployyml-อัตโนมัติ-สคริปต์) ด้านบน

Copy [`Deploy-YML-TEMPLATE.yml`](Deploy-YML-TEMPLATE.yml) ไปไว้ที่ `.github/workflows/deploy.yml` ในโปรเจกต์ แล้วแก้ค่าที่ marked `# <-- CHANGE THIS`:

| ค่า | ตัวอย่าง |
|---|---|
| `project_path` | `src/MyApp/MyApp.csproj` |
| `app_pool` | `MyApp_Pool` |
| `deploy_path` | `C:\inetpub\wwwroot\MyApp` |
| `backup_prefix` | `MyApp` |
| `runner_label` | ชื่อ runner (ค่าเดียวกับ `RunnerName` ตอนติดตั้ง = COMPUTERNAME) |

### วิธีดูค่า `project_path` (กันงง)

- ใช้ **path แบบ relative จาก root ของ repo** ไปหาไฟล์ `.csproj`
- ถ้า repo มี `src/MyApp/MyApp.csproj` ให้ใส่ `src/MyApp/MyApp.csproj`
- ถ้า repo มี `Tagat/Tagat.csproj` ให้ใส่ `Tagat/Tagat.csproj`
- ห้ามใส่ path เต็มเครื่อง เช่น `C:\Users\Admin\Documents\...`

### Template: `.github/workflows/deploy.yml`

```yaml
# ============================================================
# NEW PROJECT DEPLOY TEMPLATE
# Instructions:
#   1. Copy this file into your project repo at:
#        .github/workflows/deploy.yml
#   2. Replace every value marked with  <-- CHANGE THIS
#   3. Commit and push to the "Deploy" branch to trigger
# ============================================================

name: Deploy to IIS   # <-- CHANGE THIS  (display name shown in Actions tab)

on:
  push:
    branches:
      - Deploy          # trigger only when commits land on the Deploy branch

jobs:
  call-deploy:
    # Delegate all work to the shared reusable workflow in the central repo
    uses: SDPLaos2023/github-workflows/.github/workflows/deploy-iis-dotnet.yml@main

    with:
      # ---- REQUIRED inputs -----------------------------------------------

      # Relative path to your .csproj from the root of THIS repository
      # How to read it:
      #   Repo root + src/MyApp/MyApp.csproj -> project_path: 'src/MyApp/MyApp.csproj'
      #   Repo root + Tagat/Tagat.csproj     -> project_path: 'Tagat/Tagat.csproj'
      # Do NOT put absolute path like C:\Users\Admin\...\Tagat.csproj
      project_path: 'src/MyApp/MyApp.csproj'   # <-- CHANGE THIS

      # Exact name of the IIS Application Pool on the target server
      # Find it in IIS Manager > Application Pools
      app_pool: 'MyApp_Pool'                    # <-- CHANGE THIS

      # Full filesystem path on the server where IIS serves the app
      # This folder will be wiped and replaced on every deploy
      deploy_path: 'C:\inetpub\wwwroot\MyApp'  # <-- CHANGE THIS

      # Short identifier used as a prefix for backup archive names
      # Allowed characters: letters, digits, hyphens, underscores
      # Result example: MyApp_20260224_153000.zip
      backup_prefix: 'MyApp'                    # <-- CHANGE THIS

      # Label of the self-hosted GitHub Actions runner attached to the
      # target Windows server.  Must match a label configured in:
      #   GitHub > Settings > Actions > Runners
      runner_label: 'my-server-runner'          # <-- CHANGE THIS

      # ---- OPTIONAL inputs (defaults shown — remove line to use default) ---

      # Number of backup archives to keep in C:\BackupIIS for this project.
      # Oldest archives beyond this count are deleted automatically.
      # Default: 5
      backup_keep: 5
```

หรือใช้ AI สร้างให้:

```
ช่วยสร้างไฟล์ deploy.yml จาก template:
https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Deploy-YML-TEMPLATE.yml

แทนค่า <-- CHANGE THIS ด้วย:
- project_path:  src/MyApp/MyApp.csproj
- app_pool:      MyApp_Pool
- deploy_path:   C:\inetpub\wwwroot\MyApp
- backup_prefix: MyApp
- runner_label:  MY-SERVER
```

---

## Deploy Flow

```
push to "Deploy" branch
        │
        ▼
GitHub Actions (project repo)
        │  calls reusable workflow
        ▼
SDPLaos2023/github-workflows
deploy-iis-dotnet.yml@main
        │
  1. Checkout
  2. dotnet restore
  3. dotnet publish → ./publish/
  4. Clean publish output (.github, obj, bin)
  5. Backup current deploy → C:\BackupIIS\<prefix>_YYYYMMDD_HHmmss.zip
  6. Stop IIS App Pool
  7. robocopy publish/ → deploy_path
  8. Start IIS App Pool
  9. Verify (pool Started + .dll exists)
        │
        ▼
     Done
```

**Backup retention:** เก็บ 5 ไฟล์ล่าสุดต่อโปรเจกต์ (ปรับได้ด้วย `backup_keep`)

---

## Troubleshooting

### Runner ไม่ขึ้น Idle บน GitHub

```powershell
# ดูสถานะ service
Get-Service "actions.runner.*"

# Start ถ้า Stopped
Start-Service "actions.runner.*"

# ดู log
Get-Content "C:\actions-runner\<repo>\_diag\Runner_*.log" -Tail 50
```

### ติดตั้ง runner แล้ว error "identity references could not be translated"

Service account format ผิด — ต้องระบุเป็น `DOMAIN\username` ไม่ใช่ `.\username`

```powershell
whoami  # ดูว่า domain จริงๆ คืออะไร เช่น sdplao\administrator
```

แล้วรัน script ใหม่ ใส่ค่าที่ถูกต้อง (script จะ detect และแนะนำให้อัตโนมัติ)

### Registration Token หมดอายุ

Token มีอายุ 1 ชั่วโมง ถ้า script ค้างนานแล้วใส่ token ไม่ผ่าน:
1. ไปที่ `https://github.com/<org>/<repo>/settings/actions/runners/new`
2. Generate token ใหม่
3. รัน script ใหม่ (folder ที่สร้างค้างไว้จะถูก skip หรือถามว่า reinstall)

### Deploy ล้มเหลว — App Pool ไม่หยุดใน 30 วินาที

App Pool มี long-running request หรือ locked file — kill worker process ด้วยตนเองใน IIS Manager แล้ว re-trigger workflow

### Deploy ล้มเหลว — robocopy exit code 8+

```powershell
# เช็ค permission ของ deploy_path
Get-Acl "C:\inetpub\wwwroot\MyApp" | Format-List
```

Service account ของ runner ต้องมี **FullControl** บน `deploy_path`

### Verify ล้มเหลว — DLL not found

- ตรวจสอบว่า `project_path` ชี้ไปที่ `.csproj` ที่ถูกต้อง
- ชื่อ DLL มาจากชื่อไฟล์ `.csproj` เช่น `MyApp.csproj` → `MyApp.dll`

### เช็คค่าต่างๆ ของ runner ที่ติดตั้งอยู่

```powershell
# ดู runner ทั้งหมดในเครื่อง
Get-Service "actions.runner.*" | Select-Object Name, Status

# ดู config ของ runner
Get-Content "C:\actions-runner\<repo>\.runner" | ConvertFrom-Json
```
