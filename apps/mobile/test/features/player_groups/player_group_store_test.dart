import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FaultPreferences extends InMemorySharedPreferencesStore {
  FaultPreferences(super.data) : super.withData();
  String? failKey;
  Completer<void>? entered;
  Completer<void>? release;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (entered != null) {
      entered!.complete();
      entered = null;
      await release!.future;
    }
    if (key == failKey) {
      failKey = null;
      throw PlatformException(code: 'prefs_write_failed');
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FaultPreferences backend;
  late MobileAppState state;
  final raw = jsonEncode([
    {
      'name': 'Old',
      'players': ['Alice', 'Bob'],
    },
  ]);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mobile_group_store_');
    SharedPreferences.setMockInitialValues({});
    backend = FaultPreferences({
      'flutter.bhe.player_groups': raw,
      'flutter.bhe.default_player_group': 'Old',
    });
    SharedPreferencesStorePlatform.instance = backend;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    state = MobileAppState(
      analysisEngine: const MobileAnalysisEngineUnavailable(),
    );
    await state.ready;
  });
  tearDown(() async {
    state.dispose();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });
  test('renaming default follows and deletion clears preference', () async {
    expect(await state.editPlayerGroup('Old', 'New', ['Bob', 'Alice']), isTrue);
    expect(state.defaultPlayerGroupName, 'New');
    expect(state.playerGroups.single.players, ['Bob', 'Alice']);
    expect(await state.deletePlayerGroup('New'), isTrue);
    expect(state.defaultPlayerGroupName, isNull);
    expect(
      (await backend.getAll()).containsKey('flutter.bhe.default_player_group'),
      isFalse,
    );
  });
  test(
    'failed default rename restores old group, default and preference bytes',
    () async {
      backend.failKey = 'flutter.bhe.default_player_group';
      expect(await state.editPlayerGroup('Old', 'New', ['Alice']), isFalse);
      expect(state.playerGroups.single.name, 'Old');
      expect(state.playerGroups.single.players, ['Alice', 'Bob']);
      expect(state.defaultPlayerGroupName, 'Old');
      final disk = await backend.getAll();
      expect(disk['flutter.bhe.player_groups'], raw);
      expect(disk['flutter.bhe.default_player_group'], 'Old');
      expect(state.playerGroupError, isNotNull);
    },
  );
  test('queued changes use the latest committed groups', () async {
    final entered = Completer<void>(), release = Completer<void>();
    backend.entered = entered;
    backend.release = release;
    final rename = state.editPlayerGroup('Old', 'New', ['Alice', 'Bob']);
    await entered.future;
    final clear = state.setDefaultPlayerGroup(null);
    release.complete();
    expect(await rename, isTrue);
    expect(await clear, isTrue);
    expect(state.playerGroups.single.name, 'New');
    expect(state.defaultPlayerGroupName, isNull);
    expect(
      (await backend.getAll()).containsKey('flutter.bhe.default_player_group'),
      isFalse,
    );
  });
  test('invalid old entries are not overwritten', () async {
    SharedPreferences.setMockInitialValues({
      'bhe.player_groups': '[{"name":"Good","players":["A"]},{"broken":true}]',
    });
    final second = MobileAppState(
      analysisEngine: const MobileAnalysisEngineUnavailable(),
    );
    await second.ready;
    expect(second.playerGroups.single.name, 'Good');
    expect(await second.deletePlayerGroup('Good'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('bhe.player_groups'), contains('broken'));
    second.dispose();
  });

  test('queued rename preserves the latest edited members', () async {
    final entered = Completer<void>(), release = Completer<void>();
    backend.entered = entered;
    backend.release = release;
    final edit = state.editPlayerGroup('Old', 'Old', ['Carol']);
    await entered.future;
    final rename = state.renamePlayerGroup('Old', 'New');
    release.complete();
    expect(await edit, isTrue);
    expect(await rename, isTrue);
    expect(state.playerGroups.single.name, 'New');
    expect(state.playerGroups.single.players, ['Carol']);
  });

  test(
    'a queued create cannot silently replace a concurrently created group',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      backend.entered = entered;
      backend.release = release;
      state.project = state.project.copyWith(players: ['Alice']);
      final first = state.savePlayerGroup('New', replaceExisting: false);
      await entered.future;
      state.project = state.project.copyWith(players: ['Carol']);
      final second = state.savePlayerGroup('New', replaceExisting: false);
      release.complete();
      expect(await first, isTrue);
      expect(await second, isFalse);
      expect(state.playerGroups.last.players, ['Alice']);
    },
  );
  test('stale default is removed without rewriting saved groups', () async {
    SharedPreferences.setMockInitialValues({
      'bhe.player_groups': raw,
      'bhe.default_player_group': 'Missing',
    });
    final second = MobileAppState(
      analysisEngine: const MobileAnalysisEngineUnavailable(),
    );
    await second.ready;
    final prefs = await SharedPreferences.getInstance();
    expect(second.defaultPlayerGroupName, isNull);
    expect(prefs.containsKey('bhe.default_player_group'), isFalse);
    expect(prefs.getString('bhe.player_groups'), raw);
    second.dispose();
  });
  test('delete and recreate does not revive an old roster selection', () async {
    state.project = state.project.copyWith(players: []);
    final draft = state.rosterSelection;
    expect(draft.groupName, 'Old');
    expect(await state.deletePlayerGroup('Old'), isTrue);
    state.project = state.project.copyWith(players: ['New']);
    expect(await state.savePlayerGroup('Old'), isTrue);
    expect(draft.groupChanged, isTrue);
    expect(draft.groupName, isNull);
    expect(draft.orderedPlayers, isEmpty);
  });
  test('failed edits leave preferences and visible groups unchanged', () async {
    for (final action in <Future<bool> Function()>[
      () => state.renamePlayerGroup('Old', 'New'),
      () => state.deletePlayerGroup('Old'),
      () => state.setDefaultPlayerGroup(null),
      () => state.editPlayerGroup('Old', 'Old', ['Carol']),
      () => state.savePlayerGroup('Old'),
    ]) {
      backend.failKey = 'flutter.bhe.player_groups';
      expect(await action(), isFalse);
      expect(state.playerGroups.single.name, 'Old');
      expect(state.playerGroups.single.players, ['Alice', 'Bob']);
      expect(state.defaultPlayerGroupName, 'Old');
      expect((await backend.getAll())['flutter.bhe.player_groups'], raw);
      expect(
        (await backend.getAll())['flutter.bhe.default_player_group'],
        'Old',
      );
      expect(state.playerGroupError, isNotNull);
    }
  });
}
