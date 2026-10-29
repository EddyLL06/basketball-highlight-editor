# Local release evidence (v4, opt-in)

V4 extends the [v3 method](SHOOTER_ATTRIBUTION_V3.md) after development on
reviewed two-player clips. It focuses on the identity visible at release and
short finishes near the basket. Use `--algorithm joint-v4`. The CLI default
remains v2 (`joint`); `joint-v3` and `baseline` remain available.

```bash
python scripts/attribute_shooters.py \
  --video game.mp4 --candidates candidates.json \
  --player-model /path/to/person-model.pt --ball-model models/bball_model.pt \
  --algorithm joint-v4 --device mps \
  --observations-output .cache/shooter/observations.json \
  --output .cache/shooter/predictions-v4.json

python scripts/attribute_shooters.py \
  --video game.mp4 --candidates candidates.json \
  --observations-input .cache/shooter/observations.json \
  --algorithm joint-v4 --output .cache/shooter/replayed-v4.json
```

The output method is `local_release_trajectory_v4`. Detection models, global
assignment and appearance matching, ball-path search, v3 top-boundary gap checks,
and the final score/reliability gates are reused. V4 adds no dependency or model.
No human labels enter inference. The score threshold remains 0.78, the winner
margin 0.12, and the track-reliability threshold 0.55. Scores remain heuristic
rankings, not calibrated correctness probabilities.

## Local identity across release

A track may have ambiguous observations earlier in possession or after the first
flight points while still showing a clear releaser. V4 retains the broad history
ambiguity flag for inspection, then permits a local check only when mean
possession ownership exceeds the strongest competing player's by at least 0.25.
There must be no tracking ambiguity from the penultimate held-ball sample through
the third flight sample. Ambiguity at either boundary still rejects attribution.

When an ambiguity occurs after the third flight sample inside the remaining
flight window, separation and displacement evidence stop before that ambiguity.
This prevents later ambiguous boxes from inflating separation evidence. The
original ambiguity interval is retained in `tracking_history_ambiguous`; the
decision is recorded as `release_identity_revalidated`, with
`flight_evidence_end_seconds` identifying the last supporting flight sample.

This is a claim about the visible releaser's temporary track at release. It does
not repair an earlier ID switch, establish a persistent person identity, or
authorize combining track numbers across sessions.

## Compact finishes

V3 requires ball displacement of at least 0.25 player heights. V4 also accepts a
shorter displacement when all of these additional observations agree:

- At least three held-ball observations and ownership margin at least 0.25.
- Ball-to-player separation gain at least 0.4 player heights, with the ordinary
  sustained-separation checks still passing.
- Actual observed ball displacement at least the greater of 0.1 player heights
  and 1.5 times the median observed ball diameter in the held/flight evidence.

The displacement floor is applied to ball motion itself. A stationary ball and a
player walking away do not satisfy it. Ball size is measured in the image plane;
this is not a physical distance or a camera calibration.

## Lower upward releases

An ordinary release remains in the upper 45% of the player box. A release below
that region, through 65% of box height, requires three held observations,
ownership margin at least 0.2, and three immediately subsequent flight points
with strictly upward image motion. The rise through the third point must reach
0.15 player heights. A downward dribble fails this gate. The existing separation,
ball-path connection and later-possession checks still apply; upward motion alone
does not prove a shot.

Refinement requires contextual possession and at least three flight observations;
invalid estimator configurations are rejected instead of silently weakening the
checks. Regression tests cover ambiguity before, during and after release,
support trimming, compact finishes, stationary-ball rejection, upward releases,
downward dribbles and configuration constraints. Existing v2/v3 paths retain their
previous behavior when refinement is disabled.

## Review and evaluation

Follow the [shot-attempt label contract](SHOT_ATTEMPT_LABELS.md): review the
shooter independently from made/missed outcome. A missed attempt with the correct
releaser is a valid attribution. Use the nested `attempt_evaluation` report for
made and missed attempts; top-level made-basket metrics are retained for legacy
compatibility. Unclassified legacy negative labels are excluded from attempt
coverage until reviewed explicitly.

For a new validation clip, freeze source hashes, settings and candidate anchors
before attribution and before receiving labels. Keep the method fixed through
review. Report raw candidate assignment counts while labels are pending; only
after review report coverage among real attempt candidates and precision among
assignments with resolvable shooter truth. Report unsupported assignments and
false candidates separately. Results on clips used to develop v4 are development
results, even if all verifiable assignments agree with existing reviews.

The temporary review page uses a browser-compatible video on the same timeline,
paints the decoded frame and annotations onto one canvas, and saves each review
locally. Confirm actual video painting when opening another clip. Keep original
human labels and all candidate aliases; do not silently reinterpret a negative
basket label as a false shot or infer a shooter from a fragmented track.

Current candidate generation is inherited from BHE's basket-oriented detector.
It does not establish exhaustive attempt recall. Physical-shot deduplication and
stable person identity are also required before reporting full-game field-goal
percentages. Two-player development clips do not establish accuracy for 2-on-2,
3-on-3, general crowding, or moving cameras.

## Full-frame context and ROI diagnostics

The shooter detector already searches the full decoded frame for players and
balls, with additional player-guided upper-body crops. BHE's coarse analysis ROI
and dense rim-verification crop serve different stages. Enlarging the coarse ROI
does not by itself increase spatial detail: a fixed-size detector input gives
smaller image-space balls when it covers more of the court. Keep full-frame flight
context and local release/rim detail as complementary observations.

`scripts/compare_shooter_roi.py` replays a frozen archive after removing ball
observations outside a supplied ROI and a tight rim region. It verifies the full
replay against the original result, preserves saved player observations, and maps
human truth through spatial references when automatic window expansion changes
tracking scopes. This isolates support from observations outside the ROI. It is
not a measurement of detector accuracy after re-cropping or resizing; a real
resolution/tiling comparison requires fresh inference on matched source frames.
