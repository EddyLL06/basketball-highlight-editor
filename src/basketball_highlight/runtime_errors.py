"""Recognize native inference runtime failures without importing native libraries."""


class DetectorRuntimeUnavailable(RuntimeError):
    pass


def is_runtime_failure(details):
    if any(line.strip().partition(":")[0].rsplit(".", 1)[-1] in {
        "DetectorRuntimeUnavailable", "ImportError", "ModuleNotFoundError",
    } for line in details.splitlines()):
        return True
    lowered = details.lower()
    return any(marker in lowered for marker in (
        "dll load failed", "dll initialization", "dll init failed", "winerror 1114",
        "动态链接库(dll)初始化", "动态链接库（dll）初始化", "dll初始化失败", "dll 加载失败",
        "dlopen(", "library not loaded:", "cannot open shared object file",
    ))
