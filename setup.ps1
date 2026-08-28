#Requires -Version 5.1
# CANONICAL SOURCE — edit this file, then mirror ke repo publik:
#   github.com/mapan21/ontoken-cli (branch main) — update CHECKSUMS.txt di sana saat file ini berubah.
# (ontoken.id/cli/setup.ps1 kini 308 → raw.githubusercontent.com/mapan21/ontoken-cli/main/setup.ps1)
#
# ON Token — agent tool setup wizard (Windows / PowerShell).
# Points your AI coding agent at ON Token's OpenAI-compatible endpoint
# (https://api.ontoken.id/v1) — and Anthropic-compatible endpoint for Claude Code —
# using your sk-ont- API key.
#
# Highlights:
#   • Menampilkan SEMUA model dari /v1/models (di-fetch live) — pilih default by nomor atau ketik manual.
#   • Bisa input "master model" manual (mis. combo failover bikinanmu sendiri).
#   • Menulis config untuk banyak agent tool — Hermes sebagai prioritas utama.
#   • Tool yang support auto-fetch model (OMP, Hermes) memakai discovery — daftar model
#     selalu terbaru dari endpoint, bukan hardcoded.
#   • Opsi install OMP (oh-my-pi) jika belum punya, lalu set ontoken sebagai provider default.
#   • Idempotent: re-runnable, backup file sebelum edit, hanya replace block bertanda sendiri.
#
# Usage:
#   # Interactive (paling umum untuk Windows):
#   irm https://ontoken.id/cli/setup.ps1 | iex
#
#   # Or, download and run with flags (non-interaktif):
#   irm https://ontoken.id/cli/setup.ps1 -OutFile setup.ps1
#   ./setup.ps1 -Key sk-ont-... -Model qwen3.7-plus -Yes
#   ./setup.ps1 -Key sk-ont-... -Model qwen3.7-plus -Master my-combo -Yes
#   ./setup.ps1 -Key sk-ont-... -InstallOmp -Yes
#
# Safe: idempotent (re-runnable), backs up any file before editing, and only
# appends/overrides ON Token's own marked lines — it never clobbers your existing config.

# Manual arg parsing (compatible with both `irm | iex` and `./setup.ps1 -Key ...`).
# No param() block so it works when piped through Invoke-Expression.
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # speed up Invoke-RestMethod

$ApiKey       = ""
$Model        = ""
$Master       = ""
$AssumeYes    = $false
$InstallOmp   = $false
$BaseUrl      = if ($env:ONTOKEN_BASE_URL) { $env:ONTOKEN_BASE_URL } else { "https://api.ontoken.id" }
$ProviderName = "ontoken"

# Parse $args (populated when run as .ps1; empty when run via iex)
$__i = 0
while ($__i -lt $args.Count) {
    switch ($args[$__i]) {
        '-Key'        { if ($__i + 1 -lt $args.Count) { $ApiKey = $args[$__i + 1]; $__i += 2 } else { $__i++ } }
        '-Model'      { if ($__i + 1 -lt $args.Count) { $Model = $args[$__i + 1]; $__i += 2 } else { $__i++ } }
        '-Master'     { if ($__i + 1 -lt $args.Count) { $Master = $args[$__i + 1]; $__i += 2 } else { $__i++ } }
        '-Base'       { if ($__i + 1 -lt $args.Count) { $BaseUrl = $args[$__i + 1]; $__i += 2 } else { $__i++ } }
        '-Yes'        { $AssumeYes = $true;  $__i++ }
        '-y'          { $AssumeYes = $true;  $__i++ }
        '-InstallOmp' { $InstallOmp = $true; $__i++ }
        '-Help'       { $__help = $true;     $__i++ }
        '-h'          { $__help = $true;     $__i++ }
        Default       { Write-Host "! argumen tidak dikenal: $($args[$__i])" -ForegroundColor Yellow; $__i++ }
    }
}

# ---------- pretty ----------
function Say   { param([string]$m) Write-Host $m }
function Info  { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Ok    { param([string]$m) Write-Host "$([char]0x2713) $m" -ForegroundColor Green }
function Warn  { param([string]$m) Write-Host "! $m" -ForegroundColor Yellow }
function Hdr   { param([string]$m) Write-Host ""; Write-Host "== $m ==" -ForegroundColor White }

function Has {
    param([string]$cmd)
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# Strict charset validation (anti-injection: nilai ditulis ke config files).
function ValidKey {
    param([string]$v)
    return $v -match '^sk-[A-Za-z0-9_-]+$'
}
function ValidModel {
    param([string]$v)
    return $v -match '^[A-Za-z0-9_.-]+$'
}

function Confirm {
    param([string]$prompt)
    if ($AssumeYes) { return $true }
    $a = Read-Host "$prompt [Y/n]"
    if ($a -match '^[nN]') { return $false }
    return $true
}

function Backup {
    param([string]$file)
    if (Test-Path $file) {
        $ts  = Get-Date -Format "yyyyMMddHHmmss"
        $bak = "$file.bak.$ts"
        Copy-Item $file $bak
        Info "  backup: $bak"
    }
}

# Write UTF-8 without BOM (compatible across PS 5.1 and 7).
function WriteFile {
    param([string]$path, [string]$content)
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $content, $enc)
}

# Restrict file permissions to current user only (Windows equivalent of chmod 600).
function RestrictFile {
    param([string]$file)
    if ($file -and (Test-Path $file)) {
        try {
            & icacls $file /inheritance:r /grant:r "$($env:USERNAME):F" 2>$null | Out-Null
        } catch {
            Warn "Gagal restrict izin $file — periksa manual (file berisi API key plaintext)"
        }
    }
}

# Append-or-replace a marked block in a file. Marked so re-runs replace our own
# block instead of duplicating.
function UpsertBlock {
    param([string]$file, [string]$marker, [string]$content)
    $begin = "# >>> ontoken $marker >>>"
    $end   = "# <<< ontoken $marker <<<"
    $dir   = Split-Path $file -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $existing = ""
    if (Test-Path $file) {
        $existing = [System.IO.File]::ReadAllText($file)
    }

    if ($existing -and $existing.Contains($begin)) {
        Backup $file
        $pattern = "(?s)" + [regex]::Escape($begin) + ".*?" + [regex]::Escape($end) + "\r?\n?"
        $existing = [regex]::Replace($existing, $pattern, "")
    }

    $block = "$begin`n$content`n$end`n"
    if ($existing) {
        $existing = $existing.TrimEnd("`r", "`n") + "`n`n"
        WriteFile $file ($existing + $block)
    } else {
        WriteFile $file $block
    }
}

# ---------- help ----------
if ($__help) {
    if ($MyInvocation.MyCommand.Path) {
        (Get-Content $MyInvocation.MyCommand.Path |
            Where-Object { $_ -match '^#' } |
            ForEach-Object { $_ -replace '^# ?','' })
    }
    exit 0
}

# ---------- 1. API key ----------
Hdr "ON Token API key"
if (-not $ApiKey) {
    $ApiKey = Read-Host "Tempel API key (sk-ont-...)"
}
if ($ApiKey -match '^sk-ont-') {
    # ok
} elseif ($ApiKey -match '^sk-') {
    Warn "Key berawalan sk- tapi bukan sk-ont- — tetap lanjut, tapi pastikan benar."
} else {
    Warn "Key tidak diawali sk-ont- — tetap lanjut, tapi pastikan benar."
}
if (-not $ApiKey) { Warn "API key kosong. Batal."; exit 1 }
if (-not (ValidKey $ApiKey)) {
    Warn "API key mengandung karakter tidak valid (hanya A-Za-z0-9_- diizinkan)."
    Warn "Demi keamanan (anti-injection), input ditolak. Batal."
    exit 1
}
Ok "API key diterima"

# ---------- 2. choose model (tampilkan SEMUA, pilih default + master) ----------
Hdr "Pilih model default"
$ApiBase       = "$BaseUrl/v1"
$AnthropicBase = "$BaseUrl/v1"

$modelsResponse = $null
try {
    $modelsResponse = Invoke-RestMethod -Uri "$ApiBase/models" `
        -Headers @{ Authorization = "Bearer $ApiKey" } `
        -TimeoutSec 15 -ErrorAction Stop
} catch {
    $modelsResponse = $null
}

# Extract model ids
$modelList = @()
if ($modelsResponse -and $modelsResponse.data) {
    $modelList = @($modelsResponse.data | ForEach-Object { $_.id } | Select-Object -First 80)
}

if (-not $Model) {
    if ($modelList.Count -gt 0) {
        if ($AssumeYes) {
            $Model = $modelList[0]
            Info "Model default otomatis (non-interaktif): $Model"
        } else {
            Say "Model tersedia di ON Token (di-fetch live — bisa diganti nanti):"
            for ($__j = 0; $__j -lt $modelList.Count; $__j++) {
                Write-Host ("  {0,3}) {1}" -f ($__j + 1), $modelList[$__j]) -ForegroundColor DarkGray
            }
            $pick = Read-Host "Pilih nomor [1], atau ketik nama model (mis. combo buatanmu)"
            if (-not $pick -or $pick -eq "1") {
                $Model = $modelList[0]
            } elseif ($pick -match '^\d+$') {
                $__idx = [int]$pick - 1
                if ($__idx -ge 0 -and $__idx -lt $modelList.Count) {
                    $Model = $modelList[$__idx]
                } else {
                    Warn "Nomor di luar rentang (1-$($modelList.Count)) — pakai model pertama: $($modelList[0])"
                    $Model = $modelList[0]
                }
            } else {
                $Model = $pick
            }
        }
    } else {
        Warn "Tidak bisa fetch daftar model — pakai default qwen3.7-plus"
        $Model = "qwen3.7-plus"
    }
}
if (-not $Model) { $Model = "qwen3.7-plus" }
Ok "Model default: $Model"

# Master model opsional — mis. combo failover custom yang kamu bikin di dashboard.
if (-not $Master -and -not $AssumeYes) {
    Hdr "Master model (opsional)"
    Say "ON Token mendukung combo model — virtual model dengan rantai failover"
    Say "bikinanmu sendiri (buat di halaman Combos dashboard)."
    $Master = Read-Host "Ketik master model combo (kosongkan untuk pakai default '$Model')"
}
if ($Master) {
    Ok "Master model: $Master"
} else {
    Info "Tidak ada master model — default dipakai sebagai model utama."
}

# Model aktif = master jika diisi, selain itu default.
$ActiveModel = if ($Master) { $Master } else { $Model }

# Validasi nama model (anti-injection: nama ditulis ke config files).
if (-not (ValidModel $Model)) {
    Warn "Nama model '$Model' mengandung karakter tidak valid (hanya A-Za-z0-9_.-). Batal."
    exit 1
}
if ($Master -and -not (ValidModel $Master)) {
    Warn "Master model '$Master' mengandung karakter tidak valid. Batal."
    exit 1
}

# Apakah model aktif muncul di daftar /v1/models? Combo custom biasanya TIDAK.
# Dipakai untuk memutuskan apakah perlu menambah entri model eksplisit pada tool
# yang memakai auto-fetch discovery (agar combo tetap selectable).
$activeInCatalog = ($modelList.Count -gt 0) -and ($modelList -contains $ActiveModel)

# ---------- 3. global env (universal fallback) ----------
Hdr "Environment variables (fallback universal)"
Say "Tool yang membaca env standar akan otomatis pakai ini."
Say "Menulis user-level env vars (persisten — terminal baru otomatis pick up)."
# Deteksi env vars yang sudah ada (akan ditimpa).
$_override = @()
if ([Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User')) { $_override += 'OPENAI_API_KEY' }
if ([Environment]::GetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', 'User')) { $_override += 'ANTHROPIC_AUTH_TOKEN' }
if ($_override.Count -gt 0) {
    Warn "Env vars berikut sudah ada dan akan DITIMPA: $($_override -join ' ')"
    $_prompt = "Override & set OPENAI_* + ANTHROPIC_* env vars?"
} else {
    $_prompt = "Set OPENAI_* + ANTHROPIC_* env vars?"
}
if (Confirm $_prompt) {
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY',       $ApiKey,        'User')
    [Environment]::SetEnvironmentVariable('OPENAI_BASE_URL',      $ApiBase,       'User')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_AUTH_TOKEN', $ApiKey,        'User')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL',   $AnthropicBase, 'User')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_MODEL',      $ActiveModel,   'User')
    # also set in current session so tools work immediately
    $env:OPENAI_API_KEY       = $ApiKey
    $env:OPENAI_BASE_URL      = $ApiBase
    $env:ANTHROPIC_AUTH_TOKEN = $ApiKey
    $env:ANTHROPIC_BASE_URL   = $AnthropicBase
    $env:ANTHROPIC_MODEL      = $ActiveModel
    Ok "env vars di-set (buka terminal baru untuk pick up permanen)"
    Warn "API key tersimpan di registry User env — akses terbatas user aktif."
} else {
    Info "skip env global"
}

# ---------- 4. per-tool detection ----------
Hdr "Deteksi agent tools"

# --- Claude Code ---
if ((Has 'claude') -or (Test-Path "$HOME/.claude")) {
    Say "* Claude Code terdeteksi"
    Say "  Claude Code berbicara dialek Anthropic. Sudah diset via env ANTHROPIC_* di atas."
    Say "  (base $AnthropicBase, model $ActiveModel)"
    Ok "Claude Code siap — jalankan 'claude' setelah buka terminal baru"
}

# --- opencode ---
$ocPaths = @("$HOME/.config/opencode/opencode.json", "$HOME/.opencode/opencode.json")
$ocExists = $false
foreach ($p in $ocPaths) { if (Test-Path $p) { $ocExists = $true; break } }
$ocFound = (Has 'opencode') -or $ocExists
if ($ocFound) {
    $oc = $ocPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $oc) { $oc = $ocPaths[0] }
    Say "* opencode terdeteksi ($oc)"
    if (Confirm "  Tulis provider ontoken ke opencode.json?") {
        $ocDir = Split-Path $oc -Parent
        if (-not (Test-Path $ocDir)) { New-Item -ItemType Directory -Path $ocDir -Force | Out-Null }
        if (-not (Test-Path $oc) -or (Get-Item $oc).Length -eq 0) {
            $cfg = [ordered]@{
                '$schema' = 'https://opencode.ai/config.json'
                provider  = [ordered]@{
                    ontoken = [ordered]@{
                        npm     = '@ai-sdk/openai-compatible'
                        options = [ordered]@{ baseURL = $ApiBase; apiKey = $ApiKey }
                        models  = [ordered]@{ $ActiveModel = @{} }
                    }
                }
                model = "ontoken/$ActiveModel"
            }
            $json = $cfg | ConvertTo-Json -Depth 10
            WriteFile $oc $json
        } else {
            Warn "  opencode.json sudah ada — tambahkan provider 'ontoken' manual:"
            Say '    "provider": { "ontoken": {'
            Say '      "npm": "@ai-sdk/openai-compatible",'
            Say "      `"options`": { `"baseURL`": `"$ApiBase`", `"apiKey`": `"$ApiKey`" },"
            Say "      `"models`": { `"$ActiveModel`": {} } } }"
        }
        Ok "opencode dikonfigurasi"
        RestrictFile $oc
    }
}

# --- aider ---
if ((Has 'aider') -or (Test-Path "$HOME/.aider.conf.yml")) {
    $af = "$HOME/.aider.conf.yml"
    Say "* aider terdeteksi ($af)"
    if (Confirm "  Tulis endpoint ke .aider.conf.yml?") {
        $content = "openai-api-base: $ApiBase`nopenai-api-key: $ApiKey`nmodel: openai/$ActiveModel"
        UpsertBlock $af "config" $content
        Ok "aider dikonfigurasi (model prefix openai/)"
        RestrictFile $af
    }
}

# --- hermes (PRIORITAS UTAMA) ---
# Hermes memakai provider custom OpenAI-compatible. Daftar model di-fetch otomatis
# dari endpoint oleh perintah 'hermes model' (auto-discovery) — tidak dihardcode,
# jadi selalu terbaru. User cukup jalankan 'hermes model' untuk lihat & pindah model.
if ((Has 'hermes') -or (Test-Path "$HOME/.hermes")) {
    $hf = "$HOME/.hermes/config.yaml"
    Say "* hermes terdeteksi ($hf) — PRIORITAS UTAMA"
    if (Confirm "  Tulis provider ontoken ke hermes config?") {
        $content = @"
providers:
  ${ProviderName}:
    base_url: $ApiBase
    api_key: $ApiKey
# Daftar model di-fetch otomatis dari endpoint oleh 'hermes model'.
# Lihat & pindah model kapan saja:  hermes model  (pilih dari daftar)  atau  /model <id>
model:
  provider: ${ProviderName}
  default: $ActiveModel
"@
        UpsertBlock $hf "config" $content
        Ok "hermes dikonfigurasi — default: $ActiveModel (daftar model auto-fetch via 'hermes model')"
        RestrictFile $hf
        if ($Master -and $Master -ne $Model) {
            Info "  master model '$Master' dipakai sebagai default."
        }
        Say "  Lihat & ganti semua model: jalankan 'hermes model' (auto-fetch dari endpoint)"
    }
}

# --- open interpreter ---
if ((Has 'interpreter') -or (Test-Path "$HOME/.openinterpreter")) {
    Say "* open interpreter terdeteksi"
    Say "  tambahkan ke ~/.openinterpreter/config.toml:"
    Say '    [model_providers.ontoken]'
    Say "    base_url = `"$ApiBase`""
    Say "    api_key  = `"$ApiKey`""
}

# --- goose ---
if ((Has 'goose') -or (Test-Path "$HOME/.config/goose")) {
    Say "* goose terdeteksi — pakai env OPENAI_BASE_URL/OPENAI_API_KEY (sudah diset)."
}

# --- crush ---
if ((Has 'crush') -or (Test-Path "$HOME/.config/crush")) {
    Say "* crush terdeteksi — tambahkan ke ~/.config/crush/crush.json:"
    Say '    "providers": { "ontoken": {'
    Say "      `"type`": `"openai`", `"base_url`": `"$ApiBase`", `"api_key`": `"$ApiKey`" } }"
}

# --- Cursor / Cline (UI only) ---
$cursor = Test-Path "$HOME/.cursor"
$cline  = $false
$vsExt  = "$HOME/.vscode/extensions"
if (Test-Path $vsExt) {
    $cline = [bool](Get-ChildItem $vsExt -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'cline' })
}
if ($cursor -or $cline) {
    Hdr "Tool ber-UI (konfigurasi manual)"
    if ($cursor) {
        Say "* Cursor: Settings -> Models -> aktifkan 'Override OpenAI Base URL'"
        Say "    Base URL: $ApiBase"
        Say "    API Key : $ApiKey"
    }
    if ($cline) {
        Say "* Cline: Settings -> API Provider -> pilih 'OpenAI Compatible'"
        Say "    Base URL: $ApiBase"
        Say "    API Key : $ApiKey"
    }
}

# ---------- 5. OMP (oh-my-pi) — rekomendasi jika belum ada ----------
Hdr "OMP (oh-my-pi) — agent tool rekomendasi"
$ompInstalled = (Has 'omp') -or (Test-Path "$HOME/.omp")
if ($ompInstalled) {
    Ok "OMP sudah terinstall"
}

if (-not $ompInstalled) {
    Say "Belum ada OMP. OMP adalah coding agent terminal (subagents, LSP, plan mode)."
    Say "Installer: https://omp.sh/install"
    if ($InstallOmp -or (Confirm "Install OMP sekarang dan set ontoken sebagai provider default?")) {
        Info "Menjalankan installer OMP..."
        $ompOk = $false
        # OMP installer is a sh script — need sh/bash (Git Bash, WSL, or native if available).
        if (Has 'curl' -and (Has 'sh' -or Has 'bash')) {
            $shell = if (Has 'sh') { 'sh' } else { 'bash' }
            $tempFile = Join-Path $env:TEMP "omp-install-$([guid]::NewGuid().ToString('N').Substring(0,8)).sh"
            try {
                & curl -fsSL https://omp.sh/install -o $tempFile 2>$null
                & $shell $tempFile
                $ompOk = $true
            } catch { } finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        } elseif (Has 'wsl') {
            Say "  Menggunakan WSL..."
            try {
                & wsl bash -c "curl -fsSL https://omp.sh/install | sh"
                $ompOk = $true
            } catch { }
        } else {
            Warn "OMP installer membutuhkan sh/bash (WSL atau Git Bash)."
            Say "  Manual: install WSL/Git Bash lalu:  curl -fsSL https://omp.sh/install | sh"
            Say "  Atau cek https://omp.sh untuk installer Windows native."
        }
        if ($ompOk) {
            Ok "OMP terinstall"
            $ompInstalled = $true
        } else {
            Warn "Installer OMP gagal — lanjut tanpa install."
        }
    } else {
        Info "skip install OMP"
    }
}

# Tulis config ontoken ke OMP (models.yml) bila OMP ada atau baru diinstall.
# OMP mendukung discovery: type openai-models-list -> fetch model terbaru dari endpoint
# secara otomatis (anti-stale). Combo custom yang tidak muncul di /v1/models tetap
# dijamin selectable dengan menambahkannya sebagai satu entri model eksplisit.
if ($ompInstalled -or (Test-Path "$HOME/.omp")) {
    $ompModels = "$HOME/.omp/agent/models.yml"
    Say "* menulis provider ontoken ke $ompModels (auto-fetch model terbaru via discovery)"
    if (Confirm "  Tulis config ontoken (provider default, auto-fetch model) ke OMP?") {
        # Tambah entri model eksplisit HANYA bila model aktif tidak ada di /v1/models
        # (mis. combo custom). Jika ada di katalog, discovery sudah cukup.
        $ompExtra = ""
        if ($ActiveModel -and -not $activeInCatalog) {
            $ompExtra = "    models:`n      - id: $ActiveModel`n        name: $ActiveModel`n        api: openai-completions`n"
        }
        $content = @"
providers:
  ${ProviderName}:
    baseUrl: $ApiBase
    apiKey: $ApiKey
    api: openai-completions
    authHeader: true
    auth: apiKey
    discovery:
      type: openai-models-list
    compat:
      supportsReasoningParams: true
$ompExtra
"@
        UpsertBlock $ompModels "provider" $content
        Ok "OMP models.yml dikonfigurasi — auto-fetch model terbaru + ontoken sebagai provider"
        RestrictFile $ompModels

        # Set ontoken sebagai default via settings.json (modelRoles.default).
        $ompSettings  = "$HOME/.omp/agent/settings.json"
        $defaultModel = "$ProviderName/$ActiveModel"
        if (-not (Test-Path $ompSettings)) {
            $sDir = Split-Path $ompSettings -Parent
            if (-not (Test-Path $sDir)) { New-Item -ItemType Directory -Path $sDir -Force | Out-Null }
            $json = @{ modelRoles = @{ default = $defaultModel } } | ConvertTo-Json -Depth 10
            WriteFile $ompSettings $json
            Ok "OMP settings.json dibuat — default: $defaultModel"
        } else {
            Backup $ompSettings
            try {
                $settings = [System.IO.File]::ReadAllText($ompSettings) | ConvertFrom-Json
                if (-not $settings.modelRoles) {
                    $settings | Add-Member -NotePropertyName modelRoles -NotePropertyValue @{}
                }
                $settings.modelRoles.default = $defaultModel
                $json = $settings | ConvertTo-Json -Depth 10
                WriteFile $ompSettings $json
                Ok "OMP settings.json diupdate — default: $defaultModel"
            } catch {
                Info "  $ompSettings sudah ada. Set default manual:"
                Say "    jalankan 'omp', lalu /model $defaultModel  (tersimpan sebagai default)"
            }
        }
        Say "  Pindah model di OMP: /model atau 'omp models' (daftar auto-fetch dari endpoint)"
    }
}

# ---------- 6. verify ----------
Hdr "Verifikasi"
Say "Tes endpoint model list..."
try {
    Invoke-RestMethod -Uri "$ApiBase/models" `
        -Headers @{ Authorization = "Bearer $ApiKey" } `
        -TimeoutSec 15 -ErrorAction Stop | Out-Null
    Ok "API key valid — endpoint merespons"
} catch {
    Warn "Verifikasi gagal. Cek key & koneksi. (Bukan error fatal — config tetap ditulis.)"
}

# ---------- 7. done ----------
Hdr "Selesai"
Say "Base URL OpenAI    : $ApiBase"
Say "Base URL Anthropic : $AnthropicBase  (untuk Claude Code)"
Say "Model default      : $Model"
if ($Master) { Say "Master model       : $Master  (dipakai sebagai model aktif)" }
Say "Model aktif        : $ActiveModel"
Say ""
Say "Ganti model kapan saja: edit blok '# >>> ontoken' di config tool, atau jalankan ulang wizard ini."
Info "Docs: https://app.ontoken.id/docs"
