#!/usr/bin/env bash
#
# whisper-cache-transcribe.sh
#
# Description:
#   Download source audio with yt-dlp, reuse cached audio when available,
#   and generate transcripts with Whisper.
#
# Requirements:
#   - yt-dlp
#   - ffmpeg / ffprobe
#   - whisper (CLI available on PATH)
#
# Notes:
#   - Cache is stored under $XDG_CACHE_HOME or ~/.cache
#   - Cache entries are cleaned automatically based on TTL
#   - Intended for repeatable, idempotent execution
#

# ============================================================
# Global Configuration
# ============================================================

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/whisper-media"
CACHE_TTL_DAYS="${CACHE_TTL_DAYS:-7}"
COOKIE_BROWSER="brave"
DEFAULT_OUTPUT_DIR="."
WHISPER_MODEL="turbo"
WHISPER_LANGUAGE="en"
WHISPER_OUTPUT_FORMAT="srt"

DRY_RUN=0
SOURCE_URL=""
OUTPUT_FILE=""
OUTPUT_DIR=""

# ============================================================
# Logging / Utilities
# ============================================================

log() {
  local message="$1"
  printf '%s\n' "$message"
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi

  "$@"
  local status=$?

  if [[ $status -ne 0 ]]; then
    log "Command failed (exit $status): $*"
    return $status
  fi
}

# ============================================================
# Usage / Help
# ============================================================

usage() {
  cat <<'EOF'
Usage:
  whisper-cache-transcribe.sh [options] <source-url>

Options:
  -o, --output FILE   Exact transcript output filepath
  -p, --path DIR      Output directory for transcript file
      --cache-dir DIR Override cache directory
      --ttl-days DAYS Cache TTL in days
      --dry-run       Print commands without executing them
  -h, --help          Show this help
EOF
}

# ============================================================
# Argument Parsing
# ============================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -o | --output)
      [[ $# -ge 2 ]] || {
        log "Error: $1 requires a value"
        exit 1
      }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -p | --path)
      [[ $# -ge 2 ]] || {
        log "Error: $1 requires a value"
        exit 1
      }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || {
        log "Error: --cache-dir requires a value"
        exit 1
      }
      CACHE_DIR="$2"
      shift 2
      ;;
    --ttl-days)
      [[ $# -ge 2 ]] || {
        log "Error: --ttl-days requires a value"
        exit 1
      }
      CACHE_TTL_DAYS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      log "Error: unknown option: $1"
      usage
      exit 1
      ;;
    *)
      [[ -z "$SOURCE_URL" ]] || {
        log "Error: only one source URL allowed"
        exit 1
      }
      SOURCE_URL="$1"
      shift
      ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    log "Error: unexpected extra arguments: $*"
    usage
    exit 1
  fi

  [[ -n "$SOURCE_URL" ]] || {
    log "Error: source URL required"
    exit 1
  }

  [[ -n "$OUTPUT_FILE" && -n "$OUTPUT_DIR" ]] && {
    log "Error: use either --output or --path, not both"
    exit 1
  }

  [[ "$CACHE_TTL_DAYS" =~ ^[0-9]+$ ]] || {
    log "Error: --ttl-days must be a non-negative integer"
    exit 1
  }
}

# ============================================================
# Cache Helpers
# ============================================================

cleanup_cache() {
  local cache_dir="$1"
  local ttl_days="$2"

  [[ -d "$cache_dir" ]] || return 0

  log "Cleaning cache older than ${ttl_days} days"
  run_cmd find "$cache_dir" -type f -mtime +"$ttl_days" -delete
}

make_cache_key() {
  local source_url="$1"
  printf '%s' "$source_url" | shasum -a 256 | awk '{print $1}'
}

is_cache_valid() {
  local file="$1"
  local ttl_days="$2"

  [[ -f "$file" ]] || return 1
  [[ -s "$file" ]] || return 1
  find "$file" -mtime "-$ttl_days" | grep -q . || return 1
  ffprobe -v error "$file" >/dev/null 2>&1 || return 1

  return 0
}

touch_cache_entry() {
  local file="$1"
  run_cmd touch "$file"
}

get_cached_audio_path() {
  local source_url="$1"
  local cache_key

  cache_key="$(make_cache_key "$source_url")" || return 1
  printf '%s/%s.mp3\n' "$CACHE_DIR" "$cache_key"
}

ensure_cache_dir() {
  run_cmd mkdir -p "$CACHE_DIR"
}

ensure_cached_audio() {
  local source_url="$1"
  local cached_audio="$2"

  if is_cache_valid "$cached_audio" "$CACHE_TTL_DAYS"; then
    log "Transcript missing, resuming from cached audio: $cached_audio"
    touch_cache_entry "$cached_audio" || return 1
    return 0
  fi

  log "Transcript missing and no valid cached audio found, downloading audio"
  download_audio "$source_url" "$cached_audio"
}

# ============================================================
# Source Metadata Helpers
# ============================================================

get_source_token() {
  local source_url="$1"
  local source_id

  if [[ "$DRY_RUN" -eq 1 ]]; then
    make_cache_key "$source_url"
    return 0
  fi

  source_id="$(yt-dlp --get-id "$source_url" 2>/dev/null)"

  if [[ -z "$source_id" ]]; then
    source_id="$(yt-dlp --cookies-from-browser "$COOKIE_BROWSER" --get-id "$source_url" 2>/dev/null)"
  fi

  if [[ -n "$source_id" ]]; then
    printf '%s\n' "$source_id"
    return 0
  fi

  make_cache_key "$source_url"
}

find_existing_transcript_by_token() {
  local output_dir="$1"
  local source_token="$2"
  local format="$3"
  local file
  local base_name

  [[ -d "$output_dir" ]] || return 1

  while IFS= read -r file; do
    base_name="$(basename "$file")"

    if [[ "$base_name" == *"[$source_token].$format" ]] && [[ -s "$file" ]]; then
      printf '%s\n' "$file"
      return 0
    fi
  done < <(find "$output_dir" -maxdepth 1 -type f -name "*.${format}")

  return 1
}

transcript_exists_for_source() {
  local transcript_file="$1"
  local source_url="$2"
  local transcript_dir
  local source_token
  local existing_transcript

  if [[ -f "$transcript_file" && -s "$transcript_file" ]]; then
    log "Transcript already exists, skipping: $transcript_file"
    return 0
  fi

  transcript_dir="$(dirname "$transcript_file")"
  source_token="$(get_source_token "$source_url")" || return 1

  existing_transcript="$(find_existing_transcript_by_token "$transcript_dir" "$source_token" "$WHISPER_OUTPUT_FORMAT")" || true

  if [[ -n "$existing_transcript" ]]; then
    log "Transcript already exists for source token ${source_token}, skipping: $existing_transcript"
    return 0
  fi

  return 1
}

# ============================================================
# Download Logic
# ============================================================

download_audio() {
  local source_url="$1"
  local output_file="$2"
  local output_dir
  local output_stem
  local output_template
  local base_cmd
  local fallback_cmd

  output_dir="$(dirname "$output_file")"
  output_stem="$(basename "$output_file" .mp3)"
  output_template="${output_dir}/${output_stem}.%(ext)s"

  log "Downloading audio"

  if ! run_cmd mkdir -p "$output_dir"; then
    return 1
  fi

  base_cmd=(
    yt-dlp
    -f "ba/b"
    -x
    --audio-format mp3
    -o "$output_template"
    "$source_url"
  )

  fallback_cmd=(
    yt-dlp
    --cookies-from-browser firefox
    -f "ba/b"
    -x
    --audio-format mp3
    -o "$output_template"
    "$source_url"
  )

  if ! run_cmd "${base_cmd[@]}"; then
    log "Retrying with cookies..."
    if ! run_cmd "${fallback_cmd[@]}"; then
      log "Error: download failed"
      return 1
    fi
  fi

  return 0
}

# ============================================================
# Whisper Logic
# ============================================================

create_transcript() {
  local audio_file="$1"
  local transcript_file="$2"
  local transcript_dir
  local temp_dir
  local temp_transcript_file

  transcript_dir="$(dirname "$transcript_file")"

  run_cmd mkdir -p "$transcript_dir" || return 1

  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_cmd whisper \
      "$audio_file" \
      --language "$WHISPER_LANGUAGE" \
      --model "$WHISPER_MODEL" \
      --output_format "$WHISPER_OUTPUT_FORMAT" \
      --output_dir "$transcript_dir"
    return 0
  fi

  temp_dir="$(mktemp -d -t whisper-output)" || return 1

  if ! whisper \
    "$audio_file" \
    --language "$WHISPER_LANGUAGE" \
    --model "$WHISPER_MODEL" \
    --output_format "$WHISPER_OUTPUT_FORMAT" \
    --output_dir "$temp_dir"; then
    rm -rf "$temp_dir"
    return 1
  fi

  temp_transcript_file="${temp_dir}/$(basename "$audio_file" .mp3).${WHISPER_OUTPUT_FORMAT}"

  [[ -f "$temp_transcript_file" ]] || {
    log "Error: expected transcript file was not created: $temp_transcript_file"
    rm -rf "$temp_dir"
    return 1
  }

  if ! mv "$temp_transcript_file" "$transcript_file"; then
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
  return 0
}

# ============================================================
# Output Resolution
# ============================================================

get_yt_dlp_name() {
  local source_url="$1"
  local filename

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 1
  fi

  filename="$(
    yt-dlp \
      --get-filename \
      -o '%(extractor)s - %(title)s [%(id)s].%(ext)s' \
      "$source_url" 2>/dev/null
  )"

  if [[ -z "$filename" ]]; then
    filename="$(
      yt-dlp \
        --cookies-from-browser firefox \
        --get-filename \
        -o '%(extractor)s - %(title)s [%(id)s].%(ext)s' \
        "$source_url" 2>/dev/null
    )"
  fi

  [[ -n "$filename" ]] || return 1
  printf '%s\n' "${filename%.*}"
}

resolve_output() {
  local source_url="$1"
  local output_dir
  local name
  local source_token

  if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s\n' "$OUTPUT_FILE"
    return 0
  fi

  output_dir="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"

  if name="$(get_yt_dlp_name "$source_url")"; then
    printf '%s/%s.%s\n' "$output_dir" "$name" "$WHISPER_OUTPUT_FORMAT"
    return 0
  fi

  source_token="$(get_source_token "$source_url")" || return 1
  printf '%s/%s [%s].%s\n' "$output_dir" "source - transcript" "$source_token" "$WHISPER_OUTPUT_FORMAT"
}

# ============================================================
# Main
# ============================================================

main() {
  local transcript_file
  local cached_audio

  parse_args "$@"

  transcript_file="$(resolve_output "$SOURCE_URL")" || exit 1

  if transcript_exists_for_source "$transcript_file" "$SOURCE_URL"; then
    exit 0
  fi

  ensure_cache_dir || exit 1
  cleanup_cache "$CACHE_DIR" "$CACHE_TTL_DAYS"

  cached_audio="$(get_cached_audio_path "$SOURCE_URL")" || exit 1

  ensure_cached_audio "$SOURCE_URL" "$cached_audio" || {
    log "Error: failed to prepare cached audio"
    exit 1
  }

  create_transcript "$cached_audio" "$transcript_file" || {
    log "Error: failed to create transcript"
    exit 1
  }

  log "Done: $transcript_file"
}

# ============================================================
# Entrypoint
# ============================================================

main "$@"
