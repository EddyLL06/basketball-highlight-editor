# Lightweight release-area quick labeling

This replaces full-frame person detection in the semi-automatic desktop workflow.
The user's task is to recognize a shooter in a still, not validate a machine
identity. The normal quick-label path therefore performs no person inference,
player tracking or additional ball inference. Standalone attribution experiments
and explicit prediction import remain available separately.

Reuse the current analysis proxy and its source-time offset. Read existing BHE
ball trajectories in source coordinates, locate a sustained upward-motion segment,
and display a generous area around its beginning plus adjacent proxy frames.
When the existing track begins mid-flight, a bounded quadratic fit can suggest
an earlier view. A descending-to-rising rim bounce splits the motion segment so
the rebound is not mistaken for the original release. The fit and the approximate
release-height band are heuristics; they do not identify a player or prove an
exact hand-ball separation time.
These are approximate release areas, not detected-person boxes. Missing release
evidence produces a clearly uncertain wide view; it never invents a shooter.

During standard analysis, coarse candidates produce read-only draft cards before
refinement starts. They can be viewed while refinement continues. Final cards and
candidates commit together after successful analysis. Drafts cannot accept player
labels, and cancellation/failure retains the previous committed project data.
Fast analysis creates its cards within the same analysis job at finalization.

Existing projects can fill or refresh stills from their cached analysis proxy.
If that cache is unavailable, extract only the requested source stills without
running any detector. Trim offsets, source fingerprints, coordinate scales and
evidence generations are validated. Manual labels and shot outcomes remain
independent. No nearest-time transfer of human shooter selections is introduced.
