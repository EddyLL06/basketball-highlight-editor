import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const windows =
      '分析引擎在这台电脑上无法启动（运行库初始化失败）。请先安装最新的 VC++ 运行库后重启电脑，仍然不行请把 CPU 型号和诊断信息发给我们。';
  const generic =
      '分析引擎在这台电脑上无法启动（运行库初始化失败）。请检查或重新安装应用，仍然不行请把系统版本、CPU 型号和诊断信息发给我们。';
  const dependency =
      '分析引擎缺少模型加载依赖，请安装最新版本的应用，仍然不行请发送诊断信息。';
  const details = 'ImportError: DLL load failed: 原始异常\nstack frame 1';
  for (final language in ['zh', 'en']) {
    for (final source in [windows, generic, dependency]) {
      test(
        'runtime first line is localized and details preserved $language $source',
        () async {
          final l10n = await BheLocalizations.delegate.load(Locale(language));
          final result = l10n.text('$source\n$details');
          expect(result.substring(result.indexOf('\n') + 1), details);
          if (language == 'zh') {
            expect(result.split('\n').first, source);
          } else {
            expect(
              result,
              startsWith(
                source == dependency
                    ? 'The analysis engine is missing a dependency required to load the model.'
                    : 'The analysis engine could not start on this computer (runtime initialization failed).',
              ),
            );
            expect(
              result.split('\n').first,
              contains(source == dependency ? 'latest version' : 'CPU model'),
            );
            expect(
              result.split('\n').first.contains('Visual C++'),
              source == windows,
            );
            final coded = l10n.text(
              'ENGINE_RUNTIME_UNAVAILABLE: $source\n$details',
            );
            expect(coded, 'ENGINE_RUNTIME_UNAVAILABLE: $result');
          }
        },
      );
    }
  }
}
