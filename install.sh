#!/bin/sh
# Gamma Forge installer: downloads the latest universal binary release,
# verifies its checksum, then runs it.
set -eu

REPO="wooooooooook/display-gamma-forge"
ASSET="GammaForge-macos-universal.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

cd "$tmp_dir"

echo "Downloading ${ASSET}..."
curl -fsSLO "${BASE_URL}/${ASSET}"
curl -fsSLO "${BASE_URL}/${ASSET}.sha256"

echo "Verifying checksum..."
shasum -a 256 -c "${ASSET}.sha256"

echo "Extracting..."
tar -xzf "${ASSET}"

echo "Launching GammaForge..."
./GammaForge
