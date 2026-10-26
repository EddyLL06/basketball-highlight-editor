import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_groups_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

typedef PlayerRosterSelection = ({
  String? groupName,
  List<String> players,
  bool explicit,
});

/// A project-local attendance choice. Saving groups never changes this roster.
class PlayerRosterPicker extends ConsumerStatefulWidget {
  const PlayerRosterPicker({
    required this.hasExistingPlayers,
    required this.enabled,
    required this.onChanged,
    this.initialSelection,
    super.key,
  });

  final bool hasExistingPlayers;
  final bool enabled;
  final ValueChanged<PlayerRosterSelection> onChanged;
  final PlayerRosterSelection? initialSelection;

  @override
  ConsumerState<PlayerRosterPicker> createState() => _PlayerRosterPickerState();
}

class _PlayerRosterPickerState extends ConsumerState<PlayerRosterPicker> {
  bool _loaded = false;
  bool _explicit = false;
  String? _groupName;
  final _checked = <String>{};

  @override
  void initState() {
    super.initState();
    _loadDefault();
  }

  Future<void> _loadDefault() async {
    await ref.read(playerGroupsProvider.notifier).ready;
    if (!mounted) return;
    setState(() {
      _loaded = true;
      final initial = widget.initialSelection;
      if (initial != null && (!widget.hasExistingPlayers || initial.explicit)) {
        _select(initial.groupName, explicit: initial.explicit);
        _checked.retainAll(initial.players);
      } else if (!widget.hasExistingPlayers && initial == null) {
        _select(ref.read(defaultPlayerGroupProvider), explicit: false);
      }
    });
    _emit();
  }

  @override
  void didUpdateWidget(covariant PlayerRosterPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A retained import route may now contain players from the first analysis.
    if (!oldWidget.hasExistingPlayers &&
        widget.hasExistingPlayers &&
        !_explicit) {
      _select(null, explicit: false);
      _emit();
    }
  }

  PlayerGroup? get _group => ref
      .read(playerGroupsProvider)
      .where((group) => group.name == _groupName)
      .firstOrNull;

  void _select(String? name, {required bool explicit}) {
    _groupName = name;
    _explicit = explicit;
    _checked
      ..clear()
      ..addAll(_group?.players ?? const []);
  }

  void _emit() {
    widget.onChanged((
      groupName: _groupName,
      players: [
        for (final name in _group?.players ?? <String>[])
          if (_checked.contains(name)) name,
      ],
      explicit: _explicit,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(playerGroupsProvider);
    final defaultName = ref.watch(defaultPlayerGroupProvider);
    ref.listen(playerGroupsProvider, (_, next) {
      if (!_loaded || _groupName == null) return;
      final group = next.where((group) => group.name == _groupName).firstOrNull;
      setState(() {
        if (group == null) {
          _select(null, explicit: false);
        } else {
          _checked.retainAll(group.players);
        }
      });
      _emit();
    });
    final c = AppColors.of(context);
    final group = groups.where((group) => group.name == _groupName).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.bheText('球员名单'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: Spacing.sm),
        if (!_loaded)
          Text(context.bheText('正在读取球员分组…'))
        else if (groups.isEmpty)
          Text(
            context.bheText('还没有球员分组，可以在审核页把球员存为分组。'),
            style: TextStyle(color: c.textSecondary),
          )
        else ...[
          InputDecorator(
            decoration: InputDecoration(labelText: context.bheText('选择球员分组')),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const Key('player-roster-group'),
                value: group?.name ?? '',
                isExpanded: true,
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(context.bheText('不使用')),
                  ),
                  for (final group in groups)
                    DropdownMenuItem(
                      value: group.name,
                      child: Text(group.name),
                    ),
                ],
                onChanged: widget.enabled
                    ? (value) {
                        setState(
                          () => _select(
                            value == '' ? null : value,
                            explicit: true,
                          ),
                        );
                        _emit();
                      }
                    : null,
              ),
            ),
          ),
          if (widget.hasExistingPlayers) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              context.bheText('项目已有球员。选择分组可追加名单，不会删除或调整现有球员。'),
              style: TextStyle(color: c.textSecondary),
            ),
          ],
          if (group != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('player-roster-default'),
                icon: Icon(
                  group.name == defaultName ? Icons.star : Icons.star_border,
                  size: 18,
                ),
                label: Text(
                  context.bheText(group.name == defaultName ? '取消默认' : '设为默认'),
                ),
                onPressed: widget.enabled
                    ? () => ref
                          .read(playerGroupsProvider.notifier)
                          .setDefault(
                            group.name == defaultName ? null : group.name,
                          )
                    : null,
              ),
            ),
            Text(
              context.bheText('只勾选本次出场的球员，不会修改分组。'),
              style: TextStyle(color: c.textSecondary),
            ),
            for (final name in group.players)
              CheckboxListTile(
                key: ValueKey('roster-player-$name'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(name),
                value: _checked.contains(name),
                onChanged: widget.enabled
                    ? (checked) {
                        setState(() {
                          _explicit = true;
                          if (checked == true) {
                            _checked.add(name);
                          } else {
                            _checked.remove(name);
                          }
                        });
                        _emit();
                      }
                    : null,
              ),
          ],
        ],
      ],
    );
  }
}
