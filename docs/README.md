# Documentation

Extended documentation for `easy-ffmpeg`. The project [README](../README.md) covers installation, usage, and a headline benchmark; the documents below go deeper.

## Index

| Document | What it covers |
|---|---|
| [**nvidia-acceleration.md**](nvidia-acceleration.md) | Full writeup of the `--gpu` flag added in v0.3.0 — when to use it, why Docker, why CUDA 12.8, the two-tier pipeline, encoder mapping, quality auto-tuning, the three `--gpu-quality` modes, HDR preservation, auto-deinterlace, batch processing, troubleshooting, and known limitations. |
| [**benchmarks.md**](benchmarks.md) | CPU vs GPU measurements on real content, methodology, how to reproduce on your own hardware, how to compute SSIM manually, NVENC / NVDEC capability differences by GPU generation. |

## Quick links

- **I just want to install** → [Installation](../README.md#installation)
- **I'm curious how `--gpu` works internally** → [Pipeline tiers](nvidia-acceleration.md#how-the-pipeline-works)
- **I want smaller GPU files** → [`--gpu-quality smaller`](nvidia-acceleration.md#quality-modes---gpu-quality)
- **I want to benchmark my own hardware** → [Reproducing on your machine](benchmarks.md#reproducing-on-your-machine)
- **`--gpu` is slow or failing** → [Troubleshooting](nvidia-acceleration.md#troubleshooting)
- **My GPU is older — what works?** → [Capabilities by GPU generation](benchmarks.md#nvenc--nvdec-capabilities-by-gpu-generation)
