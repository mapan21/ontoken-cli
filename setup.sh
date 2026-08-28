#!/usr/bin/env bash
# CANONICAL SOURCE — edit this file, then: cp cli/setup.sh apps/web-marketing/public/cli/setup.sh
# (apps/web-marketing/public/cli/ is the served copy at https://ontoken.id/cli/setup.sh)
#
# ON Token — agent tool setup wizard (macOS / Linux).
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
#   • Opsi install OMP (oh-my-pi) — HANYA bila flag --install-omp diberikan eksplisit
#     (opt-in). Tanpa flag, wizard hanya mencetak instruksi manual (tidak menjalankan
#     installer pihak ketiga). Lalu set ontoken sebagai provider default.
#   • Idempotent: re-runnable, backup file sebelum edit, hanya replace block bertanda sendiri.
#
# Usage:
#   curl -fsSL https://ontoken.id/cli/setup.sh | bash
#   # or, with flags (non-interaktif):
#   bash setup.sh --key sk-ont-... --model qwen3.7-plus --yes
#   bash setup.sh --key sk-ont-... --model qwen3.7-plus --master my-combo --yes
#   bash setup.sh --key sk-ont-... --install-omp --yes
#
# Safe: idempotent (re-runnable), backs up any file before editing, and only
# appends/overrides ON Token's own marked lines — it never clobbers your existing config.

set -euo pipefail

BASE_URL="${ONTOKEN_BASE_URL:-https://api.ontoken.id}"
API_BASE="$BASE_URL/v1"
ANTHROPIC_BASE="$BASE_URL/v1"   # Claude Code appends /messages automatically
API_KEY=""
MODEL=""          # model default (dipilih dari daftar / diketik manual)
MASTER_MODEL=""   # model "master" manual opsional (mis. combo failover custom)
ASSUME_YES=0
INSTALL_OMP=0
PROVIDER_NAME="ontoken"   # nama provider di config tiap tool

# ---------- pretty ----------
if [ -t 1 ]; then
  B=$(printf '\033[1m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  C=$(printf '\033[36m'); R=$(printf '\033[0m'); M=$(printf '\033[90m')
else B=""; G=""; Y=""; C=""; R=""; M=""; fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$C" "$*" "$R"; }
ok()   { printf '%s✓%s %s\n' "$G" "$R" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$R" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$R"; }

# ---------- args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --key)        API_KEY="${2:-}"; shift 2;;
    --model)      MODEL="${2:-}"; shift 2;;
    --master)     MASTER_MODEL="${2:-}"; shift 2;;
    --yes|-y)     ASSUME_YES=1; shift;;
    --base)       BASE_URL="${2:-}"; API_BASE="$BASE_URL/v1"; ANTHROPIC_BASE="$BASE_URL/v1"; shift 2;;
    --install-omp) INSTALL_OMP=1; shift;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) warn "argumen tidak dikenal: $1"; shift;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# Strict charset validation (anti-injection: nilai ditulis ke rc file & config files).
valid_key()   { printf '%s' "$1" | grep -qxE 'sk-[A-Za-z0-9_-]+'; }
valid_model() { printf '%s' "$1" | grep -qxE '[A-Za-z0-9_.-]+'; }

confirm() { # confirm <prompt> -> 0 yes / 1 no
  [ "$ASSUME_YES" = "1" ] && return 0
  local a
  printf '%s [Y/n] ' "$1" >/dev/tty; read -r a </dev/tty 2>/dev/null || a="y"
  case "$a" in [nN]*) return 1;; *) return 0;; esac
}

backup() { # backup <file>
  [ -f "$1" ] || return 0
  cp "$1" "$1.bak.$(date +%s)" && info "  backup: $1.bak.*" || true
}

lockdown() { # lockdown <file> — restrict perms on credential file (chmod 600)
  chmod 600 "$1" 2>/dev/null || warn "  Gagal chmod 600 $1 — periksa izin manual (file berisi API key plaintext)"
}

# Mask API key untuk output stdout: hanya tampilkan 4 char terakhir (sk-ont-…XXXX).
# Mencegah key utuh tercetak ke terminal/log. Salin key utuh dari dashboard ON Token.
mask_key() { # mask_key <key> -> sk-ont-…XXXX
  local k="$1"
  if [ ${#k} -le 4 ]; then
    printf '%s' "$k"
  else
    printf 'sk-ont-…%s' "${k: -4}"
  fi
}

# Append-or-replace a marked block in a file. Marked so re-runs replace our own
# block instead of duplicating. Usage: upsert_block <file> <marker> <content>
upsert_block() {
  local file="$1" marker="$2" content="$3"
  local begin="# >>> ontoken $marker >>>" end="# <<< ontoken $marker <<<"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -qF "$begin" "$file" 2>/dev/null; then
    backup "$file"
    # delete existing marked block, then append fresh
    sed -i.tmp "/$(printf '%s' "$begin" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$end" | sed 's/[][\.*^$/]/\\&/g')/d" "$file" && rm -f "$file.tmp"
  fi
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$file"
}

# ---------- 1. API key ----------
hdr "ON Token API key"
if [ -z "$API_KEY" ]; then
  printf 'Tempel API key (sk-ont-...): ' >/dev/tty
  read -r API_KEY </dev/tty 2>/dev/null || API_KEY=""
fi
case "$API_KEY" in
  sk-ont-*) : ;;
  sk-*) warn "Key berawalan sk- tapi bukan sk-ont- — tetap lanjut, tapi pastikan benar.";;
  *) warn "Key tidak diawali sk-ont- — tetap lanjut, tapi pastikan benar.";;
esac
[ -z "$API_KEY" ] && { warn "API key kosong. Batal."; exit 1; }
# Strict charset validation — key ditulis plaintext ke rc file & config files.
# Hanya A-Za-z0-9_- diizinkan setelah prefix 'sk-' (mencegah shell injection).
if ! valid_key "$API_KEY"; then
  warn "API key mengandung karakter tidak valid (hanya A-Za-z0-9_- diizinkan)."
  warn "Demi keamanan (anti-injection), input ditolak. Batal."
  exit 1
fi
ok "API key diterima"

# ---------- 2. choose model (tampilkan SEMUA, pilih default + master) ----------
hdr "Pilih model default"
MODELS_JSON=""
if have curl; then
  MODELS_JSON=$(curl -fsSL --max-time 15 -H "Authorization: Bearer $API_KEY" "$API_BASE/models" 2>/dev/null || true)
fi
# extract model ids
MODEL_LIST=$(printf '%s' "$MODELS_JSON" \
  | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//' \
  | head -80 || true)

if [ -z "$MODEL" ]; then
  if [ -n "$MODEL_LIST" ]; then
    if [ "$ASSUME_YES" = "1" ]; then
      # Non-interaktif: ambil model pertama tanpa prompt.
      MODEL=$(printf '%s\n' "$MODEL_LIST" | sed -n '1p')
      info "Model default otomatis (non-interaktif): $MODEL"
    else
      say "Model tersedia di ON Token (di-fetch live — bisa diganti nanti):"
      i=1
      printf '%s\n' "$MODEL_LIST" | while IFS= read -r m; do
        printf '  %s%2d)%s %s\n' "$M" "$i" "$R" "$m"; i=$((i+1))
      done
      printf 'Pilih nomor [1], atau ketik nama model (mis. combo buatanmu): ' >/dev/tty
      read -r pick </dev/tty 2>/dev/null || pick="1"
      if [ -z "$pick" ] || [ "$pick" = "1" ]; then
        MODEL=$(printf '%s\n' "$MODEL_LIST" | sed -n '1p')
      elif printf '%s' "$pick" | grep -qE '^[0-9]+$'; then
        MODEL=$(printf '%s\n' "$MODEL_LIST" | sed -n "${pick}p")
      else
        MODEL="$pick"
      fi
    fi
  else
    warn "Tidak bisa fetch daftar model — pakai default qwen3.7-plus"
    MODEL="qwen3.7-plus"
  fi
fi
[ -z "$MODEL" ] && MODEL="qwen3.7-plus"
ok "Model default: $MODEL"

# Master model opsional — mis. combo failover custom yang kamu bikin di dashboard.
if [ -z "$MASTER_MODEL" ] && [ "$ASSUME_YES" != "1" ]; then
  hdr "Master model (opsional)"
  say "ON Token mendukung ${B}combo model${R} — virtual model dengan rantai failover"
  say "bikinanmu sendiri (buat di halaman Combos dashboard)."
  printf 'Ketik master model combo (kosongkan untuk pakai default "%s"): ' "$MODEL" >/dev/tty
  read -r MASTER_MODEL </dev/tty 2>/dev/null || MASTER_MODEL=""
fi
if [ -n "$MASTER_MODEL" ]; then
  ok "Master model: $MASTER_MODEL"
else
  info "Tidak ada master model — default dipakai sebagai model utama."
fi

# Model aktif = master jika diisi, selain itu default.
ACTIVE_MODEL="${MASTER_MODEL:-$MODEL}"

# Validasi nama model (anti-injection: nama ditulis ke config files).
if ! valid_model "$MODEL"; then
  warn "Nama model '$MODEL' mengandung karakter tidak valid (hanya A-Za-z0-9_.- diizinkan). Batal."
  exit 1
fi
if [ -n "$MASTER_MODEL" ] && ! valid_model "$MASTER_MODEL"; then
  warn "Master model '$MASTER_MODEL' mengandung karakter tidak valid. Batal."
  exit 1
fi

# Apakah model aktif muncul di daftar /v1/models? Combo custom biasanya TIDAK.
# Dipakai untuk memutuskan apakah perlu menambah entri model eksplisit pada tool
# yang memakai auto-fetch discovery (agar combo tetap selectable).
active_in_catalog() {
  [ -n "$MODEL_LIST" ] && printf '%s\n' "$MODEL_LIST" | grep -qxF "$ACTIVE_MODEL"
}

# ---------- 3. global env (universal fallback) ----------
hdr "Environment variables (fallback universal)"
SHELL_RC=""
case "${SHELL:-}" in
  */zsh)  SHELL_RC="$HOME/.zshrc";;
  */bash) SHELL_RC="$HOME/.bashrc";;
  *)      SHELL_RC="$HOME/.profile";;
esac
say "Tool yang membaca env standar akan otomatis pakai ini."
say "Target file: $SHELL_RC"
# Deteksi env vars yang sudah ada (akan ditimpa).
_OVERRIDE=""
[ -n "${OPENAI_API_KEY:-}" ] && _OVERRIDE="$_OVERRIDE OPENAI_API_KEY"
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && _OVERRIDE="$_OVERRIDE ANTHROPIC_AUTH_TOKEN"
[ -f "$SHELL_RC" ] && grep -qE '^[[:space:]]*export OPENAI_API_KEY=' "$SHELL_RC" 2>/dev/null && _OVERRIDE="$_OVERRIDE OPENAI_API_KEY(rc)"
[ -f "$SHELL_RC" ] && grep -qE '^[[:space:]]*export ANTHROPIC_AUTH_TOKEN=' "$SHELL_RC" 2>/dev/null && _OVERRIDE="$_OVERRIDE ANTHROPIC_AUTH_TOKEN(rc)"
if [ -n "$_OVERRIDE" ]; then
  warn "Env vars berikut sudah ada dan akan DITIMPA:$_OVERRIDE"
  _PROMPT="Override & tulis OPENAI_* + ANTHROPIC_* env ke $SHELL_RC?"
else
  _PROMPT="Tulis OPENAI_* + ANTHROPIC_* env ke $SHELL_RC?"
fi
if confirm "$_PROMPT"; then
  upsert_block "$SHELL_RC" "env" "$(cat <<EOF
export OPENAI_API_KEY="$API_KEY"
export OPENAI_BASE_URL="$API_BASE"
export ANTHROPIC_AUTH_TOKEN="$API_KEY"
export ANTHROPIC_BASE_URL="$ANTHROPIC_BASE"
export ANTHROPIC_MODEL="$ACTIVE_MODEL"
EOF
)"
  lockdown "$SHELL_RC"
  ok "env ditulis ke $SHELL_RC (buka terminal baru / 'source $SHELL_RC')"
  warn "API key tersimpan plaintext di $SHELL_RC — file di-chmod 600 (hanya pemilik). Jangan share."
else
  info "skip env global"
fi

# ---------- 4. per-tool detection ----------
hdr "Deteksi agent tools"

# --- Claude Code ---
if have claude || [ -d "$HOME/.claude" ]; then
  say "• Claude Code terdeteksi"
  say "  Claude Code berbicara dialek Anthropic. Sudah diset via env ANTHROPIC_* di atas."
  say "  ${M}(base $ANTHROPIC_BASE, model $ACTIVE_MODEL)${R}"
  ok "Claude Code siap — jalankan 'claude' setelah source env"
fi

# --- opencode ---
if have opencode || [ -d "$HOME/.config/opencode" ]; then
  OC="$HOME/.config/opencode/opencode.json"
  say "• opencode terdeteksi ($OC)"
  if confirm "  Tulis provider ontoken ke opencode.json?"; then
    backup "$OC"
    mkdir -p "$(dirname "$OC")"
    if [ ! -s "$OC" ]; then
      cat > "$OC" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ontoken": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "$API_BASE", "apiKey": "$API_KEY" },
      "models": { "$ACTIVE_MODEL": {} }
    }
  },
  "model": "ontoken/$ACTIVE_MODEL"
}
EOF
    else
      warn "  opencode.json sudah ada — tambahkan provider 'ontoken' manual:"
      cat <<EOF
    "provider": { "ontoken": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "$API_BASE", "apiKey": "$API_KEY" },
      "models": { "$ACTIVE_MODEL": {} } } }
EOF
    fi
    ok "opencode dikonfigurasi"
    lockdown "$OC"
  fi
fi

# --- aider ---
if have aider || [ -f "$HOME/.aider.conf.yml" ]; then
  AF="$HOME/.aider.conf.yml"
  say "• aider terdeteksi ($AF)"
  if confirm "  Tulis endpoint ke .aider.conf.yml?"; then
    upsert_block "$AF" "config" "$(cat <<EOF
openai-api-base: $API_BASE
openai-api-key: $API_KEY
model: openai/$ACTIVE_MODEL
EOF
)"
    ok "aider dikonfigurasi (model prefix openai/)"
    lockdown "$AF"
  fi
fi

# --- hermes (PRIORITAS UTAMA) ---
# Hermes memakai provider custom OpenAI-compatible. Daftar model di-fetch otomatis
# dari endpoint oleh perintah 'hermes model' (auto-discovery) — tidak dihardcode,
# jadi selalu terbaru. User cukup jalankan 'hermes model' untuk lihat & pindah model.
if have hermes || [ -d "$HOME/.hermes" ]; then
  HF="$HOME/.hermes/config.yaml"
  say "• hermes terdeteksi ($HF) — ${B}prioritas utama${R}"
  if confirm "  Tulis provider ontoken ke hermes config?"; then
    upsert_block "$HF" "config" "$(cat <<EOF
providers:
  $PROVIDER_NAME:
    base_url: $API_BASE
    api_key: $API_KEY
# Daftar model di-fetch otomatis dari endpoint oleh 'hermes model'.
# Lihat & pindah model kapan saja:  hermes model  (pilih dari daftar)  atau  /model <id>
model:
  provider: $PROVIDER_NAME
  default: $ACTIVE_MODEL
EOF
)"
    ok "hermes dikonfigurasi — default: $ACTIVE_MODEL (daftar model auto-fetch via 'hermes model')"
    lockdown "$HF"
    if [ -n "$MASTER_MODEL" ] && [ "$MASTER_MODEL" != "$MODEL" ]; then
      info "  master model '$MASTER_MODEL' dipakai sebagai default."
    fi
    say "  ${M}Lihat & ganti semua model: jalankan 'hermes model' (auto-fetch dari endpoint)${R}"
  fi
fi

# --- open interpreter ---
if have interpreter || [ -d "$HOME/.openinterpreter" ]; then
  say "• open interpreter terdeteksi"
  say "  tambahkan ke ~/.openinterpreter/config.toml:"
  cat <<EOF
    [model_providers.ontoken]
    base_url = "$API_BASE"
    api_key  = "$API_KEY"
EOF
fi

# --- goose ---
if have goose || [ -d "$HOME/.config/goose" ]; then
  say "• goose terdeteksi — pakai env OPENAI_BASE_URL/OPENAI_API_KEY (sudah diset)."
fi

# --- crush ---
if have crush || [ -d "$HOME/.config/crush" ]; then
  say "• crush terdeteksi — tambahkan ke ~/.config/crush/crush.json:"
  cat <<EOF
    "providers": { "ontoken": {
      "type": "openai", "base_url": "$API_BASE", "api_key": "$API_KEY" } }
EOF
fi

# --- Cursor / Cline (UI only) ---
CURSOR=0; CLINE=0
[ -d "$HOME/.cursor" ] && CURSOR=1
if [ -d "$HOME/.vscode/extensions" ] && ls "$HOME/.vscode/extensions" 2>/dev/null | grep -qi cline; then CLINE=1; fi
if [ "$CURSOR" = "1" ] || [ "$CLINE" = "1" ]; then
  hdr "Tool ber-UI (konfigurasi manual)"
  [ "$CURSOR" = "1" ] && { say "• Cursor: Settings → Models → aktifkan 'Override OpenAI Base URL'"; say "    Base URL: $API_BASE"; say "    API Key : $(mask_key "$API_KEY")  (salin key utuh dari dashboard ON Token)"; }
  [ "$CLINE" = "1" ] && { say "• Cline: Settings → API Provider → pilih 'OpenAI Compatible'"; say "    Base URL: $API_BASE"; say "    API Key : $(mask_key "$API_KEY")  (salin key utuh dari dashboard ON Token)"; }
fi

# ---------- 5. OMP (oh-my-pi) — rekomendasi jika belum ada ----------
hdr "OMP (oh-my-pi) — agent tool rekomendasi"
OMP_INSTALLED=0
if have omp || [ -d "$HOME/.omp" ]; then
  OMP_INSTALLED=1
  ok "OMP sudah terinstall"
fi

if [ "$OMP_INSTALLED" = "0" ]; then
  say "Belum ada OMP. OMP adalah coding agent terminal (subagents, LSP, plan mode)."
  say "Installer: https://omp.sh/install"
  if [ "$INSTALL_OMP" = "1" ]; then
    info "Menjalankan installer OMP (--install-omp diberikan eksplisit)..."
    if have curl; then
      # Installer resmi OMP — pipa ke sh. HANYA bila --install-omp eksplisit;
      # tidak pernah otomatis (anti social-engineering: installer pihak ketiga
      # butuh keputusan sadar, bukan auto-yes dari --yes).
      if curl -fsSL https://omp.sh/install | sh; then
        ok "OMP terinstall"
        OMP_INSTALLED=1
        # pastikan binary di PATH untuk sesi ini
        [ -d "$HOME/.local/bin" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) :;; *) export PATH="$HOME/.local/bin:$PATH";; esac
      else
        warn "Installer OMP gagal — lanjut tanpa install. Coba manual: curl -fsSL https://omp.sh/install | sh"
      fi
    else
      warn "curl tidak ada — skip install OMP. Manual: curl -fsSL https://omp.sh/install | sh"
    fi
  else
    info "OMP tidak diinstall otomatis (opt-in). Untuk memasang OMP, jalankan installer resmi secara manual:"
    say "    curl -fsSL https://omp.sh/install | sh"
    say "  atau jalankan ulang wizard ini dengan flag --install-omp."
  fi
fi

# Tulis config ontoken ke OMP (models.yml) bila OMP ada atau baru diinstall.
# OMP mendukung discovery: type openai-models-list → fetch model terbaru dari endpoint
# secara otomatis (anti-stale). Combo custom yang tidak muncul di /v1/models tetap
# dijamin selectable dengan menambahkannya sebagai satu entri model eksplisit.
if [ "$OMP_INSTALLED" = "1" ] || [ -d "$HOME/.omp" ]; then
  OMP_MODELS="$HOME/.omp/agent/models.yml"
  say "• menulis provider ontoken ke $OMP_MODELS (auto-fetch model terbaru via discovery)"
  if confirm "  Tulis config ontoken (provider default, auto-fetch model) ke OMP?"; then
    # Tambah entri model eksplisit HANYA bila model aktif tidak ada di /v1/models
    # (mis. combo custom). Jika ada di katalog, discovery sudah cukup — tidak perlu
    # hardcode apa-apa.
    OMP_EXTRA_MODELS=""
    if [ -n "$ACTIVE_MODEL" ] && ! active_in_catalog; then
      OMP_EXTRA_MODELS="    models:
      - id: $ACTIVE_MODEL
        name: $ACTIVE_MODEL
        api: openai-completions
"
    fi
    upsert_block "$OMP_MODELS" "provider" "$(cat <<EOF
providers:
  $PROVIDER_NAME:
    baseUrl: $API_BASE
    apiKey: $API_KEY
    api: openai-completions
    authHeader: true
    auth: apiKey
    discovery:
      type: openai-models-list
    compat:
      supportsReasoningParams: true
$OMP_EXTRA_MODELS
EOF
)"
    ok "OMP models.yml dikonfigurasi — auto-fetch model terbaru + ontoken sebagai provider"
    lockdown "$OMP_MODELS"

    # Set ontoken sebagai default via settings.json (modelRoles.default) bila memungkinkan.
    OMP_SETTINGS="$HOME/.omp/agent/settings.json"
    if [ ! -f "$OMP_SETTINGS" ]; then
      mkdir -p "$(dirname "$OMP_SETTINGS")"
      cat > "$OMP_SETTINGS" <<EOF
{
  "modelRoles": { "default": "$PROVIDER_NAME/$ACTIVE_MODEL" }
}
EOF
      ok "OMP settings.json dibuat — default: $PROVIDER_NAME/$ACTIVE_MODEL"
    elif have jq; then
      backup "$OMP_SETTINGS"
      jq --arg d "$PROVIDER_NAME/$ACTIVE_MODEL" '.modelRoles.default = $d' "$OMP_SETTINGS" > "$OMP_SETTINGS.tmp" \
        && mv "$OMP_SETTINGS.tmp" "$OMP_SETTINGS"
      ok "OMP settings.json diupdate — default: $PROVIDER_NAME/$ACTIVE_MODEL"
    else
      info "  $OMP_SETTINGS sudah ada (jq tidak tersedia). Set default manual:"
      say "    jalankan 'omp', lalu /model $PROVIDER_NAME/$ACTIVE_MODEL  (tersimpan sebagai default)"
    fi
    say "  ${M}Pindah model di OMP: /model atau 'omp models' (daftar auto-fetch dari endpoint)${R}"
  fi
fi

# ---------- 6. verify ----------
hdr "Verifikasi"
if have curl; then
  say "Tes endpoint model list..."
  if curl -fsSL --max-time 15 -H "Authorization: Bearer $API_KEY" "$API_BASE/models" >/dev/null 2>&1; then
    ok "API key valid — endpoint merespons"
  else
    warn "Verifikasi gagal. Cek key & koneksi. (Bukan error fatal — config tetap ditulis.)"
  fi
fi

# ---------- 7. done ----------
hdr "Selesai"
say "Base URL OpenAI    : $API_BASE"
say "Base URL Anthropic : $ANTHROPIC_BASE  (untuk Claude Code)"
say "Model default      : $MODEL"
[ -n "$MASTER_MODEL" ] && say "Master model       : $MASTER_MODEL  (dipakai sebagai model aktif)"
say "Model aktif        : $ACTIVE_MODEL"
say ""
say "Ganti model kapan saja: edit blok '# >>> ontoken' di config tool, atau jalankan ulang wizard ini."
info "Docs: https://app.ontoken.id/docs"
