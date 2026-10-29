#!/usr/bin/env python3
"""Check the NumPy/PyTorch bridge and the real Ultralytics preprocessing path."""
import argparse
import subprocess
import sys


SMOKE = '''
from types import SimpleNamespace
import numpy as np
import torch
from ultralytics.engine.predictor import BasePredictor

torch.from_numpy(np.zeros(1))
predictor = object.__new__(BasePredictor)
predictor.pre_transform = lambda frames: frames
predictor.device = 'cpu'
predictor.model = SimpleNamespace(fp16=False)
result = predictor.preprocess([np.zeros((32, 32, 3), dtype=np.uint8)])
assert tuple(result.shape) == (1, 3, 32, 32), result.shape
print('NumPy/Torch/preprocess smoke: OK')
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', default=sys.executable, help='Python interpreter to check')
    args = parser.parse_args()
    try:
        subprocess.run([args.python, '-B', '-c', SMOKE], check=True, timeout=180)
    except subprocess.TimeoutExpired:
        print('NumPy/Torch/preprocess smoke timed out after 180 seconds', file=sys.stderr)
        return 1
    except (subprocess.CalledProcessError, OSError) as error:
        print(f'NumPy/Torch/preprocess smoke failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
