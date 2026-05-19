# syntax=docker/dockerfile:1.7

# =============================================================================
# Stage 1 — Build FFmpeg from source with NVIDIA CUDA / NVENC / NVDEC / NPP.
#
# Uses the CUDA *devel* image because we need nvcc and libnpp headers, which
# are not present in the runtime image.
#
# The set of --enable-* flags and matching -dev packages must cover every
# codec/encoder the easy-ffmpeg Crystal CLI may invoke at runtime:
#
#   Video encoders : libx264, libx265, libvpx-vp9, libsvtav1, libtheora,
#                    h264_nvenc, hevc_nvenc, av1_nvenc
#   Audio encoders : aac (built-in), libmp3lame, libopus, libvorbis,
#                    flac (built-in)
#   Image decoders : png/jpeg/bmp/tiff (built-in), libwebp
#   Video decoders : h264/hevc/vp8/vp9 (built-in), libdav1d (fast AV1)
#   Subtitles      : mov_text/subrip/ass/ssa/webvtt (all built-in)
# =============================================================================
FROM nvcr.io/nvidia/cuda:12.8.2-devel-ubuntu24.04 AS ffmpeg-builder

ARG FFMPEG_REF=n7.1.1
# n13.0.19.0 = NVIDIA Video Codec SDK 13.0 headers. Required for NVDEC on
# Blackwell (RTX 50-series, SM 12.0); older tags compile but NVDEC silently
# falls back to software decode with CUDA_ERROR_INVALID_VALUE.
ARG NV_CODEC_HEADERS_REF=n13.0.19.0
ARG MAKE_JOBS=8

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential yasm nasm cmake libtool pkg-config git ca-certificates \
        wget unzip \
        libc6 libc6-dev libnuma1 libnuma-dev \
        libx264-dev libx265-dev libvpx-dev \
        libsvtav1-dev libsvtav1enc-dev libsvtav1dec-dev \
        libtheora-dev \
        libmp3lame-dev libopus-dev libvorbis-dev \
        libdav1d-dev libwebp-dev \
        libass-dev libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

# Steps 1-2: nv-codec-headers (NVENC/NVDEC/CUVID headers FFmpeg links against)
RUN git clone --depth 1 --branch ${NV_CODEC_HEADERS_REF} \
        https://git.videolan.org/git/ffmpeg/nv-codec-headers.git \
    && make -C nv-codec-headers install \
    && rm -rf nv-codec-headers

# Steps 3-7: clone, configure, compile and install FFmpeg
RUN git clone --depth 1 --branch ${FFMPEG_REF} https://git.ffmpeg.org/ffmpeg.git ffmpeg \
    && cd ffmpeg \
    && ./configure \
        --prefix=/usr/local \
        --enable-nonfree \
        --enable-gpl \
        --enable-cuda-nvcc \
        --enable-cuvid \
        --enable-nvenc \
        --enable-nvdec \
        --enable-libnpp \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvpx \
        --enable-libsvtav1 \
        --enable-libtheora \
        --enable-libmp3lame \
        --enable-libopus \
        --enable-libvorbis \
        --enable-libdav1d \
        --enable-libwebp \
        --enable-libass \
        --enable-libfreetype \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64 \
    && make -j${MAKE_JOBS} \
    && make install \
    && cd .. && rm -rf ffmpeg

# =============================================================================
# Stage 2 — Build the Crystal CLI (easy-ffmpeg) on the same runtime base
# that the final image uses, so glibc / shared-lib versions match.
# =============================================================================
FROM nvcr.io/nvidia/cuda:12.8.2-runtime-ubuntu24.04 AS app-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg build-essential \
        libpcre2-dev libssl-dev libz-dev libyaml-dev libgmp-dev libxml2-dev \
    && curl -fsSL https://crystal-lang.org/install.sh | bash \
    && apt-get install -y --no-install-recommends crystal \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY shard.yml ./
COPY shard.lock* ./
RUN shards install --production || true

COPY . .
# --single-module: works around Crystal 1.20.2 codegen crash.
RUN mkdir -p bin \
    && crystal build src/easy_ffmpeg_cli.cr -o bin/easy-ffmpeg --release --no-debug --single-module

# =============================================================================
# Stage 3 — Final runtime image (as requested).
#
# Each runtime lib here matches a --enable-* flag from stage 1. Without these,
# the FFmpeg binary would dlopen-fail at runtime even though it links cleanly.
# =============================================================================
FROM nvcr.io/nvidia/cuda:12.8.2-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg libnuma1 \
        libx264-164 libx265-199 libvpx9 \
        libsvtav1enc1d1 libsvtav1dec0 \
        libtheora0 \
        libmp3lame0 libopus0 libvorbis0a libvorbisenc2 \
        libdav1d7 libwebp7 libwebpmux3 libwebpdemux2 \
        libass9 libfreetype6 \
        libpcre2-8-0 libssl3 libgmp10 libyaml-0-2 zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Crystal toolchain in the final image so the project can be rebuilt /
# extended in-place (e.g. `crystal build`, `crystal spec`, `shards install`).
# Adds the dev headers Crystal links against at compile time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config git \
        libpcre2-dev libssl-dev libz-dev libyaml-dev libgmp-dev libxml2-dev \
    && curl -fsSL https://crystal-lang.org/install.sh | bash \
    && apt-get install -y --no-install-recommends crystal \
    && rm -rf /var/lib/apt/lists/*

# FFmpeg binaries, libraries and data from the builder
COPY --from=ffmpeg-builder /usr/local/bin/ffmpeg   /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/local/bin/ffprobe  /usr/local/bin/ffprobe
COPY --from=ffmpeg-builder /usr/local/lib/         /usr/local/lib/
COPY --from=ffmpeg-builder /usr/local/include/     /usr/local/include/
COPY --from=ffmpeg-builder /usr/local/share/ffmpeg /usr/local/share/ffmpeg

# easy-ffmpeg CLI
COPY --from=app-builder /app/bin/easy-ffmpeg /usr/local/bin/easy-ffmpeg

RUN ldconfig

WORKDIR /work

ENTRYPOINT ["easy-ffmpeg"]
CMD ["--help"]
