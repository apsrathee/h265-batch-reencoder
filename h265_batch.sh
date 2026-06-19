#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  h265_batch.sh — Safe H.264 → H.265 batch re-encoder (v2)
#  Designed for: Nobara Linux | Canon EOS 600D | single-HDD, ongoing workflow
#
#  Usage:  bash h265_batch.sh [INPUT_DIR] [SMART_DEVICE] [MAX_SESSION_MINUTES]
#  Defaults: INPUT_DIR=. | SMART_DEVICE=/dev/sda | MAX_SESSION_MINUTES=0 (unlimited)
#
#  Example — run a capped 2-hour evening session:
#    bash h265_batch.sh /mnt/karaoke /dev/sdb 120
#
#  Requires: ffmpeg ffprobe smartctl ionice nice df stat awk flock
#    sudo dnf install ffmpeg smartmontools util-linux coreutils
#
#  sudoers (one-time, avoids password prompt mid-run):
#    echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/smartctl" | sudo tee /etc/sudoers.d/smartctl-nopasswd
#    sudo chmod 440 /etc/sudoers.d/smartctl-nopasswd
# ══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

# ── CONFIG ────────────────────────────────────────────────────────────────────
INPUT_DIR="${1:-.}"
SMART_DEVICE="${2:-/dev/sda}"
MAX_SESSION_MINUTES="${3:-0}"        # 0 = unlimited
LOGFILE="$(cd "$(dirname "$0")" && pwd)/h265_encode.log"
LOCKFILE="/tmp/h265_batch_$(echo "$INPUT_DIR" | md5sum | cut -d' ' -f1).lock"
SLEEP_BETWEEN=5
TEMP_HALT=50                         # °C — pause encode at/above this
TEMP_RESUME=45                       # °C — resume once cooled to at/below this
                                      # (5°C hysteresis avoids rapid pause/resume flapping)
CRF=18
PRESET="medium"
AUDIO_BR="192k"
TEMP_SUFFIX=".h265part.mp4"          # in-progress marker, excluded from `find`
ACTIVE_PID_FILE="/tmp/h265_active_pid_$$"

# ── RUNTIME STATE ─────────────────────────────────────────────────────────────
CURRENT_TEMP=""
TEMP_MONITOR_PID=""
SESSION_START_EPOCH=$(date +%s)
SESSION_BYTES_DONE=0
SESSION_SECONDS_ENCODING=0

# ── TRAP: SIGINT / SIGTERM ────────────────────────────────────────────────────
cleanup() {
    echo ""
    log "INTERRUPTED — initiating cleanup..."
    # If ffmpeg is currently SIGSTOP-paused for heat, it must be woken before
    # SIGTERM will actually take effect — a stopped process won't act on TERM
    # until continued.
    if [[ -s "$ACTIVE_PID_FILE" ]]; then
        local pid
        pid=$(cat "$ACTIVE_PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -CONT "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null
        fi
    fi
    if [[ -n "$CURRENT_TEMP" && -f "$CURRENT_TEMP" ]]; then
        rm -f "$CURRENT_TEMP"
        log "CLEANUP: Removed partial output → $CURRENT_TEMP"
    fi
    [[ -n "$TEMP_MONITOR_PID" ]] && kill "$TEMP_MONITOR_PID" 2>/dev/null
    rm -f "$ACTIVE_PID_FILE"
    exit 130
}
trap cleanup SIGINT SIGTERM

# ── LOGGING ───────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log_row() {
    # $1=filepath $2=orig_mb $3=comp_mb $4=ratio $5=status
    printf "[%s] %-50s | ORIG: %6d MB | COMP: %6d MB | RATIO: %-6s | %s\n" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$(basename "$1")" "$2" "$3" "$4" "$5" \
        >> "$LOGFILE"
}

# ── DEPENDENCY CHECK ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in ffmpeg ffprobe smartctl ionice nice df stat awk sort flock md5sum; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log "ERROR: Missing binaries: ${missing[*]}"
        log "       sudo dnf install ffmpeg smartmontools util-linux coreutils"
        exit 1
    fi
}

# ── LOCKFILE — prevent concurrent runs against the same dir ──────────────────
acquire_lock() {
    exec 200>"$LOCKFILE"
    if ! flock -n 200; then
        log "ERROR: Another instance is already processing '$INPUT_DIR' (lock: $LOCKFILE)."
        exit 1
    fi
}

# ── SMART PRE-FLIGHT ──────────────────────────────────────────────────────────
#   5   = Reallocated_Sector_Ct   — sectors retired due to error, should be 0
#   197 = Current_Pending_Sector  — unstable sectors awaiting remap, should be 0
#   198 = Offline_Uncorrectable   — sectors that couldn't be corrected, should be 0
smart_preflight() {
    local device="$1"
    log "SMART pre-flight on $device ..."

    if ! sudo smartctl -A "$device" &>/dev/null; then
        log "ERROR: smartctl failed on $device. Check device path or sudoers config."
        exit 1
    fi

    local smart_out abort=0
    smart_out=$(sudo smartctl -A "$device")

    for attr_id in 5 197 198; do
        local raw
        raw=$(awk -v id="$attr_id" '$1 == id { print $10 }' <<< "$smart_out")
        if [[ -z "$raw" ]]; then
            log "  WARN: SMART attr $attr_id not found on $device — skipping this check."
            continue
        fi
        if (( raw != 0 )); then
            log "  ABORT: SMART attr $attr_id = $raw (non-zero). Drive integrity risk."
            abort=1
        else
            log "  OK:    SMART attr $attr_id = $raw"
        fi
    done

    (( abort == 1 )) && exit 1
    log "SMART pre-flight PASSED."
}

# ── BACKGROUND TEMPERATURE MONITOR (pause/resume) ────────────────────────────
# Polls SMART 194/190 every 15s. Safe ranges: 25–45°C ideal, 45–55°C warning,
# >55°C danger. Rather than killing the whole session at TEMP_HALT, this
# SIGSTOPs the active ffmpeg process — fully suspending it, including all
# disk I/O — and SIGCONTs it once the drive cools to TEMP_RESUME. No data
# loss, no manual restart, just genuine idle cool-down baked into the run.
# This matters a lot for non-AC environments: the drive can pause for
# minutes or hours through the heat of the day and pick back up on its own.
start_temp_monitor() {
    local device="$1" halt="$2" resume="$3" parent_pid=$$
    (
        local paused=0
        while kill -0 "$parent_pid" 2>/dev/null; do
            local temp
            temp=$(sudo smartctl -A "$device" 2>/dev/null \
                | awk '($1 == 194 || $1 == 190) { print $10; exit }')

            if [[ -n "$temp" ]]; then
                local active_pid=""
                [[ -s "$ACTIVE_PID_FILE" ]] && active_pid=$(cat "$ACTIVE_PID_FILE" 2>/dev/null)

                if (( paused == 0 )) && [[ "$temp" -ge "$halt" ]]; then
                    if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
                        kill -STOP "$active_pid" 2>/dev/null
                        paused=1
                        echo "" >&2
                        echo "[$(date '+%H:%M:%S')] !! ${temp}°C >= ${halt}°C — PAUSING encode, waiting to cool to ${resume}°C !!" \
                            | tee -a "$LOGFILE" >&2
                    fi
                elif (( paused == 1 )) && [[ "$temp" -le "$resume" ]]; then
                    if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
                        kill -CONT "$active_pid" 2>/dev/null
                        paused=0
                        echo "[$(date '+%H:%M:%S')] Cooled to ${temp}°C <= ${resume}°C — RESUMING encode" \
                            | tee -a "$LOGFILE" >&2
                    else
                        paused=0   # process finished/gone while paused; nothing to resume
                    fi
                fi
            fi
            sleep 15
        done
    ) &
    TEMP_MONITOR_PID=$!
    log "Temp monitor: PID=$TEMP_MONITOR_PID | halt=${halt}°C | resume=${resume}°C | poll=15s | mode=pause/resume"
}

# ── FREE SPACE CHECK ──────────────────────────────────────────────────────────
has_free_space() {
    local dir="$1" needed_bytes="$2" avail_bytes
    avail_bytes=$(df --output=avail -B1 "$dir" | tail -1 | tr -d ' ')
    (( avail_bytes >= needed_bytes ))
}

# ── CODEC PROBE (drives resumability) ────────────────────────────────────────
# Any file already showing hevc must be
# one of our completed outputs. This is filename-independent, works correctly
# even across renamed files, interrupted runs, or files moved between folders.
get_video_codec() {
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$1" 2>/dev/null
}

# ── FFPROBE OUTPUT INTEGRITY VERIFY ──────────────────────────────────────────
verify_output() {
    local out="$1" src="$2"
    [[ -f "$out" && -s "$out" ]] || return 1

    local codec
    codec=$(get_video_codec "$out")
    [[ "$codec" == "hevc" ]] || return 1

    local src_dur out_dur
    src_dur=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null)
    out_dur=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$out" 2>/dev/null)
    [[ -n "$src_dur" && -n "$out_dur" ]] || return 1

    awk -v s="$src_dur" -v o="$out_dur" \
        'BEGIN { d = (s > o) ? (s - o) : (o - s); exit (d <= s * 0.02) ? 0 : 1 }'
}

# ── STALE TEMP FILE SWEEP ─────────────────────────────────────────────────────
# Cleans up anything left behind by a hard crash / power loss (SIGINT trap
# only fires on Ctrl+C — it can't run after `kill -9` or a power cut).
sweep_stale_temp_files() {
    local count=0
    while IFS= read -r -d '' f; do
        rm -f "$f"
        log "SWEEP: Removed stale partial file from prior crash → $(basename "$f")"
        (( count++ )) || true
    done < <(find "$INPUT_DIR" -type f -iname "*${TEMP_SUFFIX}" -print0)
    (( count > 0 )) && log "SWEEP: Cleaned $count stale temp file(s)."
}

# ── ETA FORMATTING ────────────────────────────────────────────────────────────
fmt_eta() {
    local secs="$1"
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    printf "%dh %dm" "$h" "$m"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    check_deps
    acquire_lock
    smart_preflight "$SMART_DEVICE"
    sweep_stale_temp_files
    : > "$ACTIVE_PID_FILE"
    start_temp_monitor "$SMART_DEVICE" "$TEMP_HALT" "$TEMP_RESUME"

    log "════════════════════════════════════════════════"
    log " Session start"
    log " Input dir:    $INPUT_DIR"
    log " SMART device: $SMART_DEVICE"
    log " CRF:          $CRF | Preset: $PRESET | Audio: $AUDIO_BR"
    log " Temp:         pause at ${TEMP_HALT}°C, resume at ${TEMP_RESUME}°C"
    log " Session cap:  $([[ "$MAX_SESSION_MINUTES" -eq 0 ]] && echo unlimited || echo "${MAX_SESSION_MINUTES} min")"
    log " Logfile:      $LOGFILE"
    log "════════════════════════════════════════════════"

    # ── Build candidate list up front (needed for ETA + collision pre-checks) ──
    log "Scanning for candidates and probing codecs (this may take a minute)..."
    local -a pending_files=()
    local -a pending_sizes=()
    local total_pending_bytes=0
    local already_done=0 scanned=0

    while IFS= read -r -d '' f; do
        (( scanned++ )) || true
        local codec
        codec=$(get_video_codec "$f")
        if [[ "$codec" == "hevc" ]]; then
            (( already_done++ )) || true
            continue
        fi
        pending_files+=("$f")
        local sz
        sz=$(stat -c%s "$f")
        pending_sizes+=("$sz")
        (( total_pending_bytes += sz )) || true
    done < <(
        find "$INPUT_DIR" -type f \
            \( -iname "*.mp4" -o -iname "*.mov" \) \
            -not -iname "*${TEMP_SUFFIX}" \
            -print0 | sort -z
    )

    local total_pending=${#pending_files[@]}
    log "Scan complete: $scanned files seen | $already_done already HEVC (skip) | $total_pending pending (~$(( total_pending_bytes / 1073741824 )) GB)"
    log "════════════════════════════════════════════════"

    local ok=0 failed=0 collision_skipped=0 idx=0

    for src in "${pending_files[@]}"; do
        (( idx++ )) || true

        # ── Session time cap — checked between files only, never mid-encode ──
        if [[ "$MAX_SESSION_MINUTES" -gt 0 ]]; then
            local elapsed_min=$(( ($(date +%s) - SESSION_START_EPOCH) / 60 ))
            if (( elapsed_min >= MAX_SESSION_MINUTES )); then
                log "Session time cap (${MAX_SESSION_MINUTES} min) reached. Stopping cleanly."
                log "Resume anytime — already-encoded files are detected automatically and skipped."
                break
            fi
        fi

        local base dir stem final
        base=$(basename "$src")
        dir=$(dirname "$src")
        stem="${base%.*}"
        final="${dir}/${stem}.mp4"
        local temp="${dir}/${stem}${TEMP_SUFFIX}"

        # ── Naming collision guard ──────────────────────────────────────
        # If a DIFFERENT file already occupies the final name (e.g. stem.MOV
        # and stem.mp4 both exist as distinct original files), refuse to
        # guess — skip and flag for manual review rather than risk overwriting
        # unrelated footage.
        if [[ -e "$final" && "$final" != "$src" ]]; then
            log "SKIP (naming collision): '$base' would become '$(basename "$final")', which already exists as a different file. Resolve manually."
            (( collision_skipped++ )) || true
            continue
        fi

        local src_bytes src_mb avail_mb
        src_bytes=$(stat -c%s "$src")
        src_mb=$(( src_bytes / 1048576 ))
        avail_mb=$(( $(df --output=avail -B1M "$dir" | tail -1 | tr -d ' ') ))

        if ! has_free_space "$dir" "$src_bytes"; then
            log "SKIP (no space): $base | need ~${src_mb} MB, have ~${avail_mb} MB"
            (( failed++ )) || true
            continue
        fi

        log "────────────────────────────────────────────────"
        log "START [$idx/$total_pending]: $base"
        log "       Source: ${src_mb} MB | Free: ${avail_mb} MB"
        CURRENT_TEMP="$temp"

        local encode_start encode_end enc_ok=0
        encode_start=$(date +%s)

        # ionice -c 3 = idle I/O class | nice -n 19 = lowest CPU priority
        # -map_metadata 0           → copy global/container metadata (Canon's creation_time tag)
        # -tag:v hvc1               → Apple/QuickTime-compatible HEVC tag
        # -movflags +faststart      → moov atom up front, streaming-friendly
        ionice -c 3 nice -n 19 \
            ffmpeg -nostdin -hide_banner -loglevel warning -stats \
                -i "$src" \
                -map 0:v:0 \
                -map "0:a:0?" \
                -map_metadata 0 \
                -c:v libx265 \
                -crf "$CRF" \
                -preset "$PRESET" \
                -c:a aac \
                -b:a "$AUDIO_BR" \
                -pix_fmt yuv420p \
                -tag:v hvc1 \
                -movflags +faststart \
                -y \
                "$temp" &

        local ffmpeg_pid=$!
        echo "$ffmpeg_pid" > "$ACTIVE_PID_FILE"

        wait "$ffmpeg_pid"
        (( $? == 0 )) && enc_ok=1 || enc_ok=0

        : > "$ACTIVE_PID_FILE"

        encode_end=$(date +%s)

        if (( enc_ok == 1 )) && verify_output "$temp" "$src"; then
            local comp_bytes comp_mb ratio
            comp_bytes=$(stat -c%s "$temp")
            comp_mb=$(( comp_bytes / 1048576 ))
            ratio=$(awk -v c="$comp_bytes" -v o="$src_bytes" \
                'BEGIN { printf "%.1f%%", (c / o) * 100 }')

            # Preserve original recording date at the filesystem level —
            # do this BEFORE the rename so it's set on the file that survives.
            touch -r "$src" "$temp"

            mv -f "$temp" "$final"

            # If final == src (source was already named "x.mp4"), the mv above
            # already replaced it atomically — nothing left to delete separately.
            if [[ "$final" != "$src" ]]; then
                rm -f "$src"
            fi

            log "OK:  $base → $(basename "$final") | ${src_mb} MB → ${comp_mb} MB (${ratio})"
            log_row "$src" "$src_mb" "$comp_mb" "$ratio" "SUCCESS"
            (( ok++ )) || true

            (( SESSION_BYTES_DONE += src_bytes )) || true
            (( SESSION_SECONDS_ENCODING += (encode_end - encode_start) )) || true

            # ── ETA based on running average throughput this session ──────
            if (( SESSION_SECONDS_ENCODING > 0 )); then
                local rate_bps remaining_bytes eta_secs
                rate_bps=$(( SESSION_BYTES_DONE / SESSION_SECONDS_ENCODING ))
                if (( rate_bps > 0 )); then
                    remaining_bytes=$(( total_pending_bytes - SESSION_BYTES_DONE ))
                    eta_secs=$(( remaining_bytes / rate_bps ))
                    log "       Progress: $idx/$total_pending this session | ETA remaining: $(fmt_eta "$eta_secs") at current rate"
                fi
            fi
        else
            log "FAIL: $base — encode or verification failed. Removing partial output."
            rm -f "$temp"
            log_row "$src" "$src_mb" "0" "N/A" "FAILED"
            (( failed++ )) || true
        fi

        CURRENT_TEMP=""
        log "Sleeping ${SLEEP_BETWEEN}s ..."
        sleep "$SLEEP_BETWEEN"
    done

    [[ -n "$TEMP_MONITOR_PID" ]] && kill "$TEMP_MONITOR_PID" 2>/dev/null
    rm -f "$ACTIVE_PID_FILE"

    log "════════════════════════════════════════════════"
    log " SESSION COMPLETE"
    log " Encoded:            $ok"
    log " Failed:              $failed"
    log " Collisions skipped:  $collision_skipped"
    log " Already done (lib):  $already_done"
    log "════════════════════════════════════════════════"
}

main "$@"
