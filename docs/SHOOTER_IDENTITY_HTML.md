# Cross-shot identity association — HTML experiment

Release detection is frozen. This experiment adds names to existing shot-local
person observations and does not change outcomes, the desktop UI, or project.db.

Run with the existing Python analysis environment:

```sh
PYTHONPATH=src:engine/python:. python tools/shooter_identity_review/server.py --root /path/to/private/session
```

The private session supplies immutable `dataset.json` (fixed candidates, proxy
crop observations and an explicit media allowlist) and `features.json` (cached
normalized appearance vectors). The model, media and human data are not shipped
in Git. First-quarter through fourth-quarter test inputs remain private.

The first encoder candidate is OSNet x0.25 trained on MSMT17, published by the
author at <https://huggingface.co/kaiyangzhou/osnet>. Official definition and MIT
license: <https://github.com/KaiyangZhou/deep-person-reid>. The local experiment
pins both upstream revisions and all downloads by SHA-256, loads tensor weights
with `weights_only=True`, and verifies a local TorchScript export on single and
batched inputs. The encoder accepts only proxy person crops (RGB, 256×128,
ImageNet normalization); there are no runtime downloads or additional SDKs.

Choose at least two distinct reference shots per player (three to five preferred).
Only explicitly confirmed references participate. Similarity and runner-up margin,
plus agreement across at most three crops, gate suggestions. Similarity is not a
calibrated probability. Unknown shooters and unfamiliar appearances may abstain.

Reference shots, duplicate groups and same-video candidates within three seconds
of a reference are explicitly excluded from test scoring. Frozen run files bind
the gallery, policy, model, dataset and feature-cache hash. Gallery edits invalidate
the active run; a fresh run never silently reuses earlier reviews as new test truth.
Review results and predictions remain separate. A saved name never adds a reference.

The server binds loopback only, serves an explicit asset allowlist, supports proxy
video ranges, and rejects cross-origin mutations. Atomic state files, revision
checks, history snapshots and undo protect review edits. No original labels change.

Accuracy uses manually named test shots. Conditional identity accuracy requires
the frozen shooter box to match the human-selected person; the overall metric
counts wrong shooter selection as failure. Coverage conservatively retains unknown
reviews. Non-shots, explicit unobservable cases, duplicates, references and
unreviewed candidates are reported separately. Reference frames and adjacent crops
are never counted as successful held-out predictions.

This HTML flow must pass human accuracy review before desktop integration.
