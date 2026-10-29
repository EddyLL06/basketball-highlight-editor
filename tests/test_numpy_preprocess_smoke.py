import importlib.util
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check_numpy_preprocess.py'
spec = importlib.util.spec_from_file_location('check_numpy_preprocess', SCRIPT)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


def test_smoke_exercises_bridge_and_preprocess():
    assert 'torch.from_numpy(np.zeros(1))' in smoke.SMOKE
    assert 'predictor.preprocess([np.zeros((32, 32, 3), dtype=np.uint8)])' in smoke.SMOKE
    with patch.object(sys, 'argv', [str(SCRIPT), '--python', '/runtime/python']), \
            patch.object(smoke.subprocess, 'run') as run:
        assert smoke.main() == 0
    assert run.call_args.args[0][:3] == ['/runtime/python', '-B', '-c']
    assert run.call_args.kwargs == {'check': True, 'timeout': 180}


def test_timeout_reports_failure(capsys):
    with patch.object(sys, 'argv', [str(SCRIPT)]), \
            patch.object(smoke.subprocess, 'run', side_effect=subprocess.TimeoutExpired('python', 180)):
        assert smoke.main() == 1
    assert 'timed out after 180 seconds' in capsys.readouterr().err
