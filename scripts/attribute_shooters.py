#!/usr/bin/env python3
"""Attribute existing BHE scoring candidates to temporary player tracks."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.attribution_video import (
    AnalysisConfig,
    ShooterAttributionPipeline,
    load_ball_records,
)
from basketball_highlight.inference import SUPPORTED_DEVICES
from basketball_highlight.player_detection import (
    LocalYoloDetector,
    PlayerGuidedBallDetector,
)
from basketball_highlight.shooter_attribution import load_scoring_events
from basketball_highlight.shooter_observations import (
    ObservationArchive,
    collect_observations,
    model_fingerprint,
    write_artifact,
)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument(
        "--player-model",
        type=Path,
        help="Existing local COCO person weights; no automatic downloads",
    )
    parser.add_argument(
        "--ball-model", type=Path, default=Path("models/bball_model.pt")
    )
    parser.add_argument(
        "--ball-records",
        type=Path,
        help="Optional BHE scan log; missing samples use ball inference",
    )
    parser.add_argument(
        "--records-scale",
        type=float,
        help="Source pixels per cached input pixel; required for a different video/proxy",
    )
    parser.add_argument("--records-time-offset", type=float, default=0.0)
    parser.add_argument(
        "--cached-ball-only",
        action="store_true",
        help="Use only supplied ball records; gaps yield unknown",
    )
    parser.add_argument("--device", choices=SUPPORTED_DEVICES, default="auto")
    parser.add_argument("--player-conf", type=float, default=0.15)
    parser.add_argument("--ball-conf", type=float, default=0.1)
    parser.add_argument("--player-imgsz", type=int, default=640)
    parser.add_argument("--ball-imgsz", type=int, default=640)
    parser.add_argument("--ball-tiles", type=int, choices=(1, 2, 3), default=1)
    parser.add_argument(
        "--ball-search", choices=("full", "tiles", "players"), default="players"
    )
    parser.add_argument(
        "--algorithm",
        choices=("baseline", "joint", "joint-v3", "joint-v4"),
        default="joint",
    )
    parser.add_argument("--player-max-gap", type=float, default=0.8)
    parser.add_argument(
        "--no-appearance",
        action="store_true",
        help="Geometry-only ablation within the chosen tracker",
    )
    parser.add_argument(
        "--observations-input",
        type=Path,
        help="Replay verified local observations without loading models",
    )
    parser.add_argument(
        "--observations-output",
        type=Path,
        help="Record the full expansion windows for deterministic replay",
    )
    parser.add_argument("--collect-only", action="store_true")
    parser.add_argument("--sample-fps", type=float, default=15.0)
    parser.add_argument("--window-before", type=float, default=4)
    parser.add_argument("--window-after", type=float, default=0.5)
    parser.add_argument("--max-window-before", type=float, default=8)
    parser.add_argument("--min-score", type=float, default=0.78)
    parser.add_argument("--min-margin", type=float, default=0.12)
    parser.add_argument("--ball-max-gap", type=float, default=0.35)
    parser.add_argument("--min-track-reliability", type=float, default=0.55)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(args):
    config = AnalysisConfig(
        sample_fps=args.sample_fps,
        window_before=args.window_before,
        window_after=args.window_after,
        max_window_before=args.max_window_before,
        min_score=args.min_score,
        min_margin=args.min_margin,
        ball_max_gap=args.ball_max_gap,
        ball_min_confidence=args.ball_conf,
        min_track_reliability=args.min_track_reliability,
        player_max_gap=args.player_max_gap,
    )
    if not args.video.is_file():
        raise ValueError(f"VIDEO_NOT_FOUND: {args.video}")
    if args.cached_ball_only and not args.ball_records:
        raise ValueError("ATTRIBUTION_CACHED_BALL_REQUIRES_RECORDS")
    events = load_scoring_events(
        json.loads(args.candidates.read_text(encoding="utf-8"))
    )
    records = (
        load_ball_records(
            json.loads(args.ball_records.read_text(encoding="utf-8")),
            video=args.video,
            scale=args.records_scale,
            time_offset=args.records_time_offset,
        )
        if args.ball_records
        else []
    )
    if args.observations_input and args.observations_output:
        raise ValueError("ATTRIBUTION_OBSERVATIONS_INPUT_OUTPUT_CONFLICT")
    archive, models = None, {}
    player, ball = None, None
    if args.observations_input:
        archive = ObservationArchive(
            json.loads(args.observations_input.read_text(encoding="utf-8")), args.video
        )
        models = archive.payload.get("models", {})
    else:
        if not args.player_model:
            raise ValueError("ATTRIBUTION_PLAYER_MODEL_REQUIRED")
        player = LocalYoloDetector(
            args.player_model,
            device=args.device,
            confidence=args.player_conf,
            imgsz=args.player_imgsz,
        )
        if not args.cached_ball_only:
            ball = LocalYoloDetector(
                args.ball_model,
                label="ball",
                device=args.device,
                confidence=args.ball_conf,
                imgsz=args.ball_imgsz,
                tiles=args.ball_tiles if args.ball_search == "tiles" else 1,
            )
            if args.ball_search == "players":
                ball = PlayerGuidedBallDetector(ball)
        models = {
            "player": model_fingerprint(args.player_model),
            "ball": model_fingerprint(args.ball_model) if ball else None,
            "player_device": player.device,
            "ball_device": ball.device if ball else None,
            "player_imgsz": args.player_imgsz,
            "ball_imgsz": args.ball_imgsz,
            "ball_search": args.ball_search,
            "ball_tiles": args.ball_tiles,
            "player_conf": args.player_conf,
            "ball_conf": args.ball_conf,
        }
    if args.observations_output:
        if ball is None:
            raise ValueError("ATTRIBUTION_RECORDING_REQUIRES_BALL_DETECTOR")
        payload = collect_observations(
            args.video,
            events,
            player,
            ball,
            config,
            models=models,
            progress=lambda value: print(f"collect_progress={value:.4f}", flush=True),
        )
        write_artifact(args.observations_output, payload)
        archive = ObservationArchive(payload, args.video)
        print(f"observations={args.observations_output}", flush=True)
    if args.collect_only:
        if not args.observations_output:
            raise ValueError("ATTRIBUTION_COLLECT_ONLY_REQUIRES_OUTPUT")
        return archive.payload
    pipeline = ShooterAttributionPipeline(
        player,
        ball,
        config=config,
        algorithm=args.algorithm,
        use_appearance=not args.no_appearance,
    )
    result = pipeline.analyze(
        args.video,
        events,
        ball_records=records,
        progress=lambda value: print(f"progress={value:.4f}", flush=True),
        observation_archive=archive,
    )
    result["models"] = models
    result["analysis_algorithm"] = args.algorithm
    if archive is not None:
        result["performance"]["observation_collection_seconds"] = archive.payload.get(
            "elapsed_seconds"
        )
    try:
        import psutil

        result["performance"]["resident_memory_bytes_at_completion"] = (
            psutil.Process().memory_info().rss
        )
    except ImportError:
        pass
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )
    temporary.replace(args.output)
    print(
        f"attributed={sum(r['status'] == 'attributed' for r in result['results'])}/{len(events)}"
    )
    print(f"output={args.output}")
    return result


if __name__ == "__main__":
    try:
        main(parse_args())
    except (OSError, ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
