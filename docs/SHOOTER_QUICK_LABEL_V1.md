# Shooter quick labeling (desktop preview)

**Current semi-automatic path:** see [lightweight release-area previews](SHOOTER_RELEASE_PREVIEW.md).
Normal analysis now prepares stills from its existing low-resolution proxy and
ball trajectories, without person detection or an additional inference pass.
Coarse proposals appear as read-only previews during refinement; final cards
commit together with the candidates. The person-track/import behavior described
below is retained for compatibility with earlier developer artifacts.

The Review module contains two inline subpages: **进球审核 / Basket review**
(selected by default) and **射手快标 / Shooter quick label**. Both tabs stay at
the left of the same toolbar and use the existing BHE orange selected state.
Switching pauses playback, keeps each page's selection/filters, and refreshes
the ordinary review labels when returning. Watch clip selects that candidate
in Basket review without closing or navigating away from the Review module.

The approved [HTML layout prototype](prototypes/shooter-quick-label-five-column.html)
uses five portrait cards per row at desktop widths. Each card gives one still a
3:4 image area and displays the middle frame by default. Previous / Middle / Next
buttons switch that one image when needed; a saved human-selected frame is
restored instead of being silently replaced. The selected frame remains the
evidence saved with the player label. Existing observed rising-ball
crops receive a small display-only enlargement, while extrapolated or missing
release regions retain their wider context. Full-context viewing remains one
click away and no image regeneration or extra inference is required.

Every card always offers **Add player** next to its player-name controls,
including when the roster is empty or already populated. Both review subpages
reuse the original BHE text-entry dialog and create-player command. Creating a
player from a final card assigns that player to that shot with its selected
frame; creating from the toolbar only adds a roster name. Draft cards remain
read-only. Hidden subpages cannot consume keyboard labeling shortcuts, and
module switching is disabled while a shooter label is being saved.

The review workspace adds a static shooter contact sheet. Each candidate has a
proxy still near the estimated release, a generous release-area crop, nearby
frames and project-player buttons. Human labels are saved through the Engine.
Made/missed and inclusion decisions remain independent. Explicit legacy imports
can also display the earlier tracked-person crops.

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
The macOS preview artifact supplies the existing BHE ball runtime. Lightweight
release stills require no additional model; explicit import can reuse earlier
attribution JSON without running a detector.

The preview workflow reuses the existing macOS runtime/build scripts on GitHub
Actions. SDK installation and packaging run on the hosted runner. Preview
artifacts are for local validation; no production Release or OSS publication is
performed by this feature branch workflow.

## Local validation

Open a project in the desktop app, complete candidate analysis, then choose
**射手快标 / Shooter quick label** in Review. Add roster names if needed and choose
**Refresh stills** for an existing project that needs its images filled. New
analysis prepares these automatically. Select an adjacent frame or full context
when the suggested release is ambiguous. Click a name to save immediately. **Uncertain**
and **Clear** explicitly remove the player label; **Undo** restores the last
successful label change in this page. **Watch clip** returns to ordinary video
review. The same project-player labels drive the existing player export filters.

Preparation can cover a selected video or all project videos. The page can be
closed while its job runs; reopen it to resume progress polling. A cancelled or
interrupted job can be cancelled from the page before starting another one.
Images belong to the project folder, which should remain private alongside its
source footage. No cross-clip identity propagation is inferred from Track IDs.

## GitHub-only macOS build

The existing `.github/workflows/release-packages.yml` accepts an optional
`source_ref` for a branch/SHA preview, guarded by `publish=false` and
`publish_oss=false`. Keep `dry_run=false` (the upstream dry-run feature rehearses
production-channel publication and has different prerequisites). Set
`include_shooter=true` and `platform=macos`; use a preview tag-shaped version
such as `v0.1.13-shooter.1`. No Git tag needs to be created for a SHA preview.
The two macOS architectures reuse the upstream portable runtime, FFmpeg,
Flutter build, ad-hoc signing and DMG scripts. Flutter analysis and widget tests
run on the GitHub runners. No SDK installation or app compilation is needed on
the local development machine. Model source and checksum are recorded in
[the shooter model notice](SHOOTER_MODEL_NOTICES.md).

The preview is a semi-automatic labeling interface, not a new accuracy claim.
The frozen v4 automatic algorithm remains unchanged, and crowded multi-player
footage still requires independent validation.
