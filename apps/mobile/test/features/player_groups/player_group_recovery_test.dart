import 'dart:async';
import 'dart:convert';
import 'package:bhe_mobile/features/player_groups/player_group_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FaultStore extends InMemorySharedPreferencesStore {
  FaultStore(super.data) : super.withData();
  final calls = <String, int>{};
  String? partialKey;
  String? failRestoreKey;
  String? failRemoveKey;
  Completer<void>? loadEntered;
  Completer<void>? loadRelease;
  @override
  Future<Map<String, Object>> getAll() async {
    if (loadEntered != null) {
      loadEntered!.complete();
      loadEntered = null;
      await loadRelease!.future;
    }
    return super.getAll();
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final n = calls.update(key, (v) => v + 1, ifAbsent: () => 1);
    if (key == failRestoreKey && n == 2) {
      throw PlatformException(code: 'restore_failure');
    }
    final result = await super.setValue(type, key, value);
    if (key == partialKey && n == 1) {
      throw PlatformException(code: 'partial_write');
    }
    return result;
  }

  @override
  Future<bool> remove(String key) async {
    calls.update(key, (v) => v + 1, ifAbsent: () => 1);
    if (key == failRemoveKey) {
      failRemoveKey = null;
      throw PlatformException(code: 'remove_failure');
    }
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const groupsKey = 'flutter.bhe.player_groups',
      defaultKey = 'flutter.bhe.default_player_group';
  final raw = jsonEncode([
    {
      'name': 'Old',
      'players': ['Alice'],
    },
  ]);
  tearDown(() => SharedPreferences.setMockInitialValues({}));
  for (final restoreKey in [groupsKey, defaultKey]) {
    test('both keys attempted when restoring $restoreKey fails', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = FaultStore({groupsKey: raw, defaultKey: 'Old'});
      SharedPreferencesStorePlatform.instance = backend;
      final errors = <Object>[];
      final store = PlayerGroupStore(
        onChanged: () {},
        onFailure: (e, _) => errors.add(e),
      );
      await store.ready;
      backend.partialKey = defaultKey;
      backend.failRestoreKey = restoreKey;
      final saved = await store.change(
        (groups, value) => (
          groups: [
            (name: 'New', players: ['Alice']),
          ],
          defaultName: 'New',
        ),
      );
      expect(saved, isFalse);
      expect(backend.calls[groupsKey], 2);
      expect(backend.calls[defaultKey], 2);
      expect(errors.length, 2);
      final disk = await backend.getAll();
      if (restoreKey == groupsKey) expect(disk[defaultKey], 'Old');
      if (restoreKey == defaultKey) expect(disk[groupsKey], raw);
      expect(
        await store.change((groups, value) => (groups: [], defaultName: null)),
        isFalse,
      );
      expect(backend.calls[groupsKey], 2);
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesStorePlatform.instance = backend;
      final restarted = PlayerGroupStore(
        onChanged: () {},
        onFailure: (e, _) {},
      );
      await restarted.ready;
      expect(restarted.groups, isNotEmpty);
      expect(
        restarted.defaultName == null ||
            restarted.groups.any((g) => g.name == restarted.defaultName),
        isTrue,
      );
    });
  }
  test('partial groups write attempts both restorations', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = FaultStore({groupsKey: raw, defaultKey: 'Old'})
      ..partialKey = groupsKey;
    SharedPreferencesStorePlatform.instance = backend;
    final store = PlayerGroupStore(onChanged: () {}, onFailure: (_, _) {});
    await store.ready;
    expect(
      await store.change(
        (groups, value) => (
          groups: [
            (name: 'New', players: ['Alice']),
          ],
          defaultName: 'New',
        ),
      ),
      isFalse,
    );
    expect(backend.calls[groupsKey], 2);
    expect(backend.calls[defaultKey], 1);
    final disk = await backend.getAll();
    expect(disk[groupsKey], raw);
    expect(disk[defaultKey], 'Old');
  });
  test('delete default remove failure rolls back both preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final backend = FaultStore({groupsKey: raw, defaultKey: 'Old'})
      ..failRemoveKey = defaultKey;
    SharedPreferencesStorePlatform.instance = backend;
    final store = PlayerGroupStore(onChanged: () {}, onFailure: (_, _) {});
    await store.ready;
    expect(
      await store.change((groups, value) => (groups: [], defaultName: null)),
      isFalse,
    );
    final disk = await backend.getAll();
    expect(disk[groupsKey], raw);
    expect(disk[defaultKey], 'Old');
    expect(store.groups.single.name, 'Old');
    expect(store.defaultName, 'Old');
  });
  test('pending change waits for initial load', () async {
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>(), release = Completer<void>();
    final backend = FaultStore({groupsKey: raw, defaultKey: 'Old'})
      ..loadEntered = entered
      ..loadRelease = release;
    SharedPreferencesStorePlatform.instance = backend;
    final store = PlayerGroupStore(onChanged: () {}, onFailure: (_, _) {});
    await entered.future;
    final change = store.change(
      (groups, value) => (
        groups: [...groups, (name: 'Other', players: <String>[])],
        defaultName: value,
      ),
    );
    expect(backend.calls, isEmpty);
    release.complete();
    expect(await change, isTrue);
    expect(store.groups.map((g) => g.name), ['Old', 'Other']);
  });
  for (final rawBad in [
    '[{"name":"","players":[]}]',
    '[{"name":"Old","players":[]},{"name":"Old","players":["A"]}]',
  ]) {
    test(
      'ambiguous legacy names remain readable but cannot be overwritten: $rawBad',
      () async {
        SharedPreferences.setMockInitialValues({});
        final backend = FaultStore({groupsKey: rawBad});
        SharedPreferencesStorePlatform.instance = backend;
        final errors = <Object>[];
        final store = PlayerGroupStore(
          onChanged: () {},
          onFailure: (e, _) => errors.add(e),
        );
        await store.ready;
        expect(store.groups, isNotEmpty);
        expect(errors, isNotEmpty);
        expect(
          await store.change(
            (groups, value) => (groups: [], defaultName: null),
          ),
          isFalse,
        );
        expect((await backend.getAll())[groupsKey], rawBad);
      },
    );
  }
}
