import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:bhe_l10n/bhe_l10n.dart';

import '../../components/cs_button.dart';
import '../../components/cs_card.dart';
import '../../components/cs_empty_state.dart';
import '../../components/cs_skeleton.dart';
import '../../providers/project_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/tokens.dart';

/// Home 屏:Hero slogan + 主 CTA / 当前项目 metrics / 最近项目网格 / 工作流指示。
///
/// 所有数据来自 [projectProvider];导航用 `context.go`,打开项目走
/// `ProjectNotifier.chooseOpenProject` / `openProject`(目录选择器在 notifier 内)。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({this.onProjectOpened, super.key});

  final VoidCallback? onProjectOpened;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(projectProvider);
    final notifier = ref.read(projectProvider.notifier);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);

    final included = state.candidates
        .where(
          (it) =>
              it['selection_status']?.toString() != 'excluded' &&
              it['review_status']?.toString() != 'excluded',
        )
        .length;
    final excluded = state.candidates
        .where(
          (it) =>
              it['selection_status']?.toString() == 'excluded' ||
              it['review_status']?.toString() == 'excluded',
        )
        .length;
    final durationMs = (state.video?['duration_ms'] as num?)?.toInt() ?? 0;
    final busy = state.busy || state.exportRunning || state.analysisRunning;

    Future<void> openProject() async {
      if (await notifier.chooseOpenProject(
        openProjectButtonLabel: l10n?.openProject,
        relinkVideoButtonLabel: l10n?.relinkVideo,
        videoTypeLabel: context.bheText('视频'),
      )) {
        onProjectOpened?.call();
      }
    }

    Future<void> startNewProject() async {
      if (await notifier.startNewProject() && context.mounted) {
        context.go('/import');
      }
    }

    Future<void> openRecentProject(String root) async {
      if (await notifier.openProject(
        root,
        relinkVideoButtonLabel: l10n?.relinkVideo,
        videoTypeLabel: context.bheText('视频'),
      )) {
        onProjectOpened?.call();
      }
    }

    Future<void> deleteRecentProject(Map<String, dynamic> item) async {
      final root = item['project_root']?.toString() ?? '';
      if (root.isEmpty) return;
      final project = _map(item['project']);
      final name = project['name']?.toString() ?? context.bheText('未命名项目');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n?.deleteProjectQuestion ?? '删除项目？'),
          content: Text(
            l10n?.deleteProjectDescription(name) ??
                '将删除“$name”的项目数据库、分析缓存和导出文件，原始视频不会被删除。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n?.cancel ?? '取消'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n?.deleteProject ?? '删除项目'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await notifier.deleteProject(root);
        await notifier.loadRecentProjects();
      }
    }

    final statistics = state.statistics ?? const <String, dynamic>{};
    final currentName =
        _map(statistics['project'])['name']?.toString() ??
        context.bheText('未命名项目');
    final source = state.video?['source_path']?.toString() ?? state.videoPath;
    final currentVideoName = source == null || source.isEmpty
        ? null
        : source.split(RegExp(r'[/\\]')).last;
    final hasCurrent = state.video != null;
    final currentStatus = state.analysisRunning
        ? (l10n?.homeStatusAnalyzing ?? '分析中', c.warning)
        : state.candidates.isEmpty
        ? (l10n?.homeStatusEmpty ?? '暂无候选', c.textTertiary)
        : state.exportHistory.isNotEmpty || _int(statistics['export_count']) > 0
        ? (l10n?.homeStatusExported ?? '已导出', c.textSecondary)
        : (l10n?.homeStatusPending ?? '待审核', c.goal);

    final newProjectCard = _NewProjectCard(
      onTap: busy ? null : startNewProject,
      title: l10n?.newProject ?? '新建项目',
      description:
          l10n?.startFromVideoDescription ??
          '选择一段固定机位录像，系统会优先自动定位篮筐，随后生成候选进球片段供你审核与导出。',
      formats:
          l10n?.homeSupportedFormats ?? 'MP4 · MOV · M4V · AVI · MKV · 原始视频不会被修改',
    );
    final continueCard = CsCard(
      child: hasCurrent
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      l10n?.homeContinueTitle ?? '继续上次',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    _StatusBadge(
                      label: currentStatus.$1,
                      color: currentStatus.$2,
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  currentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (currentVideoName != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    currentVideoName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.md),
                Wrap(
                  spacing: Spacing.xl,
                  runSpacing: Spacing.sm,
                  children: [
                    _HomeStat(
                      label: l10n?.homeCandidates ?? '候选',
                      value: '${state.candidates.length}',
                    ),
                    _HomeStat(
                      label: l10n?.homeKept ?? '保留',
                      value: '$included',
                      color: included > 0 ? c.goal : null,
                    ),
                    _HomeStat(
                      label: l10n?.homeExcluded ?? '排除',
                      value: '$excluded',
                    ),
                    _HomeStat(
                      label: l10n?.videoDuration ?? '视频时长',
                      value: _formatDuration(durationMs),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.lg),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    if (state.candidates.isNotEmpty)
                      CsButton(
                        label: Text(l10n?.homeContinueReview ?? '继续审核'),
                        icon: LucideIcons.arrowRight,
                        onPressed: () => context.go('/review'),
                      )
                    else
                      CsButton(
                        label: Text(l10n?.homeContinueSetup ?? '继续配置'),
                        icon: LucideIcons.arrowRight,
                        onPressed: () => context.go('/import'),
                      ),
                    CsButton(
                      label: Text(l10n?.exportHighlights ?? '导出集锦'),
                      icon: LucideIcons.download,
                      variant: CsButtonVariant.secondary,
                      onPressed: included > 0
                          ? () => context.go('/export')
                          : null,
                    ),
                  ],
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.folderOpen, size: 22, color: c.textTertiary),
                const SizedBox(height: Spacing.sm),
                Text(
                  l10n?.homeNoCurrentProject ?? '还没有打开的项目',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  l10n?.homeNoCurrentProjectDescription ??
                      '新建项目，或从下方最近项目中打开一个继续。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textSecondary,
                  ),
                ),
              ],
            ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1240),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n?.homeHeadline ?? '把整场比赛，变成你的高光。',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          l10n?.homeSubtitle ??
                              '导入固定机位视频，本地分析候选进球，剔除误检后导出集锦。所有处理在本机完成，原始视频不会被复制或上传。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  CsButton(
                    label: Text(l10n?.openProject ?? '打开项目'),
                    icon: LucideIcons.folderOpen,
                    variant: CsButtonVariant.secondary,
                    onPressed: busy ? null : openProject,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.xl),
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= Breakpoints.md) {
                    return IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 4, child: newProjectCard),
                          const SizedBox(width: Spacing.md),
                          Expanded(flex: 5, child: continueCard),
                        ],
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      newProjectCard,
                      const SizedBox(height: Spacing.md),
                      continueCard,
                    ],
                  );
                },
              ),
              const SizedBox(height: Spacing.xxl),
              Row(
                children: [
                  Text(
                    l10n?.recentProjects ?? '最近项目',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    '${state.recentProjects.length}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: c.textTertiary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: l10n?.refreshRecentProjects ?? '刷新最近项目',
                    onPressed: state.recentLoading || busy
                        ? null
                        : () => notifier.loadRecentProjects(),
                    icon: const Icon(LucideIcons.refreshCw, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              _RecentProjects(
                state: state,
                busy: busy,
                onOpen: openRecentProject,
                onDelete: deleteRecentProject,
                onCreate: busy ? () {} : startNewProject,
              ),
              const SizedBox(height: Spacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewProjectCard extends StatelessWidget {
  const _NewProjectCard({
    required this.onTap,
    required this.title,
    required this.description,
    required this.formats,
  });

  final VoidCallback? onTap;
  final String title;
  final String description;
  final String formats;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      child: CustomPaint(
        foregroundPainter: _DashedBorderPainter(
          color: c.borderStrong,
          radius: CsRadius.lg,
        ),
        child: Material(
          key: const Key('home-new-project'),
          color: c.surface,
          borderRadius: BorderRadius.circular(CsRadius.lg),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(CsRadius.lg),
            child: Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: c.orange.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(CsRadius.md),
                    ),
                    child: Icon(LucideIcons.plus, color: c.orange, size: 22),
                  ),
                  const SizedBox(height: Spacing.md),
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    formats,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ).deflate(0.6),
      );
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 9) {
        canvas.drawPath(metric.extractPath(distance, distance + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(CsRadius.xs),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _HomeStat extends StatelessWidget {
  const _HomeStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: c.textTertiary),
        ),
      ],
    );
  }
}

/// 最近项目区域:加载(CsSkeleton) / 空(CsEmptyState) / 错(CsEmptyState) / 网格。
class _RecentProjects extends StatelessWidget {
  const _RecentProjects({
    required this.state,
    required this.busy,
    required this.onOpen,
    required this.onDelete,
    required this.onCreate,
  });

  final ProjectState state;
  final bool busy;
  final Future<void> Function(String root) onOpen;
  final Future<void> Function(Map<String, dynamic> item) onDelete;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    if (state.recentLoading && state.recentProjects.isEmpty) {
      return const _RecentSkeletonGrid();
    }
    if (state.recentProjects.isEmpty) {
      return CsEmptyState(
        icon: LucideIcons.folderOpen,
        title: state.recentError != null
            ? (l10n?.recentProjectsLoadFailed ?? '加载最近项目失败')
            : (l10n?.noProjects ?? '还没有项目'),
        description: state.recentError == null
            ? (l10n?.noProjectsDescription ?? '新建一个项目后，分析记录和导出历史会显示在这里。')
            : context.bheText(state.recentError!),
        action: CsButton(
          label: Text(l10n?.newProject ?? '新建项目'),
          onPressed: onCreate,
        ),
      );
    }
    return _RecentGrid(
      projects: state.recentProjects,
      onOpen: busy ? null : onOpen,
      onDelete: busy ? null : onDelete,
    );
  }
}

class _RecentGrid extends StatelessWidget {
  const _RecentGrid({
    required this.projects,
    required this.onOpen,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> projects;
  final Future<void> Function(String root)? onOpen;
  final Future<void> Function(Map<String, dynamic> item)? onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 1100
            ? 4
            : constraints.maxWidth >= 820
            ? 3
            : (constraints.maxWidth >= 520 ? 2 : 1);
        final rows = <Widget>[];
        for (var i = 0; i < projects.length; i += cols) {
          final cells = <Widget>[];
          for (var j = 0; j < cols; j++) {
            final index = i + j;
            if (j > 0) {
              cells.add(const SizedBox(width: Spacing.md));
            }
            if (index < projects.length) {
              cells.add(
                Expanded(
                  child: _ProjectCard(
                    item: projects[index],
                    onOpen: onOpen,
                    onDelete: onDelete,
                  ),
                ),
              );
            } else {
              cells.add(const Expanded(child: SizedBox.shrink()));
            }
          }
          rows.add(
            Padding(
              padding: EdgeInsets.zero,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cells,
                ),
              ),
            ),
          );
          if (i + cols < projects.length) {
            rows.add(const SizedBox(height: Spacing.md));
          }
        }
        return Column(children: rows);
      },
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.item,
    required this.onOpen,
    required this.onDelete,
  });

  final Map<String, dynamic> item;
  final Future<void> Function(String root)? onOpen;
  final Future<void> Function(Map<String, dynamic> item)? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    final project = _map(item['project']);
    final video = _map(item['video']);
    final statistics = _map(item['statistics']);
    final root = item['project_root']?.toString() ?? '';
    final name = project['name']?.toString() ?? context.bheText('未命名项目');
    final goals = statistics['included_count'] == null
        ? _int(statistics['goal_count'])
        : _int(statistics['included_count']);
    final candidates = _int(statistics['candidate_count']);
    final duration = _int(video['duration_ms']);
    final source = video['source_path']?.toString();
    final videoName = (source == null || source.isEmpty)
        ? null
        : source.split('/').last;

    final missing = video['source_status']?.toString() == 'missing';
    final status = missing
        ? (l10n?.homeStatusMissingVideo ?? '视频缺失', c.warning)
        : candidates == 0
        ? (l10n?.homeStatusEmpty ?? '暂无候选', c.textTertiary)
        : _int(statistics['export_count']) > 0
        ? (l10n?.homeStatusExported ?? '已导出', c.textSecondary)
        : (l10n?.homeStatusPending ?? '待审核', c.goal);
    final modified = DateTime.tryParse(
      item['last_modified_at']?.toString() ?? '',
    )?.toLocal();
    final modifiedLabel = modified == null
        ? null
        : '${modified.month.toString().padLeft(2, '0')}-'
              '${modified.day.toString().padLeft(2, '0')} '
              '${modified.hour.toString().padLeft(2, '0')}:'
              '${modified.minute.toString().padLeft(2, '0')}';

    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CsRadius.lg),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: (onOpen == null || root.isEmpty) ? null : () => onOpen!(root),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 88,
              color: c.surface2,
              child: Stack(
                children: [
                  Center(
                    child: Icon(
                      LucideIcons.film,
                      size: 26,
                      color: c.textTertiary,
                    ),
                  ),
                  Positioned(
                    left: Spacing.sm,
                    top: Spacing.sm,
                    child: _StatusBadge(label: status.$1, color: status.$2),
                  ),
                  if (duration > 0)
                    Positioned(
                      right: Spacing.sm,
                      bottom: Spacing.xs,
                      child: Text(
                        _formatDuration(duration),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textSecondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.xs,
                Spacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (onDelete != null && root.isNotEmpty)
                        PopupMenuButton<String>(
                          tooltip: l10n?.homeProjectActions ?? '项目操作',
                          icon: Icon(
                            Icons.more_horiz,
                            size: 18,
                            color: c.textSecondary,
                          ),
                          onSelected: (_) => onDelete!(item),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(l10n?.deleteProject ?? '删除项目'),
                            ),
                          ],
                        ),
                    ],
                  ),
                  Text(
                    [?videoName, ?modifiedLabel].join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n?.projectStats(
                          goals,
                          candidates,
                          _formatDuration(duration),
                        ) ??
                        '$goals 保留 · $candidates 候选 · ${_formatDuration(duration)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentSkeletonGrid extends StatelessWidget {
  const _RecentSkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 900
            ? 3
            : (constraints.maxWidth >= 560 ? 2 : 1);
        final cells = <Widget>[];
        for (var i = 0; i < cols; i++) {
          if (i > 0) {
            cells.add(const SizedBox(width: Spacing.md));
          }
          cells.add(
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    CsSkeleton(width: 120, height: 16),
                    SizedBox(height: Spacing.md),
                    CsSkeleton(width: double.infinity, height: 12),
                    SizedBox(height: Spacing.xs),
                    CsSkeleton(width: 180, height: 12),
                  ],
                ),
              ),
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: cells,
        );
      },
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

String _formatDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remaining.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remaining.toString().padLeft(2, '0')}';
}
