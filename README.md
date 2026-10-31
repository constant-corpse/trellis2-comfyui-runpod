# TRELLIS.2 (visualbruno) RunPod setup

Untested first draft. `setup.sh` installs `visualbruno/ComfyUI-Trellis2` onto the `runpod/comfyui:cuda12.8` image and then hands over to the image's `/start.sh`.

## Template
- Image: `runpod/comfyui:cuda12.8`
- Ports: `8888/http`, `8188/http`
- Container disk: 30 GB. Network volume (new, 100 GB or more) mounted at `/workspace`
- Environment variable: `HF_TOKEN` (needed for the gated DINOv3 model; accept its license first)
- GPU: L40S 48 GB (or 4090 / A6000 with CUDA filter 12.8+)
- Start command:

```
{ "entrypoint": ["bash", "-c"], "cmd": ["echo 'nameserver 8.8.8.8' > /etc/resolv.conf && sleep 10 && rm -rf /tmp/temp_repo && for i in {1..10}; do git clone https://github.com/constant-corpse/trellis2-comfyui-runpod.git /tmp/temp_repo && break || sleep 5; done && chmod +x /tmp/temp_repo/setup.sh && /tmp/temp_repo/setup.sh"] }
```

## Known assumptions
- The node repo's prebuilt Linux wheels are for Torch 2.9.1 on Python 3.12, so the script replaces the image's Torch 2.10 with 2.9.1 (cu128). The wheels' CUDA tag and GPU architecture support are not confirmed.
- `huggingface-hub` is held below 2.0 and numpy below 2.5 through `PIP_CONSTRAINT`.
- Other node packs the RunComfy workflow lists (GGUF, essentials, RMBG, Comfyroll, KJNodes) are not installed. Use ComfyUI-Manager's "Install Missing Custom Nodes" for the groups you enable.
