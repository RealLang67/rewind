#!/usr/bin/env bash

set -euo pipefail

# This is deliberately built from a pinned upstream revision.  The resulting
# helper is statically linked and Universal 2, so it has no Homebrew/runtime
# dependency on the user's Mac.
WHISPER_REVISION="c44b60b8053bbf2a5c1e014f11323fb3f2485177"
# Hugging Face commit 5359861 is immutable. Never use its mutable `main`
# alias here: that was the source of a prior checksum mismatch.
MODEL_REVISION="5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/${MODEL_REVISION}/ggml-tiny.en.bin"
MODEL_SHA256="921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_ROOT="${PROJECT_ROOT}/.build/whisper-cpp"
SOURCE_DIR="${CACHE_ROOT}/source"
BUILD_DIR="${CACHE_ROOT}/build-macos"
OUTPUT_DIR="${PROJECT_ROOT}/Resources/Whisper"
MODEL_PATH="${OUTPUT_DIR}/ggml-tiny.en.bin"
MODEL_DOWNLOAD_PATH="${MODEL_PATH}.download"

verify_model() {
  local candidate="$1"
  echo "${MODEL_SHA256}  ${candidate}" | shasum -a 256 -c -
}

cleanup_partial_model() {
  rm -f "${MODEL_DOWNLOAD_PATH}"
}
trap cleanup_partial_model EXIT

mkdir -p "${CACHE_ROOT}" "${OUTPUT_DIR}"

if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
  git clone https://github.com/ggml-org/whisper.cpp.git "${SOURCE_DIR}"
fi

git -C "${SOURCE_DIR}" fetch --depth 1 origin "${WHISPER_REVISION}"
git -C "${SOURCE_DIR}" checkout --detach "${WHISPER_REVISION}"

cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_METAL=OFF
cmake --build "${BUILD_DIR}" --config Release --target whisper-cli

HELPER_PATH="${BUILD_DIR}/bin/whisper-cli"
if [[ ! -x "${HELPER_PATH}" ]]; then
  echo "whisper-cli was not built at ${HELPER_PATH}" >&2
  exit 1
fi

echo "Whisper model URL: ${MODEL_URL}"
echo "Whisper model SHA-256: ${MODEL_SHA256}"
if [[ -f "${MODEL_PATH}" ]] && ! verify_model "${MODEL_PATH}"; then
  echo "Removing cached Whisper model with an unexpected SHA-256." >&2
  rm -f "${MODEL_PATH}"
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
  cleanup_partial_model
  curl --fail --location --retry 3 \
    --output "${MODEL_DOWNLOAD_PATH}" \
    "${MODEL_URL}"
  verify_model "${MODEL_DOWNLOAD_PATH}"
  mv "${MODEL_DOWNLOAD_PATH}" "${MODEL_PATH}"
fi
cp "${HELPER_PATH}" "${OUTPUT_DIR}/whisper-cli"
cp "${SOURCE_DIR}/LICENSE" "${OUTPUT_DIR}/whisper.cpp-LICENSE"

lipo "${OUTPUT_DIR}/whisper-cli" -verify_arch arm64 x86_64
