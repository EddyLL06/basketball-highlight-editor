# Shot attempts, outcomes and shooter labels

Shooter attribution applies to both made and missed shots. Correctly identifying
the releaser on a miss is a valid attribution. Shot outcome is independent of
shooter identity; neither establishes the other. A non-shot/false candidate is a
third category and must not be conflated with a missed field-goal attempt.

## Label schema version 2

The local review still stores a JSON array. Each structured row contains:

```json
{
  "label_schema_version": 2,
  "candidate_id": "event-7",
  "tracking_scope": "session-example",
  "is_shot": true,
  "shot_outcome": "missed",
  "is_scoring": false,
  "shooter_track_id": 2,
  "review_kind": "scoped_shooter",
  "note": "The shooter is visible; the ball did not go in."
}
```

- `is_shot=true` requires outcome `made`, `missed` or `unknown`.
- `is_shot=false` means not a shot/false candidate, with null outcome and shooter.
- `shooter_track_id` may be null on any real attempt when its releaser cannot be
  determined. An unknown outcome can still have a known shooter.
- `is_scoring` is a compatibility field derived from outcome: true for made,
  false for missed/non-shot, null for an attempt with unknown outcome.
- Optional explicit `player_id` and `attempt_id` may support later statistics.
  Track IDs and candidate IDs are not silently promoted to these identities.

`shooter_labels.normalize_shot_label` validates consistency without mutating the
input. Legacy `is_scoring=true` implies a made attempt. Legacy false only says a
basket was not made; attempt type remains unclassified (`is_shot=null`) until
explicit review distinguishes a miss from a non-shot. Production normalization
never interprets free-text notes. Historical note interpretation must be a
separate, audited operation retaining the source bytes, scope and provenance.

## Review flow

The temporary reviewer records **Shot outcome** and **Actual shooter** separately.
“Missed · selected shooter” saves the selected shooter with a missed outcome.
“Shooter cannot be determined” retains the chosen outcome and clears only shooter
truth. “Not a shot / false candidate” clears shooter and outcome and classifies
the event as a non-shot. Existing null shooter labels do not fall back to the
prediction when loaded. Saved lists show the human outcome and human shooter,
separately from the unchanged automatic prediction.

## Evaluation

`evaluate_attempts` covers all explicitly reviewed shot-attempt candidates,
including made, missed and unknown outcomes. It reports attribution coverage,
precision among assignments with resolvable shooter truth, unknowns, and separate
made/missed breakdowns. A human track label on an automatically unknown event is
ground truth, not an automatic success. Only explicit non-shots are counted as
non-shot attributions; legacy not-made candidates remain unclassified.

Existing `evaluate_shooters` and the CLI retain their historical made-only fields
with `metric_scope: made_baskets_only_legacy`. The new nested `attempt_evaluation`
is the appropriate summary for general shooter attribution. Spatial references
preserve the attempt and outcome fields when mapping a human choice to new track
numbers. The legacy `attributions_on_non_scoring_candidates` count is descriptive:
it is not an attribution-error count, because it can include valid missed shots.

## Field-goal statistics

For a real player, FGM counts made field goals, FGA counts made plus missed field
goal attempts, and FG% is `100 * FGM / FGA`. Reliable video statistics additionally
require a complete attempt detector, physical-shot deduplication and a persistent
player identity. The current event-anchored pipeline samples existing BHE hoop
candidates; it does not establish that it finds every miss or airball. Candidate
deduplication near a crossing does not prove all duplicate physical shots are
removed. Temporary `(tracking_scope, track_id)` identities can change at overlap
and differ between sessions.

`summarize_linked_field_goals` therefore requires explicit `player_id` and physical
`attempt_id`. Repeated candidate labels for the same attempt count once. Conflicting
owners/outcomes are excluded and reported. Unknown outcomes do not enter the FGA
denominator. Missing identities produce no invented per-player percentage. Even
valid linked counts are named a reviewed sample; full-game FG% remains unset
until exhaustive attempt coverage is established. Handling free throws or
official statkeeper exceptions is outside this temporary developer review.

## BHE outcome suggestions before human review

The shooter pipeline does not infer made/missed outcomes. Before review, run the
same dense rim check used by the desktop engine, then attach its suggestions to
a separate copy of the shooter predictions:

```bash
python scripts/verify_rim_crossing.py \
  --video game.mp4 --model models/bball_model.pt \
  --candidates evaluation-candidates.json --output rim-checks.json --device mps
python scripts/prepare_shooter_outcomes.py \
  --predictions predictions.json --candidates evaluation-candidates.json \
  --rim-checks rim-checks.json --output predictions-with-outcomes.json
python scripts/review_shooters.py \
  --predictions predictions-with-outcomes.json --video review.mp4 \
  --labels human-labels.json
```

The preparation script expects the candidate IDs, source-coordinate rims and
`anchor_source` (`existing_refined` or `existing_coarse_fallback`) retained by the
evaluation dataset. It verifies candidate identity, millisecond event times and
the source-video fingerprint. It invokes the engine's `apply_rim_checks`, including
video-wide occlusion and `keep_unless_seen`, rather than mapping every raw
rejection to a miss. The original shooter predictions are preserved.

Each `outcome_prediction` is explicitly machine generated and unconfirmed.
Engine `made` prefills Made, final `rejected` prefills Missed, and `unsure` or
`skipped` remains unknown. A rejected basket can be a missed attempt or a false
candidate; only the reviewer decides whether it was a shot. Shooter attribution
is retained in either case until a human explicitly labels a non-shot.

The UI labels suggestions as BHE output and prefills only unreviewed events.
Saved human outcomes, including unknown or non-shot, always take precedence.
Adding suggestions creates no human label and does not increase reviewed counts
or enter accuracy/field-goal metrics. Human review is still required to measure
outcome accuracy and shooter accuracy independently.

## Export a completed review for another development task

`scripts/export_shooter_review_dataset.py` requires a complete, unique review
whose candidate IDs and tracking scopes exactly match the predictions. It creates
a new private directory and refuses to overwrite an existing one:

```bash
python scripts/export_shooter_review_dataset.py \
  --predictions predictions-with-outcomes.json --labels human-labels.json \
  --output local-review-data/review-snapshot
```

The export preserves original human labels and predictions, then writes separate
outcome-only JSONL/CSV, wrong binary decisions, resolved unknowns, shooter errors
and unknowns, input hashes and metrics. Outcome-only records do not depend on
temporary shooter IDs. A machine abstention resolved by a reviewer is not a wrong
binary decision. Non-shots and unresolved human outcomes are excluded from binary
outcome accuracy and retained as distinct categories. Report decision accuracy,
decision coverage and the correct fraction of all reviewed outcomes separately.
Private snapshots, clips and local prompts under `local-review-data/` are ignored
by Git. They do not establish exhaustive attempt recall, physical-shot
deduplication or a full-game field-goal percentage.
