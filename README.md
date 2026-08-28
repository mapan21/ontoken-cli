# ON Token — CLI Setup Scripts

Installer resmi untuk menghubungkan CLI/agent coding favoritmu ke **ON Token**
(`https://ontoken.id`) — gateway OpenAI/Anthropic-compatible untuk model AI.

## Isi repo

| File | Fungsi |
|---|---|
| `setup.sh` | Installer interaktif macOS/Linux (bash) |
| `setup.ps1` | Installer interaktif Windows (PowerShell) |
| `CHECKSUMS.txt` | Checksum SHA-256 resmi setiap installer |

## Transparansi (baca sebelum menjalankan)

Kami percaya installer harus bisa diaudit. Inilah persis yang dilakukan script ini:

1. **Menulis konfigurasi lokal** untuk CLI yang kamu pilih (Hermes, Claude Code,
   OMP, aider, opencode, goose, crush, Cursor, Cline) — berisi API key `sk-ont-…`
   milikmu. File konfigurasi dibuat dengan permission `600` (hanya pemilik yang
   bisa baca).
2. **Menulis API key ke file lokalmu dalam bentuk teks biasa** — ini kebutuhan
   teknis semua CLI AI. Risiko dan mitigasi dijelaskan di
   https://ontoken.id/cli
3. **Menimpa environment variable** `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` bila kamu
   memilih tool tersebut (script memperingatkan sebelum menimpa).
4. **Opsional (`--install-omp`):** mengunduh dan menjalankan installer pihak
   ketiga `https://raw.githubusercontent.com/badlogic/pi-mono/main/omp.sh`
   (hanya jika flag diberikan eksplisit — tidak pernah otomatis).
5. **Tidak mengirim data apa pun** ke server kami selain permintaan HTTPS ke
   `api.ontoken.id` oleh CLI yang kamu jalankan setelahnya.

## Verifikasi checksum

```bash
curl -fsSLO https://raw.githubusercontent.com/mapan21/ontoken-cli/main/setup.sh
sha256sum -c --ignore-missing CHECKSUMS.txt   # atau: sha256sum setup.sh lalu bandingkan
less setup.sh                                  # baca dulu, baru jalankan
bash setup.sh
```

## Uninstall

Hapus blok konfigurasi yang ditandai `ON Token` di file rc shell-mu, dan/atau
file `~/.<tool>/…` yang dibuat installer. Daftar lengkap file yang disentuh ada
di https://ontoken.id/cli
