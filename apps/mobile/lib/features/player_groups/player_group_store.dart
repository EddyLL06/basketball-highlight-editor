import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../player_roster/roster_selection.dart';

/// The old JSON shape stays unchanged; mutations publish only after persistence.
class PlayerGroupStore {
  PlayerGroupStore({required this.onChanged, required this.onFailure}) {
    ready = _load();
  }
  static const groupsKey = 'bhe.player_groups';
  static const defaultKey = 'bhe.default_player_group';
  final void Function() onChanged;
  final void Function(Object, StackTrace) onFailure;
  late final Future<void> ready;
  Future<void> _tail = Future.value();
  List<PlayerGroup> groups = const [];
  String? defaultName;
  bool _loadFailed = false;
  bool get hasUnsafeData => _loadFailed;
  bool loaded = false;
  final Map<String, int> _revisions = {};
  int revisionFor(String name) => _revisions[name] ?? 0;

  void _advanceRevisions(List<PlayerGroup> before, List<PlayerGroup> after) {
    final names = <String>{
      ...before.map((g) => g.name),
      ...after.map((g) => g.name),
    };
    for (final name in names) {
      final old = before
          .where((g) => g.name == name)
          .map((g) => g.players)
          .toList();
      final next = after
          .where((g) => g.name == name)
          .map((g) => g.players)
          .toList();
      if (jsonEncode(old) != jsonEncode(next)) {
        _revisions[name] = revisionFor(name) + 1;
      }
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(groupsKey);
      final wanted = prefs.getString(defaultKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is! List) {
          throw const FormatException('Invalid player groups');
        }
        final next = <PlayerGroup>[];
        for (final item in decoded) {
          if (item is! Map ||
              item['name'] is! String ||
              item['players'] is! List ||
              (item['players'] as List).any((player) => player is! String)) {
            _loadFailed = true;
            continue;
          }
          next.add((
            name: item['name'] as String,
            players: (item['players'] as List).cast<String>().toList(),
          ));
        }
        final names = <String>{};
        for (final group in next) {
          if (group.name.trim().isEmpty || !names.add(group.name)) {
            _loadFailed = true;
          }
        }
        groups = next;
        if (_loadFailed) {
          onFailure(
            const FormatException('Some player groups are invalid'),
            StackTrace.current,
          );
        }
      }
      defaultName = groups.any((group) => group.name == wanted) ? wanted : null;
      if (wanted != null && defaultName == null && !_loadFailed) {
        try {
          if (!await prefs.remove(defaultKey)) {
            throw StateError('Preference write failed: $defaultKey');
          }
        } on Object catch (error, stack) {
          onFailure(error, stack);
        }
      }
      onChanged();
    } on Object catch (error, stack) {
      _loadFailed = true;
      onFailure(error, stack);
    } finally {
      loaded = true;
      onChanged();
    }
  }

  Future<bool> change(
    ({List<PlayerGroup> groups, String? defaultName})? Function(
      List<PlayerGroup>,
      String?,
    )
    apply,
  ) {
    final operation = _tail
        .then((_) async {
          await ready;
          if (_loadFailed) {
            onFailure(
              StateError('Player groups could not be read safely'),
              StackTrace.current,
            );
            return false;
          }
          final result = apply(groups, defaultName);
          if (result == null) return false;
          final prefs = await SharedPreferences.getInstance();
          final oldGroups = prefs.getString(groupsKey);
          final oldDefault = prefs.getString(defaultKey);
          Future<void> write(String key, String? value) async {
            final ok = value == null
                ? await prefs.remove(key)
                : await prefs.setString(key, value);
            if (!ok) throw StateError('Preference write failed: $key');
          }

          try {
            await write(
              groupsKey,
              jsonEncode([
                for (final group in result.groups)
                  {'name': group.name, 'players': group.players},
              ]),
            );
            if (result.defaultName != oldDefault) {
              await write(defaultKey, result.defaultName);
            }
            _advanceRevisions(groups, result.groups);
            groups = result.groups;
            defaultName = result.defaultName;
            onChanged();
            return true;
          } on Object catch (error, stack) {
            var restoreFailed = false;
            for (final entry in [
              (groupsKey, oldGroups),
              (defaultKey, oldDefault),
            ]) {
              try {
                await write(entry.$1, entry.$2);
              } on Object catch (restoreError, restoreStack) {
                restoreFailed = true;
                onFailure(restoreError, restoreStack);
              }
            }
            if (restoreFailed) _loadFailed = true;
            onFailure(error, stack);
            return false;
          }
        })
        .onError((Object error, StackTrace stack) {
          onFailure(error, stack);
          return false;
        });
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        onFailure(error, stack);
      },
    );
    return operation;
  }
}
