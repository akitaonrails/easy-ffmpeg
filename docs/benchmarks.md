# Benchmarks

CPU vs GPU measurements for the NVIDIA acceleration path. All numbers below
were captured with `scripts/benchmark.sh`, which runs the same `--compress`
preset twice (CPU + GPU) and computes SSIM against the source.

## Test hardware

- **CPU:** Intel Core i9-14900K (24 cores / 32 threads)
- **GPU:** NVIDIA GeForce RTX 5080 (Blackwell, 16 GB VRAM, driver 596.36)
- **OS:** Ubuntu 24.04 LTS on WSL2 (kernel 6.6)
- **CUDA:** 12.8.2 (via the Docker image shipped here)

## Headline result — full-length movie (best-case workload)

Source: H.264 1080p @ 23.976 fps + AC3 5.1 + DTS 5.1, duration 1h38m, size **5.8 GB**.

| Encode | Time | Output size | SSIM |
|---|---:|---:|---:|
| CPU (libx265 `-crf 28 -preset medium`) | 29m48s | 1.0 GB | 0.9426 |
| GPU balanced (default `--gpu`) | **4m50s** | 1.8 GB | **0.9462** |
| GPU smaller (`--gpu-quality smaller`) | 11m19s | **993 MB** | 0.9405 |

What this shows:

- **GPU `balanced` is 6.2× faster and slightly higher quality** than CPU, at the cost of a ~1.8× larger file.
- **GPU `smaller` essentially matches CPU output** (993 MB vs 1.0 GB; SSIM 0.9405 vs 0.9426 — gap is well below human perception) in **less than half the wall time**.

## Short clips

These show the speedup at the per-encode level. Wall time on short clips is dominated by Docker startup + ffmpeg init, so the speedup is artificially compressed — useful only as a sanity check that the pipeline works on each format.

### H.264 1080p SDR (screen capture, 2m17s, source 86.9 MB)

| Encode | Time | Output size | SSIM |
|---|---:|---:|---:|
| CPU | 28.3s | 10.7 MB | 0.9928 |
| GPU balanced | 10.3s | 14.7 MB | 0.9959 |

### HEVC 1080p 10-bit HDR — BT.2020 / PQ (10s, source 4.0 MB)

| Encode | Time | Output size | SSIM |
|---|---:|---:|---:|
| CPU | 6.3s | 621 KB | 0.9930 |
| GPU balanced | 4.9s | 929 KB | 0.9949 |

HDR color metadata (`pix_fmt`, `color_primaries`, `color_transfer`, `color_space`, `color_range`) was preserved byte-identical from source to output. See [HDR preservation](nvidia-acceleration.md#hdr-preservation) for the detection logic.

## How to read these numbers

- **GPU `balanced` is the default `--gpu` behavior.** It produces higher-quality output (higher SSIM) than libx265 at the same numeric `-crf`/`-cq` value, at the cost of larger files. NVENC's hardware pipeline is more conservative about discarding detail than libx265's rate-distortion search.
- **GPU `smaller` is the opt-in tighter mode** (`--gpu-quality smaller`). It bundles preset p7, `-cq +5`, and boosted lookahead/B-frames to produce files comparable in size to libx265. It's slower than `balanced` but still 2-3× faster than CPU on long content.
- **SSIM on the full movie was computed against the source.** Each pass finished in ~2 minutes because NVDEC HEVC decode reads both streams in parallel at well above realtime — much faster than the encode itself.

## Reproducing on your machine

```sh
scripts/benchmark.sh /path/to/your/input.mkv compress /path/to/outdir
```

The script:

1. Runs `--compress` (CPU only) on the input, times it, saves the output and timing
2. Runs `--compress --gpu` on the same input, times it, saves the output and timing
3. Computes SSIM of both outputs vs the source
4. Prints a comparison table

You can override the image tag with `IMAGE=easy-ffmpeg:latest scripts/benchmark.sh ...`. For `--gpu-quality smaller` runs, invoke easy-ffmpeg directly (the benchmark script only compares default balanced GPU vs CPU).

## Computing SSIM manually

If you've already encoded a file (for instance with `--gpu-quality smaller`) and want to measure its quality against the source without re-running the benchmark script, use ffmpeg's `ssim` filter directly inside the Docker image:

```sh
docker run --rm --gpus all -v /path/to/videos:/v --entrypoint ffmpeg easy-ffmpeg:cuda \
  -hide_banner -nostats -v info \
  -i /v/source.mkv \
  -i /v/encoded.mp4 \
  -lavfi "[0:v][1:v]ssim" -f null -
```

The filter prints one line at the end:

```
[Parsed_ssim_0 @ 0x...] SSIM Y:0.926266 (11.323) U:0.977125 (16.406) V:0.973523 (15.771) All:0.942618 (12.412)
```

What the columns mean:

- **Y / U / V** — per-plane SSIM (Y = luminance, U/V = chroma). The Y channel dominates perceived quality.
- **All** — combined SSIM across all planes. This is the headline number used in the tables above.
- **(N.NNN)** in parentheses — the equivalent in dB.

How to read the value:

| All SSIM | Meaning |
|---|---|
| > 0.99 | Visually indistinguishable from source |
| 0.97 – 0.99 | Very close; differences only visible on still frames under careful inspection |
| 0.94 – 0.97 | Acceptable for typical viewing; some detail loss visible if you A/B-compare |
| < 0.94 | Visible compression artifacts in motion |

**`-gpus all` is important even for SSIM-only runs**, because NVDEC accelerates the decode of both input streams in parallel — a full-length movie completes in ~2 minutes instead of 20-40 minutes of software decode.

For multiple outputs against the same source, run the command once per encoded file:

```sh
for f in /path/to/videos/encoded*.mp4; do
  echo "=== $(basename "$f") ==="
  docker run --rm --gpus all -v /path/to/videos:/v --entrypoint ffmpeg easy-ffmpeg:cuda \
    -hide_banner -nostats -v info \
    -i /v/source.mkv -i "/v/$(basename "$f")" \
    -lavfi "[0:v][1:v]ssim" -f null - 2>&1 | grep -oE 'All:[0-9.]+'
done
```

This is exactly how the full-movie SSIM numbers in the tables above were computed. The benchmark script (`scripts/benchmark.sh`) automates the same flow for its CPU-vs-GPU comparison.

## Caveats

- **One machine, one driver version.** Speedup ratios depend on CPU/GPU mix, driver version, source bitrate, resolution (4K typically shows a much larger GPU advantage), and the preset chosen.
- **Keep your NVIDIA driver up to date.** Recent CUDA features (and Blackwell support specifically) require driver 555+ on Linux / WSL.

## NVENC / NVDEC capabilities by GPU generation

The CLI's `--gpu` flag silently falls back to CPU when the chosen encoder isn't available. The table below summarizes what each generation adds — useful for predicting what `--gpu` will and won't accelerate on a given card.

| Generation | Cards | NVENC adds | NVDEC adds |
|---|---|---|---|
| Pascal | GTX 10-series | H.264 + HEVC encode, basic AQ | H.264, HEVC, VP9 8-bit |
| Turing | RTX 20-series, GTX 16-series | B-frames as references, 10-bit HEVC, much better quality at same bitrate | HEVC 4:4:4, VP9 10/12-bit |
| Ampere | RTX 30-series | _(same NVENC as Turing)_ | First AV1 *decode* |
| Ada Lovelace | RTX 40-series | First AV1 *encode* (`av1_nvenc`) | _(same as Ampere)_ |
| Blackwell | RTX 50-series | Throughput + 4:2:2 improvements | _(requires CUDA 12.8+ — Docker image already targets this)_ |

See the [encoder mapping](nvidia-acceleration.md#encoder-mapping) for which `easy-ffmpeg` preset routes to which NVENC encoder.

If you run this benchmark on different hardware, PRs to the tables above are welcome.
