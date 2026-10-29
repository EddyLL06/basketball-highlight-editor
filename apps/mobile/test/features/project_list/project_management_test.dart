import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

class _UncertainState extends MobileAppState {
  bool uncertainAnalysis = false;
  bool uncertainExport = false;
  @override
  bool get hasUncertainAnalysis => uncertainAnalysis;
  @override
  bool get hasUncertainExport => uncertainExport;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'close retains files and other project can be renamed or deleted',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final original = await f.file('original.mp4', 'original');
        f.state.project = f.project(original.path);
        expect(await f.state.renameProject('Team A'), isTrue);
        final b = f.project(original.path, id: 'B');
        final bFile = await f.file(
          'BHE Mobile/projects/B.json',
          const ProjectPackageCodec().encode(b),
        );
        expect(await f.state.renameManagedProject('B', 'Renamed'), isTrue);
        expect(f.state.project.id, 'A');
        expect(
          const ProjectPackageCodec().decode(await bFile.readAsString()).name,
          'Renamed',
        );
        expect(await f.state.deleteManagedProject('B'), isTrue);
        expect(await bFile.exists(), isFalse);
        expect(await original.exists(), isTrue);
        expect(await f.state.closeManagedProject(), isTrue);
        expect(f.state.project.video, isNull);
        expect(await File('${f.data.path}/projects/A.json').exists(), isTrue);
        await f.state.openProject('A', requireIdle: true);
        expect(f.state.project.id, 'A');
      } finally {
        await f.close();
      }
    },
  );

  test('running heavy task rejects close, delete and protected open', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final original = await f.file('original.mp4', 'original');
      f.state.project = f.project(original.path);
      await f.state.renameProject('Team A');
      f.state.exporting = true;
      expect(await f.state.closeManagedProject(), isFalse);
      expect(await f.state.deleteManagedProject('A'), isFalse);
      await f.state.openProject('B', requireIdle: true);
      expect(f.state.project.id, 'A');
      expect(await File('${f.data.path}/projects/A.json').exists(), isTrue);
      f.state.exporting = false;
    } finally {
      await f.close();
    }
  });
  test(
    'deleting current project keeps original video and removes project file',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final original = await f.file('original.mp4', 'original');
        f.state.project = f.project(original.path);
        await f.state.renameProject('Team A');
        expect(await f.state.deleteManagedProject('A'), isTrue);
        expect(await File('${f.data.path}/projects/A.json').exists(), isFalse);
        expect(await original.exists(), isTrue);
        expect(f.state.project.video, isNull);
      } finally {
        await f.close();
      }
    },
  );
  test('analysis blocks management until finished', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final original = await f.file('original.mp4', 'original');
      f.state.project = f.project(original.path);
      await f.state.renameProject('Team A');
      f.state.analysing = true;
      expect(await f.state.closeManagedProject(), isFalse);
      expect(await f.state.deleteManagedProject('A'), isFalse);
      f.state.analysing = false;
      expect(await f.state.closeManagedProject(), isTrue);
    } finally {
      await f.close();
    }
  });
  test('later close supersedes a pending video chooser', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final original = await f.file('original.mp4', 'original');
      f.state.project = f.project(original.path);
      await f.state.renameProject('Team A');
      final choice = Completer<FilePickerResult?>();
      f.picker.pick = () => choice.future;
      final pending = f.state.createNewProjectAndPickVideo(requireIdle: true);
      expect(await f.state.closeManagedProject(), isTrue);
      final closedId = f.state.project.id;
      choice.complete(
        FilePickerResult([
          PlatformFile(name: 'original.mp4', path: original.path, size: 8),
        ]),
      );
      await pending;
      expect(f.state.project.id, closedId);
      expect(f.state.project.video, isNull);
      expect(await File('${f.data.path}/projects/A.json').exists(), isTrue);
    } finally {
      await f.close();
    }
  });
  test('opening an older project keeps recent list capped at 12', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final original = await f.file('original.mp4', 'original');
      final older = f.project(original.path, id: 'older');
      await f.file(
        'BHE Mobile/projects/older.json',
        const ProjectPackageCodec().encode(older),
      );
      f.state.recentProjects = List.generate(
        12,
        (i) => f.project(original.path, id: 'p$i'),
      );
      await f.state.openProject('older', requireIdle: true);
      expect(f.state.project.id, 'older');
      expect(f.state.recentProjects.length, 12);
      expect(f.state.recentProjects.first.id, 'older');
    } finally {
      await f.close();
    }
  });
  test('unconfirmed analysis or export prevents project management', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      f.state.dispose();
      final state = _UncertainState();
      f.state = state;
      await state.ready;
      final original = await f.file('original.mp4', 'original');
      state.project = f.project(original.path);
      await state.renameProject('Team A');
      for (final analysis in [true, false]) {
        state.uncertainAnalysis = analysis;
        state.uncertainExport = !analysis;
        expect(await state.closeManagedProject(), isFalse);
        expect(await state.deleteManagedProject('A'), isFalse);
        await state.openProject('other', requireIdle: true);
        expect(state.project.id, 'A');
      }
      state.uncertainAnalysis = false;
      state.uncertainExport = false;
      expect(await state.closeManagedProject(), isTrue);
    } finally {
      await f.close();
    }
  });
}
