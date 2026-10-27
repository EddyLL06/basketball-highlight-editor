import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'diagnostic_redaction.dart';

class DiagnosticErrorRecord {
  const DiagnosticErrorRecord(this.error, this.stack, this.operation);
  final Object error;
  final StackTrace? stack;
  final String operation;
}

class DiagnosticSnapshot {
  const DiagnosticSnapshot({
    this.environment = const {},
    this.lines = const [],
    this.available = false,
  });
  final Map<String, Object?> environment;
  final List<String> lines;
  final bool available;
}

abstract class DiagnosticBackend {
  Future<void> initialize(String version, String language);
  Future<void> append(String message, String? key);
  Future<DiagnosticSnapshot> snapshot();
}

class _UnavailableBackend implements DiagnosticBackend {
  @override
  Future<void> initialize(String version, String language) async {}
  @override
  Future<void> append(String message, String? key) async {}
  @override
  Future<DiagnosticSnapshot> snapshot() async => const DiagnosticSnapshot();
}

class MethodChannelDiagnosticBackend implements DiagnosticBackend {
  const MethodChannelDiagnosticBackend();
  static const channel = MethodChannel('com.bhe.bhe/diagnostics');
  @override
  Future<void> initialize(String version, String language) =>
      channel.invokeMethod<void>('initialize', {
        'version': version,
        'language': language,
      });
  @override
  Future<void> append(String message, String? key) =>
      channel.invokeMethod<void>('append', {'message': message, 'key': key});
  @override
  Future<DiagnosticSnapshot> snapshot() async {
    final raw = await channel.invokeMapMethod<String, Object?>('snapshot');
    return DiagnosticSnapshot(
      environment:
          (raw?['environment'] as Map?)?.cast<String, Object?>() ?? const {},
      lines: (raw?['lines'] as List?)?.whereType<String>().toList() ?? const [],
      available: raw?['available'] == true,
    );
  }
}

/// Tests do not touch a native channel unless they explicitly inject its backend.
class MobileDiagnostics {
  MobileDiagnostics([DiagnosticBackend? backend])
    : _backend = backend ?? _UnavailableBackend();
  static MobileDiagnostics instance = MobileDiagnostics();
  final DiagnosticBackend _backend;
  String _version = 'dev';
  String _language = 'unknown';

  Future<void> initialize({
    required String version,
    required String language,
  }) async {
    _version = version;
    _language = language;
    try {
      await _backend
          .initialize(version, language)
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Only fixed event codes and numeric/bool fields, never filenames or project names.
  void event(String code, {int? count, bool? available}) {
    if (!RegExp(r'^[a-zA-Z0-9_.:-]{1,120}$').hasMatch(code)) return;
    _append(
      'app event: $code${count == null ? '' : ' count=$count'}${available == null ? '' : ' available=$available'}',
    );
  }

  DiagnosticErrorRecord error(
    Object error,
    StackTrace? stack, {
    String operation = 'app',
  }) {
    final record = DiagnosticErrorRecord(error, stack, operation);
    try {
      final frames =
          stack?.toString().split('\n').take(30).toList() ?? const <String>[];
      final raw = error.toString();
      final bounded = raw.length > 8192
          ? '${raw.substring(0, 8192)} [truncated]'
          : raw;
      final key = sha256
          .convert(
            utf8.encode('${error.runtimeType}|$bounded|${frames.join('\n')}'),
          )
          .toString();
      final safeOperation =
          RegExp(r'^[a-zA-Z0-9_.:-]{1,80}$').hasMatch(operation)
          ? operation
          : 'app';
      final message =
          'app error: $safeOperation ${error.runtimeType}: ${redactDiagnosticText(bounded)}';
      _append([message, ...frames.map(redactDiagnosticText)].join('\n'), key);
    } catch (_) {
      /* Error reporting must never replace the original exception. */
    }
    return record;
  }

  void _append(String message, [String? key]) {
    unawaited(() async {
      try {
        await _backend.append(message, key).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }());
  }

  Future<DiagnosticSnapshot> snapshot() async {
    try {
      final value = await _backend.snapshot().timeout(
        const Duration(seconds: 3),
      );
      return DiagnosticSnapshot(
        environment: {
          'app_version': _version,
          'language': _language,
          ...value.environment,
        },
        lines: value.lines.length > 300
            ? value.lines.sublist(value.lines.length - 300)
            : value.lines,
        available: value.available,
      );
    } catch (_) {
      return DiagnosticSnapshot(
        environment: {'app_version': _version, 'language': _language},
      );
    }
  }
}
