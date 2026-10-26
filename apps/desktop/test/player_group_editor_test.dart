import 'dart:convert';

import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:desktop/features/review/player_group_editor.dart';
import 'package:desktop/providers/player_groups_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _groupsJson = jsonEncode([
  {
    'name': 'Saturday',
    'players': ['Chris', 'Alex', 'Blake'],
  },
  {
    'name': 'Sunday',
    'players': ['Dana'],
  },
]);

Future<ProviderContainer> _openEditor(
  WidgetTester tester, {
  bool english = false,
}) async {
  SharedPreferences.setMockInitialValues({
    playerGroupsPrefsKey: _groupsJson,
    defaultPlayerGroupPrefsKey: 'Saturday',
  });
  tester.view.physicalSize = const Size(900, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(playerGroupsProvider.notifier).ready;
  final group = container.read(playerGroupsProvider).first;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: Locale(english ? 'en' : 'zh'),
        localizationsDelegates: BheLocalizations.localizationsDelegates,
        supportedLocales: BheLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PlayerGroupEditor(group: group),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'dragging down uses the final index without skipping the last player',
    (tester) async {
      final container = await _openEditor(tester);
      final handle = find.byKey(const ValueKey('group-editor-drag-Chris'));
      final last = find.byKey(const ValueKey('group-editor-player-Blake'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(tester.getBottomLeft(last) + const Offset(20, 30));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-group-save')));
      await tester.pumpAndSettle();
      expect(container.read(playerGroupsProvider).first.players, [
        'Alex',
        'Blake',
        'Chris',
      ]);
    },
  );
  testWidgets(
    'rename, add and remove are saved together and move the default',
    (tester) async {
      final container = await _openEditor(tester);
      await tester.enterText(
        find.byKey(const Key('player-group-name')),
        'Weekday',
      );
      await tester.tap(find.byKey(const ValueKey('group-editor-remove-Alex')));
      await tester.enterText(
        find.byKey(const Key('player-group-new-player')),
        'Evan',
      );
      // Save also accepts a pending name that has not yet been added with +.
      await tester.tap(find.byKey(const Key('player-group-save')));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerGroupEditor), findsNothing);
      final edited = container.read(playerGroupsProvider).first;
      expect(edited.name, 'Weekday');
      expect(edited.players, ['Chris', 'Blake', 'Evan']);
      expect(container.read(defaultPlayerGroupProvider), 'Weekday');
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(playerGroupsPrefsKey)!).first['players'],
        ['Chris', 'Blake', 'Evan'],
      );
      expect(prefs.getString(defaultPlayerGroupPrefsKey), 'Weekday');
    },
  );

  testWidgets('cancel discards a renamed group and its local roster edits', (
    tester,
  ) async {
    final container = await _openEditor(tester);
    await tester.enterText(
      find.byKey(const Key('player-group-name')),
      'Unsaved',
    );
    await tester.tap(find.byKey(const ValueKey('group-editor-remove-Alex')));
    await tester.enterText(
      find.byKey(const Key('player-group-new-player')),
      'Evan',
    );
    await tester.tap(find.byKey(const Key('player-group-add-player')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(playerGroupsProvider).first.players, [
      'Chris',
      'Alex',
      'Blake',
    ]);
    expect(container.read(defaultPlayerGroupProvider), 'Saturday');
    expect(
      (await SharedPreferences.getInstance()).getString(playerGroupsPrefsKey),
      _groupsJson,
    );
  });

  testWidgets('dragging a player changes the saved shortcut order', (
    tester,
  ) async {
    final container = await _openEditor(tester);
    final handle = find.byKey(const ValueKey('group-editor-drag-Blake'));
    final first = find.byKey(const ValueKey('group-editor-player-Chris'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -25));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(tester.getTopLeft(first) + const Offset(20, -30));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('player-group-save')));
    await tester.pumpAndSettle();
    expect(container.read(playerGroupsProvider).first.players, [
      'Blake',
      'Chris',
      'Alex',
    ]);
  });

  testWidgets('blank and duplicate names are explained without saving', (
    tester,
  ) async {
    final container = await _openEditor(tester);
    await tester.tap(find.byKey(const Key('player-group-add-player')));
    await tester.pumpAndSettle();
    expect(find.text('球员名不能为空'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('player-group-new-player')),
      ' Chris ',
    );
    await tester.tap(find.byKey(const Key('player-group-add-player')));
    await tester.pumpAndSettle();
    expect(find.text('分组内的球员不能重名'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('player-group-new-player')),
      '',
    );
    await tester.enterText(find.byKey(const Key('player-group-name')), ' ');
    await tester.tap(find.byKey(const Key('player-group-save')));
    await tester.pumpAndSettle();
    expect(find.text('分组名不能为空'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('player-group-name')),
      'Sunday',
    );
    await tester.tap(find.byKey(const Key('player-group-save')));
    await tester.pumpAndSettle();
    expect(find.text('分组名已存在，请使用其他名称'), findsOneWidget);
    expect(container.read(playerGroupsProvider).first.name, 'Saturday');
    expect(
      (await SharedPreferences.getInstance()).getString(playerGroupsPrefsKey),
      _groupsJson,
    );
  });

  testWidgets(
    'English editor and validation messages contain no Chinese copy',
    (tester) async {
      await _openEditor(tester, english: true);
      await tester.tap(find.byKey(const Key('player-group-add-player')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a player name.'), findsOneWidget);
      final texts = tester.widgetList<Text>(
        find.descendant(
          of: find.byType(PlayerGroupEditor),
          matching: find.byType(Text),
        ),
      );
      for (final text in texts) {
        expect(text.data ?? '', isNot(matches(RegExp(r'[\u4e00-\u9fff]'))));
      }
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(
          field.decoration?.labelText ?? '',
          isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
        );
      }
    },
  );
}
