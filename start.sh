#!/usr/bin/env bash
set -euo pipefail

# ---- Env ----
export HF_TOKEN="${HF_TOKEN:-}"                 # Required for gated FLUX.1-dev
export CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"   # Optional
export WORKSPACE="${WORKSPACE:-/workspace}"
export COMFY_HOME="${COMFY_HOME:-/workspace/ComfyUI}"
export COMFY_PORT="${COMFY_PORT:-3000}"
export CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
export PATH="/venv/bin:$PATH"

mkdir -p "$WORKSPACE"

# ---- Ensure ComfyUI app under /workspace ----
if [[ ! -d "$COMFY_HOME/.git" ]]; then
  echo "Cloning ComfyUI into $COMFY_HOME ..."
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_HOME"
else
  echo "Updating ComfyUI at $COMFY_HOME ..."
  (cd "$COMFY_HOME" && git pull --ff-only || true)
fi

# ---- Model directories INSIDE ComfyUI app tree ----
MODEL_ROOT="$COMFY_HOME/models"
DIFF_DIR="$MODEL_ROOT/diffusion_models"   # Flux UNET
VAE_DIR="$MODEL_ROOT/vae"                  # VAE
ENC_DIR="$MODEL_ROOT/text_encoders"        # CLIP-L, T5-XXL
LORA_DIR="$MODEL_ROOT/loras"
CN_DIR="$MODEL_ROOT/controlnet"
UP_DIR="$MODEL_ROOT/upscale_models"

mkdir -p "$DIFF_DIR" "$VAE_DIR" "$ENC_DIR" "$LORA_DIR" "$CN_DIR" "$UP_DIR"

# (Optional) migrate old layout once: /workspace/models -> app tree
if [[ -d "$WORKSPACE/models" ]]; then
  echo "Migrating legacy /workspace/models into app tree ..."
  shopt -s nullglob
  mv "$WORKSPACE/models"/diffusion_models/* "$DIFF_DIR"/ 2>/dev/null || true
  mv "$WORKSPACE/models"/vae/*              "$VAE_DIR"/  2>/dev/null || true
  mv "$WORKSPACE/models"/text_encoders/*    "$ENC_DIR"/  2>/dev/null || true
  mv "$WORKSPACE/models"/loras/*            "$LORA_DIR"/ 2>/dev/null || true
fi

# ---- Helper: HF download (token optional for public repos) ----
hf_dl () {
  local repo="$1"   # e.g. black-forest-labs/FLUX.1-dev
  local file="$2"   # e.g. ae.safetensors
  local localdir="${3:-$WORKSPACE/hf-cache/${repo}}"
  mkdir -p "$localdir"
  local args=(download "$repo" "$file" --local-dir "$localdir" --local-dir-use-symlinks False --resume)
  [[ -n "${HF_TOKEN:-}" ]] && args+=(--token "$HF_TOKEN")
  huggingface-cli "${args[@]}" >/dev/null
  echo "$localdir/$file"
}

# ---- 1) Custom Nodes (installed under app tree) ----
if [[ -f /runtime/custom_nodes.txt ]]; then
  while IFS= read -r raw; do
    # strip inline comments and trim
    repo="$(printf '%s' "$raw" | sed 's/#.*$//' | xargs)"
    [[ -z "$repo" ]] && continue
    name="$(basename "$repo" .git)"
    target="$COMFY_HOME/custom_nodes/${name}"
    if [[ ! -d "$target/.git" ]]; then
      echo "Installing custom node: $repo"
      git clone --depth=1 "$repo" "$target" || echo "WARN: Failed to clone $repo"
    else
      echo "Updating custom node: $name"
      (cd "$target" && git pull --ff-only || true)
    fi
  done < /runtime/custom_nodes.txt
fi

# Install any node requirements
find "$COMFY_HOME/custom_nodes" -maxdepth=2 -name requirements.txt -print0 | while IFS= read -r -d '' req; do
  echo "Installing node requirements: $req"
  pip install -r "$req" || true
done

# ---- 2) FLUX + VAE + Encoders (inside app tree) ----
FLUX_REPO="black-forest-labs/FLUX.1-dev"          # UNET + VAE
ENC_REPO="comfyanonymous/flux_text_encoders"      # CLIP-L + T5-XXL

echo "Downloading Flux UNET ..."
unet_candidates=("flux1-dev.safetensors" "flux1-dev-fp8.safetensors" "flux1-dev-fp8_e4m3fn_scaled.safetensors")
found_unet=""
for f in "${unet_candidates[@]}"; do
  if src="$(hf_dl "$FLUX_REPO" "$f" 2>/dev/null || true)"; then
    [[ -f "$src" ]] && cp -f "$src" "$DIFF_DIR/" && found_unet="$f" && break
  fi
done
[[ -z "$found_unet" ]] && echo "WARN: Flux UNET not found; check HF token/filenames."

echo "Downloading VAE ..."
if src="$(hf_dl "$FLUX_REPO" "ae.safetensors" 2>/dev/null || true)"; then
  [[ -f "$src" ]] && cp -f "$src" "$VAE_DIR/" || echo "WARN: VAE not found."
else
  echo "WARN: VAE download failed."
fi

echo "Downloading encoders (CLIP-L, T5-XXL) ..."
# CLIP-L
if src="$(hf_dl "$ENC_REPO" "clip_l.safetensors" 2>/dev/null || true)"; then
  [[ -f "$src" ]] && cp -f "$src" "$ENC_DIR/" || echo "WARN: CLIP-L not found."
else
  echo "WARN: CLIP-L download failed."
fi
# T5-XXL (try fp16 then fp8)
t5_candidates=("t5xxl_fp16.safetensors" "t5xxl_fp8_e4m3fn_scaled.safetensors")
found_t5=""
for f in "${t5_candidates[@]}"; do
  if src="$(hf_dl "$ENC_REPO" "$f" 2>/dev/null || true)"; then
    [[ -f "$src" ]] && cp -f "$src" "$ENC_DIR/" && found_t5="$f" && break
  fi
done
[[ -z "$found_t5" ]] && echo "WARN: No T5-XXL file found."

# ---- 3) Optional: Civitai models into app tree ----
if [[ -f /runtime/civitai_models.txt ]]; then
  echo "Fetching Civitai models into $LORA_DIR ..."
  pushd "$LORA_DIR" >/dev/null
  while IFS= read -r line; do
    spec="$(printf '%s' "$line" | sed 's/#.*$//' | xargs)"
    [[ -z "$spec" ]] && continue
    if [[ "$spec" =~ ^https?:// ]]; then
      if [[ -n "${CIVITAI_API_KEY:-}" ]]; then
        curl -L -H "Authorization: Bearer ${CIVITAI_API_KEY}" --remote-header-name --remote-name "$spec"
      else
        wget --content-disposition "$spec"
      fi
    elif [[ "$spec" =~ ^id=([0-9]+)$ ]]; then
      url="https://civitai.com/api/download/models/${BASH_REMATCH[1]}"
      if [[ -n "${CIVITAI_API_KEY:-}" ]]; then
        curl -L -H "Authorization: Bearer ${CIVITAI_API_KEY}" --remote-header-name --remote-name "$url"
      else
        wget --content-disposition "$url"
      fi
    else
      echo "Skipping unknown Civitai spec: $spec"
    fi
  done < /runtime/civitai_models.txt
  popd >/dev/null
fi

# ---- 4) Configure code-server password from env (optional) ----
if [[ -n "${CODE_SERVER_PASSWORD:-}" ]]; then
  mkdir -p /root/.config/code-server
  cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF
fi

# ---- 5) Start code-server (root folder: /workspace) ----
echo "Starting code-server on port ${CODE_SERVER_PORT}"
nohup code-server --bind-addr 0.0.0.0:${CODE_SERVER_PORT} "${WORKSPACE}" >/var/log/code-server.log 2>&1 &

# ---- 6) Start ComfyUI from app tree ----
echo "Starting ComfyUI on port ${COMFY_PORT}"
cd "$COMFY_HOME"
source /venv/bin/activate
exec python main.py --listen 0.0.0.0 --port "${COMFY_PORT}"
