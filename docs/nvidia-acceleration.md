# NVIDIA GPU Acceleration

This document covers the optional NVIDIA hardware acceleration layer added
in v0.3.0. It's gated behind the `--gpu` flag — when not passed, the CLI
behaves exactly as it did in previous versions, with no CUDA / Docker
dependency.

When `--gpu` is passed, the CLI drives a full NVIDIA hardware pipeline:
NVDEC decode → CUDA filters → NVENC encode, with no frames leaving the
GPU when possible.

## When to use `--gpu`

| Use case | Use `--gpu` |
|---|:---:|
| macOS (Apple Silicon or Intel) | No (CUDA does not run on macOS) |
| Linux, no NVIDIA GPU | No (no NVENC encoder available) |
| Linux / WSL2 with NVIDIA GPU, batch processing | Yes |
| Encoding a small one-off clip | Optional — gain is small for short content |
| You want the smallest install footprint | No (skip the Docker setup) |

The default install path (Homebrew / `install.sh`) gives you the full CPU
CLI in one command, depends only on a system `ffmpeg`, and works
identically on macOS. **No changes were made to the macOS or non-GPU code
paths in v0.3.0** — the smart-remux logic, presets, trimming, image
sequences, and the entire CLI without `--gpu` behave exactly as before.

## Why Docker?

The default install is "Crystal + a system ffmpeg." That's two things.

Adding NVENC/NVDEC means adding, at minimum:

- The CUDA Toolkit (~3 GB), including `nvcc`
- `libnpp-dev`, `libcuda-dev`, and matching runtime libs
- nv-codec-headers cloned from the right tag for your GPU generation
- A custom `ffmpeg` build, compiled with `--enable-cuda-nvcc --enable-nvenc
  --enable-nvdec --enable-cuvid --enable-libnpp`, because distro packages
  rarely include all of these

Installing that on your host is invasive and version-sensitive (a CUDA
upgrade can break your system ffmpeg, your machine-learning tooling, etc.).
A multi-stage Dockerfile keeps every one of those moving parts inside an
image you can rebuild or throw away without touching the rest of your
system.

The included setup works the same on native Linux and on WSL2 with the
NVIDIA driver and `nvidia-container-toolkit` installed.

## Why CUDA 12.8?

The base image is `nvcr.io/nvidia/cuda:12.8.2-runtime-ubuntu24.04`. CUDA
12.8 is **the minimum CUDA Toolkit that supports the RTX 50-series
(Blackwell, SM 12.0)** — earlier toolkits don't recognize the new compute
capability and the resulting binary fails to load on those GPUs. The same
image still works on Turing / Ampere / Ada (RTX 20/30/40), so 12.8 is a
safe lower bound for any consumer NVIDIA GPU you're likely to run today.
NVIDIA's own documentation does not require CUDA 13 for the ffmpeg + NVENC
toolchain.

The matching `nv-codec-headers` tag is `n13.0.19.0` (Video Codec SDK 13.0).
Earlier tags (12.x) compile fine but NVDEC silently fails on Blackwell
with `CUDA_ERROR_INVALID_VALUE` and ffmpeg falls back to software decode —
the encode still works, just without the decode acceleration.

## Quick start

```sh
# 1. Build the image (compiles FFmpeg from source — first build is 10-20 min)
scripts/docker-build.sh

# 2. Confirm everything works (encoder list, hwaccel, real NVENC encode)
scripts/docker-build.sh --skip-build

# 3a. Run via docker run directly
docker run --rm --gpus all -v "$PWD":/work easy-ffmpeg:cuda \
  input.mkv mp4 --compress --gpu

# 3b. Or via the wrapper (auto-mounts, auto-generates output name)
./scripts/easy-ffmpeg-docker.sh -i input.mkv -f mp4 --compress --gpu
```

`scripts/docker-build.sh` accepts:
- `--no-cache` — force a fresh FFmpeg compile
- `--skip-build` — run only the smoke tests on the existing image
- `--skip-gpu` — CPU-only tests (useful in CI without a GPU)

### The wrapper script (`scripts/easy-ffmpeg-docker.sh`)

The wrapper exists so day-to-day use doesn't require typing
`docker run --rm --gpus all -v ... easy-ffmpeg:cuda` every time. It:

- Accepts absolute or relative input paths via `-i`
- Mounts the input's parent directory into the container as `/work`
- Generates the output filename next to the input as
  `<input_stem>_<tags>_<YYYYMMDDHHMMSS>.<format>`, where `<tags>` is the
  set of preset / mode flags passed (`web`, `mobile`, `streaming`,
  `compress`, `gpu`, `no-subs`, `crop`, `force`) — so repeated runs with
  different flags don't overwrite each other
- Passes everything else straight through to `easy-ffmpeg`

The wrapper is **self-contained**: it doesn't read anything from this repo,
it just calls `docker run` against the `easy-ffmpeg:cuda` image. Once the
image is built and the script is in your `PATH`, you can delete the source
checkout.

Install globally:

```sh
mkdir -p ~/.local/bin
cp scripts/easy-ffmpeg-docker.sh ~/.local/bin/easy-ffmpeg
chmod +x ~/.local/bin/easy-ffmpeg
```

Then from anywhere:

```sh
easy-ffmpeg -i video.mkv -f mp4 --compress --gpu
easy-ffmpeg -i ~/movies/foo.mp4 -f mp4 --web --gpu
easy-ffmpeg -h    # full help
```

Override the Docker image tag via the `IMAGE` env var when needed:

```sh
IMAGE=easy-ffmpeg:latest easy-ffmpeg -i video.mkv -f mp4 --gpu
```

> **Note on naming:** the wrapper is named `easy-ffmpeg` so it behaves
> like a normal CLI from the user's perspective. If you already have the
> Crystal-built `easy-ffmpeg` binary installed elsewhere (e.g. via
> Homebrew), placing the wrapper in `~/.local/bin/easy-ffmpeg` will
> shadow it — `which easy-ffmpeg` shows which one wins. That's usually
> what you want (this wrapper is a superset: same CLI, plus `--gpu`),
> but if you prefer to keep both, pick a different name like
> `easy-ffmpeg-gpu`.

Requirements on the host:

- An NVIDIA GPU with the encoder you want to use (see [encoder table](#encoder-mapping))
- A recent NVIDIA driver loaded
- [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
  so Docker can pass `--gpus all` through to the container

## What's in the image

Multi-stage build:

| Stage | Base | Purpose |
|---|---|---|
| `ffmpeg-builder` | `cuda:12.8.2-devel-ubuntu24.04` | Compiles FFmpeg with `--enable-cuda-nvcc --enable-libnpp --enable-nvenc --enable-nvdec --enable-cuvid` plus every codec lib the CLI may invoke (libx264/265/vpx/svtav1/theora/mp3lame/opus/vorbis/dav1d/webp/ass/freetype) |
| `app-builder` | `cuda:12.8.2-runtime-ubuntu24.04` | Installs Crystal and compiles `bin/easy-ffmpeg --release` |
| _(final)_ | `cuda:12.8.2-runtime-ubuntu24.04` | Copies the FFmpeg binaries + libs and the CLI binary. Keeps the Crystal toolchain installed so the project can be rebuilt in-place. `NVIDIA_DRIVER_CAPABILITIES=all` so the container can drive compute / utility / video / graphics |

The build is layer-cached: a code change in `src/` rebuilds the Crystal app
stage in ~30s and reuses the (slow) FFmpeg compile from cache.

## How the pipeline works

Add `--gpu` to any transcode that maps to H.264, H.265, or AV1. The CLI
picks the fastest tier the source allows and applies quality tuning you'd
otherwise have to remember by hand.

### Two-tier pipeline

| Tier | Flags emitted to ffmpeg | When |
|---|---|---|
| **Pure GPU** | `-hwaccel cuda -hwaccel_output_format cuda` + `scale_cuda` / `yadif_cuda` filters | Default with `--gpu` when the encoder is NVENC and `--aspect` is not set. Frames stay on the GPU end-to-end. |
| **Mixed** | `-hwaccel cuda` (decode only) | When CPU-only filters are unavoidable (e.g. `--aspect wide`, `--aspect square --crop`). Decode runs on the GPU, frames are downloaded for filtering, then re-uploaded for encoding. |

Use `--dry-run` to see which tier was chosen:

```sh
easy-ffmpeg input.mkv mp4 --compress --gpu --dry-run
```

### Encoder mapping

| CPU codec (preset choice) | NVENC codec | Hardware floor |
|---|---|---|
| `libx264` | `h264_nvenc` | All NVIDIA GPUs from Kepler+ |
| `libx265` | `hevc_nvenc` | Maxwell 2nd gen+ (HDR-capable) |
| `libsvtav1` | `av1_nvenc` | Ada Lovelace (RTX 40+) only |
| `libvpx-vp9` | _(no NVENC)_ | Falls back to CPU silently |

The wrapper translates rate-control args automatically:

```
libx264/libx265: -crf N -preset medium
        ↓
NVENC:           -cq N -b:v 0 -preset p5 -rc vbr -tune hq
```

### Quality auto-tuning

Every NVENC encode gets a set of quality tuning args that depend on the
chosen `--gpu-quality` mode (see [Quality modes](#quality-modes---gpu-quality)
below). The default mode `balanced` adds:

```
-rc-lookahead 20  -spatial-aq 1  -temporal-aq 1  -bf 3  -b_ref_mode middle
```

These reduce bitrate ~5-15% at the same perceived quality with negligible
encode-time cost. Requires NVIDIA Turing (RTX 20-series) or newer for full
effect; older GPUs silently ignore the bits they don't support.

### Quality modes (`--gpu-quality`)

`--gpu-quality` picks a coarse speed-vs-size trade-off for the NVENC encode.
Default is `balanced`.

| Mode | NVENC preset | CQ offset | Quality tuning | Relative speed | Relative size |
|---|:---:|:---:|---|:---:|:---:|
| `fast` | `p2` | 0 | _none_ | ~2-3× faster than balanced | ~1.1-1.3× larger |
| `balanced` (default) | `p5` | 0 | `rc-lookahead 20`, `spatial-aq 1`, `temporal-aq 1`, `bf 3`, `b_ref_mode middle` | 1.0 | 1.0 |
| `smaller` | `p7` | +5 | `rc-lookahead 32`, `spatial-aq 1`, `temporal-aq 1`, `bf 4`, `b_ref_mode middle` | ~0.7× (slower) | ~0.6× (smaller) |

How to read the table:

- **CQ offset** is added to the `-cq` value the wrapper computes from the
  CPU `-crf`. So `--compress` (which uses `-crf 28`) becomes `-cq 28` in
  `balanced` and `-cq 33` in `smaller`.
- **NVENC preset** controls how exhaustively the hardware encoder analyzes
  each block. `p1` is fastest / lowest quality-per-bit, `p7` is slowest /
  best quality-per-bit. All still run in hardware.
- **Quality tuning** is the set of extra args appended after the rate
  control args.

Examples:

```sh
# Default — fast + high quality + slightly larger files than libx265
easy-ffmpeg movie.mkv mp4 --compress --gpu

# I want it done now, file size doesn't matter much
easy-ffmpeg movie.mkv mp4 --compress --gpu --gpu-quality fast

# I want the file as small as libx265 makes it (no SSIM advantage)
easy-ffmpeg movie.mkv mp4 --compress --gpu --gpu-quality smaller
```

When to use each mode:

- **`fast`** — previews, transcoding for editing, content you'll re-encode later.
  The extra size doesn't matter because the file is temporary.
- **`balanced`** — general-purpose viewing and sharing. Quality advantage over
  libx265 may be useful for HDR or grainy content.
- **`smaller`** — long-term archive, large library, disk pressure. Still 3-4×
  faster than libx265 medium on a modern GPU, and the size matches libx265.

`--gpu-quality` requires `--gpu`. Passing it alone errors out:

```
error: --gpu-quality requires --gpu
```

### HDR preservation

When the source is HDR (transfer characteristic `smpte2084` for HDR10 /
HDR10+ or `arib-std-b67` for HLG) and the encoder is `hevc_nvenc`, the
wrapper propagates the color metadata:

```
-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv
```

The 10-bit bit depth is inherited automatically from the input surface;
the wrapper does **not** set `-pix_fmt p010le` explicitly because that
would conflict with CUDA hwaccel surfaces.

`--compress` and `--streaming` use HEVC by default, so HDR sources stay
HDR with `--gpu`. `--web` and `--mobile` use H.264 (no robust HDR support)
and produce SDR 8-bit output.

### Auto-deinterlacing

If ffprobe reports an interlaced field order on the source
(`field_order != progressive`), the wrapper prepends `yadif_cuda` (pure GPU
tier) or `yadif` (mixed tier) to the filter chain. No flag required — this
catches DVD / broadcast captures that would otherwise produce comb
artifacts.

The filter is placed before scale and aspect filters so downstream
operations see progressive frames.

## Real-world benchmarks

The README has a [results table](../README.md#cpu-vs-gpu-benchmark) measured
on an Intel Core i9-14900K + NVIDIA RTX 5080 setup, with caveats about
hardware variability. To run the same benchmark on your machine:

```sh
scripts/benchmark.sh /path/to/your/input.mp4 compress /path/to/outdir
```

The script encodes the same `--compress` preset twice (CPU vs GPU) and
computes SSIM against the source. It prints a table with wall time, output
size, bitrate, and SSIM for each run.

### Methodology notes

- **Wall time** is measured around the `docker run` command — it includes
  container startup (~3s on this setup), ffmpeg init, NVDEC / NVENC
  session creation, and the encode itself. For short clips this overhead
  dominates and the speedup looks smaller than the steady-state NVENC
  throughput suggests; for clips of a few minutes or more it amortizes
  to near zero.
- **SSIM** is computed via `ffmpeg -lavfi "[0:v][1:v]ssim" -f null -`,
  with the source as input 0 and the encoded output as input 1. Higher
  is better; values above 0.99 are typically visually indistinguishable
  from the source.
- **NVENC `-cq` is not the same scale as libx265 `-crf`.** The wrapper
  maps them 1:1 for simplicity, so the GPU output tends to be slightly
  larger but higher-quality (higher SSIM) at the same numeric value.
  Raise `-cq` if you want size parity (out of scope for the auto-tuning
  defaults; achievable via a custom preset).

## Batch processing

Hardware acceleration is most valuable when you have many files. The
examples below assume you've installed the wrapper at
`~/.local/bin/easy-ffmpeg` (see [The wrapper script](#the-wrapper-script-scriptseasy-ffmpeg-dockersh))
— it handles the docker mount, the output filename, and the timestamp
automatically.

Serial loop:

```sh
for f in /videos/raw/*.mkv; do
  easy-ffmpeg -i "$f" -f mp4 --compress --gpu --force
done
```

Each output lands next to its input as
`<stem>_compress_gpu_force_<YYYYMMDDHHMMSS>.mp4`.

Parallel (two encodes at a time — most modern RTX cards allow 3+
concurrent NVENC sessions):

```sh
ls /videos/raw/*.mkv | xargs -P 2 -I {} \
  easy-ffmpeg -i {} -f mp4 --compress --gpu --force
```

If you'd rather invoke `docker run` directly (custom mounts, custom
output naming, CI scripts), see the snippet at the bottom of
[The wrapper script](#the-wrapper-script-scriptseasy-ffmpeg-dockersh).

## Limitations and known issues

### NVDEC H.264 surface limit on Blackwell

Some H.264 streams require more decode surfaces than NVDEC on Blackwell
(RTX 50-series) will allocate. They fail with:

```
[h264 @ ...] decoder->cvdl->cuvidCreateDecoder failed -> CUDA_ERROR_INVALID_VALUE
[h264 @ ...] Using more than 32 (37) decode surfaces might cause nvdec to fail.
```

ffmpeg falls back to software decode automatically, NVENC continues to
encode, and the overall encode is still faster than pure-CPU. The
benchmark above (`nvidia_capture01.mp4`, 2.7x speedup) hit this and still
came out ahead. `-extra_hw_frames` and `-hwaccel_flags +unsafe_output` do
not work around it. HEVC NVDEC is unaffected.

### AV1 NVENC requires RTX 40+

The `av1_nvenc` encoder is Ada Lovelace and newer. On older cards, requests
for AV1 output silently fall back to CPU encoding (`libsvtav1`). The CLI
prints the chosen encoder in the dry-run output.

### macOS

This Docker image is Linux-only (CUDA does not run on macOS). On macOS,
install the standard easy-ffmpeg binary via Homebrew or the binary
download — the CPU CLI is unchanged in v0.3.0.

### `--gpu` without an NVENC-capable ffmpeg

The CLI fails fast with a clear message:

```
--gpu requested but no NVENC encoders found in this ffmpeg build
  Build ffmpeg with --enable-nvenc or install an NVIDIA-enabled package.
```

Always true when running outside the Docker image, on a system whose
ffmpeg wasn't compiled with `--enable-nvenc`.

## Troubleshooting

### "could not select device driver with capabilities: gpu"
The `nvidia-container-toolkit` isn't installed or configured. Follow
NVIDIA's [install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).
On WSL2, install it inside the Linux distro (not on Windows).

### "Failed to load NVML: Driver/library version mismatch"
Restart the container engine after a driver update (`systemctl restart docker`),
or reboot the host on WSL.

### Encode is slower than expected
1. Check `docker run --rm --gpus all easy-ffmpeg:cuda --version` runs fast
   (~3s). If it's slow, the GPU isn't reachable from the container.
2. Watch `nvidia-smi dmon` during an encode. NVENC utilization should be
   non-zero; if it's zero, NVDEC fell back to software and you're CPU-bound
   on decode. Try a different source (HEVC inputs work more reliably than
   H.264 on Blackwell).
3. Confirm the dry-run shows `-hwaccel cuda` and the quality-tuning args
   are present. If they're missing, your Docker image is stale — rebuild.

### `bin_data` stream in MP4 output
Some MKVs carry chapter metadata that ffmpeg maps as a `bin_data` data
stream. It's harmless. To drop it, add `--no-subs` (which also removes
auxiliary streams).

## Development

To work on the GPU code path without a host CUDA install, build the
image and run the spec suite inside it:

```sh
scripts/docker-build.sh
docker run --rm --gpus all -v "$PWD":/app -w /app \
  --entrypoint crystal easy-ffmpeg:cuda spec
```

The `spec/integration/` specs auto-skip when no NVENC is available in the
ffmpeg build, so the same suite can be run on a CPU-only machine for the
unit specs.
