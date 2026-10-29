part of '../../mobile_ui.dart';

class _RosterConfirmation extends StatefulWidget {
  const _RosterConfirmation({required this.state});
  final MobileAppState state;

  @override
  State<_RosterConfirmation> createState() => _RosterConfirmationState();
}

class _RosterConfirmationState extends State<_RosterConfirmation> {
  bool _savingDefault = false;
  bool _defaultFailed = false;
  DiagnosticErrorRecord? _defaultFailure;

  Future<void> _toggleDefault(String group) async {
    if (_savingDefault) return;
    final before = widget.state.playerGroupError;
    setState(() {
      _savingDefault = true;
      _defaultFailed = false;
      _defaultFailure = null;
    });
    final saved = await widget.state.setDefaultPlayerGroup(
      widget.state.defaultPlayerGroupName == group ? null : group,
    );
    if (!mounted) return;
    final after = widget.state.playerGroupError;
    setState(() {
      _savingDefault = false;
      _defaultFailed = !saved;
      _defaultFailure = identical(before, after) ? null : after;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_savingDefault,
    child: DraggableScrollableSheet(
      initialChildSize: .8,
      minChildSize: .5,
      maxChildSize: .95,
      expand: false,
      builder: (context, scrollController) => SafeArea(
        child: AnimatedBuilder(
          animation: widget.state,
          builder: (context, _) {
            final state = widget.state;
            final draft = state.rosterSelection;
            final seenNames = <String>{};
            final groups = state.playerGroups
                .where(
                  (group) => group.name.isNotEmpty && seenNames.add(group.name),
                )
                .toList();
            final selection = draft.groupName ?? '';
            final matching = groups.where(
              (group) => group.name == draft.groupName,
            );
            final players = matching.isEmpty
                ? <String>[]
                : matching.first.players.toSet().toList();
            final l10n = Localizations.of<BheLocalizations>(
              context,
              BheLocalizations,
            );
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n?.startAnalysisTitle ?? '开始分析',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: _savingDefault
                            ? null
                            : () => Navigator.pop(context, false),
                        tooltip: context.bheText('返回上一步'),
                        icon: const Icon(LucideIcons.x),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      Text(
                        l10n?.foregroundAnalysisWarning ??
                            '分析期间请保持 BHE 在前台并保持屏幕亮起。锁屏或切到后台可能导致分析变慢或暂停。',
                      ),
                      const SizedBox(height: 16),
                      Text(
                        context.bheText('球员名单'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (groups.isEmpty)
                        Text(context.bheText('还没有球员分组，可以在审核页把球员存为分组。'))
                      else ...[
                        DropdownButtonFormField<String>(
                          key: ValueKey('roster-group-$selection'),
                          isExpanded: true,
                          initialValue: selection,
                          decoration: InputDecoration(
                            labelText: context.bheText('选择球员分组'),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(context.bheText('不使用')),
                            ),
                            for (final group in groups)
                              DropdownMenuItem(
                                value: group.name,
                                child: Text(
                                  group.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _savingDefault
                              ? null
                              : (value) => setState(() {
                                  final group = groups.where(
                                    (item) => item.name == value,
                                  );
                                  draft.choose(
                                    value == '' ? null : value,
                                    group.isEmpty
                                        ? const []
                                        : group.first.players,
                                  );
                                }),
                        ),
                        if (draft.groupChanged)
                          Text(context.bheText('球员分组已不存在，请重新选择')),
                        if (draft.groupName != null) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            key: const ValueKey('roster-default'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _savingDefault
                                ? null
                                : () => _toggleDefault(draft.groupName!),
                            child: Text(
                              context.bheText(
                                state.defaultPlayerGroupName == draft.groupName
                                    ? '取消默认'
                                    : '设为默认',
                              ),
                            ),
                          ),
                          if (_defaultFailed)
                            _InlineNotice(
                              error: true,
                              message: context.bheText(
                                _defaultFailure == null
                                    ? '分组操作未完成'
                                    : '保存失败，请重试',
                              ),
                              action: _defaultFailure == null
                                  ? null
                                  : TextButton(
                                      onPressed: () => showMobileDiagnostics(
                                        context,
                                        error: _defaultFailure,
                                      ),
                                      child: Text(context.bheText('反馈')),
                                    ),
                            ),
                          Text(context.bheText('只勾选本次出场的球员，不会修改分组。')),
                          if (players.isEmpty)
                            Text(context.bheText('这个分组还没有球员')),
                          for (final player in players)
                            CheckboxListTile(
                              key: ValueKey('roster-player-$player'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                player,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: draft.selected.contains(player),
                              onChanged: _savingDefault
                                  ? null
                                  : (value) => setState(() {
                                      if (value == true) {
                                        draft.selected.add(player);
                                      } else {
                                        draft.selected.remove(player);
                                      }
                                    }),
                            ),
                        ],
                      ],
                      const SizedBox(height: 8),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _savingDefault
                            ? null
                            : () async {
                                await showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  useSafeArea: true,
                                  enableDrag: false,
                                  isDismissible: false,
                                  builder: (_) => _PlayerGroupsSheet(
                                    state: state,
                                    allowImport: false,
                                  ),
                                );
                              },
                        child: Text(context.bheText('管理分组')),
                      ),
                      if (state.project.players.isNotEmpty)
                        Text(context.bheText('项目已有球员。选择分组可追加名单，不会删除或调整现有球员。')),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: _savingDefault
                              ? null
                              : () => Navigator.pop(context, false),
                          child: Text(l10n?.cancel ?? '取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: draft.groupChanged || _savingDefault
                              ? null
                              : () => Navigator.pop(context, true),
                          child: Text(l10n?.start ?? '开始'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
