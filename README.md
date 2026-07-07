# h265-batch-reencoder

A safety-first Bash script that batch re-encodes H.264 footage to H.265/HEVC **in place**, on the **same disk** the source files live on — built specifically for the case where you don't have a second drive to stage the output on, and can't afford to lose data if something goes wrong mid-run.

Originally built for re-encoding Canon EOS 600D footage (40Mbps H.264 MOV) down to space-efficient HEVC, but the core logic is generic to any H.264 → H.265 batch workflow on a single volume.

Defaults to **GPU hardware encode via VA-API** (`hevc_vaapi`) when available, with automatic fallback to CPU software encode (`libx265`) if the GPU path can't initialize — see [Encoder: VAAPI vs libx265](#encoder-vaapi-vs-libx265) for why VAAPI was chosen over AMD's AMF SDK, and the real compression-ratio tradeoff that comes with the speed gain.

> **TL;DR:** Point it at a folder. It finds every `.mp4`/`.mov`, re-encodes anything not already HEVC, verifies the output is actually intact before touching the original, preserves filenames/dates/metadata, and survives crashes, power loss, thermal throttling, and Ctrl+C without corrupting anything.

---

## Table of Contents

- [Why this exists](#why-this-exists)
- [Features](#features)
- [Encoder: VAAPI vs libx265](#encoder-vaapi-vs-libx265)
  - [Why not AMF?](#why-not-amf)
  - [The compression-ratio tradeoff](#the-compression-ratio-tradeoff)
  - [Tuning QP for your footage](#tuning-qp-for-your-footage)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [How It Works](#how-it-works)
  - [Per-file pipeline](#per-file-pipeline)
  - [Resumability model](#resumability-model)
  - [Thermal pause/resume](#thermal-pauseresume)
- [Configuration](#configuration)
- [Safety Mechanisms](#safety-mechanisms)
- [Pre-flight Drive Health Check (recommended)](#pre-flight-drive-health-check-recommended)
- [Testing Before a Full Run](#testing-before-a-full-run)
- [Logging](#logging)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Why this exists

Re-encoding a large video library to save space sounds simple until you hit the real-world constraints:

- You only have **one disk**, so source and output have to coexist on it, at least temporarily — meaning a naive "encode everything, then delete originals" approach can fill the disk before it's done.
- The job takes **days**, not minutes, so it has to be interruptible and resumable without babysitting or re-encoding work that's already done.
- It's running on **aging hardware** in a hot climate, so silent overheating-induced drive failure is a real risk, not a hypothetical one.
- A corrupted output must **never** result in a deleted original — that's the one mistake that can't be undone.

This script is the result of designing around all four constraints simultaneously, rather than bolting on safety after the fact.

## Features

| Category | What it does |
|---|---|
| **GPU acceleration** | Defaults to `hevc_vaapi` (GPU hardware encode via Mesa/VA-API) with automatic startup probe and clean fallback to `libx265` (CPU) if the GPU path can't initialize — no silent substitution, no mid-batch surprises |
| **Integrity** | Verifies every output with `ffprobe` (codec check + duration match within 2%) before deleting the source — not just trusting FFmpeg's exit code |
| **Resumability** | Detects already-converted files by probing actual codec (not filename), so interrupted runs, renamed files, or partially-converted libraries all resume correctly |
| **Crash recovery** | Sweeps and removes orphaned partial outputs left by hard crashes/power loss on every startup |
| **Thermal safety** | Pauses (SIGSTOP) the active encode when the drive gets too hot, resumes (SIGCONT) once it cools — no data loss, no manual restart |
| **Drive health** | Pre-flight SMART check (reallocated/pending/uncorrectable sector counts) aborts before touching a failing drive |
| **Space safety** | Confirms free space exceeds the next file's size before starting, since source and output share the same volume |
| **Metadata preservation** | Original filename, file modification time (`mtime`), and embedded container metadata (e.g. camera `creation_time`) all survive the conversion |
| **Crash-safe cleanup** | SIGINT/SIGTERM trap removes partial output files on Ctrl+C; never leaves a half-written file lying around |
| **Concurrency safety** | Lockfile prevents two instances from hammering the same folder simultaneously |
| **Low system impact** | `ionice -c3` (idle I/O class) + `nice -n19` (lowest CPU priority) keep the encode out of the way of normal system use |
| **Session control** | Optional time cap so you can run "two hours tonight" instead of multi-day unattended sessions on an old drive |
| **Visibility** | Live FFmpeg progress stats, plus a running ETA computed from actual measured throughput |
| **Logging** | Persistent, append-across-runs logfile with per-file size/ratio/timestamp records |

## Encoder: VAAPI vs libx265

The script picks between two encode paths, controlled by `ENCODER` (env override: `H265_ENCODER=libx265 ./h265_batch.sh ...`):

| Encoder | What it uses | Speed | Compression efficiency |
|---|---|---|---|
| `hevc_vaapi` (default) | GPU hardware encode via Mesa's `radeonsi` VA-API driver | Fast — 15-20x+ real-time on a Polaris-class card | Lower — see below |
| `libx265` (fallback) | CPU software encode | Slow — sub-1x real-time on a 4-core CPU | Higher — full psycho-visual RDO |

At startup, `check_vaapi_available()` runs a 1-second synthetic test encode against `$VAAPI_DEVICE` (default `/dev/dri/renderD128`). If it fails to initialize, the script logs a `WARN` and falls back to `libx265` for that entire run rather than crashing mid-batch or silently producing something unexpected.

### Why not AMF?

An earlier version of this script targeted AMD's `hevc_amf` encoder instead. That turned out to be a dead end, not a config problem:

- AMD **discontinued AMF on Linux as of driver release 25.20** — their own release notes state "AMF will no longer be included in the release... AMF users are advised to transition to VA-API / Mesa Multimedia."
- Even the community's unofficial AMF successor package only supports **RDNA3-and-later** GPUs. Anything Polaris/Vega/RDNA1/RDNA2 (e.g. the RX 570 this script was built against) has no viable AMF path at all — attempting it fails with `DLL libamfrt64.so.1 failed to open`, because that proprietary runtime library simply isn't shipped for these cards anymore.
- VA-API, by contrast, is fully open-source, ships as part of Mesa, and — critically — **already includes real hardware HEVC encode support** for these older cards. Confirm yours does before relying on this script's default:
  ```bash
  vainfo 2>&1 | grep -i hevc
  ```
  You want to see `VAProfileHEVCMain : VAEntrypointEncSlice` (encode, not just `VAEntrypointVLD` which is decode-only).

### The compression-ratio tradeoff

This is the part that's easy to miss: **VAAPI's `-qp N` and x265's `-crf N` are not the same number scale, even though they look similar.**

`libx265`'s CRF is a full perceptual-quality-targeting mode — adaptive quantization across each frame (`cu-tree`), psycho-visual rate-distortion weighting (`psy-rd`), and a 20-frame lookahead deciding where bits actually matter. It spends very few bits on regions that don't need them and more on regions that do, frame by frame.

`hevc_vaapi`'s `-qp N` (Constant QP) is a much blunter instrument — it applies the same fixed quantization step everywhere, with no adaptive weighting and a simpler hardware mode-decision/motion-search than x265's software RDO. It can't tell "static background, safe to compress harder" from "moving detail, needs the bits" — so it spends more bits everywhere, uniformly, just to hit the same nominal quality number.

Measured on identical source footage (Canon 600D MOV, same file, same nominal "18"):

| | `libx265 -crf 18` | `hevc_vaapi -qp 18` |
|---|---|---|
| Output bitrate | ~10.9 Mbps | ~31.1 Mbps (**2.85x higher**) |
| Compression ratio | ~79-80% size reduction | ~40-45% size reduction |
| Encode speed | ~0.35x real-time (CPU-bound) | ~7-20x real-time (GPU-bound) |

**In short: the default VAAPI config trades most of your compression ratio for a ~20x speed gain.** Visual quality at QP18 is not worse — if anything it's more bits than strictly necessary — but the file-size savings that were the whole point of re-encoding will be smaller than a CPU `libx265` pass would achieve.

### Tuning QP for your footage

If compression ratio matters more than encode speed for your use case, raise `QP` until the output bitrate approaches what `libx265 -crf 18` was achieving on comparable content — there's no universal "correct" VAAPI QP-to-CRF mapping, since the gap depends on how static vs. motion-heavy the footage is. A quick way to find your own curve:

```bash
for qp in 22 26 30 34; do
  ffmpeg -y -vaapi_device /dev/dri/renderD128 -i sample.MOV \
    -vf "format=nv12,hwupload" -c:v hevc_vaapi -qp "$qp" \
    -an -t 30 "/tmp/test_qp${qp}.mp4"
  echo "QP=$qp:"; ffprobe -v error -show_entries format=size -of csv=p=0 "/tmp/test_qp${qp}.mp4"
done
```

Watch for the point where size drops sharply without visible quality loss (blockiness in motion, softened detail) — that's usually a good working QP for that content type. Static/talking-head footage tolerates much higher QP than motion-heavy footage before it becomes visible.

Alternatively, VAAPI supports bitrate-targeted modes instead of fixed QP, which can get you closer to a specific file-size target directly:

```bash
ffmpeg -vaapi_device /dev/dri/renderD128 -i in.MOV \
  -vf "format=nv12,hwupload" -c:v hevc_vaapi \
  -rc_mode VBR -b:v 11M -maxrate 14M -bufsize 22M \
  -c:a aac -b:a 192k out.mp4
```
Confirm your driver actually exposes `VBR` mode first: `ffmpeg -h encoder=hevc_vaapi 2>&1 | grep -A5 rc_mode`.



```
ffmpeg (with vaapi + libx265 support — check via: ffmpeg -encoders | grep -E "hevc_vaapi|libx265")
ffprobe
libva-utils (vainfo — for confirming GPU HEVC encode support)
smartmontools (smartctl)
util-linux (ionice, flock)
coreutils (nice, df, stat, sort)
gawk/awk
```

For GPU encode, your card's VA-API driver needs to actually expose HEVC's encode entrypoint — this is a property of your Mesa version and GPU generation, not something this script can work around. Verify before assuming the default `hevc_vaapi` path will work:

```bash
vainfo 2>&1 | grep -i hevc
# Want to see: VAProfileHEVCMain : VAEntrypointEncSlice
```

If it's not there, the script's startup probe will detect this automatically and fall back to `libx265` — you don't need to pre-configure anything, just be aware encode speed will be CPU-bound in that case.

On Fedora/Nobara:

```bash
sudo dnf install ffmpeg smartmontools util-linux coreutils libva-utils
```

On Debian/Ubuntu:

```bash
sudo apt install ffmpeg smartmontools util-linux coreutils libva-utils
```

`smartctl` requires root. Set up passwordless sudo for it once — **this is important for long unattended runs**, since the background temperature monitor calls `smartctl` every 15 seconds, and an expired sudo timestamp partway through a multi-hour session will silently break temperature monitoring with no terminal to prompt on:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/smartctl" | sudo tee /etc/sudoers.d/smartctl-nopasswd
sudo chmod 440 /etc/sudoers.d/smartctl-nopasswd
```

## Installation

```bash
git clone https://github.com/<your-username>/h265-batch-reencoder.git
cd h265-batch-reencoder
chmod +x h265_batch.sh
```

## Quick Start

```bash
./h265_batch.sh /path/to/videos /dev/sdX
```

That's it for a one-off, unlimited-duration run. For an ongoing daily workflow with a time-boxed session:

```bash
./h265_batch.sh /path/to/videos /dev/sdX 180   # stop cleanly after 3 hours
```

## Usage

```
h265_batch.sh [INPUT_DIR] [SMART_DEVICE] [MAX_SESSION_MINUTES]
```

| Argument | Default | Description |
|---|---|---|
| `INPUT_DIR` | `.` | Directory to scan recursively for `.mp4`/`.MP4`/`.mov`/`.MOV` files |
| `SMART_DEVICE` | `/dev/sda` | Block device backing `INPUT_DIR` — used for SMART health/temperature checks. Find yours with `df -h /path/to/videos` or `lsblk` |
| `MAX_SESSION_MINUTES` | `0` (unlimited) | Stop cleanly between files once this many minutes have elapsed. Already-converted files are always detected and skipped, so resuming later picks up exactly where you left off |

**Examples:**

```bash
# Scan current directory, default device, run until done (GPU encode if available)
./h265_batch.sh

# Real example: external HDD, capped 3-hour evening session
./h265_batch.sh "/run/media/user/MyDrive/Karaoke" /dev/sdc 180

# Force CPU software encode for maximum compression, ignoring GPU even if available
H265_ENCODER=libx265 ./h265_batch.sh "/run/media/user/MyDrive/Karaoke" /dev/sdc
```

## How It Works

### Per-file pipeline

```mermaid
flowchart TD
    A[Scan INPUT_DIR for .mp4/.mov] --> B[Probe codec of each file]
    B -->|already hevc| C[Skip — counts toward 'already done']
    B -->|h264 or other| D[Add to pending queue]
    D --> E[Naming collision check]
    E -->|collision| F[Skip — flag for manual review]
    E -->|clear| G[Free space check]
    G -->|insufficient| H[Skip — log and continue]
    G -->|sufficient| I[Launch ffmpeg in background]
    I --> J[Record PID for thermal monitor]
    J --> K[Wait for completion]
    K --> L{Exit code 0?}
    L -->|no| M[Delete partial output, log FAIL]
    L -->|yes| N[ffprobe verify: codec=hevc AND duration within 2%]
    N -->|fails| M
    N -->|passes| O[touch -r: copy original mtime to output]
    O --> P[Rename temp file to final name]
    P --> Q[Delete original source]
    Q --> R[Log success + update ETA]
    R --> S[Sleep, then next file]
```

### Resumability model

Most batch-encode scripts track progress by checking whether an output filename already exists. That breaks the moment you want the output to keep the **original filename** — there's no separate name left to check against.

Instead, this script probes the actual video codec of every candidate file with `ffprobe` before deciding what to do with it:

```bash
ffprobe -select_streams v:0 -show_entries stream=codec_name ...
```

Since your source camera only ever shoots H.264, **any file that already reports `hevc` must be one of this script's completed outputs** — regardless of what it's named, what folder it's in, or whether a previous run got interrupted partway through. This makes resumability completely independent of filenames, timestamps, or any state file that could itself get out of sync with reality.

### Thermal pause/resume

Rather than aborting the whole session when the drive gets hot, a background monitor polls SMART temperature attributes (194/190) every 15 seconds and directly signals the active FFmpeg process:

- **At `TEMP_HALT`°C** → sends `SIGSTOP` to the FFmpeg process. This fully suspends it — zero CPU usage, zero disk I/O — letting the drive cool passively with no risk of corrupting the in-progress encode.
- **At `TEMP_RESUME`°C** → sends `SIGCONT`, and FFmpeg picks up exactly where it was paused, mid-frame, with no rework.

The gap between halt and resume thresholds (hysteresis) exists so the script doesn't rapidly flap between pausing and resuming right at the boundary temperature — it commits to a real cool-down before resuming.

This means the script can run unattended through a hot afternoon, pause itself for however long it takes to cool down, and resume entirely on its own — no monitoring or manual restarts required.

## Configuration

All tunables live as variables near the top of the script:

| Variable | Default | Notes |
|---|---|---|
| `ENCODER` | `hevc_vaapi` | `hevc_vaapi` (GPU) or `libx265` (CPU). Override per-run via `H265_ENCODER` env var rather than editing the script |
| `VAAPI_DEVICE` | `/dev/dri/renderD128` | DRI render node for GPU encode. Verify yours with `vainfo --display drm --device /dev/dri/renderD128` — on multi-GPU systems (e.g. Intel iGPU + AMD dGPU) the correct node may differ |
| `TEMP_HALT` | `50` (°C) | Pause encoding at/above this drive temperature |
| `TEMP_RESUME` | `45` (°C) | Resume once cooled to at/below this |
| `QP` | `18` | VAAPI constant-QP target, used when `ENCODER=hevc_vaapi`. **Not equivalent to CRF** — see [The compression-ratio tradeoff](#the-compression-ratio-tradeoff) — typically needs to be raised well above 18 to match `libx265 -crf 18`'s compression ratio |
| `CRF` | `18` | x265 Constant Rate Factor, used when `ENCODER=libx265`. Lower = higher quality/larger file. 18 is visually transparent for most source material |
| `PRESET` | `medium` | x265 preset, ignored by VAAPI. `slow`/`slower` improve compression ~5-10% but cost 2-3x encode time — usually not worth it for large libraries |
| `AUDIO_BR` | `192k` | AAC audio bitrate |
| `SLEEP_BETWEEN` | `5` (seconds) | Pause between files, easing sustained I/O/thermal load |

## Safety Mechanisms

**SMART pre-flight (runs once at startup).** Aborts before touching the drive if any of these are non-zero:

| Attribute ID | Name | Meaning if non-zero |
|---|---|---|
| 5 | Reallocated_Sector_Ct | Sectors have already failed and been remapped |
| 197 | Current_Pending_Sector | Unstable sectors awaiting remap — early failure signal |
| 198 | Offline_Uncorrectable | Sectors that couldn't be corrected — active data risk |

**Output verification (runs after every encode, before deletion).** A zero exit code from FFmpeg is not sufficient proof of a good file — it can exit 0 on a file truncated by a disk-full condition mid-mux. The script independently confirms via `ffprobe`:
1. Output file exists and is non-empty
2. Video stream codec is genuinely `hevc`
3. Output duration is within 2% of the source duration

Only if all three pass does the original get deleted.

**Crash-safe temp files.** Outputs are written to a `*.h265part.mp4` working name during encoding, only renamed to the final name after verification passes. Combined with a startup sweep that removes any leftover `.h265part.mp4` files, a hard crash or power loss never leaves ambiguity about what's safe.

## Pre-flight Drive Health Check (recommended)

Before trusting any drive — especially an older one — with a multi-day write-heavy job, run a full SMART self-test once:

```bash
sudo smartctl -t long /dev/sdX      # takes 2-4 hours depending on drive size
# ... wait ...
sudo smartctl -a /dev/sdX           # check results
```

If reallocated/pending/uncorrectable counts come back non-zero, **back up that drive before running anything else** — the encode is not the priority at that point.

To watch temperature live in a second terminal during a run:

```bash
watch -n 15 "sudo smartctl -A /dev/sdX | awk '(\$1==190||\$1==194){printf \"ID%-3s %-30s %s°C\n\",\$1,\$2,\$10}'"
```

## Testing Before a Full Run

Don't point this at a large library untested. Run a single-file, 60-second test first — and if you're on the default GPU path, run both so you can compare size/quality/speed before committing:

```bash
# CPU path (libx265)
ffmpeg -nostdin -hide_banner \
  -i "/path/to/sample.MOV" \
  -map 0:v:0 -map "0:a:0?" \
  -c:v libx265 -crf 18 -preset medium \
  -c:a aac -b:a 192k \
  -pix_fmt yuv420p -tag:v hvc1 \
  -movflags +faststart \
  -t 60 \
  /tmp/test_cpu.mp4

# GPU path (hevc_vaapi) — note the QP/CRF mismatch discussed above;
# start higher than 18 if compression ratio matters more than speed
ffmpeg -nostdin -hide_banner \
  -vaapi_device /dev/dri/renderD128 \
  -i "/path/to/sample.MOV" \
  -map 0:v:0 -map "0:a:0?" \
  -vf "format=nv12,hwupload" \
  -c:v hevc_vaapi -qp 18 \
  -c:a aac -b:a 192k \
  -tag:v hvc1 \
  -movflags +faststart \
  -t 60 \
  /tmp/test_gpu.mp4

# Compare
ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate \
     -show_entries format=duration,size -of default /tmp/test_cpu.mp4
ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate \
     -show_entries format=duration,size -of default /tmp/test_gpu.mp4
```

Confirm `codec_name=hevc`, resolution/framerate match the source, and the file plays back cleanly before running the batch script on anything you can't afford to lose.

## Logging

A persistent logfile (`h265_encode.log`, next to the script) accumulates across every run, with a session header each time:

```
[2026-06-17 13:20:02] START [1/4]: MVI_0320.MOV
[2026-06-17 13:20:02]        Source: 4085 MB | Free: 785298 MB
[2026-06-17 13:24:51] OK:  MVI_0320.MOV → MVI_0320.mp4 | 4085 MB → 602 MB (14.7%)
[2026-06-17 13:24:51]        Progress: 1/4 this session | ETA remaining: 0h 14m at current rate
```

A separate row-formatted entry is also written per file for easy parsing:

```
[2026-06-17 13:24:51] MVI_0320.MOV    | ORIG:   4085 MB | COMP:    602 MB | RATIO: 14.7%  | SUCCESS
```

## Known Limitations

- **Naming collisions are skipped, not resolved automatically.** If `clip.MOV` and `clip.mp4` both exist as genuinely separate source files sharing a stem, the script refuses to guess which is which and logs it for manual review rather than risk overwriting unrelated footage.
- **The session time cap counts wall-clock time, including any thermal pause duration.** A "3 hour session" interrupted by an hour of heat-induced pausing only gets ~2 hours of actual encoding done. This is intentional — better to under-promise than to run unexpectedly long into hours you didn't intend.
- **Source and output share one disk by design**, which is the whole point of this script — but it also means a catastrophic drive failure mid-run still takes everything with it. SMART pre-flight checks reduce this risk; they don't eliminate it. If your data matters and you don't have a backup elsewhere, get one before running this at scale.
- **Compression ratio is highly content-dependent, and differs significantly by encoder.** Static, low-motion footage (talking heads, karaoke, presentations) can see 80%+ size reduction at `libx265 -crf 18`. The default `hevc_vaapi -qp 18` path typically only achieves ~40-45% reduction on the same content, because VAAPI's Constant-QP mode lacks the adaptive quantization and psycho-visual optimization that let x265 spend bits only where they're visually needed — see [The compression-ratio tradeoff](#the-compression-ratio-tradeoff). If maximum space savings matters more than encode speed, raise `QP` significantly above 18, or force `H265_ENCODER=libx265`.

## Troubleshooting

**`hevc_amf` fails or isn't worth pursuing** — AMD discontinued AMF on Linux as of driver 25.20, and the unofficial successor package only supports RDNA3+ GPUs. If you're on Polaris/Vega/RDNA1/RDNA2 hardware, don't chase this — use the default `hevc_vaapi` path instead, which has genuine open-source hardware encode support for these cards via Mesa.

**`hevc_vaapi` fails to initialize (falls back to `libx265` with a WARN in the log)** — first confirm your GPU/driver actually exposes HEVC encode:
```bash
vainfo 2>&1 | grep -i hevc
```
Look for `VAProfileHEVCMain : VAEntrypointEncSlice` specifically (encode) — `VAEntrypointVLD` alone is decode-only and won't help here. If `vainfo` itself errors out or can't find a driver, confirm the correct render node with `ls /dev/dri/` and `vainfo --display drm --device /dev/dri/renderD1XX` for each, and set `VAAPI_DEVICE` accordingly if it's not `renderD128` on your system (common on machines with both an Intel iGPU and a discrete GPU).

**`Trailing garbage at the end of a stream specifier: ?`** — this means a `?` optional-stream marker was used somewhere FFmpeg doesn't support it (e.g. on `-map_metadata` rather than `-map`). Not present in the current version of the script; if you've modified the FFmpeg invocation, check this first.

**SMART checks fail or device not found** — confirm you're pointing at the correct block device with `lsblk` or `df -h /path/to/videos`. The script needs the physical disk (`/dev/sdc`), not a partition or mount path.

**Temperature monitoring silently stops working mid-run** — almost always a sudo password prompt timing out in the background with no terminal attached. Set up the passwordless sudo rule for `smartctl` described in [Requirements](#requirements).

**Script can't find any candidate files** — check the extension case-sensitivity and that you're pointing at the right directory; the `find` pattern is case-insensitive for `.mp4`/`.mov` already, so this is usually a path issue.

## License

MIT — see [LICENSE](LICENSE).
