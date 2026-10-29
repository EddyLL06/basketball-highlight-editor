part of '../../mobile_ui.dart';

class _RoiEditorSheet extends StatefulWidget {
  const _RoiEditorSheet({
    required this.video,
    required this.initialPositionMs,
    this.rim,
    this.hoop,
    this.net,
    required this.onVideoFailure,
    required this.onRelink,
  });
  final VideoInfo video;
  final int initialPositionMs;
  final Roi? rim;
  final Roi? hoop;
  final Roi? net;
  final ValueChanged<VideoSourceFailure> onVideoFailure;
  final VoidCallback onRelink;

  @override
  State<_RoiEditorSheet> createState() => _RoiEditorSheetState();
}

class _RoiEditorSheetState extends State<_RoiEditorSheet> {
  late final RoiVideoPreview _preview;
  VideoPlayerController? get controller => _preview.controller;
  VideoSourceFailure? _reportedFailure;
  late Roi hoop;
  late Roi net;
  late Roi autoHoop;
  late Roi autoNet;
  String selected = 'hoop';
  double viewZoom = 1;
  double _gestureStartZoom = 1;
  int previewPositionMs = 0;
  int _lastPreviewPositionMs = -1;
  VideoPlayerController? _lastPreviewController;
  VideoPlayerValue? _lastPreviewState;
  VideoSourceFailure? _lastPreviewFailure;
  bool _redrawMode = false;
  Offset? _drawStart;
  Offset? _drawEnd;

  @override
  void initState() {
    super.initState();
    autoHoop =
        widget.hoop ?? const Roi(left: .34, top: .25, right: .66, bottom: .48);
    hoop = autoHoop;
    autoNet = widget.rim == null
        ? const Roi(left: .37, top: .42, right: .63, bottom: .72)
        : netRoiFromRim(hoop, widget.rim!);
    net = widget.net ?? autoNet;
    previewPositionMs = widget.initialPositionMs
        .clamp(0, widget.video.durationMs)
        .toInt();
    _preview = RoiVideoPreview()..addListener(_onPreviewChanged);
    unawaited(_preview.open(widget.video.path, previewPositionMs));
  }

  @override
  void dispose() {
    _preview.removeListener(_onPreviewChanged);
    _preview.dispose();
    super.dispose();
  }

  void _onPreviewChanged() {
    if (!mounted) return;
    final failure = _preview.failure;
    if (failure != null && failure != _reportedFailure) {
      _reportedFailure = failure;
      widget.onVideoFailure(failure);
    }
    final player = controller;
    final value = player?.value;
    final position = value?.position.inMilliseconds;
    // Position alone is throttled; readiness and playback state must repaint.
    final playerState = value?.copyWith(position: Duration.zero);
    final controllerChanged = !identical(player, _lastPreviewController);
    final stateChanged =
        controllerChanged ||
        playerState != _lastPreviewState ||
        failure != _lastPreviewFailure;
    final positionChanged =
        position != null && (position - _lastPreviewPositionMs).abs() >= 100;
    if (!stateChanged && !positionChanged) return;
    setState(() {
      _lastPreviewController = player;
      _lastPreviewState = playerState;
      _lastPreviewFailure = failure;
      if (position != null && (controllerChanged || positionChanged)) {
        _lastPreviewPositionMs = position;
        previewPositionMs = position;
      }
    });
  }

  Future<void> _togglePreview() => _preview.run((player) async {
    if (player.value.isPlaying) {
      await player.pause();
    } else {
      await player.play();
    }
  });

  Future<void> _seekPreview(int offsetMs) => _preview.run((player) async {
    final duration = player.value.duration;
    final next = player.value.position + Duration(milliseconds: offsetMs);
    await player.seekTo(
      next < Duration.zero
          ? Duration.zero
          : next > duration
          ? duration
          : next,
    );
  });

  Future<void> _replayPreview() => _preview.run((player) async {
    await player.seekTo(Duration(milliseconds: widget.initialPositionMs));
    await player.play();
  });

  @override
  Widget build(BuildContext context) {
    final failure = _preview.failure;
    if (failure != null) {
      return _SheetFrame(
        title: context.bheText('设置检测区域'),
        child: RoiPreviewFailure(
          failure: failure,
          diagnostic: _preview.diagnosticError,
          onRelink: widget.onRelink,
          onBack: () => Navigator.pop(context),
        ),
      );
    }
    final current = selected == 'hoop' ? hoop : net;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .92,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 34,
                  height: 3,
                  decoration: BoxDecoration(
                    color: BhePalette.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    context.bheText('设置检测区域'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.bheText(
                        selected == 'hoop' ? '覆盖投篮发生区域' : '覆盖白色篮网区域',
                      ),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, (hoop: hoop, net: net)),
                    child: Text(context.bheText('完成')),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'hoop',
                    label: Text(context.bheText('投篮分析区')),
                    icon: Icon(LucideIcons.scan),
                  ),
                  ButtonSegment(
                    value: 'net',
                    label: Text(context.bheText('篮网区域')),
                    icon: Icon(LucideIcons.network),
                  ),
                ],
                selected: {selected},
                onSelectionChanged: (value) => setState(() {
                  selected = value.first;
                  _redrawMode = false;
                  _drawStart = null;
                  _drawEnd = null;
                }),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final ratio = widget.video.width / widget.video.height;
                    return ClipRect(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: ratio,
                          child: LayoutBuilder(
                            builder: (context, canvasConstraints) {
                              final canvasSize = canvasConstraints.biggest;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: (details) {
                                  if (_redrawMode) {
                                    final point = _clampPoint(
                                      details.localFocalPoint,
                                      canvasSize,
                                    );
                                    setState(() {
                                      _drawStart = point;
                                      _drawEnd = point;
                                    });
                                  } else {
                                    _gestureStartZoom = viewZoom;
                                  }
                                },
                                onScaleUpdate: (details) {
                                  if (_redrawMode) {
                                    setState(() {
                                      _drawEnd = _clampPoint(
                                        details.localFocalPoint,
                                        canvasSize,
                                      );
                                    });
                                  } else if ((details.scale - 1).abs() > .015) {
                                    setState(() {
                                      viewZoom =
                                          (_gestureStartZoom * details.scale)
                                              .clamp(1.0, 4.0);
                                    });
                                  } else {
                                    _updateRoi(
                                      details.focalPointDelta,
                                      1,
                                      canvasSize,
                                    );
                                  }
                                },
                                onScaleEnd: (_) {
                                  if (_redrawMode &&
                                      _drawStart != null &&
                                      _drawEnd != null) {
                                    _finishRedraw(canvasSize);
                                  }
                                },
                                child: Transform.scale(
                                  scale: viewZoom,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ColoredBox(
                                        color: Colors.black,
                                        child:
                                            controller?.value.isInitialized ==
                                                true
                                            ? VideoPlayer(controller!)
                                            : const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                      ),
                                      CustomPaint(
                                        painter: _RoiPainter(
                                          hoop: hoop,
                                          net: net,
                                          selected: selected,
                                          hoopLabel: context.bheText('投篮区'),
                                          netLabel: context.bheText('篮网'),
                                          redrawStart: _drawStart,
                                          redrawEnd: _drawEnd,
                                        ),
                                      ),
                                      if (!_redrawMode)
                                        for (final corner in const [
                                          'topLeft',
                                          'topRight',
                                          'bottomLeft',
                                          'bottomRight',
                                        ])
                                          _RoiHandle(
                                            key: ValueKey(corner),
                                            corner: corner,
                                            roi: current,
                                            size: canvasSize,
                                            onDrag: (delta) => _resizeRoi(
                                              corner,
                                              delta,
                                              canvasSize,
                                            ),
                                          ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '${_formatMs(previewPositionMs)} / ${_formatMs(widget.video.durationMs)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => _seekPreview(-5000),
                    icon: const Icon(LucideIcons.rotateCcw, size: 18),
                    tooltip:
                        '${context.bheText('后退')} 5 ${context.bheText('秒')}',
                  ),
                  IconButton.filledTonal(
                    onPressed: _togglePreview,
                    icon: Icon(
                      controller?.value.isPlaying == true
                          ? LucideIcons.pause
                          : LucideIcons.play,
                      size: 18,
                    ),
                    tooltip: context.bheText('播放/暂停'),
                  ),
                  IconButton(
                    onPressed: () => _seekPreview(5000),
                    icon: const Icon(LucideIcons.rotateCw, size: 18),
                    tooltip:
                        '${context.bheText('前进')} 5 ${context.bheText('秒')}',
                  ),
                  IconButton(
                    onPressed: _replayPreview,
                    icon: const Icon(LucideIcons.refreshCw, size: 18),
                    tooltip: context.bheText('从分析范围起点重播'),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                runSpacing: 2,
                children: [
                  IconButton(
                    onPressed: viewZoom <= 1
                        ? null
                        : () => setState(
                            () => viewZoom = (viewZoom - .5).clamp(1.0, 4.0),
                          ),
                    icon: const Icon(LucideIcons.minus),
                    tooltip: context.bheText('缩小画面'),
                  ),
                  SizedBox(
                    width: 56,
                    height: 40,
                    child: Center(
                      child: Text('${viewZoom.toStringAsFixed(1)}×'),
                    ),
                  ),
                  IconButton(
                    onPressed: viewZoom >= 4
                        ? null
                        : () => setState(
                            () => viewZoom = (viewZoom + .5).clamp(1.0, 4.0),
                          ),
                    icon: const Icon(LucideIcons.plus),
                    tooltip: context.bheText('放大画面'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => viewZoom = 1),
                    child: Text(context.bheText('复位')),
                  ),
                  TextButton.icon(
                    onPressed: _redrawMode
                        ? () => setState(() {
                            _redrawMode = false;
                            _drawStart = null;
                            _drawEnd = null;
                          })
                        : _startRedraw,
                    icon: Icon(
                      _redrawMode
                          ? LucideIcons.penLine
                          : LucideIcons.squareDashed,
                      size: 16,
                    ),
                    label: Text(
                      context.bheText(_redrawMode ? '拖动重画中' : '重新画框'),
                    ),
                  ),
                  TextButton(
                    onPressed: _resetSelectedRoi,
                    child: Text(context.bheText('重置当前')),
                  ),
                ],
              ),
              Text(
                _redrawMode
                    ? context.bheText('拖动出一个新矩形来重新设置当前区域。')
                    : context.bheText('拖动框角调整大小，拖动画面移动区域；双指捏合放大画面。'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                context.bheText(
                  '当前区域 ${(current.right - current.left).toStringAsFixed(2)} × ${(current.bottom - current.top).toStringAsFixed(2)}',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Offset _clampPoint(Offset point, Size size) => Offset(
    point.dx.clamp(0.0, size.width).toDouble(),
    point.dy.clamp(0.0, size.height).toDouble(),
  );

  void _startRedraw() {
    setState(() {
      _redrawMode = true;
      _drawStart = null;
      _drawEnd = null;
      viewZoom = 1;
    });
  }

  void _finishRedraw(Size size) {
    final start = _drawStart;
    final end = _drawEnd;
    if (start == null || end == null) return;
    final left = (start.dx < end.dx ? start.dx : end.dx) / size.width;
    final top = (start.dy < end.dy ? start.dy : end.dy) / size.height;
    final right = (start.dx > end.dx ? start.dx : end.dx) / size.width;
    final bottom = (start.dy > end.dy ? start.dy : end.dy) / size.height;
    if (right - left < .05 || bottom - top < .05) return;
    final next = Roi(
      left: left.clamp(0.0, .95).toDouble(),
      top: top.clamp(0.0, .95).toDouble(),
      right: right.clamp(.05, 1.0).toDouble(),
      bottom: bottom.clamp(.05, 1.0).toDouble(),
    );
    setState(() {
      if (selected == 'hoop') {
        hoop = next;
      } else {
        net = next;
      }
      _redrawMode = false;
      _drawStart = null;
      _drawEnd = null;
    });
  }

  void _resetSelectedRoi() {
    setState(() {
      if (selected == 'hoop') {
        hoop = autoHoop;
      } else {
        net = autoNet;
      }
      _redrawMode = false;
      _drawStart = null;
      _drawEnd = null;
    });
  }

  void _resizeRoi(String corner, Offset delta, Size size) {
    final value = selected == 'hoop' ? hoop : net;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    const minimum = .05;
    var left = value.left;
    var top = value.top;
    var right = value.right;
    var bottom = value.bottom;
    switch (corner) {
      case 'topLeft':
        left = (left + dx).clamp(0.0, right - minimum).toDouble();
        top = (top + dy).clamp(0.0, bottom - minimum).toDouble();
      case 'topRight':
        right = (right + dx).clamp(left + minimum, 1.0).toDouble();
        top = (top + dy).clamp(0.0, bottom - minimum).toDouble();
      case 'bottomLeft':
        left = (left + dx).clamp(0.0, right - minimum).toDouble();
        bottom = (bottom + dy).clamp(top + minimum, 1.0).toDouble();
      case 'bottomRight':
        right = (right + dx).clamp(left + minimum, 1.0).toDouble();
        bottom = (bottom + dy).clamp(top + minimum, 1.0).toDouble();
    }
    final next = Roi(left: left, top: top, right: right, bottom: bottom);
    setState(() {
      if (selected == 'hoop') {
        hoop = next;
      } else {
        net = next;
      }
    });
  }

  void _updateRoi(Offset delta, double scale, Size size) {
    final value = selected == 'hoop' ? hoop : net;
    final width = value.right - value.left;
    final height = value.bottom - value.top;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height;
    var nextWidth = (width / scale).clamp(.08, .92);
    var nextHeight = (height / scale).clamp(.08, .92);
    var left = (value.left + dx + (width - nextWidth) / 2).clamp(
      0.0,
      1.0 - nextWidth,
    );
    var top = (value.top + dy + (height - nextHeight) / 2).clamp(
      0.0,
      1.0 - nextHeight,
    );
    final next = Roi(
      left: left,
      top: top,
      right: left + nextWidth,
      bottom: top + nextHeight,
    );
    setState(() {
      if (selected == 'hoop') {
        hoop = next;
      } else {
        net = next;
      }
    });
  }
}

class _RoiHandle extends StatelessWidget {
  const _RoiHandle({
    super.key,
    required this.corner,
    required this.roi,
    required this.size,
    required this.onDrag,
  });
  final String corner;
  final Roi roi;
  final Size size;
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    final point = switch (corner) {
      'topLeft' => Offset(roi.left * size.width, roi.top * size.height),
      'topRight' => Offset(roi.right * size.width, roi.top * size.height),
      'bottomLeft' => Offset(roi.left * size.width, roi.bottom * size.height),
      _ => Offset(roi.right * size.width, roi.bottom * size.height),
    };
    return Positioned(
      left: point.dx - 14,
      top: point.dy - 14,
      width: 28,
      height: 28,
      child: GestureDetector(
        onPanUpdate: (details) => onDrag(details.delta),
        child: Center(
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: BhePalette.orange,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoiPainter extends CustomPainter {
  const _RoiPainter({
    required this.hoop,
    required this.net,
    required this.selected,
    required this.hoopLabel,
    required this.netLabel,
    this.redrawStart,
    this.redrawEnd,
  });
  final Roi hoop;
  final Roi net;
  final String selected;
  final String hoopLabel;
  final String netLabel;
  final Offset? redrawStart;
  final Offset? redrawEnd;

  @override
  void paint(Canvas canvas, Size size) {
    void draw(Roi roi, Color color, String label, bool active, bool isNet) {
      final rect = Rect.fromLTRB(
        roi.left * size.width,
        roi.top * size.height,
        roi.right * size.width,
        roi.bottom * size.height,
      );
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.5 : 1;
      canvas.drawRect(rect, paint);
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: color, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      const horizontalPadding = 5.0;
      const verticalPadding = 3.0;
      final labelWidth = text.width + horizontalPadding * 2;
      final labelHeight = text.height + verticalPadding * 2;
      final labelX = rect.left.clamp(0.0, size.width - labelWidth).toDouble();
      final preferredY = isNet ? rect.bottom + 6 : rect.top - labelHeight - 6;
      final labelY = preferredY >= 0 && preferredY + labelHeight <= size.height
          ? preferredY
          : preferredY < 0
          ? (rect.bottom + 6).clamp(0.0, size.height - labelHeight).toDouble()
          : (rect.top - labelHeight - 6)
                .clamp(0.0, size.height - labelHeight)
                .toDouble();
      final background = RRect.fromRectAndRadius(
        Rect.fromLTWH(labelX, labelY, labelWidth, labelHeight),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        background,
        Paint()..color = Colors.black.withValues(alpha: .82),
      );
      text.paint(
        canvas,
        Offset(labelX + horizontalPadding, labelY + verticalPadding),
      );
    }

    draw(hoop, BhePalette.orange, hoopLabel, selected == 'hoop', false);
    draw(net, BhePalette.gold, netLabel, selected == 'net', true);
    if (redrawStart != null && redrawEnd != null) {
      canvas.drawRect(
        Rect.fromPoints(redrawStart!, redrawEnd!),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_RoiPainter oldDelegate) =>
      oldDelegate.hoop != hoop ||
      oldDelegate.net != net ||
      oldDelegate.selected != selected ||
      oldDelegate.hoopLabel != hoopLabel ||
      oldDelegate.netLabel != netLabel ||
      oldDelegate.redrawStart != redrawStart ||
      oldDelegate.redrawEnd != redrawEnd;
}

String _score(double? value) =>
    value == null ? '—' : '${(value * 100).toStringAsFixed(0)}%';

String _formatMs(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

String _formatSeekStep(int milliseconds) {
  final seconds = milliseconds / 1000;
  return seconds == seconds.roundToDouble()
      ? '${seconds.round()} 秒'
      : '$seconds 秒';
}

String _formatSpeed(double value) => '${value.toString()}x';

Future<void> _showUpdateSheet(
  BuildContext context,
  AppUpdater updater,
  MobileAppState state,
) {
  if (updater.status == UpdateStatus.idle ||
      updater.status == UpdateStatus.upToDate ||
      updater.status == UpdateStatus.failed && updater.manifest == null) {
    unawaited(updater.check(manual: true));
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => AnimatedBuilder(
      animation: Listenable.merge([updater, state]),
      builder: (context, _) => _UpdateSheet(updater: updater, state: state),
    ),
  );
}

class RoiPreviewFailure extends StatelessWidget {
  const RoiPreviewFailure({
    super.key,
    required this.failure,
    required this.onRelink,
    required this.onBack,
    this.diagnostic,
  });
  final DiagnosticErrorRecord? diagnostic;
  final VideoSourceFailure failure;
  final VoidCallback onRelink;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => _InlineNotice(
    message: context.bheText(failure.message),
    error: true,
    action: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (failure.canRelink)
          TextButton(
            key: const ValueKey('roi-relink'),
            onPressed: onRelink,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: Text(context.bheText('重新选择视频')),
          ),
        TextButton(
          key: const ValueKey('roi-back'),
          onPressed: onBack,
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: Text(context.bheText('返回')),
        ),
        TextButton(
          key: const ValueKey('roi-feedback'),
          onPressed: () => showMobileDiagnostics(
            context,
            error: diagnostic ?? DiagnosticErrorRecord(
              StateError(failure.message),
              null,
              'video',
            ),
          ),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          child: Text(context.bheText('反馈')),
        ),
      ],
    ),
  );
}
