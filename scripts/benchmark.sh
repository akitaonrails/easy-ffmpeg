#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Side-by-side benchmark of easy-ffmpeg with and without --gpu.
#
# For a given input video, runs the same --compress preset twice (CPU once,
# GPU once), then computes SSIM of each output against the original source.
# Prints a comparison table: wall time, output size, bitrate, SSIM.
#
# Usage:
#   scripts/benchmark.sh <input> [preset] [output-dir]
#
# Defaults: preset=compress, output-dir=$(dirname input)/bench
#
# Requires the easy-ffmpeg:cuda docker image (built via scripts/docker-build.sh)
# and an NVIDIA GPU reachable on the host (nvidia-container-toolkit installed).
# -----------------------------------------------------------------------------
set -euo pipefail

IMAGE="${IMAGE:-easy-ffmpeg:cuda}"

INPUT="${1:?usage: $0 <input> [preset] [output-dir]}"
PRESET="${2:-compress}"
OUTDIR="${3:-$(dirname "$INPUT")/bench}"

[ -f "$INPUT" ] || { echo "input not found: $INPUT" >&2; exit 1; }
mkdir -p "$OUTDIR"

ABSDIR_IN="$(cd "$(dirname "$INPUT")" && pwd)"
ABSDIR_OUT="$(cd "$OUTDIR" && pwd)"
NAME="$(basename "${INPUT%.*}")"
EXT="${INPUT##*.}"

CPU_OUT="$ABSDIR_OUT/${NAME}__cpu.mp4"
GPU_OUT="$ABSDIR_OUT/${NAME}__gpu.mp4"

# /tmp/.bench_times.txt: written by /usr/bin/time inside the container
# Format: REAL=12.345 USER=... SYS=...

# Mount both the input dir (read) and output dir (write) into the container.
COMMON_MOUNTS=(-v "$ABSDIR_IN:/in:ro" -v "$ABSDIR_OUT:/out")

# ---------------------------------------------------------------------------
run_encode() {
  local label="$1"  # "cpu" or "gpu"
  local gpus="$2"   # "" or "--gpus all"
  local out="$3"
  local extra=()
  [ "$label" = "gpu" ] && extra=(--gpu)

  echo "=== $label encode: --$PRESET ${extra[*]} ==="
  local t0 t1
  t0=$(date +%s.%N)
  # shellcheck disable=SC2086
  docker run --rm $gpus "${COMMON_MOUNTS[@]}" "$IMAGE" \
    "/in/$(basename "$INPUT")" mp4 --$PRESET "${extra[@]}" --force \
    -o "/out/$(basename "$out")"
  t1=$(date +%s.%N)
  local elapsed
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
  echo "$elapsed" > "$out.time"
  echo "  wall time: ${elapsed}s"
}

probe_metric() {
  local path="$1"
  local field="$2"
  docker run --rm "${COMMON_MOUNTS[@]}" --entrypoint ffprobe "$IMAGE" \
    -v error -select_streams v:0 \
    -show_entries "stream=$field" \
    -of default=noprint_wrappers=1:nokey=1 \
    "/out/$(basename "$path")" 2>/dev/null | head -n 1
}

compute_ssim() {
  local source="$1"
  local encoded="$2"
  # ffmpeg ssim filter prints "[Parsed_ssim_0 ...] SSIM ... All:0.xxxxxx" at
  # info level (not error). The summary line lives on stderr.
  docker run --rm --gpus all "${COMMON_MOUNTS[@]}" --entrypoint ffmpeg "$IMAGE" \
    -hide_banner -nostats -v info \
    -i "/in/$(basename "$source")" \
    -i "/out/$(basename "$encoded")" \
    -lavfi "[0:v][1:v]ssim" -f null - 2>&1 |
    grep -oE 'All:[0-9.]+' | tail -n 1 | cut -d: -f2
}

human_size() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN{
    split("B KB MB GB TB", u);
    i=1; while (b>=1024 && i<5) { b/=1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

# ---------------------------------------------------------------------------
# Source info
SRC_SIZE=$(stat -c%s "$INPUT")
SRC_DUR=$(docker run --rm "${COMMON_MOUNTS[@]}" --entrypoint ffprobe "$IMAGE" \
  -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 \
  "/in/$(basename "$INPUT")" 2>/dev/null)
SRC_CODEC=$(docker run --rm "${COMMON_MOUNTS[@]}" --entrypoint ffprobe "$IMAGE" \
  -v error -select_streams v:0 -show_entries stream=codec_name,pix_fmt,color_transfer \
  -of default=noprint_wrappers=1:nokey=1 "/in/$(basename "$INPUT")" 2>/dev/null | tr '\n' ' ')

echo ""
echo "INPUT:  $INPUT"
echo "  size:     $(human_size "$SRC_SIZE")"
echo "  duration: ${SRC_DUR}s"
echo "  video:    $SRC_CODEC"
echo ""

run_encode cpu "" "$CPU_OUT"
echo ""
run_encode gpu "--gpus all" "$GPU_OUT"

CPU_TIME=$(cat "$CPU_OUT.time")
GPU_TIME=$(cat "$GPU_OUT.time")
CPU_SIZE=$(stat -c%s "$CPU_OUT")
GPU_SIZE=$(stat -c%s "$GPU_OUT")
CPU_BITRATE=$(awk -v s="$CPU_SIZE" -v d="$SRC_DUR" 'BEGIN{ printf "%.0f", s*8/d/1000 }')
GPU_BITRATE=$(awk -v s="$GPU_SIZE" -v d="$SRC_DUR" 'BEGIN{ printf "%.0f", s*8/d/1000 }')
SPEEDUP=$(awk -v c="$CPU_TIME" -v g="$GPU_TIME" 'BEGIN{ if (g>0) printf "%.1fx", c/g; else printf "n/a" }')

echo ""
echo "=== Quality (SSIM vs source) ==="
echo "computing CPU SSIM..."
CPU_SSIM=$(compute_ssim "$(basename "$INPUT")" "$(basename "$CPU_OUT")")
echo "computing GPU SSIM..."
GPU_SSIM=$(compute_ssim "$(basename "$INPUT")" "$(basename "$GPU_OUT")")

echo ""
printf '%-12s | %-14s | %-12s | %-12s | %-10s\n' "encode" "wall time" "size" "bitrate" "SSIM"
printf '%-12s-+-%-14s-+-%-12s-+-%-12s-+-%-10s\n' "------------" "--------------" "------------" "------------" "----------"
printf '%-12s | %-14s | %-12s | %-12s | %-10s\n' "CPU"  "${CPU_TIME}s"  "$(human_size "$CPU_SIZE")"  "${CPU_BITRATE} kbps"  "$CPU_SSIM"
printf '%-12s | %-14s | %-12s | %-12s | %-10s\n' "GPU"  "${GPU_TIME}s"  "$(human_size "$GPU_SIZE")"  "${GPU_BITRATE} kbps"  "$GPU_SSIM"
echo ""
echo "GPU speedup: $SPEEDUP"
echo "Outputs in:  $ABSDIR_OUT"
