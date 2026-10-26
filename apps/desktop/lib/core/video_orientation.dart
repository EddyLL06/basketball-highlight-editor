import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 播放器画面的方向修正。
///
/// ## 问题
///
/// 手机的 MP4 会把转正角度写在容器里（`rotation` side data）。media_kit 在
/// `real.dart` 里读到 `rotate` 后**只交换了上报的宽高**：
///
/// ```dart
/// if (rotate == 0 || rotate == 180) { width = dw; height = dh; }
/// else { width = dh; height = dw; }   // 90 / 270 度
/// ```
///
/// 但纹理内存仍是编码方向的布局。于是播放器对外声称「我是 1512×720 的横向
/// 画面」，实际内容却是竖的 720×1512。`FittedBox` 按 1512 的宽度去采样，
/// 越界后得到重复的像素——界面上表现为画面被拉伸、上下重复两遍。
///
/// ## 修法
///
/// 1. 用 [Video] 的 `aspectRatio` 覆盖掉谎报的 rect，按**编码方向**的真实比例
///    排版，纹理就不再被越界采样；
/// 2. 外层用 [RotatedBox] 把画面转到显示方向；
/// 3. 外框在上游已按显示方向算好比例，转正后正好铺满。
class OrientedVideo extends StatelessWidget {
  const OrientedVideo({
    super.key,
    required this.controller,
    required this.rotation,
    this.displayAspectRatio,
    this.fit = BoxFit.contain,
  });

  final VideoController? controller;

  /// 源文件声明的旋转角度（引擎 `inspect_video` 返回的 `rotation`），按 ffmpeg 显示矩阵
  /// 的约定是**逆时针**角度：90 表示显示时要把编码画面逆时针转 90°。
  final int rotation;

  /// 显示方向的宽高比（宽/高）。用来反推编码方向的宽高比。
  ///
  /// 不传时退回播放器报告的尺寸，退化成普通 [Video]。
  final double? displayAspectRatio;

  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return const SizedBox.shrink();
    }
    final turns = rotationQuarterTurns(rotation);
    // 编码方向（纹素真实布局）的宽高比。
    final sourceAspectRatio = _sourceAspectRatioFor(displayAspectRatio, turns);
    if (turns == 0) {
      // 不转向时按播放器上报的尺寸排版：Windows 软件渲染会把 4:3 等非 16:9
      // 画面塞进带黑边的 1920×1080 纹理，调用方用 cover 裁掉黑边，这里不能
      // 再强制比例，否则黑边露出来、画面和检测框对不齐。
      return Video(controller: c, fit: fit, controls: NoVideoControls);
    }
    final child = Video(
      controller: c,
      fit: fit,
      controls: NoVideoControls,
      // 关键：按编码方向排版，避免 FittedBox 用过宽的 rect 越界采样。
      aspectRatio: sourceAspectRatio,
    );
    if (turns % 2 == 0) {
      return RotatedBox(quarterTurns: turns, child: child);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return RotatedBox(quarterTurns: turns, child: child);
        }
        return RotatedBox(
          quarterTurns: turns,
          child: SizedBox(
            width: constraints.maxHeight,
            height: constraints.maxWidth,
            child: child,
          ),
        );
      },
    );
  }

  /// 显示比例转成编码比例：转 90/270 度时宽高互换。
  double? _sourceAspectRatioFor(double? displayAspectRatio, int turns) =>
      sourceAspectRatio(displayAspectRatio, turns);
}

/// 显示方向的宽高比换成编码方向的宽高比：转 90/270 度时宽高互换。
///
/// media_kit 上报的 rect 是显示方向的尺寸，纹理内存却是编码方向布局，
/// 用它反推才能按真实布局采样。[displayAspectRatio] 非法时返回 null。
double? sourceAspectRatio(double? displayAspectRatio, int turns) {
  final aspect = displayAspectRatio;
  if (aspect == null || aspect <= 0 || !aspect.isFinite) return null;
  if (turns % 2 == 0) return aspect;
  return 1 / aspect;
}

/// 把逆时针的 [rotation] 换成 [RotatedBox] 用的顺时针四分之一圈数（0/1/2/3），非法值当 0。
int rotationQuarterTurns(int rotation) {
  final normalized = ((-rotation % 360) + 360) % 360;
  switch (normalized) {
    case 90:
      return 1;
    case 180:
      return 2;
    case 270:
      return 3;
    default:
      return 0;
  }
}

/// 播放器是否已经把画面转正。
///
/// 只有 Windows 需要 [OrientedVideo] 兜底：media_kit 在那儿只交换宽高、
/// 不转纹理。其它平台交给播放器自己处理。
bool playerAppliesRotation() => !Platform.isWindows;
