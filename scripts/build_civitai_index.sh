#!/usr/bin/env bash
# Usage: build_civitai_index.sh runtime/civitai_links.txt docs/loras
set -euo pipefail

INPUT_FILE="${1:-runtime/civitai_models.txt}"
OUT_DIR="${2:-docs/loras}"
mkdir -p "$OUT_DIR"/readmes "$OUT_DIR"/images

# Optional auth header (needed for restricted models)
authHeader=()
if [[ -n "${CIVITAI_API_TOKEN:-}" ]]; then
  authHeader=(-H "Authorization: Bearer ${CIVITAI_API_TOKEN}")
fi

INDEX_MD="${OUT_DIR}/INDEX.md"
echo -e "# FLUX LoRAs Index\n\n" > "$INDEX_MD"
echo -e "| Preview | Name | Version | CivitAI | File | Trigger Words |" >> "$INDEX_MD"
echo -e "|---|---|---|---|---|---|" >> "$INDEX_MD"

# Helpers
trim() { awk '{$1=$1};1'; }

extract_version_id() {
  local line="$1"
  # Accept either bare numeric ID or full download URL containing /models/{id}
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    echo "$line"
    return
  fi
  # typical: https://civitai.com/api/download/models/806265?type=Model&format=SafeTensor
  if [[ "$line" =~ /models/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
}

resolve_filename() {
  local url="$1"
  # follow redirects, only headers, extract filename= from content-disposition
  local fname
  fname="$(curl -sIL "$url" "${authHeader[@]}" \
    | awk -F'filename=' 'tolower($0) ~ /content-disposition/ {gsub("\r",""); print $2}' \
    | sed 's/^"//; s/"$//' | head -n1)"
  if [[ -z "$fname" ]]; then
    # fallback
    fname="model-$(date +%s).safetensors"
  fi
  echo "$fname"
}

download_first_images() {
  local json="$1" verid="$2" max="${3:-2}"
  local count=0
  # get up to $max images
  echo "$json" | jq -r '.images[].url' | while read -r url; do
    [[ -z "$url" ]] && continue
    count=$((count+1))
    local img="${OUT_DIR}/_images/${verid}-${count}.jpg"
    curl -sL "$url" -o "$img" || true
    echo "![preview ${count}](_images/${verid}-${count}.jpg)"
    [[ "$count" -ge "$max" ]] && break
  done
}

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
  LINE="$(echo "$LINE" | trim)"
  [[ -z "$LINE" ]] && continue
  [[ "$LINE" =~ ^# ]] && continue

  VER_ID="$(extract_version_id "$LINE")"
  if [[ -z "$VER_ID" ]]; then
    echo "Skipping unrecognized line: $LINE" >&2
    continue
  fi

  # 1) Fetch model-version JSON
  JSON="$(curl -s "https://civitai.com/api/v1/model-versions/${VER_ID}" "${authHeader[@]}")"
  # Basic guard
  if [[ -z "$JSON" || "$(echo "$JSON" | jq -r '.id // empty')" != "$VER_ID" ]]; then
    echo "Warning: could not fetch metadata for version ${VER_ID}" >&2
    continue
  fi

  MODEL_ID=$(jq -r '.modelId' <<< "$JSON")
  MODEL_NAME=$(jq -r '.model.name' <<< "$JSON")
  VER_NAME=$(jq -r '.name' <<< "$JSON")
  TRAINED_WORDS=$(jq -r '(.trainedWords // []) | join(", ")' <<< "$JSON")
  DOWNLOAD_URL=$(jq -r '.downloadUrl' <<< "$JSON")

  # 2) Resolve final filename (headers only)
  FILE_NAME="$(resolve_filename "$DOWNLOAD_URL")"
  # normalize empty
  [[ -z "$FILE_NAME" ]] && FILE_NAME="model-${VER_ID}.safetensors"

  # 3) Download a couple example images
  PREVIEWS="$(download_first_images "$JSON" "$VER_ID" 2)"
  [[ -z "$PREVIEWS" ]] && PREVIEWS="(no preview)"

  # 4) Write per-LoRA README
  README="${OUT_DIR}/readmes/${VER_ID}.md"
  cat > "$README" <<EOF
# ${MODEL_NAME} — ${VER_NAME}

**CivitAI Version:** https://civitai.com/model-versions/${VER_ID}  
**Model Page:** https://civitai.com/models/${MODEL_ID}

## Trigger / Trained Words
\`${TRAINED_WORDS:-none}\`

## File
\`${FILE_NAME}\`  
Download: \`${DOWNLOAD_URL}\`

## Example Images
${PREVIEWS}

## Notes
- Base: FLUX LoRA
- Add best prompts, weights, sampler notes here.
EOF

  # 5) Update INDEX
  echo "| ![](_images/${VER_ID}-1.jpg) | ${MODEL_NAME} | ${VER_NAME} | [version](https://civitai.com/model-versions/${VER_ID}) | \`${FILE_NAME}\` | ${TRAINED_WORDS:-—} |" >> "$INDEX_MD"

done < "$INPUT_FILE"

echo -e "\n—\nGenerated on $(date -u +"%Y-%m-%d %H:%M UTC")." >> "$INDEX_MD"
echo "Done. See ${INDEX_MD}"
