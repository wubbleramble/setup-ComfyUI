#!/usr/bin/env bash
#
# download_comfyui.sh
# ------------------------------------------------------------------
# ComfyUI version of the Forge download script. Downloads models into
# a ComfyUI install and (optionally) clones custom nodes. Meant to be
# run from a Jupyter terminal cell like:
#   !bash download_comfyui.sh
# or from a regular terminal:
#   bash download_comfyui.sh
#
# WHAT THIS SCRIPT DOES (in plain terms):
#   1. Clones each custom node repo listed in CUSTOM_NODES into
#      ComfyUI/custom_nodes/. Skips it if the folder already exists.
#      (The list is empty on purpose: Forge extensions do NOT work in
#      ComfyUI, so the old Forge extension list was removed.)
#   2. Downloads each model file into its correct ComfyUI subfolder
#      (loras, controlnet, vae, text_encoders, etc). If a file with
#      the same name already exists there, the download is skipped.
#   3. Shows a live progress bar, one download at a time (Civitai does
#      not like concurrent downloads from the same source).
#   4. NEVER stops the whole script because one link failed. Failures
#      are recorded and you get a summary at the end.
#   5. Any downloaded .zip is extracted into the folder it was
#      downloaded into (the zip itself stays in place).
#
# WHERE FILES GO (default: /workspace/ComfyUI):
#   Change it without editing this file by running, before the script:
#     export COMFY_DIR="/some/other/path/ComfyUI"
# ------------------------------------------------------------------

set -uo pipefail
# NOTE: intentionally NOT using `set -e` here. `set -e` would kill the
# whole script the moment any single command (like one failed wget)
# returns a non-zero exit code, which is exactly what we don't want.

# ==================== CONFIG (edit if needed) ====================
BASE_DIR="${COMFY_DIR:-/workspace/ComfyUI}"

NODES_DIR="${BASE_DIR}/custom_nodes"
MODELS_DIR="${BASE_DIR}/models"

CONTROLNET_DIR="${MODELS_DIR}/controlnet"
EMBEDDINGS_DIR="${MODELS_DIR}/embeddings"
UPSCALE_DIR="${MODELS_DIR}/upscale_models"
LATENT_UPSCALE_DIR="${MODELS_DIR}/latent_upscale_models"
LORA_DIR="${MODELS_DIR}/loras"
# NOTE: the "Checkpoint" category below downloads into diffusion_models,
# as requested. That is the folder read by the "Load Diffusion Model"
# (UNet) loader. The regular "Load Checkpoint" node reads "checkpoints"
# instead, so change "diffusion_models" to "checkpoints" on the next
# line if a file needs to appear in that node's dropdown.
CHECKPOINT_DIR="${MODELS_DIR}/diffusion_models"
VAE_DIR="${MODELS_DIR}/vae"
VAE_APPROX_DIR="${MODELS_DIR}/vae_approx"
TEXT_ENCODER_DIR="${MODELS_DIR}/text_encoders"
# "detection" = the old ADetailer folder, as requested. Same note as
# above: the detector node you use must be looking in this folder.
DETECTION_DIR="${MODELS_DIR}/detection"
# Impact Subpack's UltralyticsDetectorProvider only scans these two
# folders, so detection models get linked into them after download.
ULTRA_BBOX_DIR="${MODELS_DIR}/ultralytics/bbox"
ULTRA_SEGM_DIR="${MODELS_DIR}/ultralytics/segm"

# Civitai API key, if your links need auth to resolve. This script
# reads it from the environment — set it BEFORE running the script,
# e.g. in your terminal session:
#   export CIVITAI_API_KEY="your_key_here"
# It is never written into this file, so it's safe for this script
# to live in a public GitHub repo.
CIVITAI_API_KEY="${CIVITAI_API_KEY:-}"

# Optional: Hugging Face token, for gated/private model repos. Public
# huggingface.co downloads (like the ControlNet/adetailer links below)
# don't need this, but it's picked up automatically if set.
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"
# Python interpreter that ComfyUI actually runs with. On vast.ai base
# images this is the pre-made /venv/main environment. If that path does
# not exist, fall back to whatever python3 is on PATH.
# Override without editing this file:  export COMFY_PYTHON="/path/to/python"
if [ -n "${COMFY_PYTHON:-}" ]; then
  PY="$COMFY_PYTHON"
elif [ -x /venv/main/bin/python ]; then
  PY=/venv/main/bin/python
else
  PY="$(command -v python3 || true)"
fi

LOG_FILE="./download_log_$(date +%Y%m%d_%H%M%S).txt"

# ==================== INTERRUPT HANDLING ====================
#
# Without this trap, pressing Ctrl+C (in a Jupyter terminal or
# anywhere else) while a wget is running gets swallowed by the retry
# loop below -- it just looks like "that attempt failed", so the
# script retries the SAME file up to 5 times and then quietly moves
# on to the NEXT one, instead of actually stopping. This trap makes
# an interrupt signal (Ctrl+C / SIGINT, or SIGTERM) immediately clean
# up temp folders and exit the whole script, no matter what it was
# doing at the time.
cleanup_and_exit_on_interrupt() {
  echo -e "\n[INTERRUPTED] Caught interrupt signal — stopping now." | tee -a "$LOG_FILE" 2>/dev/null
  rm -rf "${TMP_DL_DIR:-}" "${META_TMP_DIR:-}" 2>/dev/null
  exit 130
}
trap cleanup_and_exit_on_interrupt INT TERM

# ==================== INTERNAL STATE ====================
declare -a SUCCEEDED=()
declare -a SKIPPED=()
declare -a FAILED=()

# ==================== HELPERS ====================

log() {
  # Prints to the terminal AND appends to a log file, so you have a
  # record after the script finishes.
  echo -e "$1" | tee -a "$LOG_FILE"
}

ensure_dirs() {
  log "\n== Creating target folders (if they don't already exist) =="
  mkdir -p "$NODES_DIR" "$CONTROLNET_DIR" "$EMBEDDINGS_DIR" \
    "$UPSCALE_DIR" "$LATENT_UPSCALE_DIR" "$LORA_DIR" "$CHECKPOINT_DIR" \
    "$VAE_DIR" "$VAE_APPROX_DIR" "$TEXT_ENCODER_DIR" "$DETECTION_DIR" \
    "$ULTRA_BBOX_DIR" "$ULTRA_SEGM_DIR"
}

# clone_extension <git_url>  (used for ComfyUI custom nodes)
# Clones a repo into NODES_DIR. Skips if the folder already exists.
clone_extension() {
  local url="$1"
  local name
  name="$(basename "$url" .git)"
  local target="${NODES_DIR}/${name}"

  if [ -d "$target" ]; then
    log "  [SKIP] Extension already exists: $name"
    SKIPPED+=("extension: $name")
    return 0
  fi

  log "  [CLONE] $name"
  if git clone --depth=1 "$url" "$target" 2>&1 | tee -a "$LOG_FILE"; then
    log "  [OK] $name"
    SUCCEEDED+=("extension: $name")
    if [ -f "${target}/requirements.txt" ]; then
      log "  [NOTE] $name has a requirements.txt -- install it into ComfyUI's Python environment (pip install -r)."
    fi
  else
    log "  [FAIL] $name"
    FAILED+=(": $name (url: $url)")
    # Clean up a half-cloned folder so a retry later doesn't think
    # it's already done.
    rm -rf "$target"
  fi
}

# -------------------- Archive extraction support --------------------
#
# maybe_extract_archive <file_path> <target_dir>
#
# If the downloaded file is a .zip, extract it in place (into the
# same folder the zip lives in). The zip itself is left on disk
# afterward — only extracted, not deleted — in case anything inside
# needs re-extracting later or the archive is the thing you actually
# wanted to keep. Safe to call on non-zip files; it just does nothing.
maybe_extract_archive() {
  local file_path="$1"
  local target_dir="$2"
  local base_name
  base_name="$(basename "$file_path")"

  case "$file_path" in
    *.zip|*.ZIP)
      if ! command -v unzip >/dev/null 2>&1; then
        log "  [WARN] 'unzip' is not installed — skipping extraction of $base_name"
        return 1
      fi
      log "  [EXTRACT] Unzipping $base_name into $target_dir"
      if unzip -o -q "$file_path" -d "$target_dir" 2>>"$LOG_FILE"; then
        log "  [OK] Extracted $base_name"
      else
        log "  [WARN] Extraction failed for $base_name (archive may be corrupt or password-protected)"
        return 1
      fi
      ;;
    *)
      return 0
      ;;
  esac
}

# -------------------- Civitai metadata support --------------------
#
# For Civitai links, we now call Civitai's real metadata API
# (api/v1/model-versions/{id}) BEFORE downloading. This gets us:
#   - the real filename (more reliable than guessing from headers)
#   - the exact expected file size, so we can confirm a huge download
#     actually completed instead of silently ending up truncated
#   - trigger words / trained activation words (for LoRAs especially)
#   - a thumbnail preview image URL
#
# This requires python3 (for parsing the JSON) and curl, both of
# which are already present on essentially every Jupyter/vast.ai
# image. If either is missing, the script automatically falls back
# to the older "download first, read filename from headers" method.
HAVE_PY3="$(command -v python3 || true)"
HAVE_CURL="$(command -v curl || true)"

META_TMP_DIR="$(mktemp -d)"

# civitai_fetch_metadata <url> <out_prefix>
# On success, writes three files under $META_TMP_DIR named
# <out_prefix>.filename / .size_bytes / .thumb_url, and leaves the
# full raw API JSON at <out_prefix>.json (used later for the sidecar
# metadata file with trigger words). Returns 1 if anything about this
# lookup didn't work (missing tools, no ID found, API error, etc.) —
# callers should treat that as "fall back to the old method", not a
# fatal error.
civitai_fetch_metadata() {
  local url="$1"
  local prefix="$2"

  [ -n "$HAVE_PY3" ] && [ -n "$HAVE_CURL" ] || return 1

  local mv_id
  mv_id="$(echo "$url" | grep -oE '/models/[0-9]+' | head -1 | grep -oE '[0-9]+')"
  [ -n "$mv_id" ] || return 1

  local file_id
  file_id="$(echo "$url" | grep -oE 'fileId=[0-9]+' | grep -oE '[0-9]+')"

  local auth=()
  [ -n "$CIVITAI_API_KEY" ] && auth=(-H "Authorization: Bearer ${CIVITAI_API_KEY}")

  local raw_json="${META_TMP_DIR}/${prefix}.json"
  # Always query the official civitai.com API for metadata, even if
  # the download link itself points at the civitai.red mirror.
  if ! curl -fsSL "${auth[@]}" "https://civitai.com/api/v1/model-versions/${mv_id}" \
      -o "$raw_json" 2>>"$LOG_FILE"; then
    return 1
  fi
  [ -s "$raw_json" ] || return 1

  local parsed
  parsed="$(FILE_ID="$file_id" python3 <<PYEOF
import json, os
try:
    with open("$raw_json") as fh:
        data = json.load(fh)
    file_id = os.environ.get("FILE_ID") or ""
    files = data.get("files", []) or []
    chosen = None
    if file_id:
        for f in files:
            if str(f.get("id")) == file_id:
                chosen = f
                break
    if chosen is None:
        for f in files:
            if f.get("primary"):
                chosen = f
                break
    if chosen is None and files:
        chosen = files[0]
    name = chosen.get("name", "") if chosen else ""
    size_kb = chosen.get("sizeKB", 0) if chosen else 0
    size_bytes = int(size_kb * 1024) if size_kb else 0
    images = data.get("images", []) or []
    # Pick the first STATIC image (.jpg/.jpeg/.png) for the thumbnail,
    # skipping anything Civitai marks as a video and skipping any
    # image whose URL is actually a GIF/MP4/WEBM (animated). This is
    # what keeps animated example gallery entries from ending up as
    # the saved thumbnail.
    STATIC_EXTS = (".jpg", ".jpeg", ".png")
    thumb = ""
    for img in images:
        img_type = (img.get("type") or "").lower()
        img_url = img.get("url", "") or ""
        ext = os.path.splitext(img_url.split("?")[0])[1].lower()
        if img_type == "video":
            continue
        if ext in STATIC_EXTS:
            thumb = img_url
            break
    # Fallback: if none of the images matched (e.g. the gallery for
    # this model is entirely GIFs/videos), fall back to the first
    # image anyway so a thumbnail still gets saved.
    if not thumb and images:
        thumb = images[0].get("url", "")
    print(name)
    print(size_bytes)
    print(thumb)
except Exception:
    print("")
    print("0")
    print("")
PYEOF
)"

  local pfilename psize pthumb
  { IFS= read -r pfilename; IFS= read -r psize; IFS= read -r pthumb; } <<< "$parsed"

  [ -n "$pfilename" ] || return 1

  echo -n "$pfilename" > "${META_TMP_DIR}/${prefix}.filename"
  echo -n "$psize" > "${META_TMP_DIR}/${prefix}.size_bytes"
  echo -n "$pthumb" > "${META_TMP_DIR}/${prefix}.thumb_url"
  return 0
}

# save_civitai_sidecar <raw_json_path> <thumb_url> <target_dir> <filename>
# Writes a {filename}.json with model name / base model / trigger
# words, and a best-effort thumbnail. Called for every successful
# Civitai download that had working metadata — trigger words matter
# most for LoRAs, but thumbnails are useful across all categories.
# Failures here are logged but never fail the download itself.
#
# THUMBNAIL NAMING FIX: the preview image is now saved as
# "<name-without-original-extension>.preview.png" (e.g.
# "mymodel.preview.png" for "mymodel.safetensors") instead of the
# old "<full-filename>.preview.png" (e.g. "mymodel.safetensors.preview.png").
# Forge/A1111-style extensions like Civitai Helper and the Civitai
# Browser extension only recognize the first form — that mismatch is
# why thumbnails weren't showing up in the UI even though the image
# files were being downloaded successfully.
save_civitai_sidecar() {
  local raw_json="$1"
  local thumb_url="$2"
  local target_dir="$3"
  local filename="$4"
  local base_name="${filename%.*}"

  if [ -n "$HAVE_PY3" ] && [ -s "$raw_json" ]; then
    OUT_PATH="${target_dir}/${base_name}.json" python3 <<PYEOF || log "  [WARN] Could not write metadata sidecar for $filename"
import json, os
with open("$raw_json") as fh:
    data = json.load(fh)
trained = data.get("trainedWords", []) or []
sidecar = {
    "model_name": (data.get("model") or {}).get("name", ""),
    "version_name": data.get("name", ""),
    "base_model": data.get("baseModel", ""),
    "trained_words": trained,
    "activation text": ", ".join(trained),
}
with open(os.environ["OUT_PATH"], "w") as out:
    json.dump(sidecar, out, indent=2)
PYEOF
    log "  [META] Saved trigger words / info to ${base_name}.json"
  fi

  if [ -n "$thumb_url" ]; then
    if wget -q -O "${target_dir}/${base_name}.preview.png" "$thumb_url"; then
      log "  [META] Saved thumbnail to ${base_name}.preview.png"
    else
      log "  [WARN] Thumbnail download failed for $filename"
      rm -f "${target_dir}/${base_name}.preview.png"
    fi
  fi
}

# -------------------- Resumable download core --------------------
#
# download_with_retry <url> <output_path> <auth_header...>
#
# IMPORTANT DETAIL ABOUT CIVITAI: civitai.red / civitai.com redirect
# to a temporary, cryptographically-signed Cloudflare R2 URL that's
# generated fresh on every request (visible in the log as the long
# X-Amz-Signature... URL). If a partial file already exists locally
# and wget tries to resume (sends a Range header) against a BRAND
# NEW signed URL from a fresh request, R2 rejects it with a plain
# "400 Bad Request" rather than honoring the resume.
#
# So: resume (-c) is still used, but only within a single wget
# invocation's own internal retries (--tries=3) — those reconnect to
# the SAME already-resolved signed URL, which is safe. At the OUTER
# level (a brand new attempt after several internal retries failed),
# any partial file is deleted first, so the next attempt starts a
# clean download against whatever fresh redirect it gets. This trades
# a bit of bandwidth on repeated failures for actually working.
#
# NOTE ON HEADERS: this function shells out to wget, and wget's
# short flag "-H" means "--span-hosts" (a boolean, no argument) --
# it is NOT a header flag like curl's "-H". Any auth_header array
# passed in here MUST use wget's long-form "--header=..." syntax,
# never "-H". See auth_header_wget in download_file() below.
MAX_ATTEMPTS=5

download_with_retry() {
  local url="$1"
  local output_path="$2"
  local resume_safe="$3"
  shift 3
  local auth_header=("$@")

  local attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ "$attempt" -gt 1 ]; then
      if [ "$resume_safe" = "1" ]; then
        log "  [RETRY] Attempt ${attempt}/${MAX_ATTEMPTS} (resuming from $(du -h "$output_path" 2>/dev/null | cut -f1 || echo 0))"
      else
        log "  [RETRY] Attempt ${attempt}/${MAX_ATTEMPTS} (starting fresh — previous signed URL is no longer valid to resume against)"
        rm -f "$output_path"
      fi
      sleep 5
    fi
    wget -c --tries=3 --timeout=60 --waitretry=10 \
        --progress=bar:force:noscroll "${auth_header[@]}" \
        -O "$output_path" "$url" 2>&1 | tee -a "$LOG_FILE"
    local wget_status="${PIPESTATUS[0]}"
    if [ "$wget_status" -eq 0 ]; then
      return 0
    fi
    # 130 = killed by SIGINT (Ctrl+C), 143 = killed by SIGTERM. Either
    # way, this was a deliberate stop, not a network hiccup -- don't
    # treat it as "attempt failed, try again", let it propagate up so
    # the whole script actually stops instead of retrying/continuing.
    if [ "$wget_status" -eq 130 ] || [ "$wget_status" -eq 143 ]; then
      cleanup_and_exit_on_interrupt
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# download_with_retry_curl <url> <output_path> <auth_header...>
#
# Used ONLY for Civitai links. Both previous approaches for Civitai
# turned out broken in different ways:
#   - Handing wget the original civitai.red URL with the Authorization
#     header attached: wget follows the 307 redirect itself but keeps
#     forwarding that SAME header to the final Cloudflare R2 URL. R2's
#     own signed query-string is already self-authenticating, so the
#     extra header is a conflicting-auth combo R2 always rejects with
#     "400 Bad Request".
#   - Manually pre-resolving the redirect and stripping the header
#     before ever contacting R2: works for public files, but a file
#     that genuinely needs the API key to see the redirect AT ALL
#     (early-access/gated content) then fails with a plain
#     "401 Unauthorized" straight from civitai.red, since the header
#     never gets sent anywhere.
#
# curl actually solves both at once: with -L (follow redirects), curl
# has a built-in security feature where it automatically drops the
# Authorization header when a redirect crosses to a DIFFERENT host.
# So the Civitai API key is sent to civitai.red (satisfying gated
# files) but is never forwarded to the R2 domain (avoiding the
# conflicting-auth 400). This is the correct, general fix — no manual
# redirect resolution needed at all.
#
# NOTE ON HEADERS: this function shells out to curl, so "-H" is the
# correct header flag here (unlike wget above).
download_with_retry_curl() {
  local url="$1"
  local output_path="$2"
  shift 2
  local auth_header=("$@")

  local attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if [ "$attempt" -gt 1 ]; then
      log "  [RETRY] Attempt ${attempt}/${MAX_ATTEMPTS} (resuming from $(du -h "$output_path" 2>/dev/null | cut -f1 || echo 0))"
      sleep 5
    fi
    curl -fL --retry 2 --retry-delay 5 --connect-timeout 30 \
        -C - --progress-bar "${auth_header[@]}" \
        -o "$output_path" "$url" 2>&1 | tee -a "$LOG_FILE"
    local curl_status="${PIPESTATUS[0]}"
    if [ "$curl_status" -eq 0 ]; then
      return 0
    fi
    # 130 = killed by SIGINT (Ctrl+C), 143 = killed by SIGTERM -- a
    # deliberate stop, not a network hiccup. Let it propagate up so
    # the whole script actually stops instead of retrying/continuing.
    if [ "$curl_status" -eq 130 ] || [ "$curl_status" -eq 143 ]; then
      cleanup_and_exit_on_interrupt
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

# download_extension_zip <civitai_zip_url>
#
# Some Forge extensions are distributed on Civitai as a zip archive
# rather than a git repo. Unlike model downloads via download_file(),
# this does NOT write a .json/.preview.png sidecar (that metadata is
# model-specific and doesn't belong in the extensions folder), and
# the zip itself is discarded after extraction -- only the extracted
# extension folder is kept in NODES_DIR, matching how clone_extension()
# leaves only the checked-out folder behind.
download_extension_zip() {
  local url="$1"

  if [ -z "$HAVE_CURL" ]; then
    log "  [FAIL] curl is required for Civitai downloads but is not installed: $url"
    FAILED+=("extension archive: (unknown) (url: $url) — curl not installed")
    return 1
  fi

  local auth_header_curl=()
  [ -n "$CIVITAI_API_KEY" ] && auth_header_curl=(-H "Authorization: Bearer ${CIVITAI_API_KEY}")

  # Metadata lookup gets both a friendly name for logging AND the
  # expected file size. The expected size matters more here than it
  # does for models: extensions can legitimately be tiny (sometimes
  # just one or two Python files, well under 10KB), so a flat "must
  # be over 10KB" floor incorrectly rejects a valid small zip. Using
  # the real expected size (same approach as download_file() for
  # models) also still catches the actual failure mode this is meant
  # to guard against: Civitai returning a small HTML error/login page
  # with an HTTP 200 status instead of the real file, which curl -f
  # doesn't treat as an error on its own.
  local filename=""
  local expected_size=0
  local prefix
  prefix="e$(echo "$url" | md5sum | cut -c1-10)"
  if civitai_fetch_metadata "$url" "$prefix"; then
    filename="$(cat "${META_TMP_DIR}/${prefix}.filename" 2>/dev/null || echo "")"
    expected_size="$(cat "${META_TMP_DIR}/${prefix}.size_bytes" 2>/dev/null || echo 0)"
  fi

  local tmp_zip
  tmp_zip="$(mktemp "${NODES_DIR}/.dlext.XXXXXX.zip")"

  log "  [DOWNLOAD] extension archive -> $NODES_DIR${filename:+ ($filename)}"
  if ! download_with_retry_curl "$url" "$tmp_zip" "${auth_header_curl[@]}"; then
    log "  [FAIL] Extension archive download failed: $url"
    rm -f "$tmp_zip"
    FAILED+=("extension archive: ${filename:-unknown} (url: $url)")
    return 1
  fi

  local actual_size
  actual_size="$(stat -c%s "$tmp_zip" 2>/dev/null || echo 0)"
  local size_ok=0
  if [ "$expected_size" -gt 0 ]; then
    # Within 1% of Civitai's reported size, same tolerance as models.
    local min_ok=$(( expected_size * 99 / 100 ))
    [ "$actual_size" -ge "$min_ok" ] && size_ok=1
  elif [ "$actual_size" -gt 1024 ]; then
    # No metadata size available -- fall back to a much lower floor
    # (1KB, not 10KB) since a legitimate extension zip can be small.
    size_ok=1
  fi
  if [ "$size_ok" -ne 1 ]; then
    log "  [FAIL] Extension archive size looks wrong (got ${actual_size} bytes, expected ~${expected_size:-unknown}): $url"
    rm -f "$tmp_zip"
    FAILED+=("extension archive: ${filename:-unknown} (url: $url) — file too small/wrong size")
    return 1
  fi

  if maybe_extract_archive "$tmp_zip" "$NODES_DIR"; then
    log "  [OK] Extension archive extracted${filename:+ ($filename)}"
    SUCCEEDED+=("extension archive: ${filename:-$url}")
  else
    log "  [FAIL] Extraction failed for extension archive: $url"
    FAILED+=("extension archive: ${filename:-unknown} (url: $url) — extraction failed")
    rm -f "$tmp_zip"
    return 1
  fi

  rm -f "$tmp_zip"  # only the extracted folder is kept, not the archive
  return 0
}

# download_file <url> <target_dir> [explicit_filename]
#
# Downloads a single file with a live progress bar. Skips if a file
# of the same name already exists in target_dir. Never exits the
# script on failure — just records it. For Civitai links, also
# fetches and saves trigger words + thumbnail (for Checkpoints/LoRAs).
# If the downloaded file turns out to be a .zip, it's extracted into
# the same target_dir right after the download finishes.
download_file() {
  local url="$1"
  local target_dir="$2"
  local filename="${3:-}"
  local is_civitai=0
  [[ "$url" == *civitai.com* || "$url" == *civitai.red* ]] && is_civitai=1

  if [ "$is_civitai" -eq 1 ] && [ -z "$HAVE_CURL" ]; then
    log "  [FAIL] curl is required for Civitai downloads but is not installed: $url"
    FAILED+=("model: (unknown filename) (url: $url) — curl not installed")
    return 1
  fi

  # Two SEPARATE header arrays, in each tool's own required syntax --
  # this is important, not stylistic. curl's "-H" and wget's "-H"
  # mean completely different things (curl: header; wget: span-hosts,
  # a flag with no argument). Mixing them up silently breaks auth:
  # wget would treat "-H" as a boolean flag and the header string as
  # a stray extra URL argument. Civitai downloads always go through
  # curl (auth_header_curl), HuggingFace/direct downloads always go
  # through wget (auth_header_wget) -- never cross-used.
  local auth_header_curl=()
  local auth_header_wget=()
  if [ "$is_civitai" -eq 1 ] && [ -n "$CIVITAI_API_KEY" ]; then
    auth_header_curl=(-H "Authorization: Bearer ${CIVITAI_API_KEY}")
  elif [[ "$url" == *huggingface.co* ]] && [ -n "$HUGGINGFACE_TOKEN" ]; then
    auth_header_wget=(--header="Authorization: Bearer ${HUGGINGFACE_TOKEN}")
  fi

  local expected_size=0
  local thumb_url=""
  local meta_json=""
  local meta_ok=0

  if [ "$is_civitai" -eq 1 ] && [ -z "$filename" ]; then
    local prefix
    prefix="m$(echo "$url" | md5sum | cut -c1-10)"
    if civitai_fetch_metadata "$url" "$prefix"; then
      meta_ok=1
      filename="$(cat "${META_TMP_DIR}/${prefix}.filename")"
      expected_size="$(cat "${META_TMP_DIR}/${prefix}.size_bytes")"
      thumb_url="$(cat "${META_TMP_DIR}/${prefix}.thumb_url")"
      meta_json="${META_TMP_DIR}/${prefix}.json"
    fi
  fi

  if [ -z "$filename" ] && [ "$is_civitai" -eq 0 ]; then
    # Direct links (e.g. huggingface) — the URL's last path segment
    # is normally the real filename.
    filename="$(basename "${url%%\?*}")"
  fi

  # ---- Case A: filename known ahead of time (explicit, hf, or via
  # Civitai metadata). Duplicate check can happen before downloading.
  if [ -n "$filename" ]; then
    local target_path="${target_dir}/${filename}"
    if [ -f "$target_path" ]; then
      log "  [SKIP] Already exists: $filename"
      SKIPPED+=("model: $filename")
      return 0
    fi

    log "  [DOWNLOAD] $filename -> $target_dir"
    local dl_ok=1
    if [ "$is_civitai" -eq 1 ]; then
      # curl -L handles Civitai's redirect correctly on its own (see
      # the comment on download_with_retry_curl above) -- no manual
      # redirect resolution needed.
      if ! download_with_retry_curl "$url" "$target_path" "${auth_header_curl[@]}"; then
        dl_ok=0
      fi
    else
      if ! download_with_retry "$url" "$target_path" 1 "${auth_header_wget[@]}"; then
        dl_ok=0
      fi
    fi
    if [ "$dl_ok" -eq 1 ]; then
      local actual_size
      actual_size="$(stat -c%s "$target_path" 2>/dev/null || echo 0)"
      # If we know the expected size from Civitai's metadata, require
      # we're within 1% of it (accounts for rounding in their sizeKB
      # field). Otherwise fall back to the basic "bigger than 10KB"
      # sanity check.
      local size_ok=0
      if [ "$expected_size" -gt 0 ]; then
        local min_ok=$(( expected_size * 99 / 100 ))
        [ "$actual_size" -ge "$min_ok" ] && size_ok=1
      elif [ "$actual_size" -gt 10240 ]; then
        size_ok=1
      fi

      if [ "$size_ok" -eq 1 ]; then
        log "  [OK] $filename"
        SUCCEEDED+=("model: $filename")
        if [ "$meta_ok" -eq 1 ]; then
          save_civitai_sidecar "$meta_json" "$thumb_url" "$target_dir" "$filename"
        fi
        maybe_extract_archive "$target_path" "$target_dir"
      else
        log "  [FAIL] $filename downloaded but size looks wrong (got ${actual_size} bytes, expected ~${expected_size}) — removing"
        rm -f "$target_path"
        FAILED+=("model: $filename (url: $url) — incomplete/wrong-size download")
      fi
    else
      log "  [FAIL] $filename — all ${MAX_ATTEMPTS} attempts failed"
      rm -f "$target_path"
      FAILED+=("model: $filename (url: $url)")
    fi
    return 0
  fi

  # ---- Case B: Civitai metadata lookup failed (API down, unusual
  # URL shape, etc). Fall back to downloading into a temp folder and
  # letting the tool read the real filename from Content-Disposition.
  # NOTE: wget's -O flag always overrides --content-disposition
  # naming, so this deliberately does NOT use -O / download_with_retry
  # — it lets the tool name the file itself, with its own retry/resume
  # support for large files.
  local b_dl_url="$url"
  local b_dl_auth_curl=("${auth_header_curl[@]}")
  local b_dl_auth_wget=("${auth_header_wget[@]}")
  ( cd "$TMP_DL_DIR" && rm -f -- *
    local b_attempt=1
    while [ "$b_attempt" -le "$MAX_ATTEMPTS" ]; do
      if [ "$b_attempt" -gt 1 ]; then
        rm -f -- *
        sleep 5
      fi
      if [ "$is_civitai" -eq 1 ]; then
        # curl -L drops the Authorization header on the cross-host
        # redirect to R2 automatically -- see download_with_retry_curl
        # above for the full explanation. -O -J: use the server's
        # suggested filename (equivalent to wget's --content-disposition).
        curl -fL --retry 2 --retry-delay 5 --connect-timeout 30 \
          --progress-bar -O -J "${b_dl_auth_curl[@]}" "$b_dl_url" 2>&1 | tee -a "$LOG_FILE"
      else
        wget -c --tries=3 --timeout=60 --waitretry=10 \
          --progress=bar:force:noscroll --content-disposition \
          "${b_dl_auth_wget[@]}" "$b_dl_url" 2>&1 | tee -a "$LOG_FILE"
      fi
      b_wget_status="${PIPESTATUS[0]}"
      [ "$b_wget_status" -eq 0 ] && break
      if [ "$b_wget_status" -eq 130 ] || [ "$b_wget_status" -eq 143 ]; then
        exit 130  # exits the subshell only -- caught by the check right after it closes below
      fi
      b_attempt=$((b_attempt + 1))
    done
  )
  # ( )  is a subshell, so an `exit` inside it only ends the subshell,
  # not the whole script -- check its exit status here and trigger
  # the real cleanup-and-stop if it was killed by Ctrl+C/SIGTERM.
  local subshell_status="$?"
  if [ "$subshell_status" -eq 130 ] || [ "$subshell_status" -eq 143 ]; then
    cleanup_and_exit_on_interrupt
  fi

  local downloaded_file
  downloaded_file="$(find "$TMP_DL_DIR" -maxdepth 1 -type f -printf '%f\n' | head -1)"

  if [ -z "$downloaded_file" ]; then
    log "  [FAIL] Download produced no file: $url"
    FAILED+=("model: (unknown filename) (url: $url) — no file was produced")
    return 1
  fi

  local downloaded_size
  downloaded_size="$(stat -c%s "${TMP_DL_DIR}/${downloaded_file}" 2>/dev/null || echo 0)"

  if [ "$downloaded_size" -le 10240 ]; then
    log "  [FAIL] $downloaded_file downloaded but looks invalid (too small)"
    rm -f "${TMP_DL_DIR:?}/${downloaded_file}"
    FAILED+=("model: $downloaded_file (url: $url) — file too small, likely bad link/token")
    return 1
  fi

  local target_path="${target_dir}/${downloaded_file}"
  if [ -f "$target_path" ]; then
    log "  [SKIP] Already exists (discarding re-download): $downloaded_file"
    SKIPPED+=("model: $downloaded_file")
    rm -f "${TMP_DL_DIR:?}/${downloaded_file}"
    return 0
  fi

  mv "${TMP_DL_DIR}/${downloaded_file}" "$target_path"
  log "  [OK] $downloaded_file (no trigger-word metadata — Civitai API lookup failed for this link)"
  SUCCEEDED+=("model: $downloaded_file")
  maybe_extract_archive "$target_path" "$target_dir"
  return 0
}

# install_node_requirements
# Runs "pip install -r requirements.txt" for EVERY folder inside
# custom_nodes (new and already-existing ones). Packages that are
# already installed are skipped by pip, so re-running is safe.
install_node_requirements() {
  if [ -z "$PY" ]; then
    log "  [WARN] No Python found -- skipping custom node requirements."
    return 1
  fi
  log "  Using Python: $PY"

  # Save the currently installed torch/numpy versions as a "do not
  # change" list, so a node's requirements cannot swap the CUDA build
  # of PyTorch for a different one.
  local constraints
  constraints="$(mktemp)"
  "$PY" -m pip freeze 2>/dev/null \
    | grep -iE '^(torch|torchvision|torchaudio|numpy)==' > "$constraints"

  local req node_name
  for req in "$NODES_DIR"/*/requirements.txt; do
    [ -f "$req" ] || continue
    node_name="$(basename "$(dirname "$req")")"
    log "  [PIP] $node_name"
    if "$PY" -m pip install -c "$constraints" -r "$req" 2>&1 | tee -a "$LOG_FILE"; then
      SUCCEEDED+=("pip requirements: $node_name")
    else
      log "  [FAIL] pip install failed for $node_name"
      FAILED+=("pip requirements: $node_name (see $LOG_FILE)")
    fi
  done

  rm -f "$constraints"
}

# Temp folder used only by the Case B fallback path above (when a
# Civitai metadata lookup fails and we have to read the filename off
# the download response instead). Removed at the very end of the
# script.
TMP_DL_DIR="$(mktemp -d)"
# link_detection_models
# Symlinks every detector in DETECTION_DIR into the folder Impact
# Subpack scans. Names containing "seg" go to segm, all others to bbox.
# Already-linked files are skipped, so re-running the script is safe.
link_detection_models() {
  log "\n== Linking detection models for Impact Subpack =="
  local f name dest
  while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    case "${name,,}" in
      *seg*) dest="$ULTRA_SEGM_DIR" ;;
      *)     dest="$ULTRA_BBOX_DIR" ;;
    esac
    if [ -e "$dest/$name" ] || [ -L "$dest/$name" ]; then
      log "  [SKIP] already linked: $name"; continue
    fi
    ln -s "$f" "$dest/$name" && log "  [LINK] $name -> ${dest#$MODELS_DIR/}"
  done < <(find "$DETECTION_DIR" -type f \( -iname '*.pt' -o -iname '*.pth' -o -iname '*.safetensors' \) -print0)
}

# ==================== MAIN ====================

ensure_dirs

log "\n== Custom nodes (git) =="
# One git repo per line. Each repo is cloned into ComfyUI/custom_nodes/
# (folder named after the repo). Existing folders are skipped.
# Add more by pasting another line like:
#   "https://github.com/<author>/<repo>.git"
CUSTOM_NODES=(
"https://github.com/ukr8b3g-cmyk/Anima_Regional_Canvas.git"
"https://github.com/Azornes/Comfyui-Model-Resolver.git"
"https://gitlab.com/UmeAiRT-Studio/ComfyUI-UmeAiRT-Toolkit.git"
"https://github.com/Mirumo0u0/ComfyUI-Cosmos-Reference.git"
"https://github.com/kohya-ss/ComfyUI-Anima-LLLite.git"
"https://github.com/scraed/LanPaint.git"
"https://github.com/ltdrdata/ComfyUI-Manager.git"
"https://github.com/Fannovel16/comfyui_controlnet_aux.git"
"https://github.com/rgthree/rgthree-comfy.git"
"https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
"https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
"https://github.com/yolain/ComfyUI-Easy-Use.git"
"https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git"
"https://github.com/jags111/efficiency-nodes-comfyui.git"
"https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git"
"https://github.com/cubiq/ComfyUI_essentials.git"
"https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"
"https://github.com/alexopus/ComfyUI-Image-Saver.git"
"https://github.com/kohya-ss/ComfyUI-Anima-LLLite.git"
"https://github.com/IAMCCS/IAMCCS-nodes.git"
"https://github.com/SethRobinson/comfyui-workflow-to-api-converter-endpoint.git"
"https://github.com/hayden-cn/ComfyUI-Model-Manager.git"
"https://github.com/kijai/ComfyUI-KJNodes.git"
"https://github.com/shadowcz007/comfyui-mixlab-nodes.git"
"https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git"
"https://github.com/ltdrdata/was-node-suite-comfyui.git"
"https://github.com/regiellis/ComfyUI-EasyColorCorrector.git"
"https://github.com/PixWizardry/ComfyUI-PIX_Nvidia_RTX_Deblur_Denoise.git"
"https://github.com/ryanontheinside/ComfyUI_RealtimeNodes.git"
"https://github.com/willmiao/ComfyUI-Lora-Manager.git"
"https://github.com/Comfy-Org/Nvidia_RTX_Nodes_ComfyUI.git"
"https://github.com/Miosp/ComfyUI-FBCNN.git"
"https://github.com/BetaDoggo/comfyui-rtx-simple.git"
"https://github.com/pixaroma/ComfyUI-Pixaroma.git"
"https://github.com/Smirnov75/ComfyUI-mxToolkit.git"
"https://github.com/Azornes/Comfyui-Resolution-Master.git"
"https://github.com/BadCafeCode/masquerade-nodes-comfyui.git"
"https://github.com/ManglerFTW/ComfyI2I.git"
"https://github.com/pythongosssss/ComfyUI-WD14-Tagger.git"
"https://github.com/idrirap/ComfyUI-Lora-Auto-Trigger-Words.git"
)
for url in ${CUSTOM_NODES[@]+"${CUSTOM_NODES[@]}"}; do
  clone_extension "$url"
done

log "\n== Custom nodes (zipped, from Civitai) =="
# Same idea, for nodes distributed as a zip on Civitai.
CUSTOM_NODE_ARCHIVES=(
)
for url in ${CUSTOM_NODE_ARCHIVES[@]+"${CUSTOM_NODE_ARCHIVES[@]}"}; do
  download_extension_zip "$url"
done

log "\n== Custom node Python requirements =="
install_node_requirements

log "\n== LoRA =="
LORAS=(
"https://huggingface.co/ByteDance/Hyper-SD/resolve/main/Hyper-SDXL-8steps-CFG-lora.safetensors"
"https://civitai.red/api/download/models/3334160?fileId=3220708"
)
for url in "${LORAS[@]}"; do
  download_file "$url" "$LORA_DIR"
done
log "\n== WD14 Tagger models =="
# Models for the ComfyUI-WD14-Tagger node (pythongosssss). The .onnx and
# .csv files must share the same base name for the node to pair them.
WD14_TAGGER_DIR="${NODES_DIR}/ComfyUI-WD14-Tagger/models"
mkdir -p "$WD14_TAGGER_DIR"
download_file "https://huggingface.co/SmilingWolf/wd-eva02-large-tagger-v3/resolve/main/selected_tags.csv" "$WD14_TAGGER_DIR" "wd-eva02-large-tagger-v3.csv"
download_file "https://huggingface.co/SmilingWolf/wd-eva02-large-tagger-v3/resolve/main/model.onnx" "$WD14_TAGGER_DIR" "wd-eva02-large-tagger-v3.onnx"

log "\n== VAE =="
download_file "https://civitai.red/api/download/models/648388?fileId=824329" "$VAE_DIR"
download_file "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors" "$VAE_DIR"
download_file "https://huggingface.co/Comfy-Org/SeedVR2/resolve/main/vae/ema_vae_fp16.safetensors" "$VAE_DIR"

log "\n== Text Encoder =="
download_file "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors" "$TEXT_ENCODER_DIR"
download_file "https://huggingface.co/ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy/resolve/main/Huihui-Qwen3-VL-4B-Instruct-abliterated-fp8_scaled.safetensors" "$TEXT_ENCODER_DIR"

log "\n== Checkpoints =="
download_file "https://civitai.red/api/download/models/3334245?fileId=3220803" "$CHECKPOINT_DIR"
download_file "https://civitai.red/api/download/models/1911770?fileId=1810454" "$CHECKPOINT_DIR"
download_file "https://civitai.red/api/download/models/3302448?fileId=3187496" "$CHECKPOINT_DIR"

log "\n== ControlNet =="
CONTROLNET=(
"https://huggingface.co/Sen-sou/Anima-LLLite-Regional-Controlnet/resolve/main/anima-lllite-regional-exp-v3.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/anima-lllite-inpainting-v2.safetensors"
"https://huggingface.co/kawaimasa/Anima_Kawai_Inpaint_ControlNet-LLLite/resolve/main/anima_kawai_inpaint_lllite.safetensors"
"https://huggingface.co/kataragi/controlnetXL_inpaint/resolve/main/Kataragi_inpaintXL-fp16.safetensors"
"https://huggingface.co/Eugeoter/noob-sdxl-controlnet-tile/resolve/main/noob-sdxl-controlnet-tile.safetensors"
"https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors"
"https://huggingface.co/xinsir/controlnet-tile-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors"
"https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/ip-adapter_xl.pth"
"https://huggingface.co/lllyasviel/sd_control_collection/resolve/main/kohya_controllllite_xl_openpose_anime_v2.safetensors"
"https://civitai.com/api/download/models/1390253?type=Model&format=SafeTensor"
"https://huggingface.co/windsingai/Illustrious-XL-openpose-test/resolve/main/openpose_s6000.safetensors"
"https://civitai.com/api/download/models/1284707?type=Model&format=SafeTensor&size=full&fp=fp32"
"https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/anima-lllite-scribble-1.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/anima-lllite-pose-1.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/anima-lllite-lineart-1.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/anima-lllite-exp-change-2-000007.safetensors"
"https://huggingface.co/TaihoC/Anima-ControlNet-VACE-Depth/resolve/main/anima-vace-depth.safetensors"
"https://huggingface.co/kohya-ss/Anima-LLLite/resolve/main/anima-lllite-any-test-like-v2.safetensors"
"https://civitai.red/api/download/models/3068951?fileId=2947687"
)
for url in "${CONTROLNET[@]}"; do
  download_file "$url" "$CONTROLNET_DIR"
done

log "\n== Upscale models (ESRGAN and others) =="
UPSCALERS=(
  "https://civitai.red/api/download/models/164821?fileId=2037845"
  "https://civitai.red/api/download/models/2674200?fileId=2560903"
  "https://civitai.red/api/download/models/729727?fileId=643878"
  "https://civitai.com/api/download/models/2634279?fileId=2522213"
  "https://huggingface.co/zelt54/RoNa/resolve/main/R-ESRGAN%204x%2B%20Anime6B.pth"
  "https://huggingface.co/Kim2091/AnimeSharp/resolve/main/4x-AnimeSharp.safetensors"
)
for url in "${UPSCALERS[@]}"; do
  download_file "$url" "$UPSCALE_DIR"
done

log "\n== Detection (formerly ADetailer) =="
DETECTION=(
  "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov9c.pt"
  "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov9c.pt"
  "https://civitai.red/api/download/models/465360?fileId=384289"
  "https://civitai.red/api/download/models/582139?fileId=497510"
  "https://civitai.red/api/download/models/2038997?fileId=1935916"
  "https://civitai.red/api/download/models/2350456?fileId=2240838"
  "https://civitai.red/api/download/models/2487429?fileId=2375769"
  "https://civitai.com/api/download/models/176512"
  "https://civitai.com/api/download/models/2509406?type=Model&format=PickleTensor"
  "https://civitai.com/api/download/models/1384450?type=Model&format=PickleTensor"
  "https://civitai.com/api/download/models/168820?type=Archive&format=Other"
  "https://civitai.com/api/download/models/1780243?type=Archive&format=Other"
  "https://civitai.com/api/download/models/235730?type=Archive&format=Other"
  "https://civitai.red/models/329458/"
)
for url in "${DETECTION[@]}"; do
  download_file "$url" "$DETECTION_DIR"
done

link_detection_models

log "\n== Embeddings =="
EMBEDDINGS=(
  "https://civitai.com/api/download/models/1833157?type=Model&format=SafeTensor"
  "https://civitai.com/api/download/models/2121199?type=Model&format=Other"
  "https://civitai.com/api/download/models/1601074?type=Model&format=SafeTensor"
)
for url in "${EMBEDDINGS[@]}"; do
  download_file "$url" "$EMBEDDINGS_DIR"
done

log "\n== LoRA =="
LORAS=(
"https://huggingface.co/ByteDance/Hyper-SD/resolve/main/Hyper-SDXL-8steps-CFG-lora.safetensors"
"https://civitai.red/api/download/models/3334160?fileId=3220708"
"https://civitai.red/api/download/models/3287274?fileId=3171666"
"https://civitai.red/api/download/models/2060939?fileId=1957648"
"https://civitai.red/api/download/models/2498581?fileId=2386638"
"https://civitai.red/api/download/models/2579082?fileId=2466259"
"https://civitai.red/api/download/models/2177579?fileId=2070697"
"https://civitai.red/api/download/models/2080703?fileId=1976653"
"https://civitai.red/api/download/models/2979435?fileId=2866837"
"https://civitai.red/api/download/models/2613253?fileId=2500626"
"https://civitai.red/api/download/models/1428568?fileId=1329866"
"https://civitai.red/api/download/models/2319817?fileId=2210102"
"https://civitai.red/api/download/models/2268553?fileId=2160667"
"https://civitai.red/api/download/models/2431103?fileId=2321652"
"https://civitai.red/api/download/models/2653394?fileId=2541219"
"https://civitai.red/api/download/models/2855073?fileId=2741162"
"https://civitai.red/api/download/models/2979642?fileId=2859181"
"https://civitai.red/api/download/models/3184772?fileId=3065310"
"https://civitai.red/api/download/models/2954332?fileId=2833644"
"https://civitai.red/api/download/models/3003728?fileId=2882998"
"https://civitai.red/api/download/models/3026577?fileId=2905342"
"https://civitai.red/api/download/models/2984285?fileId=2863772"
"https://civitai.red/api/download/models/3036905?fileId=2915794"
"https://civitai.red/api/download/models/2885588?fileId=2765348"
"https://civitai.red/api/download/models/3056341?fileId=2935783"
"https://civitai.red/api/download/models/2945421?fileId=2824598"
"https://civitai.red/api/download/models/2945328?fileId=2824501"
"https://civitai.red/api/download/models/3106632?fileId=2986565"
"https://civitai.red/api/download/models/3015331?fileId=2894293"
"https://civitai.red/api/download/models/3053514?fileId=2932217"
"https://civitai.red/api/download/models/2977577?fileId=2857197"
"https://civitai.red/api/download/models/3056172?fileId=2934819"
"https://civitai.red/api/download/models/3109578?fileId=2989582"
"https://civitai.red/api/download/models/3120243?fileId=3000551"
"https://civitai.red/api/download/models/3058132?fileId=2938272"
"https://civitai.red/api/download/models/3050990?fileId=2934234"
"https://civitai.red/api/download/models/3067262?fileId=2946387"
"https://civitai.red/api/download/models/1383619?fileId=1286305"
"https://civitai.red/api/download/models/2263536?fileId=2155728"
"https://civitai.red/api/download/models/1396589?fileId=1668198"
"https://civitai.red/api/download/models/1412821?fileId=1314670"
"https://civitai.red/api/download/models/3208083?fileId=3089650"
"https://civitai.red/api/download/models/1428822?fileId=1330047"
"https://civitai.red/api/download/models/3144577?fileId=3024967"
"https://civitai.red/api/download/models/2316207?fileId=2206693"
"https://civitai.red/api/download/models/2135582?fileId=2029416"
"https://civitai.red/api/download/models/2792113?fileId=2678153"
"https://civitai.red/api/download/models/2701722?fileId=2587763"
"https://civitai.red/api/download/models/3158613?fileId=3039307"
"https://civitai.red/api/download/models/1343048?fileId=1246504"
"https://civitai.red/api/download/models/1322451?fileId=1226385"
"https://civitai.red/api/download/models/1320383?fileId=1234461"
"https://civitai.red/api/download/models/1346688?fileId=1358739"
"https://civitai.red/api/download/models/1490218?fileId=1393195"
"https://civitai.red/api/download/models/2613253?fileId=2500626"
"https://civitai.red/api/download/models/1797933?fileId=1698559"
"https://civitai.red/api/download/models/2008821?fileId=1905833"
"https://civitai.red/api/download/models/1288389?fileId=1196942"
"https://civitai.red/api/download/models/2398424?fileId=2288734"
"https://civitai.red/api/download/models/2521543?fileId=2409648"
"https://civitai.red/api/download/models/2823582?fileId=2711473"
"https://civitai.red/api/download/models/1617513?fileId=1517494"
"https://civitai.red/api/download/models/1673922?fileId=1575069"
"https://civitai.red/api/download/models/1608573?fileId=1508571"
"https://civitai.red/api/download/models/1901550?fileId=1800733"
"https://civitai.red/api/download/models/1614265?fileId=1514201"
"https://civitai.red/api/download/models/2707028?fileId=2593076"
"https://civitai.red/api/download/models/1833284?fileId=1733491"
"https://civitai.red/api/download/models/1966746?fileId=1864265"
"https://civitai.red/api/download/models/1295382?fileId=1202683"
"https://civitai.red/api/download/models/2698194?fileId=2584212"
"https://civitai.red/api/download/models/2787129?fileId=2673260"
"https://civitai.red/api/download/models/2823902?fileId=2709767"
"https://civitai.red/api/download/models/2017718?fileId=1914724"
"https://civitai.red/api/download/models/2067668?fileId=1964081"
"https://civitai.red/api/download/models/2825512?fileId=2711379"
"https://civitai.red/api/download/models/2987156?fileId=2866665"
"https://civitai.red/api/download/models/3275498?fileId=3159521"
"https://civitai.red/api/download/models/3243016?fileId=3125648"
"https://civitai.red/api/download/models/3230323?fileId=3112648"
"https://civitai.red/api/download/models/2454381?fileId=2344728"
"https://civitai.red/api/download/models/3053762?fileId=2932460"
"https://civitai.red/api/download/models/3057337?fileId=2936001"
"https://civitai.red/api/download/models/3059807?fileId=2938436"
"https://civitai.red/api/download/models/3036905?fileId=2915794"
"https://civitai.red/api/download/models/3076192?fileId=2955299"
"https://civitai.red/api/download/models/3102800?fileId=2982619"
"https://civitai.red/api/download/models/3313647?fileId=3198914"
"https://civitai.red/api/download/models/3257446?fileId=3142102"
"https://civitai.red/api/download/models/3156823?fileId=3037654"
"https://civitai.red/api/download/models/3026703?fileId=2905468"
"https://civitai.red/api/download/models/2954049?fileId=2833331"
"https://civitai.red/api/download/models/3057337?fileId=2936001"
"https://civitai.red/api/download/models/2991448?fileId=2871059"
"https://civitai.red/api/download/models/3343955?fileId=3230853"
"https://civitai.red/api/download/models/3345205?fileId=3232120"
"https://civitai.red/api/download/models/3023777?fileId=2902507"
"https://civitai.red/api/download/models/3023777?fileId=2902507"
"https://civitai.red/api/download/models/3226785?fileId=3108951"
"https://civitai.red/api/download/models/3213971?fileId=3095697"
#for luz comission
"https://civitai.red/api/download/models/3309555?fileId=3194770"
"https://civitai.red/api/download/models/3318624?fileId=3204220"
"https://civitai.red/api/download/models/2872747?fileId=2754608"
"https://civitai.red/api/download/models/2453902?fileId=2344424"
"https://civitai.red/api/download/models/1198783?fileId=1104320"
"https://civitai.red/api/download/models/1984258?fileId=1881768"
"https://civitai.red/api/download/models/1455258?fileId=1356446"
"https://civitai.red/api/download/models/2133303?fileId=2027143"
"https://civitai.red/api/download/models/2088952?fileId=1984935"
"https://civitai.red/api/download/models/3149003?fileId=3029571"
"https://civitai.red/api/download/models/2958545?fileId=2837916"
"https://civitai.red/api/download/models/1548943?fileId=1448729"
"https://civitai.red/api/download/models/2134905?fileId=2028861"
"https://civitai.red/api/download/models/2134905?fileId=2028861"
"https://civitai.red/api/download/models/2254570?fileId=2146980"
"https://civitai.red/api/download/models/1874495?fileId=1774610"
"https://civitai.red/api/download/models/1515726?fileId=1416867"
"https://civitai.red/api/download/models/1371734?fileId=1274673"
"https://civitai.red/api/download/models/2971755?fileId=2851319"
"https://civitai.red/api/download/models/2970498?fileId=2850000"
"https://civitai.red/api/download/models/1773554?fileId=1674348"
"https://civitai.red/api/download/models/2821337?fileId=2707288"
"https://civitai.red/api/download/models/1521048?fileId=1422501"
"https://civitai.red/api/download/models/2702931?fileId=2589001"
"https://civitai.red/api/download/models/3028096?fileId=2906863"
"https://civitai.red/api/download/models/3195309?fileId=3076457"
"https://civitai.red/api/download/models/2397112?fileId=2288068"
"https://civitai.red/api/download/models/2179252?fileId=2072378"
"https://civitai.red/api/download/models/1828843?fileId=1729167"
"https://civitai.red/api/download/models/2840627?fileId=2726838"
"https://civitai.red/api/download/models/1489123?fileId=1389547"
"https://civitai.red/api/download/models/1712603?fileId=1613871"
"https://civitai.red/api/download/models/1254934?fileId=1160129"
"https://civitai.red/api/download/models/2346226?fileId=2236567"
"https://civitai.red/api/download/models/2869875?fileId=2752286"
"https://civitai.red/api/download/models/1835873?fileId=1735976"
"https://civitai.red/api/download/models/3256593?fileId=3139760"
"https://civitai.red/api/download/models/3028117?fileId=2906890"
)
for url in "${LORAS[@]}"; do
  download_file "$url" "$LORA_DIR"
done

log "\n== Latent upscale models =="
# No links were provided for this folder yet. Add URLs here:
LATENT_UPSCALERS=(
)
for url in ${LATENT_UPSCALERS[@]+"${LATENT_UPSCALERS[@]}"}; do
  download_file "$url" "$LATENT_UPSCALE_DIR"
done

log "\n== VAE approx (TAESD previews) =="
# Official TAESD files from github.com/madebyollin/taesd.
# taesd_*   = SD1.x / SD2.x     taesdxl_* = SDXL
VAE_APPROX=(
  "https://github.com/madebyollin/taesd/raw/main/taesd_decoder.pth"
  "https://github.com/madebyollin/taesd/raw/main/taesd_encoder.pth"
  "https://github.com/madebyollin/taesd/raw/main/taesdxl_decoder.pth"
  "https://github.com/madebyollin/taesd/raw/main/taesdxl_encoder.pth"
)
for url in "${VAE_APPROX[@]}"; do
  download_file "$url" "$VAE_APPROX_DIR"
done

# ==================== SUMMARY ====================
log "\n\n================ SUMMARY ================"
log "Succeeded: ${#SUCCEEDED[@]}"
log "Skipped (already existed): ${#SKIPPED[@]}"
log "Failed: ${#FAILED[@]}"

if [ "${#FAILED[@]}" -gt 0 ]; then
  log "\n-- Failed items (fix these links or rerun the script) --"
  for item in "${FAILED[@]}"; do
    log "  - $item"
  done
fi

log "\nFull log saved to: $LOG_FILE"

rm -rf "$TMP_DL_DIR"
rm -rf "$META_TMP_DIR"
