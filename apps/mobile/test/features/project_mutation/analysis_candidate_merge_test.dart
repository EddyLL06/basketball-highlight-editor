import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/project_mutation/analysis_candidate_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('engine updates preserve reviews and manual candidates by ID', () {
    const old = Candidate(
      id: 'a',
      startMs: 100,
      endMs: 900,
      eventMs: 500,
      rangeEdited: true,
      selection: CandidateSelection.excluded,
      reviewed: true,
      note: 'important',
      player: 'Alice',
    );
    const manual = Candidate(
      id: 'manual',
      startMs: 1000,
      endMs: 2000,
      eventMs: 1500,
      reason: 'manual',
    );
    const refreshed = Candidate(
      id: 'a',
      startMs: 0,
      endMs: 1000,
      eventMs: 500,
      confidence: .9,
    );
    const newItem = Candidate(
      id: 'new',
      startMs: 2000,
      endMs: 3000,
      eventMs: 2500,
    );
    final result = mergeAnalysisCandidates([old, manual], [refreshed, newItem]);
    expect(result.map((item) => item.id), ['a', 'manual', 'new']);
    expect(result.first.confidence, .9);
    expect(result.first.startMs, 100);
    expect(result.first.endMs, 900);
    expect(result.first.selection, CandidateSelection.excluded);
    expect(result.first.reviewed, isTrue);
    expect(result.first.note, 'important');
    expect(result.first.player, 'Alice');
  });
}
