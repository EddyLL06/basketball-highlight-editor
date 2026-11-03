import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/engine_session.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// References are explicit choices, separate from saved shooter names.
class ShooterIdentityPanel extends StatelessWidget {
  const ShooterIdentityPanel({
    super.key,
    required this.players,
    required this.gallery,
    required this.expanded,
    required this.busy,
    required this.onRemove,
    required this.onAddPlayer,
  });

  final List<JsonMap> players;
  final JsonMap gallery;
  final bool expanded, busy;
  final ValueChanged<JsonMap> onRemove;
  final VoidCallback onAddPlayer;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final c = AppColors.of(context);
    final counts = (gallery['counts'] as Map?) ?? {};
    final refs =
        (gallery['references'] as List?)?.whereType<Map>().toList() ?? [];
    final summary = players
        .where((p) => counts.containsKey(p['id']))
        .map((p) => '${p['name']} ${counts[p['id']]}')
        .join(' · ');
    return ExpansionTile(
      key: ValueKey('identity-gallery-$expanded'),
      initiallyExpanded: expanded,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: Spacing.sm),
      title: Text(zh ? '球员参考图' : 'Player references'),
      subtitle: Text(
        summary.isEmpty
            ? (zh
                  ? '为出场球员选择参考图，之后可一键识别'
                  : 'Choose references to identify players')
            : summary,
        style: TextStyle(color: c.textSecondary, fontSize: 12),
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            zh
                ? '点击人物画面设置参考图；每人至少两次不同出手，建议 3–5 张。'
                : 'Open a person image to set references. Use at least two different shots per player; 3–5 recommended.',
            style: TextStyle(color: c.textSecondary, fontSize: 12),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.sm,
          children: [
            for (final p in players)
              SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${p['name']} · ${counts[p['id']] ?? 0}',
                      style: TextStyle(color: c.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final ref in refs.where(
                          (r) => r['player_id'] == p['id'],
                        ))
                          SizedBox(
                            width: 48,
                            height: 72,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: Image.file(
                                    File(ref['crop_path'] as String),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.person),
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: IconButton(
                                    tooltip: zh
                                        ? '移除此张参考图'
                                        : 'Remove reference',
                                    style: IconButton.styleFrom(
                                      backgroundColor: c.surface,
                                    ),
                                    constraints: const BoxConstraints(
                                      minWidth: 24,
                                      minHeight: 24,
                                    ),
                                    padding: EdgeInsets.zero,
                                    iconSize: 16,
                                    onPressed: busy
                                        ? null
                                        : () => onRemove(
                                            ref.cast<String, dynamic>(),
                                          ),
                                    icon: const Icon(Icons.close),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: busy ? null : onAddPlayer,
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: Text(zh ? '添加球员' : 'Add player'),
          ),
        ),
      ],
    );
  }
}

/// Extra controls live in the image detail instead of repeating on every card.
Future<JsonMap?> showShooterPersonDetail(
  BuildContext context, {
  required JsonMap observation,
  required List<JsonMap> players,
  required JsonMap? selected,
  required bool busy,
  required Future<void> Function(JsonMap sample, String playerId) onReference,
}) => showDialog<JsonMap>(
  context: context,
  builder: (dialogContext) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final tracks = (observation['tracks'] as List).whereType<Map>().toList();
    var trackId = selected?['track_id'] ?? observation['selected_track_id'];
    var sampleId = selected?['id'];
    var playerId = players.firstOrNull?['id'] as String?;
    var full = false, saving = false;
    String? error;
    return StatefulBuilder(
      builder: (context, update) {
        final track = tracks.where((t) => t['id'] == trackId).firstOrNull;
        final samples = ((track?['samples'] as List?) ?? [])
            .whereType<Map>()
            .toList();
        final sample =
            samples.where((s) => s['id'] == sampleId).firstOrNull ??
            samples.firstOrNull;
        final contexts = (observation['context_frames'] as List?) ?? [];
        final path =
            sample?[full ? 'context_path' : 'crop_path'] ??
            (contexts.isNotEmpty
                ? (contexts[contexts.length ~/ 2] as Map)['context_path']
                : null);
        return AlertDialog(
          title: Text(zh ? '出手人物' : 'Release person'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 300,
                    child: path == null
                        ? Center(child: Text(zh ? '暂无人物画面' : 'No person image'))
                        : Image.file(
                            File(path as String),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                  ),
                  Row(
                    children: [
                      Text(zh ? '画面人物  ' : 'Person  '),
                      DropdownButton<dynamic>(
                        value: tracks.any((t) => t['id'] == trackId)
                            ? trackId
                            : null,
                        hint: Text(zh ? '请选择人物' : 'Choose a person'),
                        items: tracks
                            .map(
                              (t) => DropdownMenuItem<dynamic>(
                                value: t['id'],
                                child: Text('P${t['id']}'),
                              ),
                            )
                            .toList(),
                        onChanged: saving
                            ? null
                            : (value) => update(() {
                                trackId = value;
                                sampleId = null;
                              }),
                      ),
                      const Spacer(),
                      FilterChip(
                        label: Text(zh ? '全景与人物框' : 'Full frame'),
                        selected: full,
                        onSelected: (v) => update(() => full = v),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (var i = 0; i < samples.length; i++)
                        ChoiceChip(
                          label: Text('${i + 1}'),
                          selected: samples[i]['id'] == sample?['id'],
                          onSelected: saving
                              ? null
                              : (_) =>
                                    update(() => sampleId = samples[i]['id']),
                        ),
                    ],
                  ),
                  if (players.isNotEmpty) ...[
                    const SizedBox(height: Spacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: playerId,
                            items: players
                                .map(
                                  (p) => DropdownMenuItem(
                                    value: p['id'] as String,
                                    child: Text(p['name'] as String),
                                  ),
                                )
                                .toList(),
                            onChanged: saving
                                ? null
                                : (value) => update(() => playerId = value),
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        TextButton(
                          onPressed:
                              busy ||
                                  saving ||
                                  sample == null ||
                                  playerId == null
                              ? null
                              : () async {
                                  update(() {
                                    saving = true;
                                    error = null;
                                  });
                                  try {
                                    await onReference(
                                      sample.cast<String, dynamic>(),
                                      playerId!,
                                    );
                                    if (context.mounted) {
                                      Navigator.pop(
                                        context,
                                        sample.cast<String, dynamic>(),
                                      );
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      update(() {
                                        error = e.toString();
                                        saving = false;
                                      });
                                    }
                                  }
                                },
                          child: Text(zh ? '设为参考图' : 'Set reference'),
                        ),
                      ],
                    ),
                  ],
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(color: AppColors.of(context).error),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving
                  ? null
                  : () =>
                        Navigator.pop(context, sample?.cast<String, dynamic>()),
              child: Text(zh ? '完成' : 'Done'),
            ),
          ],
        );
      },
    );
  },
);
