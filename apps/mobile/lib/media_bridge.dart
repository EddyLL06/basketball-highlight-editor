import 'dart:async';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';

import 'features/diagnostics/friendly_error.dart';
import 'features/diagnostics/mobile_diagnostics.dart';
import 'features/export/native_export_result.dart';

String clipFileName(int index, Candidate candidate) {
  final name =
      'goal_${index.toString().padLeft(3, '0')}_${(candidate.eventMs / 1000).toStringAsFixed(2)}s';
  var player = (candidate.player ?? '').replaceAll(
    RegExp(r'[\x00-\x1f<>:"/\\|?*]+'),
    '_',
  );
  player = player.replaceAll(RegExp(r'^[ ._]+|[ ._]+$'), '');
  if (player.length > 40) player = player.substring(0, 40);
  return player.isEmpty ? '$name.mp4' : '${name}_$player.mp4';
}

class NativeMediaExportEngine implements MobileExportEngine {
  NativeMediaExportEngine();

  static const _channel = MethodChannel('com.bhe.bhe/mobile_media');
  bool _cancelled = false;
  String? _activeMergeId;

  static Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error, stack) {
      MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'export.availability',
      );
      return false;
    }
  }

  @override
  Stream<ExportProgress> exportClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputDirectory,
  }) async* {
    if (candidates.isEmpty) return;
    _cancelled = false;

    // Parallel export: MediaExtractor/MediaMuxer on Android runs on
    // background threads; exporting 4+ clips concurrently reduces total
    // wall time from sum(N) to ~max(N) + small overhead.
    // Keep concurrency bounded to avoid thread/memory pressure on
    // low-end devices.
    const maxConcurrent = 3;
    final outputs = <String>[];
    final skipped = <String, List<SkippedAudioTrack>>{};
    var completed = 0;
    var failed = false;

    Future<void> exportOne(Candidate candidate) async {
      if (failed || _cancelled) return;
      final index = candidates.indexOf(candidate) + 1;
      final outputPath = '$outputDirectory/${clipFileName(index, candidate)}';
      try {
        final raw = await _channel.invokeMethod<Object?>('exportClip', {
          'exportId': candidate.id,
          'inputPath': video.path,
          'outputPath': outputPath,
          'startMs': candidate.startMs,
          'endMs': candidate.endMs,
        });
        if (_cancelled) return;
        outputs.add(outputPath);
        skipped[outputPath] = NativeExportResult.decode(
          raw,
          outputPath,
        ).skippedAudioTracks;
      } on MissingPluginException {
        failed = true;
        throw const MobileExportException('当前平台尚未注册视频导出模块。');
      } on PlatformException catch (error, stack) {
        MobileDiagnostics.instance.error(error, stack, operation: 'export');
        failed = true;
        throw MobileDiagnosticException(error, 'export');
      }
    }

    // Process in batches of maxConcurrent.
    for (var i = 0; i < candidates.length; i += maxConcurrent) {
      final batch = candidates.skip(i).take(maxConcurrent).toList();
      yield ExportProgress(
        progress: completed / candidates.length,
        message:
            '正在导出 ${completed + 1}-${completed + batch.length}/${candidates.length}',
      );
      await Future.wait(batch.map(exportOne));
      if (_cancelled) {
        throw const MobileExportException('导出已取消');
      }
      completed += batch.length;
      for (final path in outputs.skip(outputs.length - batch.length)) {
        yield ExportProgress(
          progress: completed / candidates.length,
          message: '已导出 $completed/${candidates.length}',
          outputPath: path,
          skippedAudioTracks: skipped[path] ?? const [],
        );
      }
    }
  }

  @override
  Stream<ExportProgress> mergeClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputPath,
  }) async* {
    if (candidates.isEmpty) return;
    _cancelled = false;
    final exportId = 'merge-${DateTime.now().microsecondsSinceEpoch}';
    _activeMergeId = exportId;
    var reserved = false;
    try {
      try {
        reserved =
            await _channel.invokeMethod<bool>('registerMergeExport', {
              'exportId': exportId,
            }) ??
            false;
      } on MissingPluginException {
        // Older platforms (including iOS) do not implement reservations.
      }
      if (_cancelled) throw const MobileExportException('导出已取消');
      yield const ExportProgress(progress: 0, message: '正在准备合并导出');
      if (_cancelled) throw const MobileExportException('导出已取消');
      final raw = await _channel.invokeMethod<Object?>('mergeClips', {
        'exportId': exportId,
        'reservationRequired': reserved,
        'inputPath': video.path,
        'outputPath': outputPath,
        'clips': [
          for (final candidate in candidates)
            {'startMs': candidate.startMs, 'endMs': candidate.endMs},
        ],
      });
      final committed = raw is Map && raw['committed'] == true;
      if (_cancelled && !committed) throw const MobileExportException('导出已取消');
      final result = NativeExportResult.decode(raw, outputPath);
      yield ExportProgress(
        progress: 1,
        message: '合并导出完成',
        outputPath: result.path,
        skippedAudioTracks: result.skippedAudioTracks,
        mergedOverlapCount: result.mergedOverlapCount,
      );
    } on MissingPluginException {
      throw const MobileExportException('当前平台尚未注册合并导出模块。');
    } on PlatformException catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'export');
      throw MobileDiagnosticException(error, 'export');
    } finally {
      if (reserved) {
        try {
          await _channel.invokeMethod<void>('releaseMergeExport', {
            'exportId': exportId,
          });
        } on Object catch (error, stack) {
          MobileDiagnostics.instance.error(
            error,
            stack,
            operation: 'export.release',
          );
        }
      }
      if (_activeMergeId == exportId) _activeMergeId = null;
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _channel.invokeMethod<void>(
        'cancelExport',
        _activeMergeId == null ? null : {'exportId': _activeMergeId},
      );
    } on MissingPluginException {
      return;
    } on PlatformException catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'export');
      throw MobileDiagnosticException(error, 'export');
    }
  }

  @override
  Future<void> saveToLibrary(String path) async {
    try {
      await _channel.invokeMethod<void>('saveToLibrary', {'path': path});
    } on MissingPluginException {
      throw const MobileExportException('当前平台尚未注册相册保存模块。');
    } on PlatformException catch (error, stack) {
      MobileDiagnostics.instance.error(error, stack, operation: 'export');
      throw MobileDiagnosticException(error, 'export');
    }
  }
}
