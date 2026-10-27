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

class _ExportRun {
  bool cancelled = false;
  bool admitted = false;
  String? mergeId;
  final Completer<void> cancelledSignal = Completer<void>();
}

class _ExportTicket {
  _ExportTicket(this.previous, this.release, this.waiting);
  final Future<void> previous;
  final Completer<void> release;
  final bool waiting;
  void finish() {
    // A timed-out or cancelled waiter must not release its predecessor.
    previous.then((_) {
      if (!release.isCompleted) release.complete();
    });
  }
}

class _ExportGate {
  static Future<void> _tail = Future.value();
  static int _pending = 0;
  static _ExportTicket enter() {
    final previous = _tail;
    final release = Completer<void>();
    final ticket = _ExportTicket(previous, release, _pending > 0);
    _pending++;
    _tail = release.future;
    release.future.then((_) {
      _pending--;
    });
    return ticket;
  }
}

class NativeMediaExportEngine implements MobileExportEngine {
  NativeMediaExportEngine({this.drainTimeout = const Duration(seconds: 30)});
  final Duration drainTimeout;

  static const _channel = MethodChannel('com.bhe.bhe/mobile_media');
  _ExportRun? _activeRun;

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
    final run = _ExportRun();
    _activeRun = run;
    final ticket = _ExportGate.enter();
    try {
      if (ticket.waiting) {
        yield const ExportProgress(progress: 0, message: '正在结束上一次导出');
      }
      await _waitForTurn(ticket, run);
      // One native call at a time, including across project switches.
      const maxConcurrent = 1;
      final outputs = <String>[];
      final skipped = <String, List<SkippedAudioTrack>>{};
      var completed = 0;
      var failed = false;

      Future<void> exportOne(Candidate candidate) async {
        if (failed || run.cancelled) return;
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
          if (run.cancelled) return;
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
        if (run.cancelled) {
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
    } finally {
      ticket.finish();
      if (identical(_activeRun, run)) _activeRun = null;
    }
  }

  @override
  Stream<ExportProgress> mergeClips({
    required VideoInfo video,
    required List<Candidate> candidates,
    required String outputPath,
  }) async* {
    if (candidates.isEmpty) return;
    final run = _ExportRun();
    _activeRun = run;
    final exportId = 'merge-${DateTime.now().microsecondsSinceEpoch}';
    run.mergeId = exportId;
    var reserved = false;
    final ticket = _ExportGate.enter();
    try {
      if (ticket.waiting) {
        yield const ExportProgress(progress: 0, message: '正在结束上一次导出');
      }
      await _waitForTurn(ticket, run);
      try {
        reserved =
            await _channel.invokeMethod<bool>('registerMergeExport', {
              'exportId': exportId,
              'outputPath': outputPath,
            }) ??
            false;
      } on MissingPluginException {
        // Older platforms (including iOS) do not implement reservations.
      }
      if (run.cancelled) throw const MobileExportException('导出已取消');
      yield const ExportProgress(progress: 0, message: '正在准备合并导出');
      if (run.cancelled) throw const MobileExportException('导出已取消');
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
      if (run.cancelled && !committed) {
        throw const MobileExportException('导出已取消');
      }
      final result = NativeExportResult.decode(raw, outputPath);
      yield ExportProgress(
        progress: 1,
        message: '合并导出完成',
        outputPath: result.path,
        skippedAudioTracks: result.skippedAudioTracks,
        mergedOverlapCount: result.mergedOverlapCount,
        committed: committed,
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
      ticket.finish();
      if (identical(_activeRun, run)) _activeRun = null;
    }
  }

  Future<void> _waitForTurn(_ExportTicket ticket, _ExportRun run) async {
    final available =
        await Future.any([
          ticket.previous.then((_) => true),
          run.cancelledSignal.future.then((_) => false),
        ]).timeout(
          drainTimeout,
          onTimeout: () =>
              throw const MobileExportException('上一次导出尚未结束，请稍后重试。'),
        );
    if (!available || run.cancelled) throw const MobileExportException('导出已取消');
    run.admitted = true;
  }

  @override
  Future<void> cancel() async {
    final run = _activeRun;
    if (run == null) return;
    run.cancelled = true;
    if (!run.cancelledSignal.isCompleted) run.cancelledSignal.complete();
    if (!run.admitted) return;
    final exportId = run.mergeId;
    try {
      await _channel.invokeMethod<void>(
        'cancelExport',
        exportId == null ? null : {'exportId': exportId},
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
