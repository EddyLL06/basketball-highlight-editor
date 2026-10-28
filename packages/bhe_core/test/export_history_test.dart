import 'dart:convert';

import 'package:bhe_core/bhe_core.dart';
import 'package:test/test.dart';

void main() {
  final entry = ExportHistoryEntry(
    id: 'r1',
    createdAt: DateTime.utc(2026, 10, 28),
    mode: 'labels',
    plannedCount: 2,
    durationMs: 123,
    files: const [
      ExportHistoryFile(
        name: 'Alice',
        relativePath: 'labels_1/group_1.mp4',
        savedToGallery: true,
      ),
    ],
  );
  final project = ProjectSnapshot(
    id: 'A',
    name: 'A',
    video: null,
    exportHistory: [entry],
  );
  test('local records persist but package has no local history', () {
    const codec = ProjectPackageCodec();
    final local = codec.encode(project, includeLocalHistory: true);
    expect(
      codec
          .decode(local, includeLocalHistory: true)
          .exportHistory
          .single
          .files
          .single
          .savedToGallery,
      isTrue,
    );
    expect(codec.decode(local).exportHistory, isEmpty);
    final package = codec.encode(project);
    expect(package, isNot(contains('export_history')));
    expect(codec.decode(package).exportHistory, isEmpty);
    expect(project.copyWith(name: 'B').exportHistory, [entry]);
  });
  test('bad entries never prevent the project from opening', () {
    const codec = ProjectPackageCodec();
    final raw =
        jsonDecode(codec.encode(project, includeLocalHistory: true))
            as Map<String, dynamic>;
    raw['local_export_history'] = [
      null,
      {},
      {'id': 'bad'},
      ...raw['local_export_history'] as List,
    ];
    final decoded = codec.decode(jsonEncode(raw), includeLocalHistory: true);
    expect(decoded.exportHistory.length, 1);
    expect(
      ExportHistoryEntry.fromJson({
        'id': 'x',
        'mode': 'merged',
        'created_at': '2026-01-01',
        'planned_count': double.infinity,
        'duration_ms': 1,
        'files': [],
      }),
      isNull,
    );
  });
  test('legacy package cannot import embedded local history', () {
    const codec = ProjectPackageCodec();
    final legacy = jsonEncode({
      'format': 'bhe-project',
      'version': 1,
      'project': project.toJson(),
    });
    expect(codec.decode(legacy).exportHistory, isEmpty);
  });
}
