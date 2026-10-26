import 'dart:convert';

import 'package:desktop/providers/player_groups_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> load(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(playerGroupsProvider.notifier).ready;
    return container;
  }

  final groups = jsonEncode([
    {
      'name': 'Saturday',
      'players': ['Chris', 'Alex', 'Blake'],
    },
    {
      'name': 'Sunday',
      'players': ['Dana'],
    },
  ]);

  test(
    'editing preserves group position, player order and default across reload',
    () async {
      final container = await load({
        playerGroupsPrefsKey: groups,
        defaultPlayerGroupPrefsKey: 'Saturday',
      });
      final notifier = container.read(playerGroupsProvider.notifier);
      await notifier.update(
        'Saturday',
        name: '  New team  ',
        players: [' Blake ', 'Chris', 'Evan'],
      );
      expect(container.read(playerGroupsProvider).map((g) => g.name), [
        'New team',
        'Sunday',
      ]);
      expect(container.read(playerGroupsProvider).first.players, [
        'Blake',
        'Chris',
        'Evan',
      ]);
      expect(container.read(defaultPlayerGroupProvider), 'New team');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(defaultPlayerGroupPrefsKey), 'New team');
      final reloaded = ProviderContainer();
      addTearDown(reloaded.dispose);
      await reloaded.read(playerGroupsProvider.notifier).ready;
      final reread = reloaded.read(playerGroupsProvider);
      expect(reread.map((group) => group.name), ['New team', 'Sunday']);
      expect(reread.first.players, ['Blake', 'Chris', 'Evan']);
      expect(reread.last.players, ['Dana']);
      expect(reloaded.read(defaultPlayerGroupProvider), 'New team');
    },
  );

  for (final invalid in [
    (name: ' ', players: <String>['Chris'], error: '分组名不能为空'),
    (name: 'Sunday', players: <String>['Chris'], error: '分组名已存在，请使用其他名称'),
    (name: 'Team', players: <String>[' '], error: '球员名不能为空'),
    (name: 'Team', players: <String>['Chris', ' Chris '], error: '分组内的球员不能重名'),
  ]) {
    test(
      'invalid edit is rejected without changing groups or default: ${invalid.error}',
      () async {
        final container = await load({
          playerGroupsPrefsKey: groups,
          defaultPlayerGroupPrefsKey: 'Saturday',
        });
        await expectLater(
          container
              .read(playerGroupsProvider.notifier)
              .update('Saturday', name: invalid.name, players: invalid.players),
          throwsA(
            isA<PlayerGroupException>().having(
              (e) => e.message,
              'message',
              invalid.error,
            ),
          ),
        );
        expect(container.read(playerGroupsProvider).first.name, 'Saturday');
        expect(container.read(defaultPlayerGroupProvider), 'Saturday');
        expect(
          (await SharedPreferences.getInstance()).getString(
            playerGroupsPrefsKey,
          ),
          groups,
        );
      },
    );
  }

  test(
    'renaming a non-default group leaves the selected default unchanged',
    () async {
      final container = await load({
        playerGroupsPrefsKey: groups,
        defaultPlayerGroupPrefsKey: 'Sunday',
      });
      await container
          .read(playerGroupsProvider.notifier)
          .update('Saturday', name: 'Team', players: []);
      expect(container.read(defaultPlayerGroupProvider), 'Sunday');
      expect(container.read(playerGroupsProvider).first.players, isEmpty);
    },
  );

  test(
    'editing a group deleted while the editor was open does not recreate it',
    () async {
      final container = await load({playerGroupsPrefsKey: groups});
      final notifier = container.read(playerGroupsProvider.notifier);
      await notifier.delete('Saturday');
      await expectLater(
        notifier.update('Saturday', name: 'Team', players: ['Chris']),
        throwsA(isA<PlayerGroupException>()),
      );
      expect(container.read(playerGroupsProvider).map((g) => g.name), [
        'Sunday',
      ]);
    },
  );

  test(
    'loads the default after the groups without changing player order',
    () async {
      final container = await load({
        playerGroupsPrefsKey: groups,
        defaultPlayerGroupPrefsKey: 'Saturday',
      });
      expect(container.read(defaultPlayerGroupProvider), 'Saturday');
      expect(container.read(playerGroupsProvider).first.players, [
        'Chris',
        'Alex',
        'Blake',
      ]);
    },
  );

  test('default selection persists and can be cleared', () async {
    final container = await load({playerGroupsPrefsKey: groups});
    final notifier = container.read(playerGroupsProvider.notifier);
    await notifier.setDefault('Sunday');
    expect(container.read(defaultPlayerGroupProvider), 'Sunday');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(defaultPlayerGroupPrefsKey), 'Sunday');
    await notifier.setDefault(null);
    expect(container.read(defaultPlayerGroupProvider), isNull);
    expect(prefs.containsKey(defaultPlayerGroupPrefsKey), isFalse);
  });

  test(
    'deleting a default group invalidates it and preserves the other group',
    () async {
      final container = await load({
        playerGroupsPrefsKey: groups,
        defaultPlayerGroupPrefsKey: 'Saturday',
      });
      await container.read(playerGroupsProvider.notifier).delete('Saturday');
      expect(container.read(defaultPlayerGroupProvider), isNull);
      expect(container.read(playerGroupsProvider).single.name, 'Sunday');
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          defaultPlayerGroupPrefsKey,
        ),
        isFalse,
      );
    },
  );

  for (final stale in ['Deleted team', 'Name before external rename']) {
    test('stale default falls back to none: $stale', () async {
      final container = await load({
        playerGroupsPrefsKey: groups,
        defaultPlayerGroupPrefsKey: stale,
      });
      expect(container.read(defaultPlayerGroupProvider), isNull);
      expect(
        (await SharedPreferences.getInstance()).containsKey(
          defaultPlayerGroupPrefsKey,
        ),
        isFalse,
      );
      await container.read(playerGroupsProvider.notifier).setDefault(stale);
      expect(container.read(defaultPlayerGroupProvider), isNull);
    });
  }

  test('writes wait for the initial read and retain existing groups', () async {
    SharedPreferences.setMockInitialValues({playerGroupsPrefsKey: groups});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(playerGroupsProvider.notifier);
    await Future.wait([
      notifier.save('New group', ['Evan']),
      notifier.setDefault('New group'),
    ]);
    expect(container.read(playerGroupsProvider).map((g) => g.name), [
      'Saturday',
      'Sunday',
      'New group',
    ]);
    expect(container.read(defaultPlayerGroupProvider), 'New group');
  });

  test(
    'an empty group name is rejected without changing stored groups',
    () async {
      final container = await load({playerGroupsPrefsKey: groups});
      await expectLater(
        container.read(playerGroupsProvider.notifier).save('  ', ['Alex']),
        throwsA(isA<PlayerGroupException>()),
      );
      expect(container.read(playerGroupsProvider), hasLength(2));
    },
  );
}
