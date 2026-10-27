#!/bin/sh
set -eu
# Usage: make_fixture.sh NEW_OUTPUT_DIR [EXPORTED_MP4]
# First run: choose a new dedicated directory. Second run: reuse it and pass
# the Android-exported MP4; the original source video is never regenerated.
# This script does not access an Android device or emulator.
out_dir=${1:?pass a dedicated output directory}
source_file="$out_dir/source-long-gop.mp4"
if [ "$#" -eq 1 ]; then
  if [ -e "$out_dir" ]; then
    printf '%s\n' 'Choose a new directory; refusing to overwrite existing files.' >&2
    exit 1
  fi
  mkdir -p "$out_dir"
  ffmpeg -hide_banner -loglevel error -n \
    -f lavfi -i 'testsrc2=size=320x180:rate=30' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
    -t 9 -c:v libx264 -pix_fmt yuv420p -g 90 -keyint_min 90 -sc_threshold 0 \
    -c:a aac -b:a 96k -shortest "$source_file"
  ffprobe -v error -select_streams v:0 -show_entries frame=key_frame,best_effort_timestamp_time \
    -of csv=p=0 "$source_file" > "$out_dir/source-video-pts.csv"
  ffmpeg -hide_banner -loglevel error -n -i "$source_file" -map 0:v:0 -f framemd5 "$out_dir/source-video.framemd5"
else
  result=$2
  if [ ! -f "$source_file" ] || [ -e "$out_dir/export-probe.json" ] ||
     [ -e "$out_dir/export-video-pts.csv" ] || [ -e "$out_dir/export-video.framemd5" ]; then
    printf '%s\n' 'Use the original fixture directory with no previous export reports.' >&2
    exit 1
  fi
  ffprobe -v error -show_streams -show_format -of json "$result" > "$out_dir/export-probe.json"
  ffprobe -v error -select_streams v:0 -show_entries frame=key_frame,best_effort_timestamp_time \
    -of csv=p=0 "$result" > "$out_dir/export-video-pts.csv"
  ffmpeg -hide_banner -loglevel error -n -i "$result" -map 0:v:0 -f framemd5 "$out_dir/export-video.framemd5"
fi
printf '%s\n' 'Suggested reviewed ranges: 1–4 s, 3–5 s (overlap); 6–7 s (separate).'
printf '%s\n' 'In Android, export merged; rerun with the exported MP4 to save stream, PTS and decoded-frame hashes.'
printf '%s\n' 'Previous-keyframe seeking may include earlier frames and may repeat frames across separate ranges.'
