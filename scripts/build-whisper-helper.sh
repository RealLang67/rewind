#!/usr/bin/env bash

set -euo pipefail

# This is deliberately built from a pinned upstream revision.  The resulting
# helper is statically linked and Universal 2, so it has no Homebrew/runtime
# dependency on the user's Mac.
WHISPER_REVISION="c44b60b8053bbf2a5c1e014f11323fb3f2485177"
MODEL_SHA256="c072a8b1619a12e0454bebadfc188fe8ec91ddc39329ac69c90371e04f0c10f1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_ROOT="${PROJECT_ROOT}/.build/whisper-cpp"
SOURCE_DIR="${CACHE_ROOT}/source"
BUILD_DIR="${CACHE_ROOT}/build-macos"
OUTPUT_DIR="${PROJECT_ROOT}/Resources/Whisper"
MODEL_PATH="${OUTPUT_DIR}/ggml-tiny.en.bin"

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

curl --fail --location --retry 3 \
  --output "${MODEL_PATH}.download" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
echo "${MODEL_SHA256}  ${MODEL_PATH}.download" | shasum -a 256 -c -
mv "${MODEL_PATH}.download" "${MODEL_PATH}"
cp "${HELPER_PATH}" "${OUTPUT_DIR}/whisper-cli"
cp "${SOURCE_DIR}/LICENSE" "${OUTPUT_DIR}/whisper.cpp-LICENSE"

lipo "${OUTPUT_DIR}/whisper-cli" -verify_arch arm64 x86_64
