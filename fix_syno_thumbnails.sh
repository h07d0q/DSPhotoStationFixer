#!/bin/sh
# ==============================================================================
# Synology DSM Auto Thumbnail Generator & Fixer for Photos & Videos
# ==============================================================================
# GitHub Repository: https://github.com/h07d0q/DSPhotoStationFixer
#
# Repairs missing thumbnails and previews (@eaDir) in:
# - Synology Photos (DSM 7 / DSM 7.2.2+)
# - Synology Photo Station (DSM 6)
# - DSM File Station & DS File
#
# Resolves:
# - Missing thumbnails after DSM 7.2.2 update (server-side codec removal)
# - Stalled indexing (cleans up blocking .fail marker files)
# - Synology-specific FFmpeg limitation without JPEG muxer (forces -f mjpeg)
# - Automatic orientation correction (EXIF / displaymatrix 90/270 degrees)
#
# Usage:
#   /volume1/photo/fix_syno_thumbnails.sh [/path/to/photo/folder]
# ==============================================================================

# Target directory: default to /volume1/photo or use the 1st parameter
TARGET_DIR="${1:-/volume1/photo}"

# Prevent concurrent overlapping runs using a lockfile
LOCKFILE="/tmp/syno_thumb_fixer.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "[$(date '+%Y-%m-%d %H:%M:%S')] Another instance is already running. Exiting."; exit 0; }

echo "================================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting thumbnail check in: $TARGET_DIR"
echo "================================================================="

# 1. Locate the best working FFmpeg binary
FFMPEG=""
for p in \
  "/var/packages/ffmpeg7/target/bin/ffmpeg" \
  "/var/packages/ffmpeg6/target/bin/ffmpeg" \
  "/var/packages/ffmpeg/target/bin/ffmpeg" \
  "/var/packages/CodecPack/target/bin/ffmpeg33" \
  "/var/packages/CodecPack/target/bin/ffmpeg41" \
  "/var/packages/CodecPack/target/bin/ffmpeg27" \
  "/usr/bin/ffmpeg"; do
  if [ -x "$p" ]; then
    FFMPEG="$p"
    break
  fi
done

if [ -z "$FFMPEG" ]; then
  echo "[ERROR] No working FFmpeg found! Please install 'FFmpeg 7' (SynoCommunity) or the Synology CodecPack."
  exit 1
fi
echo "[INFO] Using FFmpeg: $FFMPEG"

# 2. Check for ImageMagick convert (optional fallback for RAW/HEIC)
CONVERT=""
for p in "/var/packages/ImageMagick/target/bin/convert" "/usr/bin/convert" "/bin/convert"; do
  if [ -x "$p" ]; then
    CONVERT="$p"
    break
  fi
done

# ==============================================================================
# PART 1: CHECK & REPAIR VIDEOS (.mp4, .mov, .m4v, .mkv)
# ==============================================================================
echo "[INFO] Scanning videos..."

find "$TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.mkv" \) ! -path "*/@eaDir/*" ! -path "*/#recycle/*" | while read -r filepath; do
  dir="${filepath%/*}"
  name="${filepath##*/}"
  eadir="$dir/@eaDir/$name"
  thumb_xl="$eadir/SYNOPHOTO_THUMB_XL.jpg"

  # Check if XL thumbnail is missing or a .fail marker exists
  if [ ! -f "$thumb_xl" ] || [ -f "$eadir/SYNOPHOTO_THUMB_M.fail" ]; then
    mkdir -p "$eadir"
    rm -f "$eadir"/*.fail

    # Extract screenshot at second 3 (fallback to second 0 if clip is too short)
    "$FFMPEG" -hide_banner -loglevel error -y -ss 3 -i "$filepath" -vframes 1 -vf "scale=1280:1280:force_original_aspect_ratio=decrease" -q:v 2 -f mjpeg "$thumb_xl" 2>/dev/null
    [ ! -s "$thumb_xl" ] && "$FFMPEG" -hide_banner -loglevel error -y -ss 0 -i "$filepath" -vframes 1 -vf "scale=1280:1280:force_original_aspect_ratio=decrease" -q:v 2 -f mjpeg "$thumb_xl" 2>/dev/null

    if [ -s "$thumb_xl" ]; then
      # Derive all thumbnail resolutions for Synology Photos & Photo Station
      "$FFMPEG" -hide_banner -loglevel error -y -i "$thumb_xl" -vf "scale=640:640:force_original_aspect_ratio=decrease" -q:v 2 -f mjpeg "$eadir/SYNOVIDEO_VIDEO_SCREENSHOT.jpg" 2>/dev/null
      "$FFMPEG" -hide_banner -loglevel error -y -i "$thumb_xl" -vf "scale=320:320:force_original_aspect_ratio=decrease" -q:v 3 -f mjpeg "$eadir/SYNOPHOTO_THUMB_M.jpg" 2>/dev/null
      "$FFMPEG" -hide_banner -loglevel error -y -i "$thumb_xl" -vf "scale=120:120:force_original_aspect_ratio=decrease" -q:v 4 -f mjpeg "$eadir/SYNOPHOTO_THUMB_S.jpg" 2>/dev/null

      # Compatibility for DLNA, File Station & Photo Station
      cp -f "$eadir/SYNOPHOTO_THUMB_M.jpg" "$eadir/SYNOPHOTO_THUMB_B.jpg" 2>/dev/null
      cp -f "$eadir/SYNOPHOTO_THUMB_M.jpg" "$eadir/SYNOFILE_THUMB_M.jpg" 2>/dev/null
      cp -f "$eadir/SYNOPHOTO_THUMB_S.jpg" "$eadir/SYNOFILE_THUMB_S.jpg" 2>/dev/null

      echo "[$(date '+%H:%M:%S')] [VID-REPAIRED] $filepath"
    fi
  fi
done

# ==============================================================================
# PART 2: CHECK & REPAIR PHOTOS (.jpg, .jpeg, .png, .heic)
# ==============================================================================
echo "[INFO] Scanning photos..."

find "$TARGET_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" \) ! -path "*/@eaDir/*" ! -path "*/#recycle/*" | while read -r filepath; do
  dir="${filepath%/*}"
  name="${filepath##*/}"
  eadir="$dir/@eaDir/$name"
  thumb_xl="$eadir/SYNOPHOTO_THUMB_XL.jpg"

  if [ ! -f "$thumb_xl" ] || [ -f "$eadir/SYNOPHOTO_THUMB_M.fail" ]; then
    mkdir -p "$eadir"
    rm -f "$eadir"/*.fail

    if [ -n "$CONVERT" ]; then
      "$CONVERT" "$filepath[0]" -auto-orient -thumbnail "1280x1280>" -quality 85 "$thumb_xl" 2>/dev/null
    else
      "$FFMPEG" -hide_banner -loglevel error -y -i "$filepath" -vf "scale=1280:1280:force_original_aspect_ratio=decrease" -q:v 2 -f mjpeg "$thumb_xl" 2>/dev/null
    fi

    if [ -s "$thumb_xl" ]; then
      "$FFMPEG" -hide_banner -loglevel error -y -i "$thumb_xl" -vf "scale=320:320:force_original_aspect_ratio=decrease" -q:v 3 -f mjpeg "$eadir/SYNOPHOTO_THUMB_M.jpg" 2>/dev/null
      "$FFMPEG" -hide_banner -loglevel error -y -i "$thumb_xl" -vf "scale=120:120:force_original_aspect_ratio=decrease" -q:v 4 -f mjpeg "$eadir/SYNOPHOTO_THUMB_S.jpg" 2>/dev/null

      cp -f "$eadir/SYNOPHOTO_THUMB_M.jpg" "$eadir/SYNOPHOTO_THUMB_B.jpg" 2>/dev/null
      cp -f "$eadir/SYNOPHOTO_THUMB_M.jpg" "$eadir/SYNOFILE_THUMB_M.jpg" 2>/dev/null
      cp -f "$eadir/SYNOPHOTO_THUMB_S.jpg" "$eadir/SYNOFILE_THUMB_S.jpg" 2>/dev/null

      echo "[$(date '+%H:%M:%S')] [IMG-REPAIRED] $filepath"
    fi
  fi
done

echo "================================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Thumbnail repair process completed successfully!"
echo "================================================================="
