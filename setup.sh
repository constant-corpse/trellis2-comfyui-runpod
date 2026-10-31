#!/usr/bin/env bash
# TRELLIS.2 (visualbruno/ComfyUI-Trellis2) on the runpod/comfyui:cuda12.8 image.
# Idempotent: first boot installs everything onto /workspace, later boots only re-pin and launch.
set -u

COMFY=/workspace/runpod-slim/ComfyUI
NODE_DIR="$COMFY/custom_nodes/ComfyUI-Trellis2"
WHEEL_BASE=https://github.com/visualbruno/ComfyUI-Trellis2/raw/main/wheels/Linux/Torch291
TORCH_VER=2.9.1
TV_VER=0.24.1
TA_VER=2.9.1

echo "=== TRELLIS2 (visualbruno) setup ==="
apt-get update -qq && apt-get install -y -qq git wget ca-certificates libgl1 libglib2.0-0 libopengl0 >/dev/null

# First boot: copy the baked ComfyUI onto the persistent volume
if [ ! -f "$COMFY/main.py" ]; then
  echo "First time setup: copying baked ComfyUI to /workspace..."
  rm -rf "$COMFY"
  mkdir -p "$(dirname "$COMFY")"
  cp -a /opt/comfyui-baked "$COMFY"
fi

PY="$COMFY/.venv-cu128/bin/python"
[ -x "$PY" ] || PY=python3
PIP="$PY -m pip"
echo "Using python: $PY"

# Pins that stop dependency fights (huggingface-hub 2.x breaks transformers; numpy kept below 2.5)
cat > /workspace/constraints.txt <<'EOF'
huggingface-hub>=1.5,<2.0
numpy>=2.0,<2.5
EOF
export PIP_CONSTRAINT=/workspace/constraints.txt
export HF_HOME=/workspace/hf
mkdir -p "$HF_HOME"

# The prebuilt CUDA wheels in the node repo are built for torch 2.9.1 (cp312); the image ships a newer torch
CUR_TORCH=$($PY -c "import torch;print(torch.__version__.split('+')[0])" 2>/dev/null || echo none)
if [ "$CUR_TORCH" != "$TORCH_VER" ]; then
  echo "Installing torch $TORCH_VER (found $CUR_TORCH)..."
  $PIP install -q "torch==$TORCH_VER" "torchvision==$TV_VER" "torchaudio==$TA_VER" \
    --index-url https://download.pytorch.org/whl/cu128 || echo "WARN: torch install failed"
fi

# Node pack
if [ ! -d "$NODE_DIR" ]; then
  git clone --depth 1 https://github.com/visualbruno/ComfyUI-Trellis2 "$NODE_DIR" || echo "WARN: node clone failed"
fi
# The image's python lives outside the volume, so check by import instead of a marker file
if ! $PY -c "import cumesh, o_voxel, flex_gemm, trimesh, easydict, plyfile, zstandard" 2>/dev/null; then
  echo "Installing Trellis2 dependencies and CUDA wheels..."
  rm -f /workspace/.trellis2_built   # prebuilt wheels below replace any source builds, so rebuild after
  $PIP install -q -r "$NODE_DIR/requirements.txt" || echo "WARN: node requirements failed"
  # runtime deps of the wheels (installed with --no-deps below)
  $PIP install -q trimesh easydict plyfile zstandard || echo "WARN: wheel runtime deps failed"
  for w in cumesh-1.0 custom_rasterizer-0.1 flex_gemm-0.0.1 nvdiffrast-0.4.0 nvdiffrec_render-0.0.0 o_voxel-0.0.1; do
    $PIP install -q --no-deps "$WHEEL_BASE/${w}-cp312-cp312-linux_x86_64.whl" || echo "WARN: wheel $w failed"
  done
fi

# The prebuilt flex_gemm / o_voxel wheels have no kernels for some GPUs (e.g. L40S, sm_89 -> "no kernel image").
# Rebuild both from the author's source for this GPU. Installed into the venv on /workspace, so it persists.
ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
BUILD_TAG="${ARCH:-unknown}-torch${TORCH_VER}"
if [ -n "$ARCH" ] && [ "$(cat /workspace/.trellis2_built 2>/dev/null)" != "$BUILD_TAG" ]; then
  echo "Building flex_gemm and o_voxel for compute capability $ARCH..."
  command -v nvcc >/dev/null 2>&1 || apt-get install -y -qq cuda-nvcc-12-8 cuda-cudart-dev-12-8 ninja-build >/dev/null
  [ -d /workspace/FlexGEMM ] || git clone --recursive -q https://github.com/visualbruno/FlexGEMM.git /workspace/FlexGEMM
  [ -d /workspace/TRELLIS2-src ] || git clone --recursive -q https://github.com/visualbruno/TRELLIS.2.git /workspace/TRELLIS2-src
  ( # subshell: the image's pip constraint variables conflict with --no-build-isolation
    unset PIP_CONSTRAINT PIP_BUILD_CONSTRAINT UV_BUILD_CONSTRAINT
    export CUDA_HOME=$(dirname "$(dirname "$(command -v nvcc)")") TORCH_CUDA_ARCH_LIST="$ARCH"
    $PIP install -q setuptools wheel ninja
    $PIP install -q --no-build-isolation --no-deps --force-reinstall /workspace/FlexGEMM \
      && $PIP install -q --no-build-isolation --no-deps --force-reinstall /workspace/TRELLIS2-src/o-voxel \
      && echo "$BUILD_TAG" > /workspace/.trellis2_built
  ) || echo "WARN: source build of flex_gemm/o_voxel failed"
fi

# rembg needs a runtime; CPU is enough for a few images (GPU wheel targets CUDA 13 and crashes here)
$PY -c "import onnxruntime" 2>/dev/null || $PIP install -q onnxruntime || echo "WARN: onnxruntime install failed"

# An empty model folder makes the node think the model is already downloaded and then fail to load it
[ -d "$COMFY/models/microsoft/TRELLIS.2-4B" ] && [ -z "$(ls -A "$COMFY/models/microsoft/TRELLIS.2-4B")" ] \
  && rmdir "$COMFY/models/microsoft/TRELLIS.2-4B"

# Gated DINOv3 encoder (needs HF_TOKEN and an accepted license)
DINO="$COMFY/models/facebook/dinov3-vitl16-pretrain-lvd1689m"
if [ ! -d "$DINO" ] && [ -n "${HF_TOKEN:-}" ]; then
  $PIP install -q "huggingface-hub>=1.5,<2.0"
  DINO_DIR="$DINO" $PY -c "
import os
from huggingface_hub import snapshot_download
snapshot_download('facebook/dinov3-vitl16-pretrain-lvd1689m', local_dir=os.environ['DINO_DIR'], token=os.environ['HF_TOKEN'])
" || echo "WARN: DinoV3 download failed - check HF_TOKEN and accept the license at huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m"
fi

# Report final versions so problems show up in the pod log
$PIP freeze 2>/dev/null | grep -i -E "^(torch|torchvision|numpy|huggingface-hub|transformers|cumesh|o-voxel|o_voxel|flex)" || true
$PIP check 2>&1 | head -20 || true

echo "Setup complete! Handing over to start script..."
exec /start.sh
