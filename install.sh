#!/bin/sh
set -e

REPO="akitaonrails/easy-ffmpeg"

# Detect OS
case "$(uname -s)" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="darwin" ;;
  *)
    echo "Error: unsupported OS '$(uname -s)'" >&2
    exit 1
    ;;
esac

# Detect architecture
case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *)
    echo "Error: unsupported architecture '$(uname -m)'" >&2
    exit 1
    ;;
esac

BINARY="easy-ffmpeg-${OS}-${ARCH}"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

# Install directory
if [ "$(id -u)" = "0" ]; then
  INSTALL_DIR="/usr/local/bin"
else
  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Resolve the exact release tag first so the install is explicit.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$API_URL" -o "${TMPDIR}/release.json"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${TMPDIR}/release.json" "$API_URL"
else
  echo "Error: curl or wget is required" >&2
  exit 1
fi

RELEASE_TAG=$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)",$/\1/p' "${TMPDIR}/release.json" | head -n 1)
if [ -z "$RELEASE_TAG" ]; then
  echo "Error: failed to resolve the latest release tag" >&2
  exit 1
fi

URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${BINARY}"
CHECKSUMS_URL="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/SHA256SUMS.txt"

echo "Downloading easy-ffmpeg ${RELEASE_TAG} (${OS}/${ARCH})..."

# Download binary and checksums
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "${TMPDIR}/${BINARY}"
  curl -fsSL "$CHECKSUMS_URL" -o "${TMPDIR}/SHA256SUMS.txt"
else
  wget -qO "${TMPDIR}/${BINARY}" "$URL"
  wget -qO "${TMPDIR}/SHA256SUMS.txt" "$CHECKSUMS_URL"
fi

# Verify checksum
echo "Verifying checksum..."
EXPECTED=$(grep "${BINARY}" "${TMPDIR}/SHA256SUMS.txt" | awk '{print $1}')
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "${TMPDIR}/${BINARY}" | awk '{print $1}')
else
  ACTUAL=$(shasum -a 256 "${TMPDIR}/${BINARY}" | awk '{print $1}')
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "Error: checksum verification failed!" >&2
  echo "  Expected: ${EXPECTED}" >&2
  echo "  Got:      ${ACTUAL}" >&2
  exit 1
fi
echo "Checksum OK."

mv "${TMPDIR}/${BINARY}" "${INSTALL_DIR}/easy-ffmpeg"

chmod +x "${INSTALL_DIR}/easy-ffmpeg"

# macOS: remove quarantine attribute
if [ "$OS" = "darwin" ]; then
  xattr -d com.apple.quarantine "${INSTALL_DIR}/easy-ffmpeg" 2>/dev/null || true
fi

echo "Installed easy-ffmpeg to ${INSTALL_DIR}/easy-ffmpeg"

# PATH hint
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    echo ""
    echo "Add ${INSTALL_DIR} to your PATH:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    ;;
esac
