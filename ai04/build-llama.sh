#!/usr/bin/env bash
# Build llama.cpp (CUDA, Ada sm_89 for NVIDIA L4) into a fresh dated directory so a
# running llama-server is never overwritten. Prints the resulting path.
# Authored by Caleb A. Morrow
# Contributor: Claude - 2026-11-04 - captured from ~/llama-lab/setup.sh on ai04
set -euo pipefail
DIR="${1:-$HOME/llama-lab/llama.cpp-$(date +%Y%m%d)}"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake build-essential nvidia-cuda-toolkit git libcurl4-openssl-dev
[ -d "$DIR" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$DIR"
cd "$DIR"
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DLLAMA_CURL=ON
cmake --build build --config Release -j "$(nproc)" --target llama-server llama-bench
git log -1 --format='built llama.cpp %h %cd'
echo "BINARY: $DIR/build/bin/llama-server"
