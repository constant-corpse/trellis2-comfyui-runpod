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
apt-get update -qq && apt-get install -y -qq git wget ca-certificates libgl1 libglib2.0-0 >/dev/null

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
if [ ! -f /workspace/.trellis2_installed ]; then
  $PIP install -q -r "$NODE_DIR/requirements.txt" || echo "WARN: node requirements failed"
  for w in cumesh-1.0 custom_rasterizer-0.1 flex_gemm-0.0.1 nvdiffrast-0.4.0 nvdiffrec_render-0.0.0 o_voxel-0.0.1; do
    $PIP install -q --no-deps "$WHEEL_BASE/${w}-cp312-cp312-linux_x86_64.whl" || echo "WARN: wheel $w failed"
  done
  touch /workspace/.trellis2_installed
fi

# Gated DINOv3 encoder (needs HF_TOKEN and an accepted license)
DINO="$COMFY/models/facebook/dinov3-vitl16-pretrain-lvd1689m"
if [ ! -d "$DINO" ] && [ -n "${HF_TOKEN:-}" ]; then
  $PIP install -q "huggingface-hub>=1.5,<2.0"
  HF_BIN="$(dirname "$PY")/hf"
  "$HF_BIN" download facebook/dinov3-vitl16-pretrain-lvd1689m --local-dir "$DINO" \
    || echo "WARN: DinoV3 download failed - accept the license at huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m"
fi

# Report final versions so problems show up in the pod log
$PIP freeze 2>/dev/null | grep -i -E "^(torch|torchvision|numpy|huggingface-hub|transformers|cumesh|o-voxel|o_voxel|flex)" || true
$PIP check 2>&1 | head -20 || true

echo "Setup complete! Handing over to start script..."
exec /start.sh
