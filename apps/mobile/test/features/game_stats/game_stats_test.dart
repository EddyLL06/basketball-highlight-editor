import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/game_stats/game_stats.dart';
import 'package:flutter_test/flutter_test.dart';

Candidate candidate(
  String id, {
  int eventMs = 1000,
  CandidateSelection selection = CandidateSelection.included,
  bool reviewed = false,
  String? player,
  Map<String, dynamic>? rimCheck,
}) => Candidate(
  id: id,
  startMs: eventMs - 500 < 0 ? 0 : eventMs - 500,
  endMs: eventMs + 500,
  eventMs: eventMs,
  selection: selection,
  reviewed: reviewed,
  player: player,
  rimCheck: rimCheck,
);

void main() {
  test('empty project has no rate and no buckets', () {
    final stats = computeGameStats(const [], const ['Alice']);
    expect(stats.candidateCount, 0);
    expect(stats.estimatedHitRate, isNull);
    expect(stats.timeBuckets, isEmpty);
    expect(stats.playerCounts, isEmpty);
  });

  test('splits kept, unreviewed, manual and rim-check exclusions', () {
    final stats = computeGameStats([
      candidate('a', reviewed: true),
      candidate('b'),
      candidate('c', selection: CandidateSelection.excluded, reviewed: true),
      candidate(
        'd',
        selection: CandidateSelection.excluded,
        rimCheck: const {'status': 'rejected'},
      ),
      candidate(
        'e',
        selection: CandidateSelection.excluded,
        reviewed: true,
        rimCheck: const {'status': 'rejected'},
      ),
      candidate(
        'f',
        selection: CandidateSelection.excluded,
        rimCheck: const {'status': 'accepted'},
      ),
    ], const []);
    expect(stats.candidateCount, 6);
    expect(stats.keptCount, 2);
    expect(stats.unreviewedCount, 1);
    // c and e were touched by the user, f has no rim rejection.
    expect(stats.manuallyExcludedCount, 3);
    expect(stats.rimRejectedCount, 1);
    expect(stats.excludedCount, 4);
    expect(stats.estimatedHitRate, closeTo(2 / 6, 1e-9));
  });

  test('counts by player, ties follow the roster, strangers sort last', () {
    final stats = computeGameStats([
      candidate('1', player: 'Bob'),
      candidate('2', player: 'Alice'),
      candidate('3', player: 'Zed'),
      candidate('4', player: 'Bob'),
      candidate('5', player: '  '),
      candidate('6'),
      candidate('7', player: ' Alice '),
      candidate(
        '8',
        player: 'Bob',
        selection: CandidateSelection.excluded,
      ),
    ], const ['Alice', 'Bob']);
    expect(stats.playerCounts.map((p) => (p.name, p.count)).toList(), [
      ('Alice', 2),
      ('Bob', 2),
      ('Zed', 1),
    ]);
    expect(stats.unassignedCount, 2);
  });

  test('buckets use 10 minute boundaries and keep empty gaps', () {
    final stats = computeGameStats([
      candidate('a', eventMs: 0),
      candidate('b', eventMs: 599999),
      candidate('c', eventMs: 600000),
      candidate('d', eventMs: 1800000),
    ], const []);
    expect(stats.bucketMinutes, 10);
    expect(
      stats.timeBuckets.map((b) => (b.startMinute, b.endMinute, b.count)),
      [(0, 10, 2), (10, 20, 1), (20, 30, 0), (30, 40, 1)],
    );
  });

  test('negative and out of range event times are clamped', () {
    final stats = computeGameStats(
      [
        candidate('a', eventMs: -5000),
        candidate('b', eventMs: 99999999),
      ],
      const [],
      videoDurationMs: 700000,
    );
    expect(
      stats.timeBuckets.map((b) => (b.startMinute, b.count)).toList(),
      [(0, 1), (10, 1)],
    );
  });

  test('long videos widen buckets so the list stays short', () {
    final stats = computeGameStats([
      candidate('a', eventMs: 0),
      candidate('b', eventMs: 3 * 3600 * 1000),
    ], const []);
    expect(stats.bucketMinutes, greaterThan(10));
    expect(stats.timeBuckets.length, lessThanOrEqualTo(12));
    expect(stats.timeBuckets.fold<int>(0, (s, b) => s + b.count), 2);
  });
}
