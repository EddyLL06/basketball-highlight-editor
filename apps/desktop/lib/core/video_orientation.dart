import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
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
/// **以下根因是待验证的推测，Windows 上画面仍不正常。**推测纹理内存仍是编码方向的
/// 布局：播放器对外声称「我是 1512×720 的横向画面」，实际内容却是竖的 720×1512，
/// 采样越界后得到重复的像素——界面上表现为画面被拉伸、上下重复两遍。
/// 但 `aspectRatio` 只改包裹 `Texture` 的 `SizedBox`，不改 Windows 原生缓冲的宽高
/// 和行跨度；另一条待查线索是 media_kit_video 2.0.1 `windows/video_output.cc`
/// 把 32 位的 `pitch` 地址传给要求 `size_t*` 的 `MPV_RENDER_PARAM_SW_STRIDE`。
///
/// ## 当前做法
///
/// 1. 用 [Video] 的 `aspectRatio` 覆盖播放器上报的 rect，按**编码方向**的比例排版；
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

/// 调试用：`--dart-define=BHE_SOFTWARE_VIDEO=true` 让 Mac 也按 Windows 的方式播放
/// （软件渲染 + 自己转画面），不用回到 Windows 就能检查带旋转角的视频。
const _forceSoftwareVideo = bool.fromEnvironment('BHE_SOFTWARE_VIDEO');

/// 播放器是否走软件渲染：Windows 上关了硬件加速。
bool useSoftwareVideo() => Platform.isWindows || _forceSoftwareVideo;

/// 播放器是否已经把画面转正。
///
/// 软件渲染下 mpv 不处理旋转，要由 [OrientedVideo] 转正（见
/// [matchPlayerToSourceRotation]）；硬件渲染交给播放器自己处理。
bool playerAppliesRotation() => !useSoftwareVideo();

/// 打开带旋转角的视频之前调用（播放器会在片源之间复用，每次 open 前都要调）。
///
/// Windows 上关了硬件加速，mpv 的软件渲染不处理旋转：90/270 度时 media_kit 按转正后的
/// 尺寸分配缓冲区，mpv 却按未转的画面裁剪，越界后画面错位、左右重复、带绿边；180 度则
/// 原样不转（头下脚上）。这里让 mpv 按编码方向输出，由 [OrientedVideo] 在 Flutter 里转正。
/// 输出尺寸也自己算：media_kit 软件渲染把纹理限在 1920×1080 内，竖的画面按
/// `width / height` 整数相除会算出宽度 0。
Future<void> matchPlayerToSourceRotation(
  Player player,
  VideoController controller, {
  required int rotation,
  required double? displayAspectRatio,
}) async {
  if (playerAppliesRotation()) return;
  final native = player.platform;
  if (native is! NativePlayer) return;
  final turns = rotationQuarterTurns(rotation);
  await native.setProperty('video-rotate', turns == 0 ? '0' : 'no');
  final aspect = sourceAspectRatio(displayAspectRatio, turns);
  if (turns == 0 || aspect == null) {
    await controller.setSize();
    return;
  }
  final size = softwareOutputSize(aspect);
  await controller.setSize(width: size.width, height: size.height);
}

/// 编码方向的画面在 media_kit 软件渲染上限（1920×1080）内等比放下的尺寸。
({int width, int height}) softwareOutputSize(double aspect) => aspect >= 1920 / 1080
    ? (width: 1920, height: (1920 / aspect).round())
    : (width: (1080 * aspect).round(), height: 1080);
