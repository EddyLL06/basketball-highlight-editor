part of '../../mobile_ui.dart';

class _RosterConfirmation extends StatefulWidget {
  const _RosterConfirmation({required this.state});
  final MobileAppState state;

  @override
  State<_RosterConfirmation> createState() => _RosterConfirmationState();
}

class _RosterConfirmationState extends State<_RosterConfirmation> {
  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
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
                      onPressed: () => Navigator.pop(context, false),
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
                        onChanged: (value) => setState(() {
                          final group = groups.where(
                            (item) => item.name == value,
                          );
                          draft.choose(
                            value == '' ? null : value,
                            group.isEmpty ? const [] : group.first.players,
                          );
                        }),
                      ),
                      if (draft.groupChanged)
                        Text(context.bheText('球员分组已不存在，请重新选择')),
                      if (draft.groupName != null) ...[
                        const SizedBox(height: 8),
                        Text(context.bheText('只勾选本次出场的球员，不会修改分组。')),
                        if (players.isEmpty) Text(context.bheText('这个分组还没有球员')),
                        for (final player in players)
                          CheckboxListTile(
                            key: ValueKey('roster-player-$player'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              player,
                              overflow: TextOverflow.ellipsis,
                            ),
                            value: draft.selected.contains(player),
                            onChanged: (value) => setState(() {
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
                      onPressed: () async {
                        await showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          enableDrag: false,
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
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(l10n?.cancel ?? '取消'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: draft.groupChanged
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
  );
}
