import 'package:bhe_core/bhe_core.dart';

class NativeExportResult {
  const NativeExportResult(
    this.path,
    this.skippedAudioTracks, [
    this.mergedOverlapCount,
  ]);
  final String path;
  final List<SkippedAudioTrack> skippedAudioTracks;
  final int? mergedOverlapCount;

  // iOS and older platform implementations return just the output path.
  factory NativeExportResult.decode(Object? value, String fallback) {
    if (value is String) return NativeExportResult(value, const []);
    if (value is! Map) return NativeExportResult(fallback, const []);
    return NativeExportResult(
      value['outputPath'] as String? ?? fallback,
      [
        if (value['skippedAudioTracks'] is List)
          for (final track
              in (value['skippedAudioTracks'] as List).whereType<Map>())
            if (track['index'] is int && track['mime'] is String)
              SkippedAudioTrack(
                index: track['index'] as int,
                mime: track['mime'] as String,
              ),
      ],
      value['mergedOverlapCount'] is int &&
              (value['mergedOverlapCount'] as int) >= 0
          ? value['mergedOverlapCount'] as int
          : null,
    );
  }
}
