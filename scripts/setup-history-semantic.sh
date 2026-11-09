#!/usr/bin/env bash
set -euo pipefail
umask 077
directory="${DAFEIYU_DATA_DIR:-$HOME/.local/share/dafeiyu}/semantic-model"
source_host="${DAFEIYU_MODEL_SOURCE:-https://huggingface.co}"
base="$source_host/Xenova/multilingual-e5-small/resolve/761b726"
mkdir -p "$directory"
cd "$directory"

download() {
    local source=$1 target=$2 sha=$3
    if printf '%s  %s\n' "$sha" "$target" | sha256sum -c --status 2>/dev/null; then return; fi
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 240 "$base/$source" -o "$target.part"
    printf '%s  %s\n' "$sha" "$target.part" | sha256sum -c --status
    mv "$target.part" "$target"
}

download tokenizer.json tokenizer.json 0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39
download onnx/model_int8.onnx model.onnx 4d24e2bc01a447951524466ef533e52944bf48509e6552810bcee1a2711cb02c
python3 -m venv venv
venv/bin/python -m pip install --disable-pip-version-check onnxruntime==1.31.1 tokenizers==0.23.3 numpy==2.5.4
