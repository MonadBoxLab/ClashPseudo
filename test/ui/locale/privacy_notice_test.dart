import 'dart:convert';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final zh = lookupAppLocalizations(const Locale('zh'));
  tearDown(() => setMessageLanguage(AppLanguage.system));

  test('各分段文案拼接后等于完整隐私告知', () {
    for (final strings in [en, zh]) {
      expect(
        strings.privacyNoticeBody,
        [
          strings.privacyNoticeIntro,
          strings.privacyDataProcessingTitle,
          strings.privacyDataProcessingBody,
          strings.privacyNetworkCommunicationTitle,
          strings.privacyNetworkCommunicationBody,
          strings.privacyPermissionPurposesTitle,
          strings.privacyPermissionPurposesBody,
          strings.privacyFilesAndBackupsTitle,
          strings.privacyFilesAndBackupsBody,
          strings.privacyRecordsAndLogsTitle,
          strings.privacyRecordsAndLogsBody,
          strings.privacyDeletingDataTitle,
          strings.privacyDeletingDataBody,
          strings.privacyProjectRepositoryTitle,
          strings.projectRepositoryUrl,
          strings.privacyNoticeLicenseNotice,
        ].join('\n\n'),
      );
      expect(strings.privacyNoticeLicenseName, 'GPLv3');
      expect(
        strings.projectRepositoryUrl,
        'https://github.com/MonadBoxLab/ClashPseudo',
      );
    }
  });

  test('简短隐私告知与相关提示使用预期的中英文文案', () {
    expect(zh.privacyNoticeTitle, '隐私与许可');
    expect(en.privacyNoticeTitle, 'Privacy and license');
    expect(zh.privacyNoticeReadFull, '完整说明');
    expect(en.privacyNoticeReadFull, 'Full notice');
    expect(zh.privacyNoticeUnderstood, '我已了解');
    expect(en.privacyNoticeUnderstood, 'Understood');
    expect(
      zh.privacyNoticeIntro,
      'Clash Pseudo 开源、免费，不进行用户数据采集或上报，不提供任何代理节点或订阅服务。',
    );
    expect(
      en.privacyNoticeIntro,
      'Clash Pseudo is free and open source. It does not collect or report '
      'user data and does not provide any proxy nodes or subscription services.',
    );
    expect(zh.privacyNoticeLicenseNotice, '更多请参见 GPLv3 协议。');
    expect(en.privacyNoticeLicenseNotice, 'See GPLv3 for more information.');
    expect(zh.privacyNoticeNotSaved, '未能确认提示记录已保存。下次打开可能再次显示。');
    expect(
      en.privacyNoticeNotSaved,
      'Could not confirm that the notice was recorded. '
      'It may appear again on next launch.',
    );
    expect(zh.sourceDistributionNotice, '对应源码与构建材料随发行版本提供。');
    expect(
      en.sourceDistributionNotice,
      'Corresponding source and build materials are provided with each release.',
    );
  });

  test('未确认保存的提示经过通道和存储编码后内容不变', () {
    final message = messages.privacyNoticeNotSaved;
    const codec = StandardMessageCodec();
    for (final restored in [
      message,
      AppMessage.fromMap(jsonDecode(jsonEncode(message.toMap()))),
      AppMessage.fromMap(
        codec.decodeMessage(codec.encodeMessage(message.toMap())),
      ),
    ]) {
      expect(restored, message);
      expect(restored.resolve(en), en.privacyNoticeNotSaved);
      expect(restored.resolve(zh), zh.privacyNoticeNotSaved);
    }
    setMessageLanguage(AppLanguage.zh);
    expect(message.text, zh.privacyNoticeNotSaved);
    setMessageLanguage(AppLanguage.en);
    expect(message.text, en.privacyNoticeNotSaved);
  });

  test('未确认保存的提示保留完整的原始错误', () {
    const detail = 'original-I/O-failure';
    final message = messages.privacyNoticeNotSaved.withDetail(detail);
    final restored = AppMessage.fromMap(
      jsonDecode(jsonEncode(message.toMap())),
    );
    expect(restored.detail, detail);
    expect(restored.resolve(en), '${en.privacyNoticeNotSaved}\n$detail');
    expect(restored.resolve(zh), '${zh.privacyNoticeNotSaved}\n$detail');
  });

  test('GPL 入口可读取随应用提供的完整许可文本', () async {
    final license = await rootBundle.loadString('LICENSE');
    expect(license, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(license, contains('Version 3, 29 June 2007'));
    expect(license, contains('END OF TERMS AND CONDITIONS'));
  });
}
