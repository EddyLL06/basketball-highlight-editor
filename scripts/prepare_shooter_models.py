"""Prepare checksum-pinned public shooter models during CI packaging only."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import urllib.request

MODEL_REVISION = 'a5c5cc037c24235cda3b21085b93ad77c9616224'
SOURCE_REVISION = 'f8cd150fdf77e8d9e1ed143b7f308c2c609ded50'
WEIGHTS = 'osnet_x0_25_msmt17_combineall_256x128_amsgrad_ep150_stp60_lr0.0015_b64_fb10_softmax_labelsmooth_flip_jitter.pth'
SOURCES = {
    WEIGHTS: (f'https://huggingface.co/kaiyangzhou/osnet/resolve/{MODEL_REVISION}/{WEIGHTS}',
              'cf55163d78fc44c62c82f85ab62d39f10438679b5abe8c698ae08cfa84aa6e18'),
    'osnet.py': (f'https://raw.githubusercontent.com/KaiyangZhou/deep-person-reid/{SOURCE_REVISION}/torchreid/models/osnet.py',
                 'c7c1c29187d6330f859c91da229271531920464c7011aec13842a086b2263cae'),
    'LICENSE': (f'https://raw.githubusercontent.com/KaiyangZhou/deep-person-reid/{SOURCE_REVISION}/LICENSE',
                '3ac8ce2a83d170cb1c7c84152e0c1faca1f187794303514383960d2441716247'),
    'yolo11n.pt': ('https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt',
                   '0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1'),
}


def checksum(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verified_download(url, expected, destination):
    destination = Path(destination)
    if destination.is_file() and checksum(destination) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.download')
    with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as out:
        while chunk := response.read(1024 * 1024):
            out.write(chunk)
    if checksum(temporary) != expected:
        temporary.unlink()
        raise ValueError(f'Model checksum mismatch: {destination.name}')
    temporary.replace(destination)


def prepare(directory, cache):
    import torch

    directory, cache = Path(directory), Path(cache)
    directory.mkdir(parents=True, exist_ok=True)
    for name, (url, expected) in SOURCES.items():
        verified_download(url, expected, cache / name)
    spec = importlib.util.spec_from_file_location('bhe_osnet_build', cache / 'osnet.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    state = torch.load(cache / WEIGHTS, map_location='cpu', weights_only=True)
    state = state.get('state_dict', state)
    state = {k.removeprefix('module.'): v for k, v in state.items()}
    model = module.osnet_x0_25(num_classes=state['classifier.weight'].shape[0], pretrained=False).eval()
    model.load_state_dict(state, strict=True)
    torch.set_num_threads(min(4, torch.get_num_threads()))
    example = torch.linspace(-1, 1, 3 * 256 * 128).reshape(1, 3, 256, 128)
    with torch.inference_mode():
        traced = torch.jit.trace(model, example)
        for batch in (example, example.expand(4, -1, -1, -1)):
            torch.testing.assert_close(traced(batch), model(batch))
    target = directory / 'shooter-appearance.pt'
    traced.save(str(target))
    loaded = torch.jit.load(str(target), map_location='cpu').eval()
    with torch.inference_mode():
        torch.testing.assert_close(loaded(example), model(example))
    (directory / 'shooter-appearance.json').write_text(json.dumps({
        'file': target.name, 'sha256': checksum(target), 'input': [3, 256, 128],
        'output_dimension': 512, 'encoder': 'osnet_x0_25_msmt17',
        'weights_sha256': SOURCES[WEIGHTS][1], 'model_revision': MODEL_REVISION,
        'source_revision': SOURCE_REVISION, 'torch': torch.__version__,
    }, indent=2) + '\n')
    (directory / 'OSNet-LICENSE.txt').write_bytes((cache / 'LICENSE').read_bytes())
    (directory / 'yolo11n.pt').write_bytes((cache / 'yolo11n.pt').read_bytes())
    print(f'Prepared verified shooter models in {directory}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('models'))
    parser.add_argument('--cache', type=Path, default=Path('.cache/shooter-model-build'))
    args = parser.parse_args()
    prepare(args.output, args.cache)
