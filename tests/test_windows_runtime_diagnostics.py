import ctypes
from types import SimpleNamespace

import pytest

from engine.python.basketball_engine import diagnostics


class ApiCall:
    def __init__(self, function):
        self.function = function

    def __call__(self, *args):
        return self.function(*args)


@pytest.fixture
def windows_api(monkeypatch):
    calls = []
    info = (ctypes.c_uint32 * 13)(0xFEEF04BD, 0, (14 << 16) | 42, (34433 << 16) | 1)

    def system_directory(buffer, size):
        buffer.value = r'C:\Windows\System32'
        return len(buffer.value)

    def file_size(path, handle):
        calls.append(path)
        return ctypes.sizeof(info)

    def query(data, name, block, length):
        assert name == '\\'
        block._obj.value = ctypes.addressof(info)
        length._obj.value = ctypes.sizeof(info)
        return 1

    def feature(number):
        calls.append(number)
        return number != 41

    kernel = SimpleNamespace(IsProcessorFeaturePresent=ApiCall(feature),
                             GetSystemDirectoryW=ApiCall(system_directory))
    version = SimpleNamespace(GetFileVersionInfoSizeW=ApiCall(file_size),
                              GetFileVersionInfoW=ApiCall(lambda *args: 1),
                              VerQueryValueW=ApiCall(query))
    monkeypatch.setattr(ctypes, 'windll', SimpleNamespace(kernel32=kernel, version=version), raising=False)
    monkeypatch.setattr(diagnostics.sys, 'getwindowsversion', lambda: SimpleNamespace(build=19045), raising=False)
    return kernel, version, calls, info


def test_windows_environment_fields_use_official_api_constants(windows_api, monkeypatch):
    kernel, version, calls, _ = windows_api
    monkeypatch.setattr(diagnostics.platform, 'system', lambda: 'Windows')
    monkeypatch.setattr(diagnostics, '_ffmpeg_version', lambda _: 'test')
    text = diagnostics.environment_summary()
    assert 'avx=true avx2=true avx512f=false msvcp140=14.42.34433.1' in text
    assert calls == [39, 40, 41, r'C:\Windows\System32\msvcp140.dll']
    assert kernel.IsProcessorFeaturePresent.restype == ctypes.c_int
    assert len(version.VerQueryValueW.argtypes) == 4


@pytest.mark.parametrize('platform', ['Darwin', 'Linux'])
def test_other_platforms_do_not_probe_or_report_windows_fields(monkeypatch, platform):
    monkeypatch.setattr(diagnostics.platform, 'system', lambda: platform)
    monkeypatch.setattr(diagnostics, '_ffmpeg_version', lambda _: 'test')
    monkeypatch.setattr(diagnostics, '_windows_environment', lambda: pytest.fail('Windows API called'))
    text = diagnostics.environment_summary()
    assert 'avx=' not in text
    assert 'msvcp140=' not in text


def test_old_windows_reports_unknown_instead_of_no_avx(windows_api, monkeypatch):
    monkeypatch.setattr(diagnostics.sys, 'getwindowsversion', lambda: SimpleNamespace(build=18363))
    assert diagnostics._windows_cpu_features() == dict.fromkeys(['avx', 'avx2', 'avx512f'], 'unknown')
    assert windows_api[2] == []


def test_failure_to_read_one_feature_does_not_hide_the_others(windows_api):
    kernel = windows_api[0]

    def probe(number):
        if number == 40:
            raise OSError('unavailable')
        return 1

    kernel.IsProcessorFeaturePresent = ApiCall(probe)
    assert diagnostics._windows_cpu_features() == {'avx': 'true', 'avx2': 'unknown', 'avx512f': 'true'}


@pytest.mark.parametrize('function', ['GetSystemDirectoryW', 'GetFileVersionInfoSizeW',
                                    'GetFileVersionInfoW', 'VerQueryValueW'])
@pytest.mark.parametrize('throws', [False, True])
def test_version_api_failures_never_escape(windows_api, function, throws):
    target = windows_api[0] if function == 'GetSystemDirectoryW' else windows_api[1]

    def failure(*args):
        if throws:
            raise RuntimeError('bad API boundary')
        return 0

    setattr(target, function, ApiCall(failure))
    assert diagnostics._windows_msvcp_version() == 'unknown'


def test_invalid_version_signature_is_unknown(windows_api):
    windows_api[3][0] = 0
    assert diagnostics._windows_msvcp_version() == 'unknown'


def test_missing_ctypes_windows_api_is_unknown(monkeypatch):
    monkeypatch.delattr(ctypes, 'windll', raising=False)
    assert diagnostics._windows_environment() == ' avx=unknown avx2=unknown avx512f=unknown msvcp140=unknown'
