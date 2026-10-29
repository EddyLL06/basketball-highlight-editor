import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/engine_session.dart';

/// A project-scoped contact sheet. All persistence goes through the engine.
class ShooterQuickLabel extends StatefulWidget {
  const ShooterQuickLabel({
    super.key,
    required this.request,
    this.initialVideoId,
  });

  final Future<JsonMap> Function(String command, JsonMap payload) request;
  final String? initialVideoId;

  @override
  State<ShooterQuickLabel> createState() => _ShooterQuickLabelState();
}

class _ShooterQuickLabelState extends State<ShooterQuickLabel> {
  List<JsonMap> _rows = [], _players = [], _videos = [];
  final _frameChoices = <String, int>{};
  final _trackChoices = <String, int?>{};
  final _saving = <String>{};
  final _undo = <JsonMap>[];
  final _focus = FocusNode();
  String? _activeId, _videoId, _error, _watchingJob;
  JsonMap? _job;
  String _filter = 'all';
  bool _loading = true, _preparing = false, _context = false;

  String t(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  static JsonMap _map(dynamic value) =>
      value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
  static List<JsonMap> _maps(dynamic value) =>
      value is List ? value.whereType<Map>().map(_map).toList() : [];
  static String _id(JsonMap row) => row['id'].toString();
  static String _time(dynamic ms) {
    final seconds = ((ms as num?)?.toDouble() ?? 0) / 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toStringAsFixed(2).padLeft(5, '0')}';
  }

  bool get _running => ['queued', 'running'].contains(_job?['state']);
  List<JsonMap> get _visible => _rows.where((row) {
    if (_videoId != null && row['video_id'] != _videoId) return false;
    if (_filter == 'pending') return row['shooter_review_state'] == 'pending';
    if (_filter == 'uncertain') {
      return row['shooter_review_state'] == 'uncertain' ||
          _map(row['shooter_evidence'])['release_uncertain'] == true ||
          row['shooter_evidence'] == null;
    }
    return true;
  }).toList();

  @override
  void initState() {
    super.initState();
    _videoId = widget.initialVideoId;
    unawaited(_load());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await widget.request('list_shooter_review', {});
      if (!mounted) return;
      setState(() {
        _rows = _maps(result['candidates']);
        _players = _maps(result['players']);
        _videos = _maps(result['videos']);
        if (!_videos.any((v) => v['id'] == _videoId)) _videoId = null;
        _job = _maps(result['jobs']).firstOrNull;
        _loading = false;
        if (!_visible.any((row) => _id(row) == _activeId)) {
          _activeId = _visible.firstOrNull?['id']?.toString();
        }
      });
      final job = _job;
      if (job != null && _running && _watchingJob != job['id']) {
        unawaited(_watch(job['id'].toString()));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _watch(String id) async {
    _watchingJob = id;
    var ticks = 0;
    try {
      while (mounted && _watchingJob == id) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!mounted || _watchingJob != id) return;
        final result = await widget.request('get_job', {'job_id': id});
        if (!mounted) return;
        setState(() => _job = _map(result['job']));
        if (_running && _job?['type'] == 'analysis' && ++ticks % 2 == 0) {
          await _load();
        }
        if (!_running) {
          _watchingJob = null;
          _frameChoices.clear();
          _trackChoices.clear();
          await _load();
          return;
        }
      }
    } catch (error) {
      _watchingJob = null;
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _prepare({bool import = false}) async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      String? path;
      if (import) {
        if (_videoId == null) {
          throw StateError(
            t('请先选择对应的一段视频', 'Select one video before importing'),
          );
        }
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'Shooter analysis JSON',
              extensions: ['json'],
            ),
          ],
        );
        if (file == null) return;
        path = file.path;
      }
      final result = await widget.request('prepare_shooter_review', {
        if (_videoId != null) 'video_id': _videoId,
        'predictions_path': ?path,
      });
      if (!mounted) return;
      setState(() => _job = _map(result['job']));
      unawaited(_watch(_job!['id'].toString()));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.request('cancel_job', {'job_id': _job!['id']});
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _addPlayer() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('添加球员', 'Add player')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: t('球员名字', 'Player name')),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(t('添加', 'Add')),
          ),
        ],
      ),
    );
    // The dialog's route may still animate out; its TextField owns the controller
    // until the next frame. Let that route release it before disposing.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    try {
      await widget.request('create_player', {'name': name.trim()});
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  List<JsonMap> _frames(JsonMap row) =>
      _maps(_map(row['shooter_evidence'])['frames']);
  int _frameIndex(JsonMap row) {
    final frames = _frames(row);
    if (frames.isEmpty) return 0;
    final selected = _frameChoices[_id(row)];
    if (selected != null) return selected.clamp(0, frames.length - 1).toInt();
    final saved = _map(row['shooter_selection']);
    final evidence = _map(row['shooter_evidence']);
    final time =
        (saved['generation'] == evidence['generation']
                ? saved['time_ms']
                : evidence['release_time_ms'])
            as num? ??
        0;
    var best = 0;
    for (var i = 1; i < frames.length; i++) {
      if (((frames[i]['time_ms'] as num) - time).abs() <
          ((frames[best]['time_ms'] as num) - time).abs()) {
        best = i;
      }
    }
    return best;
  }

  int? _track(JsonMap row, JsonMap frame) {
    final id = _id(row), evidence = _map(row['shooter_evidence']);
    final saved = _map(row['shooter_selection']);
    final chosen = _trackChoices.containsKey(id)
        ? _trackChoices[id]
        : saved['generation'] == evidence['generation'] &&
              saved.containsKey('track_id')
        ? saved['track_id']
        : evidence['recommended_track_id'];
    return _maps(frame['people']).any((p) => p['track_id'] == chosen)
        ? chosen as int?
        : null;
  }

  Future<void> _save(
    JsonMap row,
    String? playerId,
    String state, {
    JsonMap? restore,
  }) async {
    final id = _id(row),
        frames = _frames(row),
        evidence = _map(row['shooter_evidence']);
    if (_saving.isNotEmpty || evidence.isEmpty || frames.isEmpty || row['draft'] == true) {
      return;
    }
    final frame = frames[_frameIndex(row)];
    final previous = _map(row['shooter_selection']);
    final sameGeneration = previous['generation'] == evidence['generation'];
    final prior = <String, dynamic>{
      'candidate_id': id,
      'generation': evidence['generation'],
      'player_id': row['player_id'],
      'review_state': row['shooter_review_state'],
      'time_ms': sameGeneration ? previous['time_ms'] : null,
      'track_id': sameGeneration ? previous['track_id'] : null,
    };
    // Labels assigned in the ordinary review page predate this evidence. They
    // can be restored as a name-only confirmation, without inventing a track.
    if (prior['player_id'] != null) prior['review_state'] = 'confirmed';
    setState(() {
      _saving.add(id);
      _error = null;
      _activeId = id;
    });
    try {
      final result = await widget.request('set_candidate_shooter', {
        'candidate_id': id,
        'generation': evidence['generation'],
        'time_ms': frame['time_ms'],
        'track_id': _track(row, frame),
        'player_id': playerId,
        'review_state': state,
        ...?restore,
      });
      if (!mounted) return;
      setState(() {
        if (restore == null) _undo.add(prior);
        row['player_id'] = playerId;
        row['player_name'] = _players
            .where((p) => p['id'] == playerId)
            .firstOrNull?['name'];
        row['shooter_selection'] = result['selection'];
        row['shooter_review_state'] = result['review_state'];
        _trackChoices.remove(id);
        _frameChoices.remove(id);
        if (!_visible.any((r) => _id(r) == id)) {
          _activeId = _visible.firstOrNull?['id']?.toString();
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving.remove(id));
    }
  }

  Future<void> _undoLast() async {
    if (_undo.isEmpty || _saving.isNotEmpty) return;
    final value = _undo.last;
    final row = _rows.where((r) => _id(r) == value['candidate_id']).firstOrNull;
    if (row == null ||
        _map(row['shooter_evidence'])['generation'] != value['generation']) {
      setState(() {
        _undo.clear();
        _error = t(
          '画面已更新，无法撤销旧版本的选择',
          'Evidence changed; old selections cannot be undone',
        );
      });
      return;
    }
    await _save(
      row,
      value['player_id'] as String?,
      value['review_state'] as String,
      restore: value,
    );
    if (mounted && _error == null) setState(() => _undo.removeLast());
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _saving.isNotEmpty) {
      return KeyEventResult.ignored;
    }
    final index = const [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ].indexOf(event.logicalKey);
    final row = _visible.where((r) => _id(r) == _activeId).firstOrNull;
    if (index >= 0 && index < _players.length && row != null) {
      unawaited(_save(row, _players[index]['id'].toString(), 'confirmed'));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final completed = _rows
        .where((r) => r['shooter_review_state'] == 'confirmed')
        .length;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('射手快标', 'Shooter quick label')),
          leading: IconButton(
            tooltip: t('返回审核', 'Back to review'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            TextButton.icon(
              onPressed: _undo.isEmpty || _saving.isNotEmpty ? null : _undoLast,
              icon: const Icon(Icons.undo),
              label: Text(t('撤销', 'Undo')),
            ),
            IconButton(
              tooltip: t('刷新', 'Refresh'),
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t(
                      '出手附近画面由分析自动准备。看图认人，点击名字保存；数字 1–9 标记当前卡片。',
                      'Release stills are prepared during analysis. Recognize the shooter and choose a name; keys 1–9 label the selected card.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        t(
                          '已标 $completed / ${_rows.length}',
                          'Labeled $completed / ${_rows.length}',
                        ),
                      ),
                      DropdownButton<String>(
                        value: _videoId ?? 'all',
                        items: [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text(t('全部视频', 'All videos')),
                          ),
                          for (var i = 0; i < _videos.length; i++)
                            DropdownMenuItem(
                              value: _videos[i]['id'].toString(),
                              child: Text(t('第 ${i + 1} 段', 'Video ${i + 1}')),
                            ),
                        ],
                        onChanged: (value) => setState(() {
                          _videoId = value == 'all' ? null : value;
                          _activeId = null;
                        }),
                      ),
                      for (final option in ['all', 'pending', 'uncertain'])
                        ChoiceChip(
                          label: Text(
                            option == 'all'
                                ? t('全部', 'All')
                                : option == 'pending'
                                ? t('待标注', 'Pending')
                                : t('需核实', 'Uncertain'),
                          ),
                          selected: _filter == option,
                          onSelected: (_) => setState(() => _filter = option),
                        ),
                      FilterChip(
                        label: Text(t('显示全景蓝框', 'Show full frame')),
                        selected: _context,
                        onSelected: (v) => setState(() => _context = v),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running || _preparing
                            ? null
                            : () => _prepare(),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(t('补齐/刷新画面', 'Refresh stills')),
                      ),
                      TextButton(
                        onPressed: _running || _preparing
                            ? null
                            : () => _prepare(import: true),
                        child: Text(t('导入已有分析', 'Import analysis')),
                      ),
                      TextButton.icon(
                        onPressed: _addPlayer,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: Text(t('添加球员', 'Add player')),
                      ),
                    ],
                  ),
                  if (_running || _preparing) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _preparing
                          ? null
                          : ((_job?['progress'] as num?)?.toDouble() ?? 0)
                                .clamp(0, 1),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _job?['type'] == 'analysis' ? t(
                              '分析中：出手画面会陆续出现，完成后可标注射手。',
                              'Analysis in progress: release stills appear here; label shooters after completion.',
                            ) : t(
                              '正在准备出手画面，原有标签保留。可关闭此页，稍后回来。',
                              'Preparing frames; existing labels are preserved. You can return later.',
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _running ? _cancel : null,
                          child: Text(t('取消任务', 'Cancel task')),
                        ),
                      ],
                    ),
                  ],
                  if (_error != null || _job?['state'] == 'failed')
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText(
                        _error ?? _job?['error_message']?.toString() ?? '',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_players.isEmpty)
                    Text(
                      t(
                        '先添加球员名字，之后即可一键标注。',
                        'Add player names to start labeling.',
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                  ? Center(
                      child: Text(t('当前筛选下没有片段', 'No clips match this filter')),
                    )
                  : LayoutBuilder(
                      builder: (context, size) {
                        final columns = (size.maxWidth / 370)
                            .floor()
                            .clamp(1, 6)
                            .toInt();
                        return GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: 660,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 16,
                              ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) => _card(
                            visible[index],
                            _rows.indexOf(visible[index]) + 1,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _image(String? path, {BoxFit fit = BoxFit.contain}) => path == null
      ? Center(
          child: Text(t('暂无出手画面，请先生成', 'Prepare frames to see the shooter')),
        )
      : Image.file(
          File(path),
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, error, stack) => Center(
            child: Text(
              t('图片不可用，请重新生成', 'Image unavailable; prepare frames again'),
            ),
          ),
        );

  Widget _card(JsonMap row, int number) {
    final id = _id(row),
        evidence = _map(row['shooter_evidence']),
        frames = _frames(row);
    final frame = frames.isEmpty
        ? <String, dynamic>{}
        : frames[_frameIndex(row)];
    final track = _track(row, frame), people = _maps(frame['people']);
    final person = people.where((p) => p['track_id'] == track).firstOrNull;
    final light = evidence['method'] == 'ball_release_preview_v1';
    final focus = _map(frame['focus_region']);
    final draft = row['draft'] == true;
    final uncertain = evidence['release_uncertain'] == true;
    final state = row['shooter_review_state'];
    final canSave =
        evidence.isNotEmpty && !draft && !_saving.contains(id) && _saving.isEmpty;
    final active = _activeId == id;
    return Card(
      key: ValueKey('shooter-card-$id'),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor,
          width: active ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          setState(() => _activeId = id);
          _focus.requestFocus();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '#$number  ${_time(row['event_time_ms'])}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    draft ? t('分析中预览', 'Analysis preview') : state == 'confirmed'
                        ? t('已保存', 'Saved')
                        : state == 'uncertain'
                        ? t('不确定', 'Uncertain')
                        : t('待标注', 'Pending'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                height: 238,
                decoration: BoxDecoration(
                  color: Colors.black87,
                  border: Border.all(color: Colors.lightBlueAccent, width: 2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _image(
                  (_context ? frame['context_path']
                      : person?['crop_path'] ?? focus['crop_path'] ?? frame['context_path'])
                      as String?,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                evidence.isEmpty
                    ? row['shooter_evidence_stale'] == true
                          ? t(
                              '源视频已变化，请重新生成',
                              'Source changed; prepare frames again',
                            )
                          : t('尚未生成出手画面', 'Frames not prepared')
                    : light
                    ? t('出手附近 · ${_time(frame['time_ms'])}', 'Near release · ${_time(frame['time_ms'])}')
                    : uncertain
                    ? t(
                        '出手时刻待核实 · ${_time(frame['time_ms'])}',
                        'Release uncertain · ${_time(frame['time_ms'])}',
                      )
                    : t(
                        '估计出手 · ${_time(frame['time_ms'])}',
                        'Estimated release · ${_time(frame['time_ms'])}',
                      ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(
                height: 38,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < frames.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          label: Text(
                            '${((frames[i]['time_ms'] as num) - (evidence['release_time_ms'] as num)).round()} ms',
                          ),
                          selected: i == _frameIndex(row),
                          onSelected: (_) => setState(() {
                            _activeId = id;
                            _frameChoices[id] = i;
                          }),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                  ),
                ),
              ),
              if (light) Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t('蓝框仅表示大致出手区域，请自行确认射手。', 'The blue region is approximate. Choose the shooter by sight.'),
                  style: Theme.of(context).textTheme.bodySmall),
              ),
              if (!light) SizedBox(
                height: 58,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in people)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Semantics(
                          button: true,
                          selected: track == p['track_id'],
                          label: 'Track ${p['track_id']}',
                          child: InkWell(
                            key: ValueKey(
                              'shooter-person-$id-${p['track_id']}',
                            ),
                            onTap: () {
                              setState(() {
                                _activeId = id;
                                _trackChoices[id] = p['track_id'] as int;
                              });
                              _focus.requestFocus();
                            },
                            child: Container(
                              width: 72,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: track == p['track_id']
                                      ? Colors.lightBlueAccent
                                      : Theme.of(context).dividerColor,
                                  width: 2,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: _image(p['crop_path'] as String?),
                                  ),
                                  Text(
                                    'Track ${p['track_id']}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (people.isEmpty)
                      Center(
                        child: Text(
                          t(
                            '无人框；可按名字标注或看视频',
                            'No person box; label by name or watch video',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                row['player_name'] == null
                    ? t('点击名字保存射手', 'Choose a name to save')
                    : t(
                        '射手：${row['player_name']}',
                        'Shooter: ${row['player_name']}',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < _players.length; i++)
                        FilledButton.tonal(
                          key: ValueKey(
                            'shooter-name-$id-${_players[i]['id']}',
                          ),
                          onPressed: canSave
                              ? () => _save(
                                  row,
                                  _players[i]['id'].toString(),
                                  'confirmed',
                                )
                              : null,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(
                            '${i < 9 ? '${i + 1} · ' : ''}${_players[i]['name']}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: canSave
                        ? () => _save(row, null, 'uncertain')
                        : null,
                    child: Text(t('不确定', 'Uncertain')),
                  ),
                  TextButton(
                    onPressed: canSave
                        ? () => _save(row, null, 'pending')
                        : null,
                    child: Text(t('清除', 'Clear')),
                  ),
                  TextButton.icon(
                    onPressed: _saving.isEmpty && !draft
                        ? () => Navigator.pop(context, id)
                        : null,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: Text(t('看视频', 'Watch clip')),
                  ),
                ],
              ),
              Text(
                row['selection_status'] == 'excluded'
                    ? t(
                        '片段已排除 · 射手仍可标注',
                        'Excluded clip · shooter can still be labeled',
                      )
                    : t(
                        '片段已保留 · 射手独立保存',
                        'Included clip · shooter saved separately',
                      ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
