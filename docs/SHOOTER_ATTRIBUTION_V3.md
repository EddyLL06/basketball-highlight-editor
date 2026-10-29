# Contextual shooter attribution (v3, opt-in)

[V4](SHOOTER_ATTRIBUTION_V4.md) adds opt-in local release identity checks and
compact-finish evidence. The explicit v3 method below remains reproducible.

Shooter labels now cover both made and missed attempts. See the independent
[shot-attempt/outcome contract](SHOT_ATTEMPT_LABELS.md) and `attempt_evaluation`
metrics. An attribution on a missed shot is valid; only an explicitly labeled
non-shot is a false candidate. This label/evaluation revision does not change
the frozen v3 inference method.

V3 addresses coverage limits found during the first-quarter review while keeping
the [v2 method](SHOOTER_ATTRIBUTION_V2.md) reproducible. Use `--algorithm joint-v3`;
the existing `joint` selection and CLI default still run v2, and `baseline`
retains the original association method. V3 adds no model or dependency.

```bash
python scripts/attribute_shooters.py \
  --video game.mp4 --candidates candidates.json \
  --observations-input .cache/shooter/observations.json \
  --algorithm joint-v3 --output .cache/shooter/predictions-v3.json
```

Live inference accepts the same local model and detector options documented in
v2. All three algorithms use the same outer result schema. V3 exports
`method: contextual_release_trajectory_v3`; tracking scopes include the algorithm
and resulting observation histories. Scoped track numbers must not be copied
between runs.

## Context before attribution

Duplicate person boxes can create two tracks for one player and falsely trigger
tracking ambiguity. V3 suppresses a lower-confidence box only when IoU is at
least 0.65, at least 90% of the smaller box is contained, and torso Hellinger
distance is at most 0.35. With missing torso evidence, IoU must reach 0.9.
Differently dressed overlapping players remain separate. Similar clothing with
almost identical projected boxes remains a limitation; this is not general
multi-person occlusion resolution.

The possession radius can include a nearby defender. For each release hypothesis,
v3 compares that exact observed ball history against the other temporary tracks.
If a rival's mean upper-body possession strength is at least 0.65 and exceeds the
candidate's by at least 0.2, the defender explanation is rejected. Equal ownership
remains ambiguous. The original score threshold 0.78, winner margin 0.12 and
track-reliability threshold 0.55 remain unchanged; no human label enters inference.

Tracking ambiguity must intersect the actual possession/flight support interval.
The v2 extra 0.25-second padding before the first supporting held-ball observation
is removed for this method. Ambiguity during the release interval still causes
an unknown result. This concerns the visible releaser's temporary track, not
proof of an identity earlier in the clip.

A later catch is checked from 0.1 seconds after the held-ball endpoint, including
the initial flight window. V2 could miss a quick catch that occurred entirely
inside that window. Multiple slow relative-motion observations are still
required, so a ball flying through a projected body box is not automatically a
catch. Flight displacement uses the maximum observed displacement in the window;
an arc returning toward its release height need not end at its maximum extent.

## An explicit gap above the frame

Normal ball links retain the 0.35-second gap limit. A separate exception is
available for a top-of-frame occlusion of at most 0.85 seconds. It requires:

- At least three observed ball points on each side, with temporal spread.
- Both gap endpoints within the top 10% of the frame.
- A quadratic image-plane fit with downward curvature, upward departure,
  downward reappearance, and consistent horizontal direction.
- Residual bounded by ball size and source-frame scale, and at least four of
  nine interior fit samples above the frame boundary.
- Final support from observations belonging to the exported trajectory.

`trajectory_gaps.top_boundary_bridge` validates association only. It does not
estimate physical gravity, add synthetic ball observations, or fill the missing
timestamps. The exported `ball_trajectory.observed_gaps` and shooter evidence
record the gap duration, fit residual, supporting count and zero synthetic
observations. Unsupported in-frame gaps, insufficient support, inconsistent
reappearances and long gaps remain unconnected. General camera motion and
occlusion inside the court still require further work.

## Reviewed evaluation and reproducibility

Freeze observations and method source hashes before evaluating another segment.
Evaluate existing human selections through exact-video spatial references when
track numbers change, and retain fresh manual labels separately. Report scoring
coverage, verifiable shooter precision, unknowns, assignments without usable
truth, and attributions on non-scoring candidates separately. Existing BHE
candidate detection is unchanged; v3 does not determine whether a shot went in.

Tests cover duplicate containment, differently dressed and similarly dressed
overlaps, defender rejection, equal ownership, ambiguity during release, quick
catch-and-shoot sequences, supported top-boundary gaps, missing support, outliers,
in-frame gaps and overlong gaps. The explicit v2 replay is also compared with its
preserved development predictions. The current two-player video does not validate
larger games or calibrate the heuristic score as a probability.
