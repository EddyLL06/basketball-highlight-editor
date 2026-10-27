import json
import subprocess
from pathlib import Path

import pytest

from engine.python.basketball_engine.adapters import export
from engine.python.basketball_engine.adapters.analysis import PipelineCancelled
from engine.python.basketball_engine.media_tools import resolve_media_tool


@pytest.fixture
def sources(tmp_path):
    paths = []
    for audio in (True, False):
        path = tmp_path / f'source_{audio}.mp4'
        subprocess.run([
            resolve_media_tool('ffmpeg'), '-v', 'error', '-y',
            '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=30',
            *(['-f', 'lavfi', '-i', 'sine=frequency=440'] if audio else []),
            '-t', '6', '-c:v', 'mpeg4', *(['-c:a', 'aac'] if audio else []), str(path),
        ], check=True)
        paths.append(path)
    return paths


def candidate(source, start, end, **metadata):
    return {
        'source_path': str(source), 'review_start_ms': start, 'review_end_ms': end,
        'event_time_ms': start + 500, 'width': 160, 'height': 120, **metadata,
    }


def probe(path):
    return json.loads(subprocess.run([
        resolve_media_tool('ffprobe'), '-v', 'error', '-show_format', '-show_streams',
        '-of', 'json', str(path),
    ], check=True, capture_output=True, text=True).stdout)


@pytest.mark.parametrize('ranges,expected,count', [
    ([(0, 2000), (1000, 3000)], 3000, 1),
    ([(0, 1000), (1000, 2000)], 2000, 1),
    ([(0, 2000), (1000, 3000), (2500, 4000)], 4000, 2),
    ([(0, 1000), (2000, 3000)], 2000, 0),
    ([(2000, 4000), (0, 2500), (500, 1000)], 4000, 2),
])
def test_merge_exports_union(sources, tmp_path, ranges, expected, count):
    candidates = [candidate(sources[0], start, end) for start, end in ranges]
    progress = []
    result = export.export_goal_clips(candidates, tmp_path / 'out', 'merge',
                                      progress_callback=lambda stage, value: progress.append((stage, value)))
    assert result['merged_overlap_count'] == count
    assert result['duration_ms'] == expected
    assert len(result['clip_files']) == len(ranges) - count
    assert float(probe(result['files'][0])['format']['duration']) == pytest.approx(expected / 1000, abs=0.15)
    assert [value for stage, value in progress if stage == 'export_clips'] == [
        index / (len(ranges) - count) for index in range(1, len(ranges) - count + 1)
    ]
    assert candidates[0]['review_start_ms'] == ranges[0][0]


@pytest.mark.parametrize('mode,effect', [('separate', 'none'), ('merge', 'approach'), ('merge', 'replay')])
def test_other_export_modes_preserve_clips(sources, tmp_path, mode, effect):
    # Manual clips still must not merge when an effect is selected.
    clips = [candidate(sources[0], 0, 2000, manual=True), candidate(sources[0], 1000, 3000, manual=True)]
    result = export.export_goal_clips(clips, tmp_path / 'out', mode, effect=effect)
    assert result['merged_overlap_count'] == 0
    assert len(result['clip_files']) == 2
    assert result['duration_ms'] == 4000


def test_sources_stay_separate_with_mixed_audio(sources, tmp_path):
    result = export.export_goal_clips([
        candidate(sources[0], 0, 2000), candidate(sources[1], 0, 2000, has_audio=False),
    ], tmp_path / 'out', 'merge')
    assert result['merged_overlap_count'] == 0
    assert len(result['clip_files']) == 2
    assert float(probe(result['files'][0])['format']['duration']) == pytest.approx(4, abs=0.15)


def test_merged_audio_uses_all_members_and_first_metadata(sources, tmp_path):
    clips = [candidate(sources[0], 1000, 3000, player_name='first'),
             candidate(sources[0], 0, 2000, has_audio=False, player_name='second')]
    result = export.export_goal_clips(clips, tmp_path / 'out', 'merge')
    assert result['merged_overlap_count'] == 1
    assert 'first' in result['clip_files'][0]
    assert not any(stream['codec_type'] == 'audio' for stream in probe(result['files'][0])['streams'])


def test_groups_preserve_first_input_position_and_metadata():
    clips = [candidate('a', 4000, 5000, player_name='first'), candidate('b', 0, 1000),
             candidate('a', 0, 1000), candidate('a', 500, 4500, player_name='last')]
    merged = export.merge_overlapping_candidates(clips)
    assert [(clip['source_path'], clip['review_start_ms'], clip['review_end_ms']) for clip in merged] == [
        ('a', 0, 5000), ('b', 0, 1000),
    ]
    assert merged[0]['player_name'] == 'first'


@pytest.mark.parametrize('cancel', [False, True])
def test_failed_or_cancelled_merge_cleans_outputs(sources, tmp_path, cancel):
    clips = [candidate(sources[0], 0, 1000), candidate(sources[0] if cancel else tmp_path / 'missing.mp4', 2000, 3000)]
    cancelled = False

    def progress(stage, value):
        nonlocal cancelled
        if stage == 'export_clips':
            cancelled = True

    out = tmp_path / 'out'
    with pytest.raises(PipelineCancelled if cancel else subprocess.CalledProcessError):
        export.export_goal_clips(clips, out, 'merge', progress_callback=progress,
                                 cancel_check=(lambda: cancelled) if cancel else None)
    assert not list(out.glob('*.mp4'))
    assert not list(out.glob('*.part*'))


@pytest.mark.parametrize('start,end', [(-1, 1000), (2000, 1000), (1000, 1000)])
def test_merge_preserves_invalid_range_validation(start, end, tmp_path):
    with pytest.raises(ValueError, match='INVALID_CLIP_RANGE'):
        export.export_goal_clips([
            candidate('source.mp4', 0, 3000), candidate('source.mp4', start, end),
        ], tmp_path / 'out', 'merge')


def test_cancel_after_concat_cleans_all_created_files(sources, tmp_path):
    def progress(stage, fraction):
        if stage == 'merge_clips':
            raise PipelineCancelled('JOB_CANCELLED')

    out = tmp_path / 'out'
    with pytest.raises(PipelineCancelled):
        export.export_goal_clips([candidate(sources[0], 0, 2000), candidate(sources[0], 1000, 3000)],
                                 out, 'merge', progress_callback=progress)
    assert not list(out.iterdir())
