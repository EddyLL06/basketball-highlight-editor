"""Inspect checkpoint imports without unpickling or importing heavy runtimes."""

import collections
from pathlib import Path
import pickle
import pickletools
import re
import sys
import zipfile

import pytest


def checkpoint_modules(data):
    """Track symbolic strings/memo entries so protocol 4+ STACK_GLOBAL is covered."""
    stack, memo, modules = [], {}, set()
    unknown, mark = object(), object()
    for op, arg, _ in pickletools.genops(data):
        name = op.name
        if name == 'GLOBAL':
            modules.add(arg.split(' ', 1)[0].split('.', 1)[0])
            stack.append(unknown)
        elif name == 'STACK_GLOBAL':
            symbol, module = stack.pop(), stack.pop()
            assert isinstance(module, str) and isinstance(symbol, str)
            modules.add(module.split('.', 1)[0])
            stack.append(unknown)
        elif name in {'UNICODE', 'BINUNICODE', 'SHORT_BINUNICODE', 'BINUNICODE8',
                      'STRING', 'BINSTRING', 'SHORT_BINSTRING'}:
            stack.append(arg)
        elif name in {'PUT', 'BINPUT', 'LONG_BINPUT', 'MEMOIZE'}:
            memo[len(memo) if name == 'MEMOIZE' else arg] = stack[-1]
        elif name in {'GET', 'BINGET', 'LONG_BINGET'}:
            stack.append(memo[arg])
        elif name == 'DUP':
            stack.append(stack[-1])
        else:
            before = op.stack_before
            if pickletools.stackslice in before:
                mark_index = len(stack) - 1 - stack[::-1].index(mark)
                del stack[mark_index - before.index(pickletools.markobject):]
            elif before:
                del stack[-len(before):]
            stack.extend(mark if item is pickletools.markobject else unknown
                         for item in op.stack_after)
    return modules


def undeclared_modules(modules, requirements):
    declared = {
        re.split(r'[<>=!~\[;\s]', line.strip(), maxsplit=1)[0].replace('-', '_')
        for line in requirements.splitlines() if line.strip() and not line.lstrip().startswith('#')
    }
    # Ultralytics declares torch itself; the checkpoint additionally needs dill.
    if 'ultralytics' in declared:
        declared.add('torch')
    return modules - sys.stdlib_module_names - declared


@pytest.mark.parametrize('protocol', range(pickle.HIGHEST_PROTOCOL + 1))
def test_scanner_handles_global_stack_global_and_memo_reuse(protocol):
    data = pickle.dumps((collections.OrderedDict, collections.Counter), protocol=protocol)
    assert checkpoint_modules(data) == {'collections'}


def test_developer_installed_dependency_does_not_hide_missing_declaration():
    assert undeclared_modules({'dill', 'torch', 'ultralytics', 'collections'},
                              'ultralytics>=8.4,<9') == {'dill'}


def test_packaged_checkpoint_dependencies_are_declared():
    root = Path(__file__).resolve().parents[1]
    models = list((root / 'models').glob('*.pt'))
    assert models, 'No packaged checkpoints found'
    requirements = (root / 'requirements.txt').read_text(encoding='utf-8')
    for model in models:
        with zipfile.ZipFile(model) as archive:
            pickles = [name for name in archive.namelist() if name.rsplit('/', 1)[-1] == 'data.pkl']
            assert pickles, f'{model.name}: data.pkl missing'
            for name in pickles:
                missing = undeclared_modules(checkpoint_modules(archive.read(name)), requirements)
                assert not missing, f'{model.name}: undeclared model dependencies: {sorted(missing)}'
