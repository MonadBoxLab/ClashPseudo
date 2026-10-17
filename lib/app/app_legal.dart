import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Clash Pseudo (GPL-3.0-only)',
    ], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks(const [
      'mihomo v1.19.32',
    ], await rootBundle.loadString('third_party/mihomo/LICENSE'));
    yield LicenseEntryWithLineBreaks(const [
      'Go 原生运行依赖',
    ], await rootBundle.loadString('third_party/go-notices.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Android 运行依赖',
    ], await rootBundle.loadString('third_party/android-notices.txt'));
    yield LicenseEntryWithLineBreaks(const [
      'Material Icons 字体',
    ], await rootBundle.loadString('third_party/material-icons-notice.txt'));
  });
}

Future<void> showAppLegal(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: const Text('关于 Clash Pseudo'),
    content: const Text(
      '自有代码采用 GPL-3.0-only。您可以依照 GNU 通用公共许可证第 3 版复制、修改和分发。'
      '在适用法律允许范围内不提供担保。第三方部分保留各自版权与许可。\n\n'
      '许可全文与随包第三方通知可在下方查看。对应源码与构建材料须随实际分发版本提供；'
      '当前为未公开发布的开发版本。',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => const LicensePage(applicationName: 'Clash Pseudo'),
          ),
        ),
        child: const Text('许可与第三方通知'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);
