# easy-ffmpeg

A smart CLI wrapper around ffmpeg for video conversion, remuxing, and image sequence encoding. It analyzes your input, picks the best strategy (copy when possible, transcode only when needed), and shows clear progress.

> **New in v0.3.0:** opt-in NVIDIA GPU acceleration (`--gpu`) for **Linux / WSL2 with an NVIDIA GPU**. The CPU and macOS code paths are unchanged — if you don't pass `--gpu`, the CLI behaves the same as previous versions. GPU acceleration requires CUDA + a custom FFmpeg build, packaged via Docker (see [docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)).

## Contents

- [What's new in v0.3.0](#whats-new-in-v030)
- [Headline benchmark (RTX 5080)](#headline-benchmark-rtx-5080)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Development](#development)
- [Contributing](#contributing)

## What's new in v0.3.0

- **`--gpu`** — opt-in NVIDIA hardware pipeline (NVDEC decode → CUDA filters → NVENC encode)
- **`--gpu-quality fast|balanced|smaller`** — speed/size trade-off for the GPU encode
- **End-to-end GPU pipeline** when possible (frames never leave VRAM); graceful CPU/GPU fallback when a filter requires system memory
- **HDR preservation** — 10-bit + BT.2020 / PQ / HLG metadata propagated through `hevc_nvenc`
- **Auto-deinterlace** via `yadif_cuda` / `yadif` when ffprobe reports an interlaced field order
- **Dockerfile + helper scripts** that compile FFmpeg with full CUDA support so you don't have to

Full writeup: **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)**.

## Headline benchmark (RTX 5080)

Source: H.264 1080p movie (1h38m, 5.8 GB) → MP4/HEVC with `--compress`.

| Encode | Time | Output | SSIM |
|---|---:|---:|---:|
| CPU (libx265 `-crf 28 -preset medium`) | 29m48s | 1.0 GB | 0.9426 |
| GPU balanced (default `--gpu`) | **4m50s** | 1.8 GB | **0.9462** |
| GPU smaller (`--gpu-quality smaller`) | 11m19s | **993 MB** | 0.9405 |

In short: **`balanced` is 6.2× faster with slightly higher quality** (at ~1.8× the file size); **`smaller` matches CPU file size with a quality difference below human perception, still 2.6× faster.**

Full benchmark methodology, additional source formats (SDR + HDR clips), and per-generation NVENC/NVDEC capabilities: **[docs/benchmarks.md](docs/benchmarks.md)**.

## Installation

### macOS / Linux without GPU

The simple paths — same as previous versions, no Docker required:

```sh
# macOS
brew install akitaonrails/tap/easy-ffmpeg

# Linux / macOS (binary download)
curl -fsSL https://raw.githubusercontent.com/akitaonrails/easy-ffmpeg/master/install.sh | sh
```

### Linux / WSL2 with NVIDIA GPU — via Docker

```sh
# 1. Clone and build the CUDA image (10-20 min the first time)
git clone <this-repo>
cd easy-ffmpeg
scripts/docker-build.sh

# 2. Install the wrapper globally (copies the script — repo can be deleted after)
mkdir -p ~/.local/bin
cp scripts/easy-ffmpeg-docker.sh ~/.local/bin/easy-ffmpeg
chmod +x ~/.local/bin/easy-ffmpeg

# 3. (Optional) drop the source checkout — the wrapper only needs the Docker image
cd .. && rm -rf easy-ffmpeg

# 4. Use it from anywhere
easy-ffmpeg -i video.mkv -f mp4 --compress --gpu
```

Prerequisites and details (driver version, nvidia-container-toolkit, build options, troubleshooting): **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md#quick-start)**.

### Build the CPU-only Crystal binary from source

```sh
git clone <this-repo>
cd easy-ffmpeg
crystal build src/easy_ffmpeg_cli.cr -o bin/easy-ffmpeg --release
```

Copy `bin/easy-ffmpeg` somewhere in your `$PATH`.

## Usage

```
easy-ffmpeg <input> <format> [options]
```

- `input` — a video file or a directory of images
- `format` — output format: `mp4`, `mkv`, `mov`, `webm`, `avi`, `ts`, or `gif` (GIF for image sequences only)

### Video conversion

```sh
easy-ffmpeg movie.mkv mp4              # remux only (no re-encoding, very fast)
easy-ffmpeg movie.mkv mp4 --web        # H.264 + AAC, faststart
easy-ffmpeg movie.mkv mp4 --compress   # H.265, CRF 28
easy-ffmpeg movie.mkv mp4 --mobile     # H.264 720p, AAC stereo
easy-ffmpeg movie.mkv mp4 --streaming  # H.265, Netflix/YouTube-like
```

### Trimming

```sh
easy-ffmpeg movie.mkv mp4 --start 1:30 --duration 90        # 90s clip starting at 1:30
easy-ffmpeg movie.mkv mp4 --start 10:00 --end 15:00         # absolute trim
easy-ffmpeg movie.mkv mp4 --mobile --start 0:30 --end 2:00 -o clip.mp4
```

Time formats: `90`, `1:31`, `1:31.500`, `1:02:30`, `1:02:30.5`.

### Scaling & aspect ratio

```sh
easy-ffmpeg movie.mkv mp4 --scale hd                  # 720p
easy-ffmpeg movie.mkv mp4 --aspect wide               # pad to 16:9 (black bars)
easy-ffmpeg movie.mkv mp4 --aspect square --crop      # crop to square
easy-ffmpeg movie.mkv mp4 --scale fullhd --aspect wide
```

Scale presets: `2k`, `fullhd`, `hd`, `retro`, `icon` (downscale only).
Aspect presets: `wide` (16:9), `4:3`, `8:7`, `square` (1:1), `tiktok` (9:16). `--crop` to crop instead of pad.

### GPU acceleration

Add `--gpu` to any transcode that maps to H.264, H.265, or AV1:

```sh
easy-ffmpeg movie.mkv mp4 --compress --gpu                          # default (balanced)
easy-ffmpeg movie.mkv mp4 --compress --gpu --gpu-quality fast       # ~2-3× faster, larger
easy-ffmpeg movie.mkv mp4 --compress --gpu --gpu-quality smaller    # similar size to CPU
```

Through the Docker wrapper (no `docker run` boilerplate):

```sh
easy-ffmpeg -i movie.mkv -f mp4 --compress --gpu
```

The wrapper requires `-i <input>` and `-f <format>` (positional `<format>` also works for backwards compatibility).

Pipeline tiers, quality auto-tuning, HDR preservation, auto-deinterlace: **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)**.

### Image sequences

```sh
easy-ffmpeg /path/to/frames/ mp4                # video from PNG/JPG/BMP/TIFF/WebP
easy-ffmpeg /path/to/frames/ gif --fps 15       # animated GIF at 15 fps
easy-ffmpeg /path/to/frames/ mp4 --compress    # with preset
```

Default frame rate is 24 fps for video, 10 fps for GIF. Auto-detects sequential numbering.

### Flags

| Flag | Description |
|---|---|
| `--scale NAME` | Scale resolution: `2k`, `fullhd`, `hd`, `retro`, `icon` |
| `--aspect RATIO` | Aspect ratio: `wide`, `4:3`, `8:7`, `square`, `tiktok` |
| `--crop` | Crop to aspect ratio instead of padding |
| `--gpu` | Use NVIDIA NVENC for H.264/H.265/AV1 transcodes |
| `--gpu-quality MODE` | NVENC mode: `fast` \| `balanced` (default) \| `smaller` |
| `--fps N` | Frame rate for image sequences (1-120) |
| `-o PATH` | Custom output file path |
| `--dry-run` | Print the ffmpeg command without executing |
| `--force` | Overwrite output file if it exists |
| `--no-subs` | Drop all subtitle tracks |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## Documentation

- **[docs/nvidia-acceleration.md](docs/nvidia-acceleration.md)** — full GPU writeup: rationale, Docker setup, pipeline internals, quality modes, HDR, troubleshooting
- **[docs/benchmarks.md](docs/benchmarks.md)** — full benchmark detail, methodology, per-generation NVENC/NVDEC capabilities

## How It Works

1. **Analyze** — probes the input with ffprobe to identify all streams
2. **Plan** — decides per-stream: copy (compatible), transcode (incompatible), or drop
3. **Execute** — runs ffmpeg with progress tracking
4. **Report** — shows output file size, compression ratio, and elapsed time

## Development

```sh
crystal build src/easy_ffmpeg_cli.cr -o bin/easy-ffmpeg
crystal spec
```

To work on the GPU code path without a local CUDA install, see the [Development section](docs/nvidia-acceleration.md#development) of the GPU docs.

## Contributing

1. Fork it (<https://github.com/akitaonrails/easy-ffmpeg/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [AkitaOnRails](https://github.com/akitaonrails) — creator and maintainer
