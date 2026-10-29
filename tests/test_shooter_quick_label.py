"""Contact-sheet integration: real frames, independent labels, atomic reruns."""

import copy
import json
import threading
import time
from pathlib import Path

import cv2
import numpy as np
import pytest

from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore
from engine.python.basketball_engine.shooter_review import (
    persist_evidence,
    render_evidence,
    shooter_candidate_inputs,
)


@pytest.fixture
def sheet(tmp_path):
    source = tmp_path / "two-players.avi"
    writer = cv2.VideoWriter(
        str(source), cv2.VideoWriter_fourcc(*"MJPG"), 30, (320, 240)
    )
    assert writer.isOpened()
    for _ in range(90):
        image = np.full((240, 320, 3), (40, 80, 120), dtype=np.uint8)
        image[50:210, 30:100] = (30, 30, 230)
        image[50:210, 220:290] = (30, 230, 30)
        cv2.circle(image, (149, 28), 8, (30, 230, 230), -1)
        writer.write(image)
    writer.release()
    service = EngineService()
    root = tmp_path / "project"
    service.handle("create_project", {"name": "Quick label", "root_path": str(root)})
    store = ProjectStore(root)
    video = store.link_video(
        {
            "source_path": str(source),
            "source_size_bytes": source.stat().st_size,
            "source_mtime_ns": source.stat().st_mtime_ns,
            "duration_ms": 3000,
            "width": 320,
            "height": 240,
            "fps": 30,
        }
    )
    candidates = [
        {
            "id": f"c{i}",
            "video_id": video["id"],
            "event_time_ms": event,
            "default_start_ms": 0,
            "default_end_ms": 3000,
            "review_start_ms": 0,
            "review_end_ms": 3000,
            "detector_version": "fixture",
            "evidence_json": "{}",
        }
        for i, event in enumerate((1800, 2600))
    ]
    store.replace_candidates(video["id"], candidates)
    player = store.create_player("Red")
    fingerprint = {
        "name": source.name,
        "size": source.stat().st_size,
        "mtime_ns": source.stat().st_mtime_ns,
    }
    predictions = {
        "video_fingerprint": fingerprint,
        "frame_width": 320,
        "frame_height": 240,
        "sessions": [
            {
                "tracking_scope": "s1",
                "tracks": [
                    {
                        "track_id": tid,
                        "observations": [
                            {"timestamp": i / 30, "bbox": box} for i in range(90)
                        ],
                    }
                    for tid, box in ((1, [30, 50, 100, 210]), (2, [220, 50, 290, 210]))
                ],
            }
        ],
        "results": [
            {
                "candidate_id": c["id"],
                "event_time_ms": c["event_time_ms"],
                "tracking_scope": "s1",
                "status": "attributed",
                "method": "fixture",
                "shooter": {"track_id": 1, "release_time_ms": c["event_time_ms"] - 700},
            }
            for c in candidates
        ],
    }
    data = dict(
        service=service,
        store=store,
        root=root,
        source=source,
        video=video,
        candidates=candidates,
        player=player,
        predictions=predictions,
    )
    try:
        yield data
    finally:
        service.shutdown()


def render(sheet, generation="g1"):
    return render_evidence(
        sheet["predictions"],
        sheet["source"],
        sheet["candidates"],
        sheet["root"] / generation,
        generation,
        threading.Event(),
        lambda _: None,
    )


def label_payload(sheet, evidence, **extra):
    frame = evidence[0]["frames"][1]
    return {
        "project_root": str(sheet["root"]),
        "candidate_id": "c0",
        "generation": evidence[0]["generation"],
        "time_ms": frame["time_ms"],
        "track_id": 1,
        "player_id": sheet["player"]["id"],
        "review_state": "confirmed",
        **extra,
    }


def test_engine_rim_coordinates_are_accepted_by_attribution_cli(sheet):
    from src.basketball_highlight.shooter_attribution import load_scoring_events

    candidate = dict(sheet["candidates"][0])
    candidate["evidence_json"] = json.dumps(
        {"overlay": {"rim": {"center_x": 180.5, "rim_y": 45.25, "width": 30}}}
    )
    rows = shooter_candidate_inputs(sheet["service"], sheet["store"], [candidate])
    event = load_scoring_events({"candidates": rows})[0]
    assert event.candidate_id == candidate["id"]
    assert event.timestamp == candidate["event_time_ms"] / 1000
    assert event.rim == {"center_x": 180.5, "rim_y": 45.25, "width": 30}


def test_real_frames_preserve_people_and_context(sheet):
    evidence = render(sheet)
    assert len(evidence) == 2
    assert len(evidence[0]["frames"]) == 3
    for frame in evidence[0]["frames"]:
        assert {p["track_id"] for p in frame["people"]} == {1, 2}
        assert cv2.imread(frame["context_path"]).shape[:2] == (240, 320)
        red, green = [cv2.imread(p["crop_path"]) for p in frame["people"]]
        assert red[:, :, 2].mean() > red[:, :, 1].mean()
        assert green[:, :, 1].mean() > green[:, :, 2].mean()
        # The released ball/raised arm can be outside the body detector box.
        assert ((red[:, :, 1] > 180) & (red[:, :, 2] > 180)).sum() > 30
        assert all(
            Path(p["crop_path"]).is_relative_to(sheet["root"]) for p in frame["people"]
        )


def test_shooter_save_preserves_miss_exclusion_note_and_reopens(sheet):
    evidence = render(sheet)
    persist_evidence(sheet["store"], evidence)
    sheet["store"].review_candidate(
        "c0", "excluded", note="miss; correct tracking", reason="rim_out"
    )
    sheet["service"].handle("set_candidate_shooter", label_payload(sheet, evidence))
    reopened = EngineService()
    try:
        result = reopened.handle(
            "list_shooter_review", {"project_root": str(sheet["root"])}
        )
        row = next(r for r in result["candidates"] if r["id"] == "c0")
        assert row["player_id"] == sheet["player"]["id"]
        assert row["review_status"] == "excluded"
        assert row["review_reason"] == "rim_out"
        assert row["note"] == "miss; correct tracking"
        assert row["shooter_review_state"] == "confirmed"
        assert row["shooter_selection"]["tracking_scope"] == "s1"
        assert row["shooter_selection"]["track_id"] == 1
    finally:
        reopened.shutdown()


@pytest.mark.parametrize(
    "change",
    [
        {"generation": "old"},
        {"track_id": 999},
        {"time_ms": -1},
        {"player_id": "foreign-player"},
        {"review_state": "uncertain"},
        {"track_id": True},
        {"review_state": "confirmed", "player_id": None},
    ],
)
def test_invalid_or_stale_selection_is_rejected_without_writes(sheet, change):
    evidence = render(sheet)
    persist_evidence(sheet["store"], evidence)
    with pytest.raises(ProtocolError):
        sheet["service"].handle(
            "set_candidate_shooter", label_payload(sheet, evidence, **change)
        )
    result = sheet["service"].handle(
        "list_shooter_review", {"project_root": str(sheet["root"])}
    )
    assert result["candidates"][0]["player_id"] is None
    assert result["candidates"][0]["shooter_review_state"] == "pending"


def test_rerun_preserves_human_label_but_rejects_old_generation(sheet):
    first = render(sheet)
    persist_evidence(sheet["store"], first)
    sheet["service"].handle("set_candidate_shooter", label_payload(sheet, first))
    persist_evidence(sheet["store"], render(sheet, "g2"))
    with pytest.raises(ProtocolError, match="刷新"):
        sheet["service"].handle("set_candidate_shooter", label_payload(sheet, first))
    result = sheet["service"].handle(
        "list_shooter_review", {"project_root": str(sheet["root"])}
    )
    row = result["candidates"][0]
    assert row["player_id"] == sheet["player"]["id"]
    assert row["shooter_selection"]["generation"] == "g1"
    assert row["shooter_evidence"]["generation"] == "g2"


def test_atomic_persistence_rejects_changed_candidate_without_partial_commit(sheet):
    first = render(sheet)
    persist_evidence(sheet["store"], first)
    changed = copy.deepcopy(first)
    changed[0]["generation"] = "partial"
    changed[1]["event_time_ms"] += 1
    with pytest.raises(ProtocolError):
        persist_evidence(sheet["store"], changed)
    with sheet["store"].connect() as connection:
        assert {
            row[0]
            for row in connection.execute(
                "SELECT generation FROM shooter_review_evidence"
            )
        } == {"g1"}


@pytest.mark.parametrize("change", ["fingerprint", "candidate", "time", "scope"])
def test_import_requires_same_source_candidates_times_and_scopes(sheet, change):
    prediction = sheet["predictions"]
    if change == "fingerprint":
        prediction["video_fingerprint"]["size"] += 1
    if change == "candidate":
        prediction["results"][0]["candidate_id"] = "other"
    if change == "time":
        prediction["results"][0]["event_time_ms"] += 1
    if change == "scope":
        prediction["results"][0]["tracking_scope"] = "other"
    with pytest.raises(ProtocolError):
        render(sheet)


def test_missing_tracks_have_context_and_uncertain_release(sheet):
    for result in sheet["predictions"]["results"]:
        result.update(status="unknown", shooter=None, rankings=[])
    sheet["predictions"]["sessions"][0]["tracks"] = []
    result = render(sheet)
    assert all(
        e["release_uncertain"] and e["recommended_track_id"] is None for e in result
    )
    assert result[0]["frames"][1]["people"] == []
    assert Path(result[0]["frames"][1]["context_path"]).is_file()


def test_import_worker_completes_and_failed_rerun_keeps_evidence(sheet, tmp_path):
    path = tmp_path / "prediction.json"
    path.write_text(json.dumps(sheet["predictions"]))
    payload = {
        "project_root": str(sheet["root"]),
        "video_id": sheet["video"]["id"],
        "predictions_path": str(path),
    }

    def run():
        job_id = sheet["service"].handle("prepare_shooter_review", payload)["job"]["id"]
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            job = sheet["store"].get_job(job_id)
            if job["state"] in {"failed", "completed", "cancelled"}:
                # The worker removes its lock bookkeeping just after storing the terminal state.
                for thread in list(sheet["service"]._job_threads.values()):
                    thread.join(1)
                return job
            time.sleep(0.02)
        pytest.fail("Quick-label worker did not finish")

    assert run()["state"] == "completed"
    before = sheet["service"].handle(
        "list_shooter_review", {"project_root": str(sheet["root"])}
    )["candidates"]
    path.write_text("{invalid")
    assert run()["state"] == "failed"
    after = sheet["service"].handle(
        "list_shooter_review", {"project_root": str(sheet["root"])}
    )["candidates"]
    assert before == after


def test_cancelled_render_and_other_heavy_job_leave_original_evidence(sheet):
    first = render(sheet)
    persist_evidence(sheet["store"], first)
    cancel = threading.Event()
    cancel.set()
    from engine.python.basketball_engine.adapters.analysis import PipelineCancelled

    with pytest.raises(PipelineCancelled):
        render_evidence(
            sheet["predictions"],
            sheet["source"],
            sheet["candidates"],
            sheet["root"] / "cancelled",
            "cancelled",
            cancel,
            lambda _: None,
        )
    sheet["store"].create_job(
        sheet["store"].project()["id"], sheet["video"]["id"], "analysis"
    )
    with pytest.raises(ProtocolError, match="现有"):
        sheet["service"].handle(
            "prepare_shooter_review", {"project_root": str(sheet["root"])}
        )
    assert (
        sheet["service"].handle(
            "list_shooter_review", {"project_root": str(sheet["root"])}
        )["candidates"][0]["shooter_evidence"]["generation"]
        == "g1"
    )


def test_source_change_hides_frames_and_blocks_label(sheet):
    evidence = render(sheet)
    persist_evidence(sheet["store"], evidence)
    sheet["source"].write_bytes(b"changed video")
    result = sheet["service"].handle(
        "list_shooter_review", {"project_root": str(sheet["root"])}
    )
    assert result["candidates"][0]["shooter_evidence"] is None
    assert result["candidates"][0]["shooter_evidence_stale"] is True
    with pytest.raises(ProtocolError):
        sheet["service"].handle("set_candidate_shooter", label_payload(sheet, evidence))
