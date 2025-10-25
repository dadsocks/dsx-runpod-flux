#!/usr/bin/env bash
set -euo pipefail

# ---------- Env & defaults ----------
export HF_TOKEN="${HF_TOKEN:-}"                 # Required for FLUX.1-dev (gated)
export CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"   # Optional (private rate limits)
export COMFY_PORT="${COMFY_PORT:-8188}"
export CODE_SERVER_PORT="${CODE_SERVER_PORT:-13337}"
export COMFY_HOME="${COMFY_HOME:-/opt/ComfyUI}"
export WORKSPACE="${WORKSPACE:-/workspace}"
export PATH="/venv/bin:$PATH"

# Comfy paths
UNET_DIR="$WORKSPACE/models/unet"
VAE_DIR="$WORKSPACE/models/vae"
CLIP_DIR="$WORKSPACE/models/clip"
CN_DIR="$WORKSPACE/models/controlnet"
LORA_DIR="$WORKSPACE/models/loras"

mkdir -p "$UNET_DIR" "$VAE_DIR" "$CLIP_DIR" "$CN_DIR" "$LORA_DIR" "$WORKSPACE/custom_nodes"

# ---------- Helpers ----------
hf_dl () {
  # $1 = repo_id (e.g., black-forest-labs/FLUX.1-dev)
  # $2 = file path in repo (e.g., ae.safetensors)
  local repo="$1"
  local file="$2"
  if [[ -z "${HF_TOKEN}" ]]; then
    echo "ERROR: HF_TOKEN is not set but is required to download ${repo}/${file}"
    exit 1
  fi
  huggingface-cli download "$repo" "$file" \
    --token "$HF_TOKEN" \
    --local-dir "$WORKSPACE/hf-cache/${repo}" \
    --local-dir-use-symlinks False \
    --resume \
    >/dev/null
  local src="$WORKSPACE/hf-cache/${repo}/$file"
  echo "$src"
}

civit_dl () {
  # Accepts either:
  #  - full URL (https://civitai.com/api/download/models/12345?...), OR
  #  - id=<NUMBER> (we’ll call the standard endpoint)
  local spec="$1"
  local url=""
  if [[ "$spec" =~ ^https?:// ]]; then
    url="$spec"
  elif [[ "$spec" =~ ^id=([0-9]+)$ ]]; then
    url="https://civitai.com/api/download/models/${BASH_REMATCH[1]}"
  else
    echo "Skipping unknown Civitai spec: $spec"
    return 0
  fi

  # Prefer curl with header if API key provided, else try wget
  if [[ -n "${CIVITAI_API_KEY}" ]]; then
    echo "Downloading from Civitai with API key: $url"
    curl -L \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CIVITAI_API_KEY}" \
      --remote-header-name --remote-name \
      "$url"
  else
    echo "Downloading from Civitai (no API key): $url"
    # --content-disposition picks up the server’s filename
    wget --content-disposition "$url"
  fi
}

# ---------- 1) Install recommended custom nodes ----------
# You can edit runtime/custom_nodes.txt to control what gets installed.
# Format: one Git repo per line.
if [[ -f /runtime/custom_nodes.txt ]]; then
  while IFS= read -r repo; do
    [[ -z "$repo" || "$repo" =~ ^# ]] && continue
    name="$(basename "$repo" .git)"
    target="$WORKSPACE/custom_nodes/${name}"
    if [[ ! -d "$target/.git" ]]; then
      echo "Installing custom node: $repo"
      git clone --depth=1 "$repo" "$target" || echo "WARN: Failed to clone $repo"
    else
      echo "Updating custom node: $name"
      (cd "$target" && git pull --ff-only || true)
    fi
  done < /runtime/custom_nodes.txt
fi

# Some nodes ship Python deps; install them if present
find "$WORKSPACE/custom_nodes" -maxdepth 2 -name requirements.txt -print0 | while IFS= read -r -d '' req; do
  echo "Installing node requirements: $req"
  pip install -r "$req" || true
done

# ---------- 2) Download FLUX.1-dev + encoders + VAE at runtime ----------
# Hugging Face repo(s)
FLUX_REPO="black-forest-labs/FLUX.1-dev"
# Typical filenames (subject to change upstream; we try common names + fallbacks)
UNET_FILES=("flux1-dev.safetensors" "flux1-dev-fp8.safetensors" "flux1-dev-fp8_e4m3fn_scaled.safetensors")
VAE_FILES=("ae.safetensors")
CLIP_FILES=("clip_l.safetensors")
T5_FILES=("t5xxl_fp16.safetensors" "t5xxl_fp8_e4m3fn_scaled.safetensors")

echo "Downloading FLUX.1-dev UNET..."
found_unet=""
for f in "${UNET_FILES[@]}"; do
  if src="$(hf_dl "$FLUX_REPO" "$f" 2>/dev/null || true)"; then
    if [[ -f "$src" ]]; then cp -f "$src" "$UNET_DIR/"; found_unet="$f"; break; fi
  fi
done
[[ -z "$found_unet" ]] && { echo "ERROR: Could not fetch any known UNET file for FLUX.1-dev."; exit 1; }

echo "Downloading VAE..."
for f in "${VAE_FILES[@]}"; do
  src="$(hf_dl "$FLUX_REPO" "$f")"
  cp -f "$src" "$VAE_DIR/"
done

echo "Downloading CLIP L + T5 encoders..."
for f in "${CLIP_FILES[@]}"; do
  src="$(hf_dl "$FLUX_REPO" "$f")"
  cp -f "$src" "$CLIP_DIR/"
done
found_t5=""
for f in "${T5_FILES[@]}"; do
  if src="$(hf_dl "$FLUX_REPO" "$f" 2>/dev/null || true)"; then
    if [[ -f "$src" ]]; then cp -f "$src" "$CLIP_DIR/"; found_t5="$f"; break; fi
  fi
done
[[ -z "$found_t5" ]] && { echo "ERROR: Could not fetch a T5 encoder (t5xxl*)."; exit 1; }

# ---------- 3) Optional: download extra models from Civitai ----------
if [[ -f /runtime/civitai_models.txt ]]; then
  echo "Fetching Civitai models listed in /runtime/civitai_models.txt ..."
  pushd "$LORA_DIR" >/dev/null
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    civit_dl "$line"
  done < /runtime/civitai_models.txt
  popd >/dev/null
fi

# ---------- 4) Configure & Launch code-server (VS Code in browser) ----------
# If CODE_SERVER_PASSWORD is set, patch or create the code-server config first
if [[ -n "${CODE_SERVER_PASSWORD:-}" ]]; then
  mkdir -p /root/.config/code-server
  if [[ -f /root/.config/code-server/config.yaml ]]; then
    # Update password & port if config exists
    sed -i "s/^password: .*/password: ${CODE_SERVER_PASSWORD}/" /root/.config/code-server/config.yaml || true
    sed -i "s/^bind-addr: .*/bind-addr: 0.0.0.0:${CODE_SERVER_PORT}/" /root/.config/code-server/config.yaml || true
    # Ensure auth and cert settings are present
    grep -q '^auth:' /root/.config/code-server/config.yaml || echo "auth: password" >> /root/.config/code-server/config.yaml
    grep -q '^cert:' /root/.config/code-server/config.yaml || echo "cert: false" >> /root/.config/code-server/config.yaml
  else
    # Create a minimal config when none exists
    cat > /root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_SERVER_PORT}
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
EOF
  fi
fi

echo "Starting code-server on port ${CODE_SERVER_PORT}"
nohup code-server --bind-addr 0.0.0.0:${CODE_SERVER_PORT} "${WORKSPACE}" >/var/log/code-server.log 2>&1 &


# ---------- 5) Launch ComfyUI ----------
echo "Starting ComfyUI on port ${COMFY_PORT}"
cd "$COMFY_HOME"
# Ensure Comfy sees the workspace models
ln -sfn "$WORKSPACE/models" "$COMFY_HOME/models"
ln -sfn "$WORKSPACE/custom_nodes" "$COMFY_HOME/custom_nodes"

source /venv/bin/activate
python main.py --listen 0.0.0.0 --port "${COMFY_PORT}"

