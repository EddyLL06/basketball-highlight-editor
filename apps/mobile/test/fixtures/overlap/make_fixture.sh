#!/bin/sh
set -eu
# Usage: make_fixture.sh OUTPUT_DIR [EXPORTED_MP4]
# No Android device or emulator is accessed by this script.
out_dir=${1:?pass an output directory}
mkdir -p "$out_dir"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -t 9 -c:v libx264 -pix_fmt yuv420p -g 90 -keyint_min 90 -sc_threshold 0 \
  -c:a aac -b:a 96k -shortest "$out_dir/source-long-gop.mp4"
ffprobe -v error -select_streams v:0 -show_entries frame=key_frame,best_effort_timestamp_time \
  -of csv=p=0 "$out_dir/source-long-gop.mp4" > "$out_dir/source-video-pts.csv"
ffmpeg -hide_banner -loglevel error -y -i "$out_dir/source-long-gop.mp4" -map 0:v:0 -f framemd5 "$out_dir/source-video.framemd5"
if [ "$#" -ge 2 ]; then
  result=$2
  ffprobe -v error -show_streams -show_format -of json "$result" > "$out_dir/export-probe.json"
  ffprobe -v error -select_streams v:0 -show_entries frame=key_frame,best_effort_timestamp_time \
    -of csv=p=0 "$result" > "$out_dir/export-video-pts.csv"
  ffmpeg -hide_banner -loglevel error -y -i "$result" -map 0:v:0 -f framemd5 "$out_dir/export-video.framemd5"
fi
printf '%s\n' 'Source created. Suggested reviewed ranges: 1–4 s, 3–5 s (overlap); 6–7 s (separate).'
printf '%s\n' 'In Android, export merged; rerun with the exported MP4 to save stream, PTS and decoded-frame hashes.'
printf '%s\n' 'Previous-keyframe seeking may include frames before a requested start and may repeat frames across separate ranges.'
