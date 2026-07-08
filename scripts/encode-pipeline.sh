#!/usr/bin/env bash
# Drive -> encode -> R2 pipeline (runs on GitHub Actions ubuntu runner).
# Google Drive is the read-only master. Anything in Drive that is not yet
# in R2 under $PREFIX/<mirrored-path>/ gets downloaded, encoded to HLS,
# thumbnailed, and uploaded. Processes up to $MAX_FILES per run.
set -euo pipefail

BUCKET="${BUCKET:-fast-poc}"
PREFIX="${PREFIX:-playout}"
PUBLIC_BASE="${PUBLIC_BASE:-https://myskn.media}"
MAX_FILES="${MAX_FILES:-10}"
WORK="$(mktemp -d)"

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

slugpath() {  # sanitize every path segment, drop the extension on the last
  local rel="$1" out="" IFS='/'
  read -ra parts <<< "$rel"
  local last=$((${#parts[@]}-1))
  for i in "${!parts[@]}"; do
    local p="${parts[$i]}"
    [ "$i" -eq "$last" ] && p="${p%.*}"
    out="$out$(slug "$p")/"
  done
  echo "${out%/}"
}

echo "=== Listing Drive library..."
rclone lsf gdrive: -R --files-only \
  --include "*.mp4" --include "*.MP4" \
  --include "*.mov" --include "*.MOV" \
  --include "*.mkv" --include "*.MKV" > "$WORK/all.txt"
total=$(wc -l < "$WORK/all.txt")
echo "    $total video file(s) in Drive"

echo "=== Listing already-encoded in R2..."
rclone lsf "r2:$BUCKET/$PREFIX" -R --files-only --include "index.m3u8" \
  | sed 's|/index.m3u8$||' > "$WORK/done.txt" || true

done_count=0
new_urls=()
while IFS= read -r rel; do
  [ "$done_count" -ge "$MAX_FILES" ] && { echo "=== MAX_FILES reached; remaining files next run."; break; }
  sp="$(slugpath "$rel")"
  if grep -qxF "$sp" "$WORK/done.txt"; then continue; fi

  echo ">>> [$((done_count+1))/$MAX_FILES] $rel  ->  $PREFIX/$sp/"
  rm -rf "$WORK/job"; mkdir -p "$WORK/job/out/$sp"
  rclone copyto "gdrive:$rel" "$WORK/job/src" --retries 3

  dest="$WORK/job/out/$sp"
  ffmpeg -nostdin -y -loglevel warning -i "$WORK/job/src" \
    -c:v libx264 -preset veryfast -crf 21 \
    -profile:v main -level 4.0 -pix_fmt yuv420p \
    -vf "scale=-2:720" -r 30 -g 60 -keyint_min 60 -sc_threshold 0 \
    -c:a aac -b:a 128k -ac 2 \
    -f hls -hls_time 6 -hls_playlist_type vod \
    -hls_segment_filename "$dest/seg_%04d.ts" \
    "$dest/index.m3u8"

  mid=$(ls "$dest"/seg_*.ts | awk '{a[NR]=$0} END{print a[int((NR+1)/2)]}')
  ffmpeg -nostdin -y -loglevel error -i "$mid" \
    -vf "thumbnail=150,scale=640:-2" -frames:v 1 -q:v 3 "$dest/thumb.jpg" 2>/dev/null || true
  [ -s "$dest/thumb.jpg" ] || ffmpeg -nostdin -y -loglevel error -i "$dest/seg_0000.ts" \
    -frames:v 1 -vf "scale=640:-2" -q:v 3 "$dest/thumb.jpg"

  rclone copy "$WORK/job/out" "r2:$BUCKET/$PREFIX" --include "*.ts" \
    --header-upload "Content-Type: video/mp2t" -q
  rclone copy "$WORK/job/out" "r2:$BUCKET/$PREFIX" --include "*.m3u8" \
    --header-upload "Content-Type: application/vnd.apple.mpegurl" -q
  rclone copy "$WORK/job/out" "r2:$BUCKET/$PREFIX" --include "*.jpg" \
    --header-upload "Content-Type: image/jpeg" -q

  new_urls+=("$PUBLIC_BASE/$PREFIX/$sp/index.m3u8")
  done_count=$((done_count+1))
  rm -rf "$WORK/job"
done < "$WORK/all.txt"

echo ""
echo "=== Run complete: $done_count new video(s) encoded."
if [ "$done_count" -gt 0 ]; then
  echo "=== New playlist URLs (add to Viloud; thumb.jpg alongside each):"
  printf '%s\n' "${new_urls[@]}"
fi
