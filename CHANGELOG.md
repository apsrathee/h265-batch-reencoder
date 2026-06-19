# Changelog

All notable changes to this script are documented here.

## [2.1] — Thermal pause/resume

### Changed
- Overheat handling is no longer a hard session-stop. The background temperature
  monitor now sends `SIGSTOP` to the active FFmpeg process at `TEMP_HALT` (default
  50°C) and `SIGCONT` once cooled to `TEMP_RESUME` (default 45°C). No data loss,
  no manual restart — encoding genuinely pauses and resumes around ambient heat.
- FFmpeg is now launched in the background with its PID tracked via a pid file,
  specifically so the thermal monitor can signal it directly.
- Cleanup trap (Ctrl+C) now wakes a SIGSTOP-paused FFmpeg process before sending
  SIGTERM, since a stopped process won't act on TERM until continued.

### Fixed
- Live progress stats (`frame=... fps=... speed=...`) weren't displaying because
  `-loglevel warning` was suppressing them in some FFmpeg builds. Added explicit
  `-stats` flag to force them regardless of log verbosity.
- Removed `-map_metadata:s:v:0` / `-map_metadata:s:a:0` flags — these used a `?`
  optional-stream marker that `-map_metadata` doesn't support (unlike `-map`),
  causing a hard failure on every file (`Trailing garbage at the end of a stream
  specifier`). Global `-map_metadata 0` alone still carries over the container-
  level `creation_time` tag, which is what mattered.

## [2.0] — Filename/resumability rework

### Changed
- **Breaking:** output files now keep the original filename (extension normalized
  to `.mp4`) instead of appending `_h265`.
- Resumability is now based on probing each candidate's actual video codec via
  `ffprobe` rather than checking for a differently-named output file. Since the
  source camera only shoots H.264, any file already reporting `hevc` is treated
  as a completed output — this works correctly across renames, interrupted runs,
  and partially-converted libraries.
- Added `touch -r` to copy the original file's mtime onto the encoded output, so
  file-manager date-sort order matches original recording order.
- Added explicit `-map_metadata 0` to carry over container-level metadata
  (e.g. camera `creation_time`) rather than relying on FFmpeg's implicit default.
- Added optional 3rd argument: session time cap in minutes, so long jobs can be
  run in bounded chunks instead of multi-day unattended sessions.
- Added a naming-collision guard: if a different file already occupies the
  target output name, the candidate is skipped and logged for manual review
  rather than risking an overwrite.
- Added a lockfile to prevent two instances processing the same directory
  concurrently.
- Added a stale-temp-file sweep on startup to clean up partial outputs left by
  hard crashes or power loss (the SIGINT trap only covers Ctrl+C).
- Added a live ETA based on measured throughput from an upfront codec-probe scan
  of pending work.
- Logfile is now persistent (fixed filename, appended across runs) instead of a
  new timestamped file per run.

## [1.0] — Initial release

- Recursive batch H.264 → H.265 (libx265, CRF 18, preset medium) re-encode.
- Per-file ffprobe-based output verification (codec + duration match) before
  deleting the source — not just trusting FFmpeg's exit code.
- SMART pre-flight check (reallocated/pending/uncorrectable sector attributes).
- Background temperature monitor with a hard-stop threshold.
- Free-space check before each file, since source and output share one disk.
- `ionice -c3` / `nice -n19` to minimize system impact during long runs.
- SIGINT/SIGTERM trap to clean up partial output on Ctrl+C.
- Per-file logging (name, original/compressed size, timestamp).
