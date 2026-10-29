#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/macos-runtime}"
PYTHON_RUNTIME="${BHE_PYTHON_RUNTIME:-}"

if [[ -z "$PYTHON_RUNTIME" || ! -x "$PYTHON_RUNTIME/bin/python3" ]]; then
  echo "BHE_PYTHON_RUNTIME must point to a portable Python runtime with bin/python3" >&2
  exit 2
fi

while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  if [[ "$target" = /* ]]; then
    echo "Python runtime contains an absolute symlink: $link -> $target" >&2
    echo "Use a relocatable Python distribution, not a developer virtualenv." >&2
    exit 2
  fi
done < <(find "$PYTHON_RUNTIME/bin" -type l -print0)

FFMPEG="${BHE_FFMPEG:-$(command -v ffmpeg || true)}"
FFPROBE="${BHE_FFPROBE:-$(command -v ffprobe || true)}"
if [[ -z "$FFMPEG" || -z "$FFPROBE" ]]; then
  echo "ffmpeg and ffprobe are required; set BHE_FFMPEG and BHE_FFPROBE if needed" >&2
  exit 2
fi
if [[ "$FFMPEG" -ef "$FFPROBE" ]] || cmp -s "$FFMPEG" "$FFPROBE"; then
  echo "ffmpeg and ffprobe resolve to the same binary; provide a real ffprobe executable" >&2
  exit 2
fi

if [[ "$(uname -s)" == "Darwin" && "${BHE_ALLOW_EXTERNAL_FFMPEG:-0}" != "1" ]]; then
  external_deps="$(otool -L "$FFMPEG" "$FFPROBE" | grep -E '/(usr/local|opt/homebrew|opt/local)/' || true)"
  if [[ -n "$external_deps" ]]; then
    echo "The selected FFmpeg depends on Homebrew/foreign dylibs and is not portable:" >&2
    echo "$external_deps" >&2
    echo "Use a self-contained/static FFmpeg build, or set BHE_ALLOW_EXTERNAL_FFMPEG=1 for local-only testing." >&2
    exit 2
  fi
fi

MODEL="${BHE_MODEL:-$ROOT/models/bball_model.pt}"
if [[ ! -f "$MODEL" ]]; then
  MODEL="$ROOT/third_party/basketball-shot-detection/bball_model.pt"
fi
if [[ ! -f "$MODEL" ]]; then
  echo "Model not found; place it at models/bball_model.pt or set BHE_MODEL" >&2
  exit 2
fi

rm -rf "$OUT"
mkdir -p "$OUT"/bin "$OUT"/python "$OUT"/engine "$OUT"/scripts "$OUT"/src "$OUT"/docs/architecture "$OUT"/models

cp -R "$PYTHON_RUNTIME"/. "$OUT/python/"
cp -R "$ROOT/engine/python" "$OUT/engine/"
cp -R "$ROOT/scripts"/. "$OUT/scripts/"
cp -R "$ROOT/src"/. "$OUT/src/"
cp "$ROOT/docs/architecture/SQLITE_SCHEMA_V1.sql" "$OUT/docs/architecture/"
cp "$MODEL" "$OUT/models/bball_model.pt"
# CoreML 用的静态 batch=1 模型是可选的:构建时导出过就一起打包,
# 没有就只保留 Metal/CPU 路径(引擎会在缺文件时自动降级,不会报错)。
STATIC_ONNX="${BHE_STATIC_ONNX:-${MODEL%.*}.static.onnx}"
if [[ -f "$STATIC_ONNX" ]]; then
  cp "$STATIC_ONNX" "$OUT/models/bball_model.static.onnx"
  echo "Packaged static ONNX for CoreML: $(basename "$STATIC_ONNX")"
else
  echo "No static ONNX found; CoreML backend disabled, macOS will use Metal/CPU"
fi
cp "$FFMPEG" "$OUT/bin/ffmpeg"
cp "$FFPROBE" "$OUT/bin/ffprobe"

# 目标架构校验。主程序是 universal 二进制，但 Python 运行时是单架构的：
# 一旦把 arm64 的解释器或 arm64 的 numpy/torch 打进 Intel 包，问题只会在
# 用户机器上暴露（Intel 上解释器直接无法执行，或 .so 架构不符导致 import
# 失败）。这里在同一处把三件东西一起对齐，只在显式指定 BHE_TARGET_ARCH 时生效。
if [[ "$(uname -s)" == "Darwin" && -n "${BHE_TARGET_ARCH:-}" ]]; then
  assert_arch() {
    local label="$1" path="$2"
    if [[ -z "$path" || ! -e "$path" ]]; then
      echo "Architecture check: missing $label" >&2
      exit 2
    fi
    local archs
    archs="$(lipo -archs "$path" 2>/dev/null || true)"
    if [[ " $archs " != *" $BHE_TARGET_ARCH "* ]]; then
      echo "Architecture check: $label is '${archs:-unknown}', expected $BHE_TARGET_ARCH" >&2
      echo "  $path" >&2
      exit 2
    fi
  }
  PY_SITE="$(find "$OUT"/python/lib -maxdepth 3 -type d -name site-packages -print -quit 2>/dev/null || true)"
  assert_arch "python3" "$OUT/python/bin/python3"
  assert_arch "numpy" "$(find "$PY_SITE/numpy" -name '_multiarray_umath*.so' -type f -print -quit 2>/dev/null || true)"
  assert_arch "torch" "$(find "$PY_SITE/torch" -maxdepth 1 -name '_C*.so' -type f -print -quit 2>/dev/null || true)"
  echo "Architecture check: python3, numpy, torch are all $BHE_TARGET_ARCH"
fi

"$OUT/python/bin/python3" "$OUT/scripts/check_runtime.py" \
  --root "$OUT" \
  --python "$OUT/python/bin/python3" \
  --ffmpeg "$OUT/bin/ffmpeg" \
  --ffprobe "$OUT/bin/ffprobe" \
  --model "$OUT/models/bball_model.pt"

echo "Prepared runtime: $OUT"
