import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/engine_session.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';
import 'review_text_entry_dialog.dart';
import 'shooter_identity_panel.dart';

/// A project-scoped contact sheet. All persistence goes through the engine.
class ShooterQuickLabel extends StatefulWidget {
  const ShooterQuickLabel({
    super.key,
    required this.request,
    this.initialVideoId,
    this.embedded = false,
    this.active = true,
    this.reloadToken = 0,
    this.onWatchClip,
    this.onSavingChanged,
  });

  final Future<JsonMap> Function(String command, JsonMap payload) request;
  final String? initialVideoId;
  final bool embedded, active;
  final int reloadToken;
  final ValueChanged<String>? onWatchClip;
  final ValueChanged<bool>? onSavingChanged;

  @override
  State<ShooterQuickLabel> createState() => _ShooterQuickLabelState();
}

class _ShooterQuickLabelState extends State<ShooterQuickLabel> {
  List<JsonMap> _rows = [], _players = [], _videos = [];
  JsonMap _gallery = {};
  final Map<String, dynamic> _personChoices = {};
  bool _showReferences = false;
  final _frameChoices = <String, int>{};
  final _saving = <String>{};
  final _undo = <JsonMap>[];
  final _focus = FocusNode();
  String? _activeId, _videoId, _error, _watchingJob;
  JsonMap? _job;
  String _filter = 'all';
  bool _loading = true, _preparing = false, _context = false;
  bool _addingPlayer = false;

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
      if (row['shooter_review_state'] == 'confirmed') return false;
      if (_auto(row).isNotEmpty) {
        return row['shooter_review_state'] == 'uncertain' ||
            _auto(row)['selected_track_id'] == null ||
            _map(_auto(row)['prediction'])['status'] != 'suggested';
      }
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
  void didUpdateWidget(covariant ShooterQuickLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && widget.reloadToken != oldWidget.reloadToken) {
      unawaited(_load());
    }
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  void _notifyBusy() =>
      widget.onSavingChanged?.call(_addingPlayer || _saving.isNotEmpty);

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
        _gallery = _map(result['identity_gallery']);
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
          await _load();
          if (mounted && _job?['stage'] == 'shooter_references') {
            setState(() => _showReferences = true);
          }
          return;
        }
      }
    } catch (error) {
      _watchingJob = null;
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _prepare() async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final result = await widget.request('prepare_shooter_review', {
        if (_videoId != null) 'video_id': _videoId,
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

  Future<void> _identify() async {
    setState(() { _preparing = true; _error = null; });
    try {
      final result = await widget.request('start_shooter_identification', {
        if (_videoId != null) 'video_id': _videoId,
      });
      if (!mounted) return;
      setState(() => _job = _map(result['job']));
      unawaited(_watch(_job!['id'].toString()));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _reference(JsonMap row, JsonMap sample, String playerId) async {
    await widget.request('set_shooter_reference', {
      'sample_id': sample['id'], 'generation': _auto(row)['generation'],
      'player_id': playerId, 'human_confirmed': true,
    });
    await _load();
  }

  Future<void> _removeReference(JsonMap reference) async {
    try {
      await widget.request('set_shooter_reference', {
        'sample_id': reference['sample_id'], 'remove': true,
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _adoptSuggestions() async {
    setState(() => _preparing = true);
    try {
      await widget.request('apply_shooter_suggestions', {
        'gallery_hash': _gallery['hash'],
        if (_videoId != null) 'video_id': _videoId,
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  JsonMap _auto(JsonMap row) => _map(row['shooter_auto']);
  JsonMap _evidence(JsonMap row) => _auto(row).isNotEmpty
      ? _auto(row) : _map(row['shooter_evidence']);

  Future<void> _personDetail(JsonMap row) async {
    final auto = _auto(row);
    if (auto.isEmpty) {
      setState(() => _context = !_context);
      return;
    }
    final frames = _frames(row);
    final frame = frames.isEmpty ? null : frames[_frameIndex(row)];
    final selected = await showShooterPersonDetail(context,
      observation: auto, players: _players, selected: frame?['sample'] as JsonMap?,
      busy: _running || _preparing,
      onReference: (sample, player) => _reference(row, sample, player),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _personChoices[_id(row)] = selected['track_id'];
      _activeId = _id(row);
      _frameChoices.remove(_id(row));
    });
  }

  Future<void> _cancel() async {
    try {
      await widget.request('cancel_job', {'job_id': _job!['id']});
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _addPlayer([JsonMap? row]) async {
    if (_addingPlayer || _saving.isNotEmpty) return;
    final name = await promptReviewPlayerName(context);
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() => _addingPlayer = true);
    _notifyBusy();
    try {
      final result = await widget.request('create_player', {
        'name': name.trim(),
      });
      final playerId = _map(result['player'])['id']?.toString();
      await _load();
      if (!mounted || row == null || playerId == null) return;
      final current = _rows.where((r) => _id(r) == _id(row)).firstOrNull;
      if (current != null) await _save(current, playerId, 'confirmed');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _addingPlayer = false);
        _notifyBusy();
      }
    }
  }

  List<JsonMap> _frames(JsonMap row) {
    final auto = _auto(row);
    if (auto.isEmpty) return _maps(_map(row['shooter_evidence'])['frames']);
    final trackId = _personChoices[_id(row)] ??
        _map(auto['selection'])['track_id'] ?? auto['selected_track_id'];
    final track = _maps(auto['tracks']).where((t) => t['id'] == trackId).firstOrNull;
    final samples = _maps(track?['samples'])..sort((a, b) =>
        (a['time_ms'] as num).compareTo(b['time_ms'] as num));
    if (samples.isEmpty) return _maps(auto['context_frames']);
    return samples.map((s) => <String, dynamic>{
      'time_ms': s['time_ms'], 'context_path': s['context_path'], 'sample': s,
      'focus_region': {'crop_path': s['crop_path'], 'kind': 'person'},
    }).toList();
  }
  int _frameIndex(JsonMap row) {
    final frames = _frames(row);
    if (frames.isEmpty) return 0;
    final selected = _frameChoices[_id(row)];
    if (selected != null) return selected.clamp(0, frames.length - 1).toInt();
    final saved = _auto(row).isNotEmpty
        ? _map(_auto(row)['selection']) : _map(row['shooter_selection']);
    final evidence = _evidence(row);
    final time =
        (saved['generation'] == evidence['generation']
                ? saved['time_ms']
                : null)
            as num?;
    final targetTime = time ?? _auto(row)['display_time_ms'] as num?;
    if (targetTime == null) {
      return frames.length ~/ 2;
    }
    var best = 0;
    for (var i = 1; i < frames.length; i++) {
      if (((frames[i]['time_ms'] as num) - targetTime).abs() <
          ((frames[best]['time_ms'] as num) - targetTime).abs()) {
        best = i;
      }
    }
    return best;
  }

  Future<void> _save(
    JsonMap row,
    String? playerId,
    String state, {
    JsonMap? restore,
  }) async {
    final id = _id(row),
        frames = _frames(row),
        evidence = _evidence(row);
    if (_saving.isNotEmpty ||
        evidence.isEmpty ||
        frames.isEmpty ||
        row['draft'] == true) {
      return;
    }
    final frame = frames[_frameIndex(row)];
    final previous = _auto(row).isNotEmpty
        ? _map(_auto(row)['selection']) : _map(row['shooter_selection']);
    final sameGeneration = previous['generation'] == evidence['generation'];
    final prior = <String, dynamic>{
      'candidate_id': id,
      'generation': evidence['generation'],
      'player_id': row['player_id'],
      'review_state': row['shooter_review_state'],
      'time_ms': sameGeneration ? previous['time_ms'] : null,
      if (_auto(row).isNotEmpty) ...{
        'automatic_evidence': true,
        'sample_id': sameGeneration ? previous['sample_id'] : null,
      },
    };
    // Ordinary review labels may predate these stills; undo can restore a name
    // without claiming that an evidence frame had already been selected.
    if (prior['player_id'] != null) prior['review_state'] = 'confirmed';
    setState(() {
      _saving.add(id);
      _error = null;
      _activeId = id;
    });
    _notifyBusy();
    try {
      final result = await widget.request('set_candidate_shooter', {
        'candidate_id': id,
        'generation': evidence['generation'],
        'time_ms': frame['time_ms'],
        'player_id': playerId,
        'review_state': state,
        if (_auto(row).isNotEmpty) ...{
          'automatic_evidence': true,
          'sample_id': _map(frame['sample'])['id'],
        },
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
        if (_auto(row).isNotEmpty) _auto(row)['selection'] = result['selection'];
        row['shooter_review_state'] = result['review_state'];
        _frameChoices.remove(id);
        if (!_visible.any((r) => _id(r) == id)) {
          _activeId = _visible.firstOrNull?['id']?.toString();
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _saving.remove(id));
        _notifyBusy();
      }
    }
  }

  Future<void> _undoLast() async {
    if (_undo.isEmpty || _saving.isNotEmpty) return;
    final value = _undo.last;
    final row = _rows.where((r) => _id(r) == value['candidate_id']).firstOrNull;
    if (row == null ||
        _evidence(row)['generation'] != value['generation']) {
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
    if (!widget.active ||
        event is! KeyDownEvent ||
        _saving.isNotEmpty ||
        _addingPlayer) {
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
    final c = AppColors.of(context);
    final visible = _visible;
    final completed = _rows
        .where((r) => r['shooter_review_state'] == 'confirmed')
        .length;
    return ExcludeFocus(
      excluding: !widget.active,
      child: Focus(
        focusNode: _focus,
        autofocus: widget.active,
        onKeyEvent: _key,
        child: Scaffold(
          backgroundColor: c.background,
          appBar: widget.embedded
              ? null
              : AppBar(
                  title: Text(t('射手快标', 'Shooter quick label')),
                  leading: IconButton(
                    tooltip: t('返回审核', 'Back to review'),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
          body: Column(
            children: [
              Container(
                width: double.infinity,
                color: c.surface,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: Spacing.sm,
                      runSpacing: Spacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          t(
                            '已标 $completed / ${_rows.length}',
                            'Labeled $completed / ${_rows.length}',
                          ),
                          style: TextStyle(color: c.textSecondary),
                        ),
                        DropdownButton<String>(
                          value: _videos.any((v) => v['id'] == _videoId)
                              ? _videoId
                              : 'all',
                          isDense: true,
                          items: [
                            DropdownMenuItem(
                              value: 'all',
                              child: Text(t('全部视频', 'All videos')),
                            ),
                            for (var i = 0; i < _videos.length; i++)
                              DropdownMenuItem(
                                value: _videos[i]['id'].toString(),
                                child: Text(
                                  t('第 ${i + 1} 段', 'Video ${i + 1}'),
                                ),
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
                            selectedColor: c.orange.withValues(alpha: .14),
                            backgroundColor: c.surface2,
                            labelStyle: TextStyle(
                              color: _filter == option
                                  ? c.orange
                                  : c.textSecondary,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(CsRadius.sm),
                            ),
                            onSelected: (_) => setState(() => _filter = option),
                          ),
                        FilledButton.icon(
                          key: const Key('identify-shooters'),
                          onPressed: _running || _preparing
                              ? null
                              : _identify,
                          style: FilledButton.styleFrom(backgroundColor: c.orange,
                              foregroundColor: Colors.black),
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: Text(t('自动识别出手者', 'Identify shooters')),
                        ),
                        PopupMenuButton<String>(
                          tooltip: t('更多操作', 'More actions'),
                          onSelected: (value) {
                            if (value == 'references') setState(() => _showReferences = !_showReferences);
                            if (value == 'context') setState(() => _context = !_context);
                            if (value == 'stills') unawaited(_prepare());
                            if (value == 'refresh') unawaited(_load());
                            if (value == 'undo') unawaited(_undoLast());
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'references', child: Text(t('球员参考图', 'Player references'))),
                            PopupMenuItem(value: 'context', child: Text(t('显示全景蓝框', 'Show full frame'))),
                            PopupMenuItem(value: 'stills', enabled: !_running && !_preparing,
                                child: Text(t('补齐/刷新画面', 'Refresh stills'))),
                            PopupMenuItem(value: 'undo', enabled: _undo.isNotEmpty && _saving.isEmpty,
                                child: Text(t('撤销', 'Undo'))),
                            PopupMenuItem(value: 'refresh', child: Text(t('刷新', 'Refresh'))),
                          ],
                        ),
                      ],
                    ),
                    Text(
                      t(
                        '点击姓名保存；点击人物画面查看详情或设置参考图。数字 1–9 标记当前卡片。',
                        'Choose a name to save. Open an image for details or references. Keys 1–9 label the selected card.',
                      ),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: c.textSecondary),
                    ),
                    if (_showReferences || _maps(_gallery['references']).isNotEmpty)
                      ShooterIdentityPanel(
                        players: _players, gallery: _gallery,
                        expanded: _showReferences, busy: _running || _preparing,
                        onRemove: (r) => unawaited(_removeReference(r)),
                        onAddPlayer: () => unawaited(_addPlayer()),
                      ),
                    if (_rows.any((r) => (_videoId == null || r['video_id'] == _videoId) && r['player_id'] == null &&
                        r['shooter_review_state'] == 'pending' &&
                        _map(_auto(r)['prediction'])['status'] == 'suggested'))
                      Align(alignment: Alignment.centerRight, child: TextButton(
                        key: const Key('adopt-shooter-suggestions'),
                        onPressed: _running || _preparing ? null : _adoptSuggestions,
                        child: Text(t('采用本次建议', 'Use suggestions')),
                      )),
                    if (_running || _preparing) ...[
                      const SizedBox(height: Spacing.sm),
                      LinearProgressIndicator(
                        value: _preparing
                            ? null
                            : ((_job?['progress'] as num?)?.toDouble() ?? 0)
                                  .clamp(0, 1),
                        color: c.orange,
                        backgroundColor: c.surface3,
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _job?['type'] == 'analysis'
                                  ? t(
                                      '分析中：出手画面会陆续出现，完成后可标注射手。',
                                      'Analysis in progress: release stills appear here; label shooters after completion.',
                                    )
                                  : t(
                                      '正在处理代理出手画面，原有标签保留。',
                                      'Processing proxy release frames; existing labels are preserved.',
                                    ),
                              style: Theme.of(context).textTheme.bodySmall,
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
                        padding: const EdgeInsets.only(top: Spacing.xs),
                        child: SelectableText(
                          _error ?? _job?['error_message']?.toString() ?? '',
                          style: TextStyle(color: c.error),
                        ),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : visible.isEmpty
                    ? Center(
                        child: Text(
                          t('当前筛选下没有片段', 'No clips match this filter'),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, size) {
                          final columns = size.maxWidth >= Breakpoints.md
                              ? 5
                              : size.maxWidth >= 600
                              ? 2
                              : 1;
                          final cardWidth =
                              (size.maxWidth -
                                  Spacing.md * 2 -
                                  12 * (columns - 1)) /
                              columns;
                          final imageHeight = (cardWidth - 20) * 4 / 3;
                          final scale =
                              (MediaQuery.textScalerOf(context).scale(13) / 13)
                                  .clamp(1.0, 2.0);
                          return GridView.builder(
                            key: const Key('shooter-card-grid'),
                            padding: const EdgeInsets.all(Spacing.md),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent:
                                      imageHeight + 220 * scale,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
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
      ),
    );
  }

  Widget _image(String? path, {BoxFit fit = BoxFit.contain}) => path == null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              t('暂无出手画面', 'No release frame'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        )
      : Image.file(
          File(path),
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, error, stack) => Center(
            child: Text(
              t('图片不可用，请刷新画面', 'Image unavailable; refresh stills'),
              textAlign: TextAlign.center,
            ),
          ),
        );

  void _selectFrame(JsonMap row, int index) {
    setState(() {
      _activeId = _id(row);
      _frameChoices[_id(row)] = index;
    });
    _focus.requestFocus();
  }

  Widget _framePreview(JsonMap row, JsonMap frame, int index) {
    final c = AppColors.of(context);
    final id = _id(row), evidence = _evidence(row);
    final focus = _map(frame['focus_region']);
    final cropPath = focus['crop_path'];
    final path =
        (_context ? frame['context_path'] : cropPath ?? frame['context_path'])
            as String?;
    final zoom =
        !_context &&
            cropPath != null &&
            evidence['reason'] == 'upward_ball_motion_estimate'
        ? 1.12
        : 1.0;
    final hasRegion = !_context && cropPath != null;
    return Semantics(
      image: true,
      label: t(
        '第 ${index + 1} 帧，${_time(frame['time_ms'])}',
        'Frame ${index + 1}, ${_time(frame['time_ms'])}',
      ),
      child: InkWell(
        onTap: () => unawaited(_personDetail(row)),
        child: Container(
        key: ValueKey('shooter-preview-$id-$index'),
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: c.borderStrong),
          borderRadius: BorderRadius.circular(CsRadius.sm),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: Transform.scale(
                key: ValueKey('shooter-frame-zoom-$id-$index'),
                scale: zoom,
                child: SizedBox.expand(child: _image(path)),
              ),
            ),
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: c.background.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  hasRegion ? focus['kind'] == 'person'
                      ? t('出手人物', 'Release person')
                      : t('出手区域', 'Release area') : t('全景', 'Full frame'),
                  style: TextStyle(
                    fontSize: 10,
                    color: hasRegion ? c.data : c.textSecondary,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: c.background.withValues(alpha: .82),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${index + 1} / ${_frames(row).length}',
                  style: TextStyle(fontSize: 10, color: c.textSecondary),
                ),
              ),
            ),
          ],
        ),
      )),
    );
  }

  String _frameLabel(int index, int count) {
    final middle = count ~/ 2;
    if (index == middle) return t('中间帧', 'Middle');
    return index < middle ? t('前一帧', 'Previous') : t('后一帧', 'Next');
  }

  Widget _framePicker(JsonMap row) {
    final c = AppColors.of(context);
    final id = _id(row), frames = _frames(row);
    return SizedBox(
      height: 30,
      child: Row(
        key: ValueKey('shooter-frames-$id'),
        children: [
          for (var i = 0; i < frames.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Semantics(
                selected: i == _frameIndex(row),
                child: Tooltip(
                  message:
                      '${_frameLabel(i, frames.length)} · ${_time(frames[i]['time_ms'])}',
                  child: TextButton(
                    key: ValueKey('shooter-frame-$id-$i'),
                    onPressed: () => _selectFrame(row, i),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      minimumSize: const Size(24, 28),
                      foregroundColor: i == _frameIndex(row)
                          ? c.orange
                          : c.textSecondary,
                      backgroundColor: i == _frameIndex(row)
                          ? c.orange.withValues(alpha: .14)
                          : c.surface2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      textStyle: const TextStyle(fontSize: 10),
                    ),
                    child: Text(
                      _frameLabel(i, frames.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(JsonMap row, int number) {
    final c = AppColors.of(context);
    final id = _id(row),
        evidence = _evidence(row),
        frames = _frames(row);
    final frame = frames.isEmpty
        ? <String, dynamic>{}
        : frames[_frameIndex(row)];
    final draft = row['draft'] == true;
    final state = row['shooter_review_state'];
    final canSave =
        evidence.isNotEmpty &&
        frames.isNotEmpty &&
        !draft &&
        _saving.isEmpty &&
        !_addingPlayer;
    final active = _activeId == id;
    final suggestion = _map(_auto(row)['prediction']);
    final suggestedName = suggestion['status'] == 'suggested'
        ? (_players.where((p) => p['id'] == suggestion['player_id']).firstOrNull?['name'])
        : null;
    return Card(
      key: ValueKey('shooter-card-$id'),
      margin: EdgeInsets.zero,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.md),
        side: BorderSide(
          color: active ? c.orange : c.border,
          width: active ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          setState(() => _activeId = id);
          _focus.requestFocus();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '#$number  ${_time(row['event_time_ms'])}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: c.textPrimary),
                    ),
                  ),
                  Text(
                    draft
                        ? t('分析中预览', 'Analysis preview')
                        : state == 'confirmed'
                        ? t('已保存', 'Saved')
                        : state == 'uncertain'
                        ? t('不确定', 'Uncertain')
                        : suggestedName != null
                        ? t('姓名建议', 'Suggested')
                        : t('待标注', 'Pending'),
                    style: TextStyle(
                      fontSize: 11,
                      color: state == 'confirmed' ? c.success : c.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              AspectRatio(
                key: ValueKey('shooter-photo-$id'),
                aspectRatio: 3 / 4,
                child: frames.isEmpty
                    ? _image(null)
                    : _framePreview(row, frame, _frameIndex(row)),
              ),
              if (frames.isNotEmpty && _auto(row).isEmpty) ...[
                const SizedBox(height: 4),
                _framePicker(row),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      row['player_name'] == null
                          ? suggestedName == null
                              ? t('点击名字保存射手', 'Choose a name to save')
                              : t('建议：$suggestedName', 'Suggested: $suggestedName')
                          : t(
                              '射手：${row['player_name']}',
                              'Shooter: ${row['player_name']}',
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: c.textPrimary),
                    ),
                  ),
                  TextButton.icon(
                    key: ValueKey('shooter-add-player-$id'),
                    onPressed: _addingPlayer || _saving.isNotEmpty
                        ? null
                        : () => _addPlayer(row),
                    icon: const Icon(Icons.person_add_alt_1, size: 15),
                    label: Text(t('添加球员', 'Add player')),
                    style: TextButton.styleFrom(
                      foregroundColor: c.orange,
                      minimumSize: const Size(44, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 4,
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
                            backgroundColor:
                                (row['player_id'] ?? suggestion['player_id']) == _players[i]['id']
                                ? c.orange.withValues(alpha: .16)
                                : c.surface2,
                            foregroundColor:
                                (row['player_id'] ?? suggestion['player_id']) == _players[i]['id']
                                ? c.orange
                                : c.textPrimary,
                            minimumSize: const Size(44, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(CsRadius.sm),
                            ),
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          child: Text(
                            '${_players[i]['name']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (_players.isEmpty)
                        Text(
                          t('添加球员后即可标注', 'Add players to start labeling'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: c.textSecondary),
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
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    child: Text(t('不确定', 'Uncertain')),
                  ),
                  TextButton(
                    onPressed: canSave
                        ? () => _save(row, null, 'pending')
                        : null,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                    child: Text(t('清除', 'Clear')),
                  ),
                  TextButton.icon(
                    onPressed: _saving.isEmpty && !_addingPlayer && !draft
                        ? () {
                            if (widget.onWatchClip case final watch?) {
                              watch(id);
                            } else {
                              Navigator.pop(context, id);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.play_circle_outline, size: 16),
                    label: Text(t('看视频', 'Watch clip')),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
              Text(
                row['shooter_evidence_stale'] == true
                    ? t('源视频已变化，请刷新画面', 'Source changed; refresh stills')
                    : row['selection_status'] == 'excluded'
                    ? t(
                        '片段已排除 · 射手仍可标注',
                        'Excluded clip · shooter can still be labeled',
                      )
                    : t(
                        '出手区域为估计 · 射手独立保存',
                        'Approximate release area · shooter saved separately',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 10,
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
