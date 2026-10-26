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

    test('90 度转四分之一圈', () {
      expect(rotationQuarterTurns(90), 1);
    });

    test('180 度转半圈', () {
      expect(rotationQuarterTurns(180), 2);
    });

    test('270 度转四分之三圈', () {
      expect(rotationQuarterTurns(270), 3);
    });

    test('负数角度归一化（-90 等价于 270）', () {
      expect(rotationQuarterTurns(-90), 3);
    });

    test('超过 360 的角度归一化（450 等价于 90）', () {
      expect(rotationQuarterTurns(450), 1);
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
}
