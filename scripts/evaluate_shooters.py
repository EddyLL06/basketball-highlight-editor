#!/usr/bin/env python3
"""Evaluate standalone predictions against human-confirmed temporary track IDs."""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from basketball_highlight.shooter_evaluation import (
    evaluate_shooters,
    evaluate_spatial_references,
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--labels", type=Path)
    source.add_argument("--references", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    evaluator = evaluate_spatial_references if args.references else evaluate_shooters
    report = evaluator(
        json.loads(args.predictions.read_text(encoding="utf-8")),
        json.loads((args.references or args.labels).read_text(encoding="utf-8")),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, allow_nan=False), encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
