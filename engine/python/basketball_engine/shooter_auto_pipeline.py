"""Independent, cached release-person analysis on the existing video proxy."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from .adapters.analysis import PipelineCancelled
from .person_candidates import PERSON_MODEL_SHA256, person_search_region
from .protocol import ProtocolError
from .release_preview import read_json, source_fingerprint
from . import release_shooter

PIPELINE_VERSION = "desktop_proxy_release_v1"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, allow_nan=False).encode()).hexdigest()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False))
    temporary.replace(path)


class ProxyReleaseAnalyzer:
    def __init__(self, proxy, source, video, context, directory, person_detector,
                 ball_factory, cancel, progress):
        import cv2

        self.cv2, self.source, self.video = cv2, Path(source), video
        self.proxy, self.context = Path(proxy), context
        if self.proxy.resolve() == self.source.resolve():
            raise ProtocolError("PERSON_PROXY_REQUIRED", "请先完成视频分析，自动识别只使用分析代理")
        self.capture = cv2.VideoCapture(str(self.proxy))
        self.fps = float(self.capture.get(cv2.CAP_PROP_FPS))
        self.count = int(self.capture.get(cv2.CAP_PROP_FRAME_COUNT))
        pw, ph = (int(self.capture.get(p)) for p in (cv2.CAP_PROP_FRAME_WIDTH, cv2.CAP_PROP_FRAME_HEIGHT))
        if not self.capture.isOpened() or min(self.fps, self.count, pw, ph) <= 0:
            self.capture.release()
            raise ProtocolError("SHOOTER_FRAME_MISSING", "无法读取分析代理，请重新分析视频")
        self.resize = min(1.0, 960 / pw, 540 / ph)
        self.width, self.height = round(pw * self.resize), round(ph * self.resize)
        self.step = max(1, round(self.fps / 5))
        self.offset = context['offset_ms'] / 1000
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.person_detector, self.ball_factory = person_detector, ball_factory
        self.cancel, self.progress = cancel, progress
        self.ball_model = None
        self.ball_records = {}
        self.signature = {
            'method': PIPELINE_VERSION,
            'algorithm': hashlib.sha256(Path(release_shooter.__file__).read_bytes()).hexdigest(),
            'person_model': PERSON_MODEL_SHA256,
            'source': source_fingerprint(self.source),
            'proxy': source_fingerprint(self.proxy),
            'offset_ms': context['offset_ms'],
            'size': [self.width, self.height], 'fps': self.fps,
        }
        self.ball_cache = self.directory / 'balls.json'
        cached = read_json(self.ball_cache, {})
        if cached.get('signature') == self.signature:
            self.ball_records = cached.get('records', {})

    def check(self):
        if self.cancel.is_set():
            raise PipelineCancelled("JOB_CANCELLED")

    def close(self):
        self.capture.release()

    def read(self, index):
        self.check()
        self.capture.set(self.cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = self.capture.read()
        if not ok:
            raise ProtocolError("SHOOTER_FRAME_MISSING", "分析代理中的出手画面读取失败")
        if self.resize < 1:
            frame = self.cv2.resize(frame, (self.width, self.height))
        return frame

    def window(self, event):
        start = max(0, math.floor((event - self.offset - 3.6) * self.fps))
        end = min(self.count - 1, math.ceil((event - self.offset + .3) * self.fps))
        return list(range(start, end + 1, self.step))

    def ball_scan(self, indices, expanded=False):
        missing = [i for i in indices if str(i) not in self.ball_records or (
            expanded and not self.ball_records[str(i)].get('expanded'))]
        for ordinal, index in enumerate(missing):
            self.check()
            if self.ball_model is None:
                self.ball_model, self.device, self.classes = self.ball_factory()
            frame = self.read(index)
            regions = release_shooter.expanded_ball_regions(self.width, self.height) if expanded else [
                (0, 0, self.width, self.height)]
            balls = list(self.ball_records.get(str(index), {}).get('balls', [])) if expanded else []
            for left, top, right, bottom in regions:
                self.check()
                result = self.ball_model.predict(frame[top:bottom, left:right], device=self.device,
                    imgsz=640, conf=.1, classes=self.classes, rect=False, max_det=12, verbose=False)[0]
                for box in result.boxes:
                    if int(box.cls[0]) not in self.classes:
                        continue
                    a, b, c, d = box.xyxy[0].tolist()
                    balls.append({'bbox': [a + left, b + top, c + left, d + top],
                        'x': (a + c) / 2 + left, 'y': (b + d) / 2 + top,
                        'confidence': float(box.conf[0])})
            kept = []
            for ball in sorted(balls, key=lambda p: -p['confidence']):
                if not any(math.hypot(ball['x'] - old['x'], ball['y'] - old['y']) < 4 for old in kept):
                    kept.append(ball)
            self.ball_records[str(index)] = {'frame_index': index,
                'time': self.offset + index / self.fps, 'balls': kept, 'expanded': expanded}
            if ordinal % 10 == 0:
                self.progress((ordinal + 1) / max(1, len(missing)), 'shooter_ball')
        if missing:
            atomic_json(self.ball_cache, {'signature': self.signature, 'records': self.ball_records})

    def rim(self, candidate):
        coarse = self.context.get('coarse') or {}
        if coarse.get('rim') and (not coarse.get('video') or Path(coarse['video']).resolve() == self.proxy.resolve()):
            return {k: float(v) * self.resize for k, v in coarse['rim'].items()
                    if k in ('center_x', 'rim_y', 'width', 'height')}
        evidence = json.loads(candidate.get('evidence_json') or '{}')
        rim = (evidence.get('overlay') or {}).get('rim') or {}
        return {k: float(v) * (self.height / self.video['height'] if k in ('rim_y', 'height')
                              else self.width / self.video['width']) for k, v in rim.items()
                if k in ('center_x', 'rim_y', 'width', 'height')}

    def cache_key(self, candidate):
        return digest({**self.signature, 'candidate': candidate['id'], 'event': candidate['event_time_ms'],
                       'rim': self.rim(candidate)})

    def analyze(self, candidate):
        key = self.cache_key(candidate)
        target = self.directory / key
        existing = read_json(target / 'observation.json', {})
        if existing.get('generation') == key and all(Path(s['crop_path']).is_file()
                and Path(s['context_path']).is_file() for t in existing.get('tracks', []) for s in t['samples']):
            return existing
        target.mkdir(parents=True, exist_ok=True)
        event = candidate['event_time_ms'] / 1000
        indices = self.window(event)
        self.ball_scan(indices)
        result = self._people(candidate, target, key, indices, False)
        if result['selected_track_id'] is None:
            self.ball_scan(indices, expanded=True)
            result = self._people(candidate, target, key, indices, True)
        self.check()
        atomic_json(target / 'observation.json', result)
        return result

    def _people(self, candidate, directory, generation, indices, expanded):
        event = candidate['event_time_ms'] / 1000
        records = [self.ball_records[str(i)] for i in indices]
        rim = self.rim(candidate)
        flight = None
        if all(k in rim for k in ('center_x', 'rim_y', 'width')):
            flight = release_shooter.fit_ball_flight(records, event_time=event, rim=rim,
                frame_size=(self.width, self.height), expanded=expanded, earlier_rim_seconds=2.6)
            flight = release_shooter.refine_release_anchor(flight, records, frame_size=(self.width, self.height))
            flight = release_shooter.with_release_contacts(flight, records, frame_size=(self.width, self.height))
        hint = flight['launch'] if flight else {'time': event - 1.3, 'x': None, 'y': None}
        center = round((hint['time'] - self.offset) * self.fps)
        frame_indices = sorted({max(0, min(self.count - 1, center + d * self.step)) for d in (-2, -1, 0, 1, 2)})
        region = None
        if flight:
            w, h = self.width * .38, self.height * .76
            left = max(0, min(self.width - w, hint['x'] - w / 2))
            top = max(0, min(self.height - h, hint['y'] - self.height * .27))
            region, _ = person_search_region([left, top, left + w, top + h], self.width, self.height,
                release_point=(hint['x'], hint['y']), basis='upward_ball_motion_estimate'
                if hint.get('observed') else 'existing_ball_flight_backprojection')
        frames = []
        for index in frame_indices:
            image = self.read(index)
            people = self.person_detector.infer(image, region,
                release_point=(hint['x'], hint['y']) if flight else None, cancel=self.cancel)['people']
            for number, person in enumerate(people, 1):
                person['id'] = f"{generation}:{index}:{number}"
                path = directory / f'{index}-person-{number}.jpg'
                x1, y1, x2, y2 = person['bbox']
                if not self.cv2.imwrite(str(path), image[y1:y2, x1:x2]):
                    raise OSError('Could not save proxy person crop')
                person['crop_path'] = str(path)
            path = directory / f'{index}-context.jpg'
            if not self.cv2.imwrite(str(path), image):
                raise OSError('Could not save proxy context')
            frames.append({'time': self.offset + index / self.fps, 'frame_index': index,
                           'people': people, 'context_path': str(path)})
        decision = release_shooter.select_release_shooter(frames, flight)
        evidence = decision['rankings'][0]['evidence_frame'] if decision['rankings'] else None
        display = evidence['time'] if evidence else hint['time']
        for frame in frames:
            image = self.cv2.imread(frame['context_path'])
            for track in decision['tracks']:
                person = next((p for p in track['observations'] if p['time'] == frame['time']), None)
                if person:
                    x1, y1, x2, y2 = person['bbox']
                    color = (235, 145, 45) if track['id'] == decision['selected_track_id'] else (70, 175, 80)
                    self.cv2.rectangle(image, (x1, y1), (x2, y2), color, 2)
                    self.cv2.putText(image, 'P' + str(track['id']), (x1, max(16, y1 - 5)),
                                     self.cv2.FONT_HERSHEY_SIMPLEX, .6, color, 2)
            annotated = directory / f"{frame['frame_index']}-annotated.jpg"
            if not self.cv2.imwrite(str(annotated), image):
                raise OSError('Could not save annotated proxy context')
            frame['annotated_path'] = str(annotated)
        frame_map = {round(f['time'], 3): f for f in frames}
        tracks = []
        for track in decision['tracks']:
            observations = sorted(track['observations'],
                key=lambda p: (-p['confidence'], abs(p['time'] - display)))[:3]
            observations.sort(key=lambda p: abs(p['time'] - display))
            samples = []
            for obs in observations:
                image = self.cv2.imread(obs['crop_path'])
                if image is None or image.shape[0] < 32 or image.shape[1] < 8:
                    continue
                sample_id = hashlib.sha256((candidate['id'] + obs['id']).encode()).hexdigest()[:24]
                samples.append({'id': sample_id, 'shot_id': candidate['id'], 'track_id': track['id'],
                    'time_ms': round(obs['time'] * 1000), 'bbox': obs['bbox'], 'confidence': obs['confidence'],
                    'crop_path': obs['crop_path'], 'context_path': frame_map[round(obs['time'], 3)]['annotated_path']})
            tracks.append({'id': track['id'], 'samples': samples})
        return {'candidate_id': candidate['id'], 'video_id': candidate['video_id'],
            'event_time_ms': candidate['event_time_ms'], 'generation': generation,
            'source_fingerprint': self.signature['source'], 'tracks': tracks,
            'selected_track_id': decision['selected_track_id'], 'decision': decision,
            'display_time_ms': round(display * 1000), 'input_source': 'analysis_proxy',
            'proxy_size': [self.width, self.height], 'proxy_fps': self.fps / self.step,
            'context_frames': [{'time_ms': round(f['time'] * 1000), 'context_path': f['annotated_path']}
                               for f in frames], 'expanded_ball_search': expanded}
