import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A known failure is not a loading operation.
class VideoUnavailablePlaceholder extends StatelessWidget {
  const VideoUnavailablePlaceholder({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.videoOff, color: Colors.white70, size: 32),
          const SizedBox(height: 8),
          Text(
            context.bheText('视频不可用'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}
