#!/usr/bin/env python3
"""Freeze human-selected player boxes for same-video algorithm comparisons."""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from basketball_highlight.shooter_evaluation import build_spatial_references
from basketball_highlight.shooter_observations import write_artifact


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build_spatial_references(
        json.loads(args.predictions.read_text(encoding="utf-8")),
        json.loads(args.labels.read_text(encoding="utf-8")),
    )
    write_artifact(args.output, result)
    print(
        f"reference_events={len(result['events'])} resolvable={sum(bool(e['shooter_anchors']) for e in result['events'])}"
    )


if __name__ == "__main__":
    main()
