#!/usr/bin/env python3
"""Load the analysis detector in an isolated process, without touching a video."""

import argparse
import json
import os
from pathlib import Path
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.inference import SUPPORTED_DEVICES, current_device, load_detector, select_device
from basketball_highlight.runtime_errors import DetectorRuntimeUnavailable, is_runtime_failure

RESULT_PREFIX = "BHE_PREFLIGHT_RESULT="


def main():
    # A packaged runtime cannot repair itself; report missing dependencies
    # immediately instead of waiting for Ultralytics to run an online install.
    os.environ["YOLO_AUTOINSTALL"] = "false"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--device", default="auto", choices=SUPPORTED_DEVICES)
    args = parser.parse_args()
    started = time.perf_counter()
    try:
        select_device(args.device)
        load_detector(args.model)
    except Exception as exc:
        details = traceback.format_exc()
        unavailable = (
            isinstance(exc, (DetectorRuntimeUnavailable, ImportError, OSError))
            and not isinstance(exc, (FileNotFoundError, PermissionError))
        ) or is_runtime_failure(str(exc))
        result = {
            "status": "unavailable" if unavailable else "unknown",
            "error_code": "ENGINE_RUNTIME_UNAVAILABLE" if unavailable else None,
            "details": details,
        }
        cause = exc
        while cause is not None:
            if isinstance(cause, ModuleNotFoundError):
                result["missing_module"] = cause.name
                break
            cause = cause.__cause__ or cause.__context__
        print(details, file=sys.stderr, flush=True)
    else:
        result = {"status": "ready", "device": current_device()}
    result["load_ms"] = round((time.perf_counter() - started) * 1000)
    print(RESULT_PREFIX + json.dumps(result, ensure_ascii=False), flush=True)
    return 0 if result["status"] == "ready" else 1


if __name__ == "__main__":
    sys.exit(main())
