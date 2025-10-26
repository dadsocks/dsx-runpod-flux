# 1) CUDA base — adjust to your RunPod image family if needed
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

SHELL ["/bin/bash","-lc"]

# 2) Environment
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    # Where persistent files live on RunPod
    WORKSPACE=/workspace \
    # ComfyUI app will live inside the persistent volume
    COMFY_HOME=/workspace/ComfyUI \
    # Default ports (override via RunPod env if you like)
    COMFY_PORT=3000 \
    CODE_SERVER_PORT=8080

# 3) System deps + code-server
RUN set -euxo pipefail \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates tini python3 python3-pip python3-venv \
      build-essential ffmpeg unzip nano \
 && curl -fsSL https://code-server.dev/install.sh | sh \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# 4) Python venv + base Python deps (ComfyUI deps will be installed at runtime after clone)
RUN python3 -m venv /venv \
 && source /venv/bin/activate \
 && pip install --upgrade pip wheel

# 4b) Extra runtime helpers (HF client, requests, gitpython, tqdm)
COPY requirements.txt /tmp/req.txt
RUN source /venv/bin/activate && pip install -r /tmp/req.txt || true

# 5) Prepare persistent workspace dir
RUN mkdir -p $WORKSPACE

# 6) Config + startup
COPY config/codeserver.yaml /root/.config/code-server/config.yaml
COPY config/comfyui.env /etc/comfyui.env
COPY runtime /runtime
COPY start.sh /start.sh
RUN chmod +x /start.sh

# 7) Networking + default workdir
EXPOSE ${COMFY_PORT} ${CODE_SERVER_PORT}
WORKDIR ${WORKSPACE}

# 8) Proper init (tini as subreaper) and start script
ENTRYPOINT ["/usr/bin/tini","-s","--"]
CMD ["/start.sh"]
