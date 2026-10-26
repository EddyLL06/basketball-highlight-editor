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
}
