#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build and smoke-test the easy-ffmpeg CUDA container.
#
# Steps:
#   1. docker build -> easy-ffmpeg:cuda  (also tags :latest)
#   2. Run a CPU-only smoke test (no GPU required):
#        - ffmpeg version
#        - presence of every encoder the CLI may invoke
#        - presence of NVENC encoders (compiled in even without a GPU)
#        - presence of libdav1d / libwebp decoders
#        - easy-ffmpeg --help works
#   3. If an NVIDIA GPU is detected via nvidia-smi on the host and the
#      Docker runtime supports --gpus, run a GPU smoke test:
#        - nvidia-smi inside the container
#        - 1-second h264_nvenc encode of a generated test pattern
#
# Usage:
#   scripts/docker-build.sh [--no-cache] [--skip-build] [--skip-gpu]
# -----------------------------------------------------------------------------
set -euo pipefail

IMAGE="${IMAGE:-easy-ffmpeg:cuda}"
LATEST_TAG="easy-ffmpeg:latest"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUILD_ARGS=()
SKIP_BUILD=false
SKIP_GPU=false

for arg in "$@"; do
  case "$arg" in
    --no-cache)   BUILD_ARGS+=(--no-cache) ;;
    --skip-build) SKIP_BUILD=true ;;
    --skip-gpu)   SKIP_GPU=true ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1 ;;
  esac
done

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok  \033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m FAIL \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Sanity check
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker not found in PATH"

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = "false" ]; then
  log "Building $IMAGE (this compiles FFmpeg from source — first build takes 10-20 min)"
  docker build "${BUILD_ARGS[@]}" -t "$IMAGE" -t "$LATEST_TAG" .
  ok "Image built: $IMAGE"
else
  log "Skipping build (--skip-build)"
fi

# ---------------------------------------------------------------------------
# 2. CPU smoke tests (no GPU required)
# ---------------------------------------------------------------------------
log "Running CPU smoke tests"

run_in_image() {
  docker run --rm --entrypoint "$1" "$IMAGE" "${@:2}"
}

log "  ffmpeg version"
run_in_image ffmpeg -hide_banner -version | head -n 1
ok "ffmpeg runs"

# All encoders the easy-ffmpeg CLI may invoke
REQUIRED_ENCODERS=(
  libx264 libx265 libvpx-vp9 libsvtav1 libtheora
  h264_nvenc hevc_nvenc av1_nvenc
  aac libmp3lame libopus libvorbis flac
  mov_text subrip ass ssa webvtt
  gif
)

log "  checking required encoders are compiled in"
ENCODERS_OUTPUT="$(run_in_image ffmpeg -hide_banner -encoders 2>/dev/null)"
MISSING=()
for enc in "${REQUIRED_ENCODERS[@]}"; do
  if ! grep -qE "^[[:space:]]+[VAS][[:print:]]*[[:space:]]+${enc}([[:space:]]|$)" <<<"$ENCODERS_OUTPUT"; then
    MISSING+=("$enc")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  fail "missing encoders: ${MISSING[*]}"
fi
ok "all ${#REQUIRED_ENCODERS[@]} encoders present"

# Required decoders. libwebp has no decoder in ffmpeg — the WebP decoder is
# built in and called `webp`. libdav1d is the fast AV1 decoder.
REQUIRED_DECODERS=(libdav1d webp)

log "  checking required decoders are compiled in"
DECODERS_OUTPUT="$(run_in_image ffmpeg -hide_banner -decoders 2>/dev/null)"
MISSING=()
for dec in "${REQUIRED_DECODERS[@]}"; do
  if ! grep -qE "[[:space:]]${dec}([[:space:]]|$)" <<<"$DECODERS_OUTPUT"; then
    MISSING+=("$dec")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  fail "missing decoders: ${MISSING[*]}"
fi
ok "decoders present: ${REQUIRED_DECODERS[*]}"

log "  checking CUDA hwaccel is registered"
if ! run_in_image ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q '^cuda$'; then
  fail "cuda hwaccel not registered in this ffmpeg build"
fi
ok "cuda hwaccel registered"

log "  easy-ffmpeg --help"
docker run --rm "$IMAGE" --help >/dev/null
ok "easy-ffmpeg CLI runs"

log "  crystal toolchain present"
CRYSTAL_VERSION="$(run_in_image crystal --version | head -n 1)"
ok "$CRYSTAL_VERSION"

# ---------------------------------------------------------------------------
# 3. GPU smoke tests (only if a GPU is reachable)
# ---------------------------------------------------------------------------
if [ "$SKIP_GPU" = "true" ]; then
  log "Skipping GPU smoke tests (--skip-gpu)"
  ok "Done."
  exit 0
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  log "nvidia-smi not found on host — skipping GPU tests"
  ok "Done (CPU tests only)."
  exit 0
fi

if ! nvidia-smi >/dev/null 2>&1; then
  log "nvidia-smi present but no GPU reachable — skipping GPU tests"
  ok "Done (CPU tests only)."
  exit 0
fi

log "Running GPU smoke tests"

log "  nvidia-smi inside container"
if ! docker run --rm --gpus all --entrypoint nvidia-smi "$IMAGE" -L >/dev/null 2>&1; then
  fail "container could not reach the GPU — is nvidia-container-toolkit installed?"
fi
docker run --rm --gpus all --entrypoint nvidia-smi "$IMAGE" -L
ok "GPU reachable from container"

log "  encoding 1s test pattern with h264_nvenc"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! docker run --rm --gpus all \
       -v "$TMP_DIR":/out \
       --entrypoint ffmpeg \
       "$IMAGE" \
       -hide_banner -v error \
       -f lavfi -i "testsrc=duration=1:size=640x360:rate=30" \
       -c:v h264_nvenc -preset p4 -y /out/nvenc-test.mp4; then
  fail "h264_nvenc encode failed"
fi

if [ ! -s "$TMP_DIR/nvenc-test.mp4" ]; then
  fail "nvenc output file is empty"
fi
ok "h264_nvenc produced $(stat -c%s "$TMP_DIR/nvenc-test.mp4") bytes"

ok "All tests passed."
