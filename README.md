# easy-ffmpeg

A smart CLI wrapper around ffmpeg for video conversion, remuxing, and image sequence encoding. It analyzes your input, picks the best strategy (copy when possible, transcode only when needed), and shows clear progress.

## Features

- **Smart remuxing** — copies streams when compatible, only transcodes what's necessary
- **Presets** — one-flag profiles for web, mobile, streaming, and compression
- **Trimming** — cut clips with `--start`, `--end`, and `--duration`
- **Image sequences** — turn a folder of images into a video or animated GIF
- **Progress bar** — real-time encoding progress with ETA
- **Dry run** — preview the exact ffmpeg command before running it

## Requirements

- [ffmpeg](https://ffmpeg.org/) (includes ffprobe)
- [Crystal](https://crystal-lang.org/) 1.19+ (to build from source)

## Installation

### Quick install

```sh
curl -fsSL https://raw.githubusercontent.com/akitaonrails/easy-ffmpeg/main/install.sh | sh
```

Pre-built binaries are available for Linux (x86_64, arm64) and macOS (Intel, Apple Silicon).

### Download from GitHub Releases

Grab the binary for your platform from the [latest release](https://github.com/akitaonrails/easy-ffmpeg/releases/latest), make it executable, and move it to your `$PATH`.

### Build from source

```sh
git clone https://github.com/akitaonrails/easy-ffmpeg.git
cd easy-ffmpeg
crystal build src/easy_ffmpeg.cr -o bin/easy-ffmpeg --release
```

Copy `bin/easy-ffmpeg` somewhere in your `$PATH`.

## Usage

```
easy-ffmpeg <input> <format> [options]
```

- `input` — a video file or a directory of images
- `format` — output format: `mp4`, `mkv`, `mov`, `webm`, `avi`, `ts`, or `gif` (GIF for image sequences only)

### Video Conversion

**Remux MKV to MP4** (no re-encoding, very fast):

```sh
easy-ffmpeg movie.mkv mp4
```

**Convert for web embedding** (H.264 + AAC, faststart):

```sh
easy-ffmpeg movie.mkv mp4 --web
```

**Compress a large file** (H.265, CRF 28):

```sh
easy-ffmpeg movie.mkv mp4 --compress
```

**Optimize for mobile** (H.264 720p, AAC stereo):

```sh
easy-ffmpeg movie.mkv mp4 --mobile
```

**Streaming-quality encode** (H.265, Netflix/YouTube-like):

```sh
easy-ffmpeg movie.mkv mp4 --streaming
```

### Trimming

**Extract a 90-second clip starting at 1:30:**

```sh
easy-ffmpeg movie.mkv mp4 --start 1:30 --duration 90
```

**Trim from 10 minutes to 15 minutes:**

```sh
easy-ffmpeg movie.mkv mp4 --start 10:00 --end 15:00
```

**Combine trimming with a preset and custom output path:**

```sh
easy-ffmpeg movie.mkv mp4 --mobile --start 0:30 --end 2:00 -o clip.mp4
```

Time formats: `90` (seconds), `1:31` (mm:ss), `1:31.500` (mm:ss.ms), `1:02:30` (hh:mm:ss), `1:02:30.5` (hh:mm:ss.ms).

### Scaling & Aspect Ratio

**Scale to 720p:**

```sh
easy-ffmpeg movie.mkv mp4 --scale hd
```

**Pad to 16:9 (black bars):**

```sh
easy-ffmpeg movie.mkv mp4 --aspect wide
```

**Crop to square:**

```sh
easy-ffmpeg movie.mkv mp4 --aspect square --crop
```

**Scale and change aspect ratio:**

```sh
easy-ffmpeg movie.mkv mp4 --scale fullhd --aspect wide
```

Scale presets: `2k` (1440p), `fullhd` (1080p), `hd` (720p), `retro` (480p), `icon` (240p). Only downscales — skipped if the source is already at or below the target height.

Aspect ratio presets: `wide` (16:9), `4:3`, `8:7`, `square` (1:1), `tiktok` (9:16). Default mode adds black bars (pad); use `--crop` to crop instead.

Both `--scale` and `--aspect` work with image sequences and GIF output.

### Image Sequences

Turn a directory of numbered images (PNG, JPG, BMP, TIFF, WebP) into a video or animated GIF.

**Create an MP4 from a folder of PNGs:**

```sh
easy-ffmpeg /path/to/frames/ mp4
```

**Create an animated GIF at 15 fps:**

```sh
easy-ffmpeg /path/to/frames/ gif --fps 15
```

**Apply a preset to an image sequence:**

```sh
easy-ffmpeg /path/to/frames/ mp4 --compress
```

**Preview the ffmpeg command without running it:**

```sh
easy-ffmpeg /path/to/frames/ mp4 --dry-run
```

The tool auto-detects sequential numbering (e.g. `frame_0001.png`, `frame_0002.png`) for efficient input, and falls back to glob mode for non-sequential filenames. If the directory contains mixed image formats, the most common one is used.

Default frame rate is 24 fps for video and 10 fps for GIF. Override with `--fps`.

### Other Options

| Flag | Description |
|---|---|
| `--scale NAME` | Scale resolution: `2k`, `fullhd`, `hd`, `retro`, `icon` |
| `--aspect RATIO` | Aspect ratio: `wide`, `4:3`, `8:7`, `square`, `tiktok` |
| `--crop` | Crop to aspect ratio instead of padding (requires `--aspect`) |
| `--fps N` | Frame rate for image sequences (1-120) |
| `-o PATH` | Custom output file path |
| `--dry-run` | Print the ffmpeg command without executing |
| `--force` | Overwrite output file if it exists |
| `--no-subs` | Drop all subtitle tracks |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## How It Works

1. **Analyze** — probes the input with ffprobe to identify all streams
2. **Plan** — decides per-stream: copy (compatible), transcode (incompatible), or drop
3. **Execute** — runs ffmpeg with progress tracking
4. **Report** — shows output file size, compression ratio, and elapsed time

For image sequences, it scans the directory, detects the naming pattern, probes resolution from the first image, and builds the appropriate ffmpeg command (including palette generation for GIFs).

## Development

```sh
crystal build src/easy_ffmpeg.cr -o bin/easy-ffmpeg
```

## Contributing

1. Fork it (<https://github.com/akitaonrails/easy-ffmpeg/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [AkitaOnRails](https://github.com/akitaonrails) - creator and maintainer
