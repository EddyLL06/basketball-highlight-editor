part of '../../mobile_ui.dart';

class _PlayerGroupEditor extends StatefulWidget {
  const _PlayerGroupEditor({required this.state, required this.group});
  final MobileAppState state;
  final ({String name, List<String> players}) group;

  @override
  State<_PlayerGroupEditor> createState() => _PlayerGroupEditorState();
}

class _PlayerGroupEditorState extends State<_PlayerGroupEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.group.name,
  );
  final _newPlayer = TextEditingController();
  late final List<String> _original = List.of(widget.group.players);
  late final List<({int id, String name})> _players = [
    for (var i = 0; i < _original.length; i++) (id: i, name: _original[i]),
  ];
  late int _nextId = _players.length;
  String? _error;
  DiagnosticErrorRecord? _failure;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _newPlayer.dispose();
    super.dispose();
  }

  bool _addPlayer() {
    final name = _newPlayer.text.trim();
    if (name.isEmpty || _players.any((player) => player.name == name)) {
      setState(() => _error = name.isEmpty ? '球员名不能为空' : '分组内的球员不能重名');
      return false;
    }
    setState(() {
      _players.add((id: _nextId++, name: name));
      _newPlayer.clear();
      _error = null;
    });
    return true;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_newPlayer.text.trim().isNotEmpty && !_addPlayer()) return;
    final name = _name.text.trim();
    if (name.isEmpty ||
        widget.state.playerGroups.any(
          (g) => g.name == name && g.name != widget.group.name,
        )) {
      setState(() => _error = name.isEmpty ? '分组名不能为空' : '分组名已存在，请使用其他名称');
      return;
    }
    final names = _players.map((player) => player.name.trim()).toList();
    if (names.any((name) => name.isEmpty) ||
        names.toSet().length != names.length) {
      setState(() => _error = '分组内的球员不能重名');
      return;
    }
    final before = widget.state.playerGroupError;
    setState(() {
      _saving = true;
      _error = null;
      _failure = null;
    });
    final saved = await widget.state.editPlayerGroup(
      widget.group.name,
      name,
      names,
      expectedPlayers: _original,
    );
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
      return;
    }
    final after = widget.state.playerGroupError;
    setState(() {
      _saving = false;
      _failure = identical(before, after) ? null : after;
      _error = _failure == null ? '分组已变更，请重新选择' : '保存失败，请重试';
    });
  }

  Future<void> _action(int index, String action) async {
    if (_saving) return;
    if (action == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(context.bheText('确认移除球员？')),
          content: Text(_players[index].name),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.bheText('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(context.bheText('移除球员')),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      setState(() => _players.removeAt(index));
    } else {
      final target = action == 'up' ? index - 1 : index + 1;
      if (target < 0 || target >= _players.length) return;
      setState(() {
        final player = _players.removeAt(index);
        _players.insert(target, player);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: context.bheText('取消'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(context.bheText('编辑球员分组')),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('group-editor-name'),
                controller: _name,
                enabled: !_saving,
                decoration: InputDecoration(labelText: context.bheText('分组名称')),
              ),
              if (_error != null)
                _InlineNotice(
                  error: true,
                  message: context.bheText(_error!),
                  action: _failure == null
                      ? null
                      : TextButton(
                          onPressed: () =>
                              showMobileDiagnostics(context, error: _failure),
                          child: Text(context.bheText('反馈')),
                        ),
                ),
              Text(context.bheText('球员顺序影响名单显示顺序')),
              Expanded(
                child: _players.isEmpty
                    ? Center(child: Text(context.bheText('还没有球员，请添加。')))
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: _players.length,
                        onReorderItem: (oldIndex, newIndex) {
                          if (_saving) return;
                          setState(() {
                            final player = _players.removeAt(oldIndex);
                            _players.insert(newIndex, player);
                          });
                        },
                        itemBuilder: (context, index) {
                          final player = _players[index];
                          return ListTile(
                            key: ValueKey('group-editor-row-${player.id}'),
                            contentPadding: EdgeInsets.zero,
                            leading: ReorderableDelayedDragStartListener(
                              index: index,
                              enabled: !_saving,
                              child: SizedBox(
                                key: ValueKey(
                                  'group-editor-handle-${player.id}',
                                ),
                                width: 48,
                                height: 48,
                                child: Semantics(
                                  label: context.bheText('拖动调整顺序'),
                                  child: const Icon(Icons.drag_handle),
                                ),
                              ),
                            ),
                            title: Text(
                              player.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: PopupMenuButton<String>(
                              key: ValueKey('group-editor-menu-${player.id}'),
                              enabled: !_saving,
                              onSelected: (action) => _action(index, action),
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'up',
                                  enabled: index > 0,
                                  child: Text(context.bheText('上移')),
                                ),
                                PopupMenuItem(
                                  value: 'down',
                                  enabled: index + 1 < _players.length,
                                  child: Text(context.bheText('下移')),
                                ),
                                PopupMenuItem(
                                  value: 'remove',
                                  child: Text(context.bheText('移除球员')),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('group-editor-new-player'),
                      controller: _newPlayer,
                      enabled: !_saving,
                      decoration: InputDecoration(
                        labelText: context.bheText('球员姓名'),
                      ),
                      onSubmitted: (_) => _addPlayer(),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('group-editor-add'),
                    onPressed: _saving ? null : _addPlayer,
                    tooltip: context.bheText('添加'),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('group-editor-save'),
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: Text(context.bheText('保存')),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}
