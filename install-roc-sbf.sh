#!/usr/bin/env bash
set -e

ROC_SBF_REPO="${ROC_SBF_REPO:-DaviRain-Su/roc}"
ROC_SBF_VERSION="${ROC_SBF_VERSION:-}"

output_dir="${1:-roc-sbf}"
output_dir="$(mkdir -p "$output_dir" 2>/dev/null; cd "$output_dir"; pwd)"

arch=$(uname -m)
case "$arch" in
  "x86_64")
    arch="x86_64"
    ;;
  "arm64" | "aarch64")
    arch="aarch64"
    ;;
  *)
    echo "install-roc-sbf.sh: Unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

case $(uname -s) in
  "Linux")
    os="linux"
    if [[ "$arch" != "x86_64" ]]; then
      echo "Error: Linux ARM64 is not yet supported." >&2
      echo "Only Linux x86_64 is available." >&2
      exit 1
    fi
    ;;
  "Darwin")
    os="macos"
    if [[ "$arch" == "x86_64" ]]; then
      echo "Error: macOS x86_64 (Intel) is not supported." >&2
      echo "Only macOS ARM64 (Apple Silicon M1/M2/M3) is available." >&2
      exit 1
    fi
    ;;
  *)
    echo "install-roc-sbf.sh: Unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

if [[ -z "$ROC_SBF_VERSION" ]]; then
  echo "Fetching latest release version..."
  ROC_SBF_VERSION=$(curl -sSfL "https://api.github.com/repos/${ROC_SBF_REPO}/releases/latest" | \
    grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  
  if [[ -z "$ROC_SBF_VERSION" ]]; then
    echo "Warning: Could not fetch latest version, using 'nightly'" >&2
    ROC_SBF_VERSION="nightly"
  fi
fi

echo "Installing Roc SBF version: $ROC_SBF_VERSION"
echo "Target: $os-$arch"
echo "Output directory: $output_dir"

release_url="https://github.com/${ROC_SBF_REPO}/releases/download/${ROC_SBF_VERSION}"
tarball="roc-sbf-${os}-${arch}-${ROC_SBF_VERSION}.tar.gz"
url="${release_url}/${tarball}"

echo ""
echo "Downloading $url..."
cd "$output_dir"

if command -v curl &> /dev/null; then
  curl --proto '=https' --tlsv1.2 -SfOL "$url"
elif command -v wget &> /dev/null; then
  wget -q "$url"
else
  echo "Error: Neither curl nor wget found." >&2
  exit 1
fi

checksum_url="${url}.sha256"
if curl --proto '=https' --tlsv1.2 -SfOL "$checksum_url" 2>/dev/null; then
  echo "Verifying checksum..."
  if command -v sha256sum &> /dev/null; then
    sha256sum -c "$(basename "$checksum_url")" || { echo "Checksum failed!" >&2; exit 1; }
  elif command -v shasum &> /dev/null; then
    shasum -a 256 -c "$(basename "$checksum_url")" || { echo "Checksum failed!" >&2; exit 1; }
  fi
  rm -f "$(basename "$checksum_url")"
fi

echo "Extracting $tarball..."
tar -xzf "$tarball"
rm -f "$tarball"

extracted_dir=$(ls -d roc-sbf-* 2>/dev/null | head -n 1)
if [[ -n "$extracted_dir" && -d "$extracted_dir" ]]; then
  mv "$extracted_dir"/* .
  rmdir "$extracted_dir"
fi

chmod +x roc roc_language_server 2>/dev/null || true

echo ""
if [[ -x "./roc" ]]; then
  ./roc version
  echo ""
  echo "Roc SBF compiler installed successfully!"
  echo "Location: $output_dir/roc"
  echo ""
  echo "Add to PATH: export PATH=\"$output_dir:\$PATH\""
else
  echo "Error: Installation failed." >&2
  exit 1
fi
