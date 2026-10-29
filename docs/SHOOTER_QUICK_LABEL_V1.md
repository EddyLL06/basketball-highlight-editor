# Shooter quick labeling (desktop preview)

The review workspace adds a static shooter contact sheet. Each candidate has a
source-video frame near the estimated release, selectable tracked-person crops,
three nearby frames and project-player buttons. Human labels are saved through
the Engine. Made/missed and inclusion decisions remain independent.

Acceptance: generate or import evidence; label a player in one click; select an
alternative track/frame; mark uncertain; undo; reopen the project and retain
labels; open a difficult candidate in video review. A release estimate is marked
uncertain when automatic support is insufficient. Unknown track IDs never become
global person identities. A keyboard route and text status accompany every action.

New Engine commands: `list_shooter_review`, `prepare_shooter_review`, and
`set_candidate_shooter`. Preparation is a cancellable `shooter_review` heavy job,
mutually exclusive with analysis/export. It handles all project video segments,
or one explicit video. Optional prediction import requires exact source
fingerprint, candidate IDs and source event times. No nearest-time label transfer.

The additive `shooter_review_evidence` table stores generated evidence separately
from human selections. `candidate_reviews.player_id` remains the authoritative
project-player label used by existing review/export. Saving both is transactional.
Regenerating images preserves human player labels and retains selection provenance;
a stale generation cannot overwrite a newer result. Failed/cancelled preparation
does not replace existing evidence. All images are local project artifacts.

Image caching includes source fingerprint, candidate event, generation and source
frame. Frames and boxes use original decoded pixel coordinates. Crops include
hands/ball context, and the full frame retains blue track boxes. Missing imagery
is explicit, with video review available. Preparation never downloads models.
The macOS preview artifact supplies the existing ball model and a pinned local
person detector; development import can reuse existing attribution JSON.

The preview workflow reuses the existing macOS runtime/build scripts on GitHub
Actions. SDK installation and packaging run on the hosted runner. Preview
artifacts are for local validation; no production Release or OSS publication is
performed by this feature branch workflow.
