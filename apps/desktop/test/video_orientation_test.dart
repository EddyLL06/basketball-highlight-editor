import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/core/video_orientation.dart';

void main() {
  group('rotationQuarterTurns', () {
    test('0 度不旋转', () {
      expect(rotationQuarterTurns(0), 0);
    });

    test('360 度等于不旋转', () {
      expect(rotationQuarterTurns(360), 0);
    });

    // rotation 是逆时针角度，RotatedBox 按顺时针转。
    test('逆时针 90 度要顺时针转四分之三圈', () {
      expect(rotationQuarterTurns(90), 3);
    });

    test('180 度转半圈', () {
      expect(rotationQuarterTurns(180), 2);
    });

    test('逆时针 270 度要顺时针转四分之一圈', () {
      expect(rotationQuarterTurns(270), 1);
    });

    test('手机竖拍常见的 -90（顺时针 90 度）转四分之一圈', () {
      expect(rotationQuarterTurns(-90), 1);
    });

    test('超过 360 的角度归一化（450 等价于 90）', () {
      expect(rotationQuarterTurns(450), 3);
    });

    test('无法识别的角度当不旋转处理', () {
      expect(rotationQuarterTurns(37), 0);
    });
  });

  group('sourceAspectRatio（显示比例反推编码比例）', () {
    // 竖拍横看：显示 1512x720（2.10），编码是 720x1512（0.476）。
    test('90 度时宽高互换', () {
      expect(sourceAspectRatio(2.10, 1), closeTo(1 / 2.10, 1e-9));
    });

    test('270 度时同样互换', () {
      expect(sourceAspectRatio(0.476, 3), closeTo(1 / 0.476, 1e-9));
    });

    test('180 度不互换', () {
      expect(sourceAspectRatio(2.10, 2), closeTo(2.10, 1e-9));
    });

    test('不旋转时保持原值', () {
      expect(sourceAspectRatio(1.778, 0), closeTo(1.778, 1e-9));
    });

    test('非法比例返回 null，退化为普通播放', () {
      expect(sourceAspectRatio(null, 1), isNull);
      expect(sourceAspectRatio(0, 1), isNull);
      expect(sourceAspectRatio(-1, 1), isNull);
    });
  });

  group('softwareOutputSize（Windows 软件渲染的输出尺寸）', () {
    test('竖拍 720x1512 等比放进 1080 高，不再被整数除法算成宽 0', () {
      expect(softwareOutputSize(720 / 1512), (width: 514, height: 1080));
    });

    test('比 16:9 还宽的画面以 1920 宽为准', () {
      expect(softwareOutputSize(1512 / 720), (width: 1920, height: 914));
    });

    test('4:3 画面以 1080 高为准', () {
      expect(softwareOutputSize(4 / 3), (width: 1440, height: 1080));
    });
  });
}
