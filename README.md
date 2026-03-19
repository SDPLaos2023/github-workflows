# SDPLaos2023 / github-workflows

Centralized GitHub Actions reusable workflows and runner management scripts for the **SDPLaos2023** organization.

---

## สารบัญ

- [ติดตั้ง Runner บน Server ใหม่](#ติดตั้ง-runner-บน-server-ใหม่)
- [สร้าง deploy.yml อัตโนมัติ - .NET](#สร้าง-deployyml-อัตโนมัติ---net)
- [สร้าง deploy-nuxt.yml อัตโนมัติ - Nuxt](#สร้าง-deploy-nuxtyml-อัตโนมัติ---nuxt)
- [ลบ Runner](#ลบ-runner)
- [ไฟล์ Template](#ไฟล์-template)
- [Troubleshooting](#troubleshooting)

---

## ติดตั้ง Runner บน Server ใหม่

เปิด **PowerShell as Administrator** บน server แล้วรัน:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
```

หมายเหตุ:

- ใช้ script นี้สำหรับ **ติดตั้ง / ลบ Runner**
- หลังติดตั้งเสร็จ ให้ไปสร้าง workflow deploy ใน repo ของโปรเจกต์ต่อด้านล่าง

---

## สร้าง deploy.yml อัตโนมัติ - .NET

เปิด **PowerShell** ใน **root folder ของ repo .NET** แล้วรัน:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml.ps1' -UseBasicParsing).Content))
```

ผลลัพธ์:

- สร้างไฟล์ `.github/workflows/deploy.yml`
- หา `.csproj` ให้อัตโนมัติ
- ถ้ามีหลาย `.csproj` จะให้เลือก
- ถ้ามีไฟล์เดิม จะถาม overwrite / backup / cancel

ไฟล์ที่เกี่ยวข้อง:

- [`Generate-DeployYml.ps1`](Generate-DeployYml.ps1)
- [`Deploy-YML-TEMPLATE.yml`](Deploy-YML-TEMPLATE.yml)
- [`.github/workflows/deploy-iis-dotnet.yml`](.github/workflows/deploy-iis-dotnet.yml)

---

## สร้าง deploy-nuxt.yml อัตโนมัติ - Nuxt

เปิด **PowerShell** ใน **root folder ของ repo Nuxt** แล้วรัน:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Generate-DeployYml-Nuxt.ps1' -UseBasicParsing).Content))
```

ผลลัพธ์:

- สร้างไฟล์ `.github/workflows/deploy-nuxt.yml`
- ใช้กับ repo ที่มี `package.json`
- พยายาม detect `package_manager` และ `build_output` ให้อัตโนมัติ
- ถ้ามีไฟล์เดิม จะถาม overwrite / backup / cancel

ไฟล์ที่เกี่ยวข้อง:

- [`Generate-DeployYml-Nuxt.ps1`](Generate-DeployYml-Nuxt.ps1)
- [`Deploy-YML-NUXT-TEMPLATE.yml`](Deploy-YML-NUXT-TEMPLATE.yml)
- [`.github/workflows/deploy-iis-nuxt.yml`](.github/workflows/deploy-iis-nuxt.yml)

---

## ลบ Runner

เปิด **PowerShell as Administrator** บน server แล้วรัน script เดิม:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([ScriptBlock]::Create((Invoke-WebRequest 'https://raw.githubusercontent.com/SDPLaos2023/github-workflows/main/Install-GitHubRunner.ps1' -UseBasicParsing).Content))
```

จากนั้นเลือกเมนู `2`

---

## ไฟล์ Template

- .NET manual template: [`Deploy-YML-TEMPLATE.yml`](Deploy-YML-TEMPLATE.yml)
- Nuxt manual template: [`Deploy-YML-NUXT-TEMPLATE.yml`](Deploy-YML-NUXT-TEMPLATE.yml)

ถ้าต้องการสร้างเองแบบ manual:

- .NET: copy ไปไว้ที่ `.github/workflows/deploy.yml`
- Nuxt: copy ไปไว้ที่ `.github/workflows/deploy-nuxt.yml`

---

## Troubleshooting

### Runner ไม่ขึ้นบน GitHub

```powershell
Get-Service "actions.runner.*"
Start-Service "actions.runner.*"
Get-Content "C:\actions-runner\<repo>\_diag\Runner_*.log" -Tail 50
```

### Service account format ผิด

ต้องใช้รูปแบบ `DOMAIN\username` ไม่ใช่ `.\username`

```powershell
whoami
```

### Nuxt build output ไม่ตรง

ใช้ค่า `build_output` ให้ตรงกับโปรเจกต์ เช่น:

- `.output/public`
- `dist`

### Package manager ไม่ตรงกับ lockfile

- `package-lock.json` → `npm`
- `pnpm-lock.yaml` → `pnpm`
- `yarn.lock` → `yarn`
