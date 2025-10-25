# 1) CUDA base — adjust to your RunPod image family if needed
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

SHELL ["/bin/bash","-lc"]

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    # ComfyUI defaults
    COMFY_PORT=8188 \
    # code-server defaults (VS Code in the browser)
    CODE_SERVER_PORT=13337 \
    # Where ComfyUI lives
    COMFY_HOME=/opt/ComfyUI \
    # Where models land (RunPod persists /workspace by default)
    WORKSPACE=/workspace

# 2) System deps
RUN set -euxo pipefail \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates tini python3 python3-pip python3-venv \
      build-essential ffmpeg unzip nano \
 # code-server (VS Code) - official install script
 && curl -fsSL https://code-server.dev/install.sh | sh \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# 3) ComfyUI (no models here)
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git $COMFY_HOME

# 4) Python venv + deps
RUN python3 -m venv /venv \
 && source /venv/bin/activate \
 && pip install --upgrade pip wheel \
 && pip install -r $COMFY_HOME/requirements.txt \
 && pip install -r /tmp/req.txt || true

# 4b) Our extra requirements (huggingface_hub, etc.)
COPY requirements.txt /tmp/req.txt
RUN source /venv/bin/activate && pip install -r /tmp/req.txt

# 5) Create model folders (ComfyUI expects these)
RUN mkdir -p $WORKSPACE/models/unet \
             $WORKSPACE/models/vae \
             $WORKSPACE/models/clip \
             $WORKSPACE/models/loras \
             $WORKSPACE/models/checkpoints \
             $WORKSPACE/models/upscale_models \
             $WORKSPACE/models/controlnet \
             $WORKSPACE/custom_nodes

# 6) Copy runtime config
COPY config/codeserver.yaml /root/.config/code-server/config.yaml
COPY config/comfyui.env /etc/comfyui.env
COPY runtime /runtime
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE ${COMFY_PORT} ${CODE_SERVER_PORT}
WORKDIR ${WORKSPACE}

# Use tini for proper signal handling
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["/start.sh"]

