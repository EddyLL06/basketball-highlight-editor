import json
from pathlib import Path
import shutil
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest

from engine.python.basketball_engine.adapters import runtime_preflight as preflight
from engine.python.basketball_engine.adapters.analysis import PipelineCancelled
from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


@pytest.fixture
def detector_repo(tmp_path):
    root = tmp_path / 'runtime'
    package = root / 'src' / 'basketball_highlight'
    package.mkdir(parents=True)
    (package / '__init__.py').touch()
    source_root = Path(__file__).resolve().parents[1]
    shutil.copy(source_root / 'src/basketball_highlight/runtime_errors.py', package)
    (package / 'inference.py').write_text('''
import os
from pathlib import Path
import time
SUPPORTED_DEVICES = ('auto', 'cpu', 'cuda', 'mps', 'dml', 'coreml')
_device = 'cpu'
def select_device(requested):
    global _device
    _device = 'coreml' if requested == 'auto' else requested
def load_detector(model):
    model = Path(model)
    with (model.parent / 'loads.txt').open('a') as output:
        output.write(_device + '\\n')
    mode = model.read_text()
    if mode == 'autoinstall':
        assert os.environ.get('YOLO_AUTOINSTALL') == 'false'
    if mode == 'ImportError':
        raise ImportError('DLL load failed while importing onnxruntime_pybind11_state')
    if mode == 'OSError':
        raise OSError('[WinError 1114] DLL initialization failed')
    if mode == 'dill':
        from basketball_highlight.runtime_errors import DetectorRuntimeUnavailable
        try:
            raise ModuleNotFoundError("No module named 'dill'", name='dill')
        except ImportError as exc:
            raise DetectorRuntimeUnavailable(str(exc)) from exc
    if mode == 'unknown':
        raise ValueError('unrecognized model')
    if mode == 'crash':
        os._exit(9)
    time.sleep(0.05)
def current_device():
    return _device
''', encoding='utf-8')
    (root / 'scripts').mkdir()
    shutil.copy(source_root / 'scripts/check_detector.py', root / 'scripts')
    return root


@pytest.fixture
def model(tmp_path):
    path = tmp_path / 'model.pt'
    path.write_text('ready')
    return path


def loads(model):
    return (model.parent / 'loads.txt').read_text().splitlines()


@pytest.mark.parametrize('device', ['auto', 'cpu', 'cuda', 'mps', 'dml', 'coreml'])
def test_real_child_loads_the_requested_backend(detector_repo, model, device):
    result = preflight.check_detector(detector_repo, model, device)
    assert result['device'] == ('coreml' if device == 'auto' else device)
    assert result['status'] == 'ready'
    assert result['elapsed_ms'] >= result['load_ms']
    assert loads(model) == [result['device']]


def test_preflight_disables_online_dependency_install(detector_repo, model, monkeypatch):
    monkeypatch.setenv('YOLO_AUTOINSTALL', 'true')
    model.write_text('autoinstall')
    assert preflight.check_detector(detector_repo, model, 'cpu')['status'] == 'ready'


@pytest.mark.parametrize('error', ['ImportError', 'OSError'])
def test_only_confirmed_loader_failures_block(detector_repo, model, error, monkeypatch):
    model.write_text(error)
    monkeypatch.setattr(preflight.platform, 'system', lambda: 'Windows')
    with pytest.raises(ProtocolError) as failure:
        preflight.check_detector(detector_repo, model, 'cpu')
    assert failure.value.code == 'ENGINE_RUNTIME_UNAVAILABLE'
    assert str(failure.value).splitlines()[0] == preflight.WINDOWS_MESSAGE
    assert error in str(failure.value)
    assert 'Traceback' in str(failure.value)


@pytest.mark.parametrize('mode', ['unknown', 'crash'])
def test_inconclusive_checks_pass_and_are_not_cached(detector_repo, model, mode, capsys):
    model.write_text(mode)
    cache = preflight.DetectorPreflight()
    assert cache.ensure(detector_repo, model, 'cpu') is None
    assert cache.ensure(detector_repo, model, 'cpu') is None
    assert loads(model) == ['cpu', 'cpu']
    assert 'warning: inconclusive check; continuing analysis' in capsys.readouterr().err


@pytest.mark.parametrize('output', ['not-json', 'BHE_PREFLIGHT_RESULT={bad',
                                  'BHE_PREFLIGHT_RESULT=[]', 'BHE_PREFLIGHT_RESULT={"status":"ready"}'])
def test_invalid_output_is_not_a_failure(detector_repo, model, output, capsys):
    (detector_repo / 'scripts/check_detector.py').write_text(f'print({output!r})\n')
    assert preflight.check_detector(detector_repo, model, 'cpu') is None
    assert 'continuing analysis' in capsys.readouterr().err


def test_missing_check_script_passes(detector_repo, model, capsys):
    (detector_repo / 'scripts/check_detector.py').unlink()
    assert preflight.check_detector(detector_repo, model, 'cpu') is None
    assert 'continuing analysis' in capsys.readouterr().err


def test_timeout_passes_and_stops_only_the_check_child(detector_repo, model, capsys):
    (detector_repo / 'scripts/check_detector.py').write_text('import time\ntime.sleep(60)\n')
    processes = []
    assert preflight.check_detector(detector_repo, model, 'cpu', timeout=0.03,
                                    process_callback=processes.append) is None
    assert processes[-1] is None
    assert processes[0].poll() is not None
    assert 'timed out' in capsys.readouterr().err


def test_cancel_is_not_passed_through(detector_repo, model):
    (detector_repo / 'scripts/check_detector.py').write_text('import time\ntime.sleep(60)\n')
    cancelled = threading.Event()
    processes = []

    def started(process):
        processes.append(process)
        if process is not None:
            cancelled.set()

    with pytest.raises(PipelineCancelled):
        preflight.check_detector(detector_repo, model, 'cpu', cancel_check=cancelled.is_set,
                                 process_callback=started)
    assert processes[0].poll() is not None
    assert processes[-1] is None


def test_cache_reuses_success_only_and_invalidates_model_and_device(detector_repo, model):
    cache = preflight.DetectorPreflight()
    cache.ensure(detector_repo, model, 'auto')
    assert cache.ensure(detector_repo, model, 'auto')['cached']
    cache.ensure(detector_repo, model, 'cpu')
    model.write_text('ready-again')
    cache.ensure(detector_repo, model, 'cpu')
    cache.invalidate()
    cache.ensure(detector_repo, model, 'cpu')
    assert loads(model) == ['coreml', 'cpu', 'cpu', 'cpu']


def test_concurrent_requests_share_a_success(detector_repo, model):
    cache = preflight.DetectorPreflight()
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: cache.ensure(detector_repo, model, 'cpu'), range(2)))
    assert len(loads(model)) == 1
    assert sum(bool(item.get('cached')) for item in results) == 1


@pytest.fixture
def project(tmp_path, detector_repo, model, monkeypatch):
    monkeypatch.setattr('engine.python.basketball_engine.service.__file__',
                        str(detector_repo / 'engine/python/basketball_engine/service.py'))
    service = EngineService()
    root = tmp_path / 'project'
    service.handle('create_project', {'root_path': str(root), 'name': 'preflight'})
    store = ProjectStore(root)
    source = tmp_path / 'source.mp4'
    source.write_bytes(b'fixture')
    video = store.link_video({
        'source_path': str(source), 'source_size_bytes': source.stat().st_size,
        'source_mtime_ns': source.stat().st_mtime_ns, 'duration_ms': 10000,
        'width': 160, 'height': 120, 'fps': 30,
    })
    store.save_roi(video['id'], {'x1': 0, 'y1': 0, 'x2': 100, 'y2': 100})
    payload = {'project_root': str(root), 'video_id': video['id'], 'model_path': str(model),
               'mode': 'fast', 'device': 'cpu'}
    return service, store, payload


def run_analysis(project):
    service, store, payload = project
    job = store.create_job(store.project()['id'], payload['video_id'], 'analysis', payload)
    service._run_analysis(payload, job['id'])
    return store.get_job(job['id'])


@pytest.mark.parametrize('system', ['Darwin', 'Windows', 'Linux'])
@pytest.mark.parametrize('mode', ['fast', 'standard'])
@pytest.mark.parametrize('error', ['ImportError', 'OSError', 'dill'])
def test_failed_preflight_never_prepares_proxy_or_roi(project, detector_repo, model, error, system, mode, monkeypatch):
    monkeypatch.setattr(preflight.platform, 'system', lambda: system)
    model.write_text(error)
    service, store, payload = project
    payload['mode'] = mode
    original_roi = store.active_roi(payload['video_id'])

    def no_pipeline(**kwargs):
        pytest.fail('preflight must fail before building the proxy pipeline')

    monkeypatch.setattr('engine.python.basketball_engine.service.build_pipeline_commands', no_pipeline)
    job = run_analysis(project)
    assert job['state'] == 'failed'
    assert job['error_code'] == 'ENGINE_RUNTIME_UNAVAILABLE'
    expected = preflight.DEPENDENCY_MESSAGE if error == 'dill' else (
        preflight.WINDOWS_MESSAGE if system == 'Windows' else preflight.GENERIC_MESSAGE
    )
    assert job['error_message'].startswith(expected + '\n')
    if error == 'dill':
        assert "No module named 'dill'" in job['error_message']
    with pytest.raises(ProtocolError) as failure:
        service.suggest_roi(payload)
    assert failure.value.code == 'ENGINE_RUNTIME_UNAVAILABLE'
    assert str(failure.value).startswith(expected + '\n')
    assert loads(model) == ['cpu', 'cpu']
    assert not list((store.root / 'artifacts').rglob('*.*'))
    assert store.active_roi(payload['video_id']) == original_roi


def fake_pipeline(monkeypatch, fail_scan=False):
    def commands(**kwargs):
        values = [('proxy_video', b'proxy'), ('coarse_detections', {'records': [{'detections': [{'name': 'ball'}]}]}),
                  ('coarse_candidates', {'candidates': []})]
        result = []
        for key, value in values:
            code = (f'from pathlib import Path; p=Path({str(kwargs[key])!r}); '
                    'p.parent.mkdir(parents=True, exist_ok=True); ')
            if fail_scan and key == 'coarse_detections':
                code += "raise ImportError('DLL load failed while importing onnxruntime_pybind11_state')"
            elif isinstance(value, bytes):
                code += f'p.write_bytes({value!r})'
            else:
                code += f'p.write_text({json.dumps(value)!r})'
            result.append([sys.executable, '-c', code])
        return result
    monkeypatch.setattr('engine.python.basketball_engine.service.build_pipeline_commands', commands)


@pytest.mark.parametrize('mode', ['ready', 'unknown', 'crash'])
def test_success_and_inconclusive_checks_allow_analysis(project, model, mode, monkeypatch, capsys):
    model.write_text(mode)
    fake_pipeline(monkeypatch)
    first = run_analysis(project)
    assert first['state'] == 'completed', first
    assert 'engine_preflight' in json.loads(first['checkpoint_json'])['stage_timings_ms']
    second = run_analysis(project)
    assert second['state'] == 'completed', second
    assert len(loads(model)) == (1 if mode == 'ready' else 2)
    log = capsys.readouterr().err
    assert log.index('stage=engine_preflight') < log.index('stage=prepare_proxy')


def test_actual_pipeline_failure_is_friendly_and_clears_cache(project, model, monkeypatch):
    service, store, payload = project
    fake_pipeline(monkeypatch, fail_scan=True)
    job = run_analysis(project)
    assert job['state'] == 'failed'
    assert job['error_code'] == 'ENGINE_RUNTIME_UNAVAILABLE'
    assert job['error_message'].startswith(preflight.GENERIC_MESSAGE + '\n')
    service._ensure_detector_ready(model, 'cpu')
    assert len(loads(model)) == 2


def test_roi_actual_failure_uses_same_message_and_invalidates_shared_cache(project, detector_repo, model):
    service, store, payload = project
    service._ensure_detector_ready(model, 'cpu')
    (detector_repo / 'scripts/detect_auto_roi.py').write_text(
        "raise ImportError('DLL load failed while importing onnxruntime_pybind11_state')\n")
    with pytest.raises(ProtocolError) as failure:
        service.suggest_roi(payload)
    assert failure.value.code == 'ENGINE_RUNTIME_UNAVAILABLE'
    assert str(failure.value).startswith(preflight.GENERIC_MESSAGE + '\n')
    assert len(loads(model)) == 1
    service._ensure_detector_ready(model, 'cpu')
    assert len(loads(model)) == 2
    assert not list((store.root / 'artifacts').rglob('roi_suggestion*'))


def test_crash_or_invalid_output_with_raw_dll_text_still_passes(detector_repo, model):
    (detector_repo / 'scripts/check_detector.py').write_text(
        "import sys\nprint('BHE_PREFLIGHT_RESULT={bad')\n"
        "print('ImportError: DLL load failed', file=sys.stderr)\nsys.exit(9)\n")
    assert preflight.check_detector(detector_repo, model, 'cpu') is None


def test_unknown_result_does_not_turn_a_handled_dll_warning_into_a_failure(detector_repo, model):
    (detector_repo / 'scripts/check_detector.py').write_text(
        "import sys\nprint('ImportError: DLL load failed', file=sys.stderr)\n"
        "print('BHE_PREFLIGHT_RESULT={\"status\":\"unknown\",\"details\":\"bad model\"}')\nsys.exit(1)\n")
    assert preflight.check_detector(detector_repo, model, 'cpu') is None


def test_timeout_is_not_cached_and_still_allows_proxy_pipeline(project, detector_repo, model, monkeypatch):
    original = preflight.check_detector
    checked = []

    def timed_out(*args, **kwargs):
        checked.append(True)
        return original(*args, **kwargs, timeout=0)

    monkeypatch.setattr(preflight, 'check_detector', timed_out)
    fake_pipeline(monkeypatch)
    assert run_analysis(project)['state'] == 'completed'
    assert run_analysis(project)['state'] == 'completed'
    assert len(checked) == 2


def test_failure_to_start_a_child_is_inconclusive(detector_repo, model, monkeypatch):
    def cannot_start(*args, **kwargs):
        raise OSError('process could not start')

    monkeypatch.setattr(preflight.subprocess, 'Popen', cannot_start)
    assert preflight.check_detector(detector_repo, model, 'cpu') is None


def test_cache_fingerprint_detects_mtime_and_path_changes(detector_repo, model):
    import os

    cache = preflight.DetectorPreflight()
    cache.ensure(detector_repo, model, 'cpu')
    info = model.stat()
    os.utime(model, ns=(info.st_atime_ns, info.st_mtime_ns + 1000000))
    cache.ensure(detector_repo, model, 'cpu')
    another = model.with_name('another.pt')
    another.write_bytes(model.read_bytes())
    info = model.stat()
    os.utime(another, ns=(info.st_atime_ns, info.st_mtime_ns))
    cache.ensure(detector_repo, another, 'cpu')
    assert loads(model) == ['cpu', 'cpu', 'cpu']


def test_cancellation_while_waiting_for_the_cache_lock(detector_repo, model):
    cache = preflight.DetectorPreflight()
    cache._lock.acquire()
    try:
        with pytest.raises(PipelineCancelled):
            cache.ensure(detector_repo, model, 'cpu', cancel_check=lambda: True)
    finally:
        cache._lock.release()
