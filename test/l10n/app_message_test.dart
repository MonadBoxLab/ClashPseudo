import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_text_page.dart';
import 'package:clash_pseudo/src/features/configs/widgets/config_field_dialog.dart';
import 'package:clash_pseudo/src/features/configs/widgets/confirm_action.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FeedbackController extends AppController {
  _FeedbackController() : super(AppBridge()) {
    loading = false;
    state = const AppSnapshot(phase: 'STOPPED');
  }

  final commands = <Map<String, Object?>>[];

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(Map.of(command));
    lastCommand = Map.of(command);
    lastCommandAutomatic = automatic;
    commandErrorMessage = null;
    notifyListeners();
    return 'retry-${commands.length}';
  }

  void changed() => notifyListeners();
}

Future<void> _showFeedback(
  WidgetTester tester,
  _FeedbackController controller,
) async {
  setMessageLanguage(AppLanguage.en);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: OperationFeedback(
        controller: controller,
        child: const Scaffold(body: Text('Reader anchor')),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final zh = lookupAppLocalizations(const Locale('zh'));
  tearDown(() => setMessageLanguage(AppLanguage.system));

  test(
    'saved verification and partial restore wrappers retain nested facts',
    () {
      final result = messages.storageSyncWarning(
        messages.overrideSavedApplyLater,
      );
      final verification = messages.localCustomSavedVerificationFailed(
        result: result,
        reason: messages.overrideChangedReopen,
      );
      final restored = messages.backupRestoredWithIssue(
        issue: const AppMessage('backupConnectionFailed'),
      );
      const codec = StandardMessageCodec();
      for (final message in [
        verification,
        restored,
        messages.storageSyncWarning(restored),
      ]) {
        for (final decoded in [
          AppMessage.fromMap(jsonDecode(jsonEncode(message.toMap()))),
          AppMessage.fromMap(
            codec.decodeMessage(codec.encodeMessage(message.toMap())),
          ),
        ]) {
          expect(decoded, message);
          for (final strings in [en, zh, en]) {
            expect(decoded.resolve(strings), message.resolve(strings));
            expect(decoded.toMap(), message.toMap());
          }
        }
      }
      expect(verification.args['result'], isA<AppMessage>());
      expect(verification.args['reason'], isA<AppMessage>());
      expect(verification.resolve(en), startsWith('${result.resolve(en)}\n\n'));
      expect(verification.resolve(zh), startsWith('${result.resolve(zh)}\n\n'));
      expect(
        verification.resolve(en),
        contains('The draft was not submitted again.'),
      );
      expect(verification.resolve(zh), contains('未再次提交草稿。'));
      expect(
        restored.resolve(en),
        'Backup data restored. ${en.backupConnectionFailed}',
      );
      expect(restored.resolve(zh), '数据已恢复。${zh.backupConnectionFailed}');
      expect(
        messages.storageSyncWarning(restored).resolve(en),
        startsWith('Backup data restored. ${en.backupConnectionFailed}\n\n'),
      );
    },
  );

  test('saved-result wrappers reject raw or missing nested descriptions', () {
    const private = 'private-native-detail-or-file-path';
    for (final args in <Map<String, Object?>>[
      {},
      {'result': messages.overrideSavedApplyLater},
      {'reason': messages.overrideChangedReopen},
      {'result': private, 'reason': messages.overrideChangedReopen},
      {'result': messages.overrideSavedApplyLater, 'reason': private},
      {'result': true, 'reason': messages.overrideChangedReopen},
    ]) {
      final message = AppMessage.withArgs(
        'localCustomSavedVerificationFailed',
        args,
      );
      for (final strings in [en, zh]) {
        expect(message.resolve(strings), strings.operationNotCompletedRetry);
        expect(message.resolve(strings), isNot(contains(private)));
      }
    }
    for (final issue in <Object?>[null, private, 1, false]) {
      final message = AppMessage.withArgs('backupRestoredWithIssue', {
        'issue': issue,
      });
      for (final strings in [en, zh]) {
        expect(message.resolve(strings), strings.operationNotCompletedRetry);
        expect(message.resolve(strings), isNot(contains(private)));
      }
    }
  });

  test('backup document failure messages do not imply VPN failure or atomic saving', () {
    final values = [
      ('backupFailed', en.backupFailed, zh.backupFailed),
      (
        'backupDocumentWriteUnconfirmed',
        en.backupDocumentWriteUnconfirmed,
        zh.backupDocumentWriteUnconfirmed,
      ),
    ];
    for (final (id, english, chinese) in values) {
      final original = AppMessage(id);
      final restored = AppMessage.fromMap(
        jsonDecode(jsonEncode(original.toMap())),
      );
      expect(restored, original);
      expect(restored.resolve(en), english);
      expect(restored.resolve(zh), chinese);
      expect(english, isNot(contains('VPN')));
      expect(chinese, isNot(contains('VPN')));
      final diagnostic = AppMessage.withArgs(id, {
        'raw': 'private-document-uri',
      });
      expect(diagnostic.resolve(en), english);
      expect(diagnostic.resolve(zh), chinese);
    }
    expect(en.backupFailed, 'The backup operation could not be completed.');
    expect(zh.backupFailed, '备份操作未完成。');
    expect(
      en.backupDocumentWriteUnconfirmed,
      'Saving the backup file was not confirmed. An incomplete file may remain at the chosen location.',
    );
    expect(zh.backupDocumentWriteUnconfirmed, '备份文件未确认保存完成；所选位置可能留有不完整文件。');
  });

  test('connection-rule controls reuse a generic expired-context label', () {
    expect(en.connectionRuleScope, 'Match scope');
    expect(zh.connectionRuleScope, '匹配范围');
    expect(
      en.connectionRuleUnavailable,
      'Current connection information cannot be used to add a rule.',
    );
    expect(zh.connectionRuleUnavailable, '当前连接信息不可用于新增规则。');
    expect(
      en.connectionRuleTargetsFailed,
      'Could not read current strategy groups. Try again.',
    );
    expect(zh.connectionRuleTargetsFailed, '无法读取当前策略组，请重试。');
    expect(en.popupExpiredShort, 'Expired · Reopen');
    expect(zh.popupExpiredShort, '已失效 · 请重新打开');
    expect(en.popupExpiredShort.toLowerCase(), isNot(contains('strategy')));
    expect(zh.popupExpiredShort, isNot(contains('策略')));
  });

  test(
    'backup labels separate stored data, follow-ups and unconfirmed outcomes',
    () {
      expect(en.backupCounts(1, 1), '1 configuration · 1 plugin');
      expect(en.backupCounts(0, 2), '0 configurations · 2 plugins');
      expect(zh.backupCounts(1, 2), '1 个配置 · 2 个插件');
      expect(en.backupSelected('Selected'), 'Selected configuration: Selected');
      expect(zh.backupSelected('配置'), '所选配置：配置');
      expect(en.backupCreatedAt('2026-10-19'), 'Created: 2026-10-19');
      expect(zh.backupCreatedAt('2026-10-19'), '创建时间：2026-10-19');
      for (final strings in [en, zh]) {
        expect(
          [
            strings.backupTitle,
            strings.backupExport,
            strings.backupImport,
            strings.backupRestore,
            strings.backupSensitiveNotice,
            strings.backupScopeNotice,
            strings.backupNoSelection,
            strings.backupNotSelected,
            strings.backupConfirmTitle,
            strings.backupConfirmMessage,
            strings.backupConfirmRunning,
            strings.backupConfirmStopped,
            strings.backupConfirmUnconfirmed,
            strings.backupPreparing,
            strings.backupConnectionStopped,
            strings.backupConnectionNotStarted,
            strings.backupConnectionRestored,
          ].every((value) => value.trim().isNotEmpty),
          isTrue,
        );
        expect(strings.backupNoSelection, isNot(strings.backupNotSelected));
        expect(strings.backupRestored, isNot(strings.backupRestoreUnconfirmed));
        expect(strings.backupRestored, isNot(strings.backupConnectionRestored));
      }
      expect(en.backupSensitiveNotice, contains('not encrypted'));
      expect(zh.backupSensitiveNotice, contains('未加密'));
      expect(en.backupConfirmMessage, contains('Empty collections also clear'));
      expect(zh.backupConfirmMessage, contains('空集合也会清空'));
      expect(
        en.backupConfirmRunning,
        contains('newer disconnect request takes priority'),
      );
      expect(zh.backupConfirmRunning, contains('新的断开意图优先'));
      expect(
        en.backupConfirmStopped,
        'Restoration will not start a connection.',
      );
      expect(zh.backupConfirmStopped, '恢复后不会主动建立连接。');
    },
  );

  for (final (id, english, chinese) in [
    ('backupCancelled', en.backupCancelled, zh.backupCancelled),
    (
      'backupCandidateExpired',
      en.backupCandidateExpired,
      zh.backupCandidateExpired,
    ),
    (
      'backupConnectionCancelled',
      en.backupConnectionCancelled,
      zh.backupConnectionCancelled,
    ),
    (
      'backupConnectionFailed',
      en.backupConnectionFailed,
      zh.backupConnectionFailed,
    ),
    ('backupExportSaved', en.backupExportSaved, zh.backupExportSaved),
    ('backupInvalid', en.backupInvalid, zh.backupInvalid),
    ('backupNotRestored', en.backupNotRestored, zh.backupNotRestored),
    ('backupRestored', en.backupRestored, zh.backupRestored),
    (
      'backupRestoreUnconfirmed',
      en.backupRestoreUnconfirmed,
      zh.backupRestoreUnconfirmed,
    ),
    (
      'backupSchedulesFailed',
      en.backupSchedulesFailed,
      zh.backupSchedulesFailed,
    ),
    (
      'backupSettingsRefreshFailed',
      en.backupSettingsRefreshFailed,
      zh.backupSettingsRefreshFailed,
    ),
    ('backupTooLarge', en.backupTooLarge, zh.backupTooLarge),
  ]) {
    test('$id remains localized after storage and channel round trips', () {
      final message = AppMessage(id);
      const codec = StandardMessageCodec();
      for (final restored in [
        message,
        AppMessage.fromMap(jsonDecode(jsonEncode(message.toMap()))),
        AppMessage.fromMap(
          codec.decodeMessage(codec.encodeMessage(message.toMap())),
        ),
      ]) {
        expect(restored, message);
        expect(restored.resolve(en), english);
        expect(restored.resolve(zh), chinese);
        expect(english, isNot(en.operationNotCompletedRetry));
        expect(chinese, isNot(zh.operationNotCompletedRetry));
      }
      const private = 'private-backup-file-or-native-diagnostic';
      final extra = AppMessage.withArgs(id, {'raw': private});
      expect(extra.resolve(en), english);
      expect(extra.resolve(zh), chinese);
      expect(extra.resolve(en), isNot(contains(private)));
      expect(extra.resolve(zh), isNot(contains(private)));
    });
  }

  test(
    'local custom notices retain lower-priority and reference semantics',
    () {
      expect(en.localCustomNotice, contains('lower-priority definition'));
      expect(zh.localCustomNotice, contains('较低优先级的同名定义'));
      expect(
        en.localCustomNotice,
        contains('references are not repaired automatically'),
      );
      expect(zh.localCustomNotice, contains('不会自动修复引用'));
      expect(
        en.localCustomDefinitionsEmpty,
        'There are no directly defined local custom entries here.',
      );
      expect(zh.localCustomDefinitionsEmpty, '此处没有直接定义的本地自定义条目。');
      expect(
        en.localCustomDeleteConfirm,
        contains('existing references will not be changed'),
      );
      expect(zh.localCustomDeleteConfirm, contains('已有引用不会自动修改'));
    },
  );

  test(
    'all strategy group labels do not reuse current-mode visibility text',
    () {
      expect(en.allStrategyGroups, 'All strategy groups');
      expect(zh.allStrategyGroups, '全部策略组');
      expect(en.hiddenGroupAttribute, 'Hidden');
      expect(zh.hiddenGroupAttribute, '隐藏');
      expect(en.globalGroupAttribute, 'Global group');
      expect(zh.globalGroupAttribute, '全局组');
      expect(en.noStrategyGroups, 'No strategy groups');
      expect(zh.noStrategyGroups, '没有策略组');
      for (final strings in [en, zh]) {
        expect(strings.noStrategyGroups, isNot(strings.noVisibleGroups));
        expect(strings.hiddenGroupAttribute, isNot(strings.hideHiddenGroups));
      }
    },
  );

  test('settings sections distinguish configuration, routing and tools', () {
    expect(en.configurationsAndPlugins, 'Configurations & plugins');
    expect(zh.configurationsAndPlugins, '配置与插件');
    expect(en.routingAndResources, 'Routing & resources');
    expect(zh.routingAndResources, '分流与资源');
    expect(en.diagnosticTools, 'Diagnostics');
    expect(zh.diagnosticTools, '诊断工具');
    for (final strings in [en, zh]) {
      expect({
        strings.configurationsAndPlugins,
        strings.routingAndResources,
        strings.diagnosticTools,
      }, hasLength(3));
    }
  });

  test('DNS tools and session metrics have localized SDK-generated labels', () {
    for (final strings in [en, zh]) {
      final labels = [
        strings.trafficDownloaded,
        strings.trafficUploaded,
        strings.trafficConnections,
        strings.processMemory,
        strings.processMemoryUnavailable,
        strings.dnsTools,
        strings.dnsName,
        strings.dnsRecordType,
        strings.dnsQuery,
        strings.dnsResolverNotice,
        strings.dnsReady,
        strings.dnsPreparing,
        strings.dnsRunning,
        strings.dnsExpired,
        strings.dnsNoConfiguration,
        strings.dnsUnavailable,
        strings.dnsInvalidRequest,
        strings.dnsBusy,
        strings.dnsTimeout,
        strings.dnsCancelled,
        strings.dnsQueryFailed,
        strings.dnsResultTooLarge,
        strings.dnsInvalidResponse,
        strings.dnsQuestion,
        strings.dnsAnswer,
        strings.dnsAuthority,
        strings.dnsAdditional,
        strings.dnsNoRecords,
        strings.dnsTruncated,
        strings.dnsClearCache,
        strings.dnsClearFakeIp,
        strings.dnsFakeIpWarning,
        strings.dnsCacheCompleted,
        strings.dnsCacheEmpty,
        strings.dnsFakeIpCompleted,
        strings.dnsFakeIpEmpty,
        strings.dnsCachePartialOrFailed,
        strings.dnsCacheFailed,
      ];
      expect(labels.every((text) => text.trim().isNotEmpty), isTrue);
      expect(strings.dnsRecordMeta('AAAA', 'IN', 60), 'AAAA · IN · TTL 60 s');
    }
    expect(en.trafficDownloaded, 'Downloaded');
    expect(en.trafficUploaded, 'Uploaded');
    expect(en.trafficConnections, 'Connections');
    expect(
      en.trafficSessionScope,
      'Core-counted traffic for this VPN session, not device-wide usage or billed traffic.',
    );
    expect(zh.trafficSessionScope, '本次 VPN 连接的内核统计，并非设备总量或计费流量。');
    expect(
      en.providerFormFormatHint,
      'format controls external content encoding; inline uses rule entries.',
    );
    expect(zh.providerFormFormatHint, 'format 控制外部内容编码；inline 使用规则条目。');
    expect(zh.trafficDownloaded, '累计下载');
    expect(zh.trafficUploaded, '累计上传');
    expect(zh.trafficConnections, '连接');
    expect(
      en.strategyGroupHashKeyInvalid,
      'round-robin does not accept a non-empty hash-key',
    );
    expect(zh.strategyGroupHashKeyInvalid, 'round-robin 不接受非空 hash-key');
    expect(en.dnsElapsed(12.5), 'Query time 12.5 ms');
    expect(zh.dnsElapsed(12.5), '查询耗时 12.5 ms');
    expect(en.dnsRcode('NXDOMAIN', 3), 'RCODE: NXDOMAIN (3)');
    expect(zh.dnsRcode('NXDOMAIN', 3), '返回码：NXDOMAIN (3)');
    expect(en.dnsTimeout, contains('not retried'));
    expect(zh.dnsTimeout, contains('未自动重试'));
    expect(
      en.dnsResolverNotice,
      contains('does not reproduce client DNS responses'),
    );
    expect(zh.dnsResolverNotice, contains('不等同于客户端 DNS 响应'));
    expect(en.dnsCacheCompleted, contains('refill them immediately'));
    expect(zh.dnsCacheCompleted, contains('查询可立即回填'));
    expect(en.dnsCachePartialOrFailed, contains('partial effects'));
    expect(zh.dnsCachePartialOrFailed, contains('部分影响'));
  });

  for (final (suffix, reason, english, chinese) in [
    (
      'TunDisabled',
      messages.nativeReasonTunDisabled,
      en.nativeReasonTunDisabled,
      zh.nativeReasonTunDisabled,
    ),
    (
      'ControllerUnavailable',
      messages.nativeReasonControllerUnavailable,
      en.nativeReasonControllerUnavailable,
      zh.nativeReasonControllerUnavailable,
    ),
    (
      'RootRedirection',
      messages.nativeReasonRootRedirection,
      en.nativeReasonRootRedirection,
      zh.nativeReasonRootRedirection,
    ),
    (
      'TransparentSockets',
      messages.nativeReasonTransparentSockets,
      en.nativeReasonTransparentSockets,
      zh.nativeReasonTransparentSockets,
    ),
    (
      'InterfaceBinding',
      messages.nativeReasonInterfaceBinding,
      en.nativeReasonInterfaceBinding,
      zh.nativeReasonInterfaceBinding,
    ),
    (
      'RoutingMark',
      messages.nativeReasonRoutingMark,
      en.nativeReasonRoutingMark,
      zh.nativeReasonRoutingMark,
    ),
    (
      'TcpFastOpen',
      messages.nativeReasonTcpFastOpen,
      en.nativeReasonTcpFastOpen,
      zh.nativeReasonTcpFastOpen,
    ),
    (
      'Firewall',
      messages.nativeReasonFirewall,
      en.nativeReasonFirewall,
      zh.nativeReasonFirewall,
    ),
    (
      'SystemClock',
      messages.nativeReasonSystemClock,
      en.nativeReasonSystemClock,
      zh.nativeReasonSystemClock,
    ),
    (
      'ExternalFd',
      messages.nativeReasonExternalFd,
      en.nativeReasonExternalFd,
      zh.nativeReasonExternalFd,
    ),
    (
      'InterfaceName',
      messages.nativeReasonInterfaceName,
      en.nativeReasonInterfaceName,
      zh.nativeReasonInterfaceName,
    ),
    ('Gso', messages.nativeReasonGso, en.nativeReasonGso, zh.nativeReasonGso),
    (
      'AutoRedirect',
      messages.nativeReasonAutoRedirect,
      en.nativeReasonAutoRedirect,
      zh.nativeReasonAutoRedirect,
    ),
    (
      'LinuxRouting',
      messages.nativeReasonLinuxRouting,
      en.nativeReasonLinuxRouting,
      zh.nativeReasonLinuxRouting,
    ),
    (
      'InterfaceFilter',
      messages.nativeReasonInterfaceFilter,
      en.nativeReasonInterfaceFilter,
      zh.nativeReasonInterfaceFilter,
    ),
    (
      'MacFilter',
      messages.nativeReasonMacFilter,
      en.nativeReasonMacFilter,
      zh.nativeReasonMacFilter,
    ),
    (
      'PortFilter',
      messages.nativeReasonPortFilter,
      en.nativeReasonPortFilter,
      zh.nativeReasonPortFilter,
    ),
    (
      'StrictRoute',
      messages.nativeReasonStrictRoute,
      en.nativeReasonStrictRoute,
      zh.nativeReasonStrictRoute,
    ),
    (
      'DnsHijackConflict',
      messages.nativeReasonDnsHijackConflict,
      en.nativeReasonDnsHijackConflict,
      zh.nativeReasonDnsHijackConflict,
    ),
    (
      'Ipv6Unavailable',
      messages.nativeReasonIpv6Unavailable,
      en.nativeReasonIpv6Unavailable,
      zh.nativeReasonIpv6Unavailable,
    ),
    (
      'InvalidMtu',
      messages.nativeReasonInvalidMtu,
      en.nativeReasonInvalidMtu,
      zh.nativeReasonInvalidMtu,
    ),
    (
      'InvalidAddress',
      messages.nativeReasonInvalidAddress,
      en.nativeReasonInvalidAddress,
      zh.nativeReasonInvalidAddress,
    ),
    (
      'SystemDnsUnavailable',
      messages.nativeReasonSystemDnsUnavailable,
      en.nativeReasonSystemDnsUnavailable,
      zh.nativeReasonSystemDnsUnavailable,
    ),
    (
      'PrivateDnsUnavailable',
      messages.nativeReasonPrivateDnsUnavailable,
      en.nativeReasonPrivateDnsUnavailable,
      zh.nativeReasonPrivateDnsUnavailable,
    ),
    (
      'ProviderPath',
      messages.nativeReasonProviderPath,
      en.nativeReasonProviderPath,
      zh.nativeReasonProviderPath,
    ),
    (
      'AndroidUserUnavailable',
      messages.nativeReasonAndroidUserUnavailable,
      en.nativeReasonAndroidUserUnavailable,
      zh.nativeReasonAndroidUserUnavailable,
    ),
  ]) {
    test(
      'native reason $suffix renders in both locales after nested round-trip',
      () {
        const field = 'tun.enable';
        final description = messages.nativeConfigurationUnsupported(
          field,
          reason,
        );
        final encoded = {
          'id': 'nativeConfigurationUnsupported',
          'args': {
            'field': field,
            'reason': {
              'id': 'nativeReason$suffix',
              'args': <String, Object?>{},
            },
          },
        };
        expect(description.toMap(), encoded);
        expect(encodeAppMessages({'message': description}), {
          'message': encoded,
        });
        const codec = StandardMessageCodec();
        final channel = codec.decodeMessage(codec.encodeMessage(encoded));
        final stored = jsonDecode(jsonEncode(encoded));
        for (final restored in [
          description,
          AppMessage.fromMap(channel),
          AppMessage.fromMap(stored),
          messageFromPlatform(
            PlatformException(
              code: 'native',
              message: 'private native diagnostic',
              details: encoded,
            ),
            fallback: messages.operationFailed,
          ),
        ]) {
          expect(restored, description);
          expect(restored.args['reason'], isA<AppMessage>());
          expect(reason.id, 'nativeReason$suffix');
          expect(reason.resolve(en), english);
          expect(reason.resolve(zh), chinese);
          expect(english, isNot(en.operationNotCompletedRetry));
          expect(chinese, isNot(zh.operationNotCompletedRetry));
          expect(english, isNot(chinese));
          expect(
            restored.resolve(en),
            'Unsupported configuration field $field: $english',
          );
          expect(restored.resolve(zh), '无法使用配置项 $field：$chinese');
          expect(restored.toMap(), encoded);
        }
      },
    );
  }

  test(
    'native rejection invalid parameters never display raw native values',
    () {
      const private = 'private-token-or-file-path';
      for (final args in <Map<String, Object?>>[
        {},
        {'field': 'tun.mtu'},
        {'reason': messages.nativeReasonInvalidMtu},
        {'field': null, 'reason': messages.nativeReasonInvalidMtu},
        {'field': 1280, 'reason': messages.nativeReasonInvalidMtu},
        {
          'field': messages.nativeReasonInvalidMtu,
          'reason': messages.nativeReasonInvalidMtu,
        },
        {'field': 'tun.mtu', 'reason': private},
        {'field': 'tun.mtu', 'reason': true},
        {'field': 'tun.mtu', 'reason': null},
        {
          'field': 'tun.mtu',
          'reason': [private],
        },
        {
          'field': 'tun.mtu',
          'reason': {'id': private, 'args': <String, Object?>{}},
        },
      ]) {
        final malformed = AppMessage.withArgs(
          'nativeConfigurationUnsupported',
          args,
        );
        for (final strings in [en, zh]) {
          expect(
            malformed.resolve(strings),
            strings.operationNotCompletedRetry,
          );
          expect(malformed.resolve(strings), isNot(contains(private)));
        }
      }
      final unknown = messages.nativeConfigurationUnsupported(
        'tun.mtu',
        AppMessage.withArgs(private, {'value': private}),
      );
      final invalidNested = {
        'id': 'nativeConfigurationUnsupported',
        'args': {
          'field': 'tun.mtu',
          'reason': {'id': 'nativeReasonInvalidMtu', 'args': private},
        },
      };
      expect(() => AppMessage.fromMap(invalidNested), throwsFormatException);
      for (final strings in [en, zh]) {
        expect(
          unknown.resolve(strings),
          strings.nativeConfigurationUnsupported(
            'tun.mtu',
            strings.operationNotCompletedRetry,
          ),
        );
        expect(unknown.resolve(strings), isNot(contains(private)));
        expect(
          AppMessage.withArgs(private, {
            'reason': messages.nativeReasonInvalidMtu,
          }).resolve(strings),
          strings.operationNotCompletedRetry,
        );
        expect(
          messageFromPlatform(
            PlatformException(
              code: 'native',
              message: private,
              details: invalidNested,
            ),
            fallback: messages.operationFailed,
          ).resolve(strings),
          strings.operationFailed,
        );
        final extra = messages.nativeConfigurationUnsupported(
          'tun.mtu',
          AppMessage.withArgs('nativeReasonInvalidMtu', {'value': private}),
        );
        expect(extra.resolve(strings), isNot(contains(private)));
        expect(
          extra.resolve(strings),
          strings.nativeConfigurationUnsupported(
            'tun.mtu',
            strings.nativeReasonInvalidMtu,
          ),
        );
      }
    },
  );

  testWidgets(
    'native rejection feedback re-localizes without translating stored args',
    (tester) async {
      final controller = _FeedbackController();
      addTearDown(controller.dispose);
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      final message = messages.nativeConfigurationUnsupported(
        'dns.nameserver',
        messages.nativeReasonPrivateDnsUnavailable,
      );
      final original = message.toMap();
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: locale,
          builder: (_, value, _) => MaterialApp(
            locale: value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: OperationFeedback(
              controller: controller,
              child: const Scaffold(body: Text('Reader anchor')),
            ),
          ),
        ),
      );
      controller.lastCommand = {'action': 'start'};
      controller.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'native-rejection',
        resultMessage: message,
      );
      controller.changed();
      await tester.pumpAndSettle();
      final dialog = tester.element(find.byType(AlertDialog));
      for (final strings in [en, zh, en]) {
        locale.value = Locale(strings.localeName);
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(AlertDialog)), same(dialog));
        expect(find.text(message.resolve(strings)), findsOneWidget);
        expect(controller.state.resultMessageDescription, same(message));
        expect(message.toMap(), original);
        expect(controller.commands, isEmpty);
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'default trusted roots failure stays localized without native details',
    () {
      const private = 'private-certificate-or-native-diagnostic';
      final message = messageFromPlatform(
        PlatformException(
          code: 'trustedRoots',
          message: private,
          details: private,
        ),
        fallback: messages.trustedRootsUnavailable,
      );
      expect(message.toMap(), {
        'id': 'trustedRootsUnavailable',
        'args': <String, Object?>{},
      });
      final restored = AppMessage.fromMap(
        jsonDecode(jsonEncode(message.toMap())),
      );
      expect(
        restored.resolve(en),
        'Could not read or parse the default trusted root certificates. Try again.',
      );
      expect(restored.resolve(zh), '无法读取或解析默认受信根证书，请重试。');
      for (final strings in [en, zh]) {
        expect(restored.resolve(strings), isNot(contains(private)));
      }
    },
  );

  test(
    'mode labels distinguish configuration mode from the saved fallback',
    () {
      expect(en.modeFollowConfigIdle, 'Configuration mode · Not running');
      expect(zh.modeFollowConfigIdle, '随配置 · 未运行');
      expect(en.modeDiffers, 'Running mode and saved fallback');
      expect(zh.modeDiffers, '实际模式与保存回退');
      expect(
        en.modeSaved('Global'),
        contains('only if the configuration does not specify a mode'),
      );
      expect(zh.modeSaved('全局'), contains('仅在配置未指定 mode 时使用'));
      expect(
        en.modeActualDiffers('Direct'),
        contains('A configuration-defined mode can differ'),
      );
      expect(zh.modeActualDiffers('直连'), contains('配置指定的模式可以与已保存的回退模式不同'));
      expect(en.modeHint, contains('switches the running tunnel immediately'));
      expect(zh.modeHint, contains('立即切换实际模式'));
      for (final message in [
        messages.modeSavedNextStart,
        messages.modeNotConfirmed,
      ]) {
        final restored = AppMessage.fromMap(message.toMap());
        expect(
          restored.resolve(en),
          contains('only if the configuration does not specify a mode'),
        );
        expect(restored.resolve(zh), contains('仅在配置未指定 mode 时使用'));
      }
    },
  );

  test(
    'Loon controls and conversion errors have owned user-facing wording',
    () {
      expect(en.loonProxyName, 'Proxy name');
      expect(zh.loonProxyName, '代理名称');
      expect(en.loonAddNoResolve, 'Add no-resolve to Loon IP rules');
      expect(zh.loonAddNoResolve, 'Loon IP 规则添加 no-resolve');
      expect(en.loonProxyNameHint, contains('Built-in targets stay unchanged'));
      expect(zh.loonProxyNameHint, contains('内置目标不替换'));
      expect(
        messages.overrideContentUnsupported.resolve(en),
        'The remote plugin is not a valid YAML configuration fragment or a recognizable Loon plugin.',
      );
      expect(
        messages.overrideContentUnsupported.resolve(zh),
        '远程插件不是有效的 YAML 配置片段或可识别的 Loon 插件。',
      );
      expect(
        messages.loonProxyNameInvalid.resolve(en),
        'The proxy name must not contain commas, line breaks or control characters.',
      );
      expect(messages.loonProxyNameInvalid.resolve(zh), '代理名称不能包含逗号、换行或控制字符。');
    },
  );

  test(
    'Loon result descriptions preserve nested outcomes and integer counts',
    () {
      const codec = StandardMessageCodec();
      for (final result in [
        messages.overrideSavedApplyLater,
        messages.overridesAppliedReconnected,
        messages.overrideUnchanged,
      ]) {
        for (final count in [0, 1, 27]) {
          final descriptions = [
            messages.loonConvertedResult(
              result: result,
              rules: count,
              comments: count + 2,
            ),
            messages.loonNoRulesResult(result: result, comments: count),
          ];
          for (final description in descriptions) {
            final encoded = description.toMap();
            expect((encoded['args']! as Map)['result'], result.toMap());
            for (final restored in [
              AppMessage.fromMap(jsonDecode(jsonEncode(encoded))),
              AppMessage.fromMap(
                codec.decodeMessage(codec.encodeMessage(encoded)),
              ),
            ]) {
              expect(restored, description);
              expect(restored.args['result'], isA<AppMessage>());
              expect(restored.args['comments'], isA<int>());
              for (final strings in [en, zh, en]) {
                final expected = restored.id == 'loonConvertedResult'
                    ? strings.loonConvertedResult(
                        result.resolve(strings),
                        count,
                        count + 2,
                      )
                    : strings.loonNoRulesResult(result.resolve(strings), count);
                expect(restored.resolve(strings), expected);
                expect(
                  restored.resolve(strings),
                  startsWith('${result.resolve(strings)}\n\n'),
                );
                expect(restored.toMap(), encoded);
              }
            }
          }
        }
      }
      expect(
        messages
            .loonConvertedResult(
              result: messages.overrideSavedApplyLater,
              rules: 3,
              comments: 7,
            )
            .resolve(en),
        'Plugin saved.\n\nExtracted 3 compatible rules; retained 7 source lines as comments.',
      );
      expect(
        messages
            .loonNoRulesResult(result: messages.overrideUnchanged, comments: 12)
            .resolve(zh),
        '插件内容未变化。\n\n未提取到兼容规则；插件不改变现有规则，12 行保留为注释。',
      );
    },
  );

  test('invalid Loon result parameters use safe localized feedback', () {
    const private = 'private-source-or-proxy-name';
    for (final invalid in <Object?>[
      null,
      true,
      '3',
      3.5,
      -1,
      [private],
    ]) {
      final malformed = [
        AppMessage.withArgs('loonConvertedResult', {
          'result': messages.overrideUnchanged,
          'rules': invalid,
          'comments': 0,
        }),
        AppMessage.withArgs('loonConvertedResult', {
          'result': messages.overrideUnchanged,
          'rules': 0,
          'comments': invalid,
        }),
        AppMessage.withArgs('loonNoRulesResult', {
          'result': messages.overrideUnchanged,
          'comments': invalid,
        }),
      ];
      for (final description in malformed) {
        for (final strings in [en, zh]) {
          expect(
            description.resolve(strings),
            strings.operationNotCompletedRetry,
          );
          expect(description.resolve(strings), isNot(contains(private)));
        }
      }
    }
    for (final id in ['loonConvertedResult', 'loonNoRulesResult']) {
      for (final args in <Map<String, Object?>>[
        {},
        {'result': messages.overrideUnchanged},
        {'result': private, 'rules': 1, 'comments': 2},
        {
          'result': {'id': private, 'args': <String, Object?>{}},
          'rules': 1,
          'comments': 2,
        },
      ]) {
        final malformed = AppMessage.withArgs(id, args);
        for (final strings in [en, zh]) {
          expect(
            malformed.resolve(strings),
            strings.operationNotCompletedRetry,
          );
        }
      }
    }
    final unknown = messages.loonConvertedResult(
      result: AppMessage.withArgs(private, {'value': private}),
      rules: 3,
      comments: 7,
    );
    for (final strings in [en, zh]) {
      expect(
        unknown.resolve(strings),
        strings.loonConvertedResult(strings.operationNotCompletedRetry, 3, 7),
      );
      expect(unknown.resolve(strings), isNot(contains(private)));
    }
    expect(
      () => AppMessage.fromMap({
        'id': 'loonNoRulesResult',
        'args': {
          'result': {'id': 'overrideUnchanged', 'args': private},
          'comments': 0,
        },
      }),
      throwsFormatException,
    );
  });

  test(
    'local customization labels do not imply enabling a disabled plugin',
    () {
      expect(en.localCustomTitle, 'Local customizations');
      expect(zh.localCustomTitle, '本地自定义');
      expect(
        en.localCustomDisabled,
        'This plugin is disabled. Saving does not enable it.',
      );
      expect(zh.localCustomDisabled, '此插件已停用，保存不会启用它。');
    },
  );

  for (final (id, message, english, chinese) in [
    (
      'localYamlInvalid',
      messages.localYamlInvalid,
      en.localYamlInvalid,
      zh.localYamlInvalid,
    ),
    (
      'localYamlInvalidStructure',
      messages.localYamlInvalidStructure,
      en.localYamlInvalidStructure,
      zh.localYamlInvalidStructure,
    ),
    (
      'localYamlDuplicateName',
      messages.localYamlDuplicateName,
      en.localYamlDuplicateName,
      zh.localYamlDuplicateName,
    ),
    (
      'localYamlAliasTarget',
      messages.localYamlAliasTarget,
      en.localYamlAliasTarget,
      zh.localYamlAliasTarget,
    ),
    (
      'localYamlInheritedTarget',
      messages.localYamlInheritedTarget,
      en.localYamlInheritedTarget,
      zh.localYamlInheritedTarget,
    ),
    (
      'localYamlUnsafeStructure',
      messages.localYamlUnsafeStructure,
      en.localYamlUnsafeStructure,
      zh.localYamlUnsafeStructure,
    ),
    (
      'localYamlUnsupportedEdit',
      messages.localYamlUnsupportedEdit,
      en.localYamlUnsupportedEdit,
      zh.localYamlUnsupportedEdit,
    ),
  ]) {
    test('$id keeps a localized description without source paths or names', () {
      final encoded = {'id': id, 'args': <String, Object?>{}};
      expect(message.toMap(), encoded);
      const codec = StandardMessageCodec();
      for (final restored in [
        AppMessage.fromMap(jsonDecode(jsonEncode(encoded))),
        AppMessage.fromMap(codec.decodeMessage(codec.encodeMessage(encoded))),
      ]) {
        expect(restored, message);
        expect(restored.resolve(en), english);
        expect(restored.resolve(zh), chinese);
        expect(english, isNot(en.operationNotCompletedRetry));
        expect(chinese, isNot(zh.operationNotCompletedRetry));
        expect(restored.toMap(), encoded);
      }
      const private = 'private-source-path-or-definition-name';
      final untrusted = AppMessage.withArgs(id, {
        'raw': private,
        'path': private,
        'name': private,
      });
      expect(untrusted.resolve(en), english);
      expect(untrusted.resolve(zh), chinese);
      expect(untrusted.resolve(en), isNot(contains(private)));
      expect(untrusted.resolve(zh), isNot(contains(private)));
    });
  }

  test(
    'proxy form labels localize basics and preserve advanced YAML identifiers',
    () {
      expect(en.proxyName, 'Proxy name');
      expect(zh.proxyName, '节点名称');
      expect(en.proxyServer, 'Server');
      expect(zh.proxyServer, '服务器');
      expect(en.proxyUsername, 'Username');
      expect(zh.proxyUsername, '用户名');
      expect(en.proxyShowSecret, 'Show sensitive value');
      expect(zh.proxyShowSecret, '显示敏感内容');
      expect(en.proxyHideSecret, 'Hide sensitive value');
      expect(zh.proxyHideSecret, '隐藏敏感内容');
      expect(en.proxyPassword, 'Password');
      expect(zh.proxyPassword, '密码');
      expect(en.proxyUnset, 'Not set');
      expect(zh.proxyUnset, '未设置');
      expect(en.proxyFalse, 'Off');
      expect(zh.proxyFalse, '关闭');
      for (final strings in [en, zh]) {
        expect([
          strings.proxyFormTitle,
          strings.proxyFormType,
          strings.proxyFormBasic,
          strings.proxyFormProtocol,
          strings.proxyFormAdvanced,
          strings.proxyCategoryStandard,
          strings.proxyCategoryCommunity,
          strings.proxyCategoryVpn,
          strings.proxyCategoryBuiltin,
          strings.proxyBuiltinDescription,
          strings.proxyOptional,
          strings.proxyUnset,
          strings.proxyTrue,
          strings.proxyFalse,
          strings.proxyRequired,
          strings.proxyInvalidInteger,
          strings.proxyInvalidDecimal,
          strings.proxyInvalidPort,
          strings.proxyInvalidByte,
          strings.proxyDuplicateKey,
          strings.proxyMapKey,
          strings.proxyMapValue,
          strings.proxyPlatformIgnored,
          strings.proxySaveFailed,
          strings.proxyServer,
          strings.proxyUsername,
          strings.proxyPassword,
          strings.proxyName,
          strings.proxyUnitBytes,
          strings.proxyUnitSeconds,
          strings.proxyUnitMilliseconds,
          strings.proxyUnitNanoseconds,
          strings.proxyUnitMbps,
          strings.proxyUnitPackets,
        ], everyElement(isNotEmpty));
        expect(strings.proxyUnset, isNot(strings.proxyFalse));
      }
      for (final field in [
        'client-fingerprint',
        'reality-opts',
        'ws-opts.headers',
        'udp-over-tcp',
      ]) {
        expect(en.proxyAddItem(field), 'Add $field');
        expect(zh.proxyAddItem(field), '添加 $field');
        for (final index in [1, 27]) {
          expect(en.proxyRemoveItem(field, index), 'Remove $field item $index');
          expect(zh.proxyRemoveItem(field, index), '移除 $field 第 $index 项');
        }
      }
    },
  );

  test('unavailable storage keeps a safe message without blocking Stop', () {
    final encoded = messages.storageUnavailable.toMap();
    expect(encoded, {'id': 'storageUnavailable', 'args': <String, Object?>{}});
    final restored = AppMessage.fromMap(jsonDecode(jsonEncode(encoded)));
    expect(restored.resolve(zh), '配置、插件和设置暂时不可用，数据恢复确认后才能继续。停止连接不受影响。');
    expect(
      restored.resolve(en),
      'Configurations, plugins and settings are temporarily unavailable. Wait for data recovery to be confirmed before continuing. Stopping the connection is still available.',
    );
  });

  test('storage sync warning preserves the actual nested saved outcome', () {
    const codec = StandardMessageCodec();
    expect(messages.storageSyncUnconfirmed.toMap(), {
      'id': 'storageSyncUnconfirmed',
      'args': <String, Object?>{},
    });
    for (final result in [
      messages.configSaved,
      messages.overrideSavedApplyLater,
      messages.modeConfirmed,
    ]) {
      final warning = messages.storageSyncWarning(result);
      final encoded = {
        'id': 'storageSyncWarning',
        'args': {'result': result.toMap()},
      };
      expect(warning.toMap(), encoded);
      for (final restored in [
        AppMessage.fromMap(jsonDecode(jsonEncode(encoded))),
        AppMessage.fromMap(codec.decodeMessage(codec.encodeMessage(encoded))),
      ]) {
        expect(restored, warning);
        expect(restored.args['result'], result);
        for (final strings in [en, zh, en]) {
          expect(
            restored.resolve(strings),
            '${result.resolve(strings)}\n\n${messages.storageSyncUnconfirmed.resolve(strings)}',
          );
          expect(restored.toMap(), encoded);
        }
      }
    }
    expect(
      messages.storageSyncUnconfirmed.resolve(zh),
      '内容已保存，但未能确认存储同步完成；突然断电可能丢失本次修改。',
    );
    expect(
      messages.storageSyncUnconfirmed.resolve(en),
      'The content was saved, but storage synchronization could not be confirmed. This change may be lost if power is suddenly interrupted.',
    );
  });

  test('storage sync warning never treats raw native content as a result', () {
    const private = 'private-native-file-path-or-error';
    for (final result in <Object?>[
      null,
      private,
      false,
      1,
      {'id': private, 'args': <String, Object?>{}},
    ]) {
      final malformed = AppMessage.withArgs('storageSyncWarning', {
        'result': result,
      });
      for (final strings in [en, zh]) {
        expect(malformed.resolve(strings), strings.operationNotCompletedRetry);
      }
    }
    for (final strings in [en, zh]) {
      final unknown = messages.storageSyncWarning(
        AppMessage.withArgs(private, {'raw': private}),
      );
      expect(
        unknown.resolve(strings),
        '${strings.operationNotCompletedRetry}\n\n${strings.storageSyncUnconfirmed}',
      );
      expect(unknown.resolve(strings), isNot(contains(private)));
    }
  });

  test(
    'group provider and rule form labels keep raw YAML identifiers readable',
    () {
      expect(en.strategyGroupFormTitle, 'Add strategy group');
      expect(zh.strategyGroupFormTitle, '新增策略组');
      expect(en.providerProxyFormTitle, 'Add proxy provider');
      expect(zh.providerProxyFormTitle, '新增节点来源');
      expect(en.providerRuleFormTitle, 'Add rule provider');
      expect(zh.providerRuleFormTitle, '新增规则集来源');
      expect(en.ruleFormTitle, 'Add rule');
      expect(zh.ruleFormTitle, '新增规则');
      expect(en.definitionFormMoveUp, 'Move up');
      expect(zh.definitionFormMoveUp, '上移');
      expect(en.definitionFormMoveDown, 'Move down');
      expect(zh.definitionFormMoveDown, '下移');
      expect(en.providerFormFallbackPayload, 'Fallback inline payload');
      expect(zh.providerFormFallbackPayload, '后备内联内容');
      expect(en.providerFormEditProxy, 'Edit inline proxy');
      expect(zh.providerFormEditProxy, '修改内联节点');
      for (final strings in [en, zh]) {
        expect([
          strings.strategyGroupFormTitle,
          strings.strategyGroupFormType,
          strings.strategyGroupFormMembers,
          strings.strategyGroupFormProviders,
          strings.providerProxyFormTitle,
          strings.providerRuleFormTitle,
          strings.providerFormType,
          strings.providerFormHeaders,
          strings.providerFormDownloadProxy,
          strings.providerFormHealthCheck,
          strings.providerFormOverride,
          strings.providerFormPayload,
          strings.providerFormAddProxy,
          strings.providerFormEditProxy,
          strings.providerFormProxyNames,
          strings.providerFormExpressions,
          strings.providerFormPattern,
          strings.providerFormReplacement,
          strings.providerFormPathHint,
          strings.providerFormInvalidPath,
          strings.providerFormInvalidUrl,
          strings.providerFormMRSClassical,
          strings.providerFormAndroidIgnored,
          strings.ruleFormTitle,
          strings.ruleFormType,
          strings.ruleFormMatch,
          strings.ruleFormTarget,
          strings.ruleFormProvider,
          strings.ruleFormSubRule,
          strings.ruleFormCondition,
          strings.ruleFormUnrepresentable,
          strings.ruleFormTargetHint,
          strings.ruleFormSrcHint,
          strings.ruleFormIdentityNotice,
          strings.definitionFormSuggestions,
        ], everyElement(isNotEmpty));
        expect(strings.providerFormMRSClassical, contains('MRS'));
        expect(strings.providerFormMRSClassical, contains('classical'));
        expect(strings.providerFormAndroidIgnored, contains('interface-name'));
        expect(strings.providerFormAndroidIgnored, contains('routing-mark'));
        expect(strings.providerFormAndroidIgnored, contains('TFO'));
        expect(strings.ruleFormSrcHint, contains('src'));
        expect(strings.ruleFormSrcHint, contains('no-resolve'));
        expect(strings.ruleFormIdentityNotice, contains('UID'));
      }
    },
  );

  test(
    'replaced storage context preserves an owned message without native values',
    () {
      final encoded = messages.storageContextChanged.toMap();
      expect(encoded, {
        'id': 'storageContextChanged',
        'args': <String, Object?>{},
      });
      const codec = StandardMessageCodec();
      for (final restored in [
        AppMessage.fromMap(jsonDecode(jsonEncode(encoded))),
        AppMessage.fromMap(codec.decodeMessage(codec.encodeMessage(encoded))),
      ]) {
        expect(restored.resolve(zh), '数据已恢复或替换，请重新打开此页面。未提交的输入仍可复制保留。');
        expect(
          restored.resolve(en),
          'The data was restored or replaced. Reopen this page. Unsubmitted input can still be copied and kept.',
        );
        expect(restored.toMap(), encoded);
      }
    },
  );

  test(
    'provenance contributor labels preserve integer count and plural meaning',
    () {
      expect(en.provenanceHeading, 'Contributing plugins');
      expect(zh.provenanceHeading, '参与插件');
      expect(en.provenanceProviderHeading, 'Definition contributors');
      expect(zh.provenanceProviderHeading, '定义参与插件');
      expect(en.provenancePlugins(0), '0 contributing plugins');
      expect(en.provenancePlugins(1), '1 contributing plugin');
      expect(en.provenancePlugins(2), '2 contributing plugins');
      expect(zh.provenancePlugins(0), '0 个插件参与');
      expect(zh.provenancePlugins(1), '1 个插件参与');
      expect(zh.provenancePlugins(2), '2 个插件参与');
    },
  );

  test('saved results do not require a separate plugin apply action', () {
    for (final (message, english, chinese) in [
      (messages.overrideSettingsSaved, 'Plugin settings saved.', '插件设置已保存。'),
      (messages.overrideOrderSaved, 'Plugin order saved.', '插件顺序已保存。'),
      (messages.overrideDeleted, 'Plugin deleted.', '插件已删除。'),
      (
        messages.configUpdatedPending,
        'Configuration updated and saved.',
        '配置已更新并保存。',
      ),
      (
        messages.overrideUpdatedPending,
        'Plugin updated and saved.',
        '插件已更新并保存。',
      ),
    ]) {
      final restored = AppMessage.fromMap(message.toMap());
      expect(restored, message);
      expect(restored.resolve(en), english);
      expect(restored.resolve(zh), chinese);
    }
    expect(
      en.overrideDeleteMessage,
      contains('does not start a stopped tunnel'),
    );
    expect(zh.overrideDeleteMessage, contains('未连接时不会启动接管'));
  });

  test('connection summary keeps the same compact localized label', () {
    expect(en.trafficConnections, 'Connections');
    expect(zh.trafficConnections, '连接');
  });

  for (final locales in const [
    [Locale('fr'), Locale('zh')],
    [Locale('fr'), Locale('en'), Locale('zh')],
    [Locale('zh'), Locale('en')],
    [Locale('fr'), Locale('de')],
  ]) {
    testWidgets('system message convenience matches SDK list $locales', (
      tester,
    ) async {
      tester.binding.platformDispatcher.localesTestValue = locales;
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      setMessageLanguage(AppLanguage.system);
      String? displayed;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              displayed = AppLocalizations.of(context).operationFailed;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Exercise locale resolution with the full MaterialApp locale list and binding
      // dispatcher wrapper.
      expect(messageLocalizationsFor(locales).operationFailed, displayed);
      expect(
        messageLocalizationsFor(locales).localeName,
        basicLocaleListResolution(
          locales,
          AppLocalizations.supportedLocales,
        ).languageCode,
      );
      setMessageLanguage(AppLanguage.en);
      expect(messages.operationFailed.text, en.operationFailed);
      setMessageLanguage(AppLanguage.zh);
      expect(messages.operationFailed.text, zh.operationFailed);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'retained confirmation resolves all owned labels scale=$scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final locale = ValueNotifier(const Locale('en'));
        addTearDown(locale.dispose);
        const subject = '用户 source https://example.test/原文';
        await tester.pumpWidget(
          ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, value, _) => MaterialApp(
              locale: value,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('Open'),
                    onPressed: () => confirmAction(
                      context,
                      title: (strings) => strings.discardEditsTitle,
                      message: (strings) => strings.discardEditsMessage,
                      confirmLabel: (strings) => strings.discard,
                      cancelLabel: (strings) => strings.continueEditing,
                      subject: subject,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final element = tester.element(find.byType(AlertDialog));
        for (final strings in [en, zh, en]) {
          locale.value = Locale(strings.localeName);
          await tester.pumpAndSettle();
          expect(tester.element(find.byType(AlertDialog)), same(element));
          expect(find.text(strings.discardEditsTitle), findsOneWidget);
          expect(find.text(strings.discardEditsMessage), findsOneWidget);
          expect(find.text(strings.discard), findsOneWidget);
          expect(find.text(strings.continueEditing), findsOneWidget);
          expect(find.text(subject), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'retained custom field labels translate without replacing draft',
    (tester) async {
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<Locale>(
          valueListenable: locale,
          builder: (_, value, _) => MaterialApp(
            locale: value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () => showDialog<String>(
                    context: context,
                    builder: (_) => ConfigFieldDialog(
                      initial: '用户 原始名称',
                      title: (strings) => strings.newLocalConfig,
                      confirmLabel: (strings) => strings.continueLabel,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(ConfigFieldDialog));
      final field = find.byType(TextField);
      await tester.enterText(field, '保留 draft 🌐');
      for (final strings in [zh, en]) {
        locale.value = Locale(strings.localeName);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ConfigFieldDialog)), same(state));
        expect(find.text(strings.newLocalConfig), findsOneWidget);
        expect(find.text(strings.continueLabel), findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, '保留 draft 🌐');
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('retained editor custom save action follows current locale', (
    tester,
  ) async {
    final app = _FeedbackController();
    addTearDown(app.dispose);
    final locale = ValueNotifier(const Locale('en'));
    addTearDown(locale.dispose);
    final page = ConfigTextPage(
      app: app,
      initialName: '用户名称',
      initialText: 'rules: []',
      saveLabel: (strings) => strings.save,
    );
    await tester.pumpWidget(
      ValueListenableBuilder<Locale>(
        valueListenable: locale,
        builder: (_, value, _) => MaterialApp(
          locale: value,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(ConfigTextPage));
    for (final strings in [zh, en]) {
      locale.value = Locale(strings.localeName);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ConfigTextPage)), same(state));
      expect(find.text(strings.save), findsWidgets);
      expect(find.text('用户名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in const [
    'import',
    'updateConfig',
    'importOverride',
    'updateOverride',
    'changeOverrideSource',
  ]) {
    testWidgets('$action failure is shown once without resubmission', (
      tester,
    ) async {
      final controller = _FeedbackController();
      addTearDown(controller.dispose);
      await _showFeedback(tester, controller);
      controller.lastCommand = {
        'action': action,
        'id': 'target',
        'source': 'http://fixture.test/config',
      };
      controller.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'failed-$action',
        resultMessage: messages.downloadFailed,
      );
      controller.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(en.downloadFailed), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(controller.commands, isEmpty);
      await tester.tap(find.text(en.close));
      await tester.pumpAndSettle();
      controller.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('submission failure does not reuse an earlier result', (
    tester,
  ) async {
    final controller = _FeedbackController()
      ..state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'earlier-failure',
        resultMessage: messages.downloadFailed,
      );
    addTearDown(controller.dispose);
    await _showFeedback(tester, controller);
    controller.lastCommand = {'action': 'updateOverride', 'id': 'new-target'};
    controller.commandErrorMessage = messages.androidErrorBusy;
    controller.changed();
    await tester.pumpAndSettle();
    expect(find.text(en.androidErrorBusy), findsOneWidget);
    expect(find.text(en.downloadFailed), findsNothing);
    expect(controller.commands, isEmpty);
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();
    controller.changed();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final action in const [
    'changeOverride',
    'reorderOverrides',
    'deleteOverride',
  ]) {
    for (final success in [false, true]) {
      testWidgets(
        '$action ${success ? 'success is quiet' : 'failure stays visible'}',
        (tester) async {
          final controller = _FeedbackController();
          addTearDown(controller.dispose);
          await _showFeedback(tester, controller);
          controller.lastCommand = {'action': action};
          controller.state = AppSnapshot(
            phase: 'STOPPED',
            resultId: 'result-$action',
            resultSuccess: success,
            resultMessage: success
                ? messages.settingsSaved
                : messages.operationFailed,
          );
          controller.changed();
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          if (success) {
            expect(find.byType(AlertDialog), findsNothing);
          } else {
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(
              find.byWidgetPredicate(
                (widget) =>
                    widget is SelectableText &&
                    widget.data == en.operationFailed,
              ),
              findsOneWidget,
            );
            await tester.tap(find.text(en.close));
            await tester.pumpAndSettle();
          }
          expect(controller.commands, isEmpty);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  test('resource outcomes keep IDs until their current-locale projection', () {
    for (final (message, id) in [
      (messages.resourceUpdateSuccess, 'resourceUpdateSuccess'),
      (messages.resourceUpdateFailed, 'resourceUpdateFailed'),
      (messages.resourceUpdateStopped, 'resourceUpdateStopped'),
    ]) {
      expect(message.toMap(), {'id': id, 'args': <String, Object?>{}});
      expect(AppMessage.fromMap(message.toMap()), message);
    }
    for (final strings in [en, zh]) {
      expect(
        messages.resourceUpdateSuccess.resolve(strings),
        strings.resourceUpdateSuccess,
      );
      expect(
        messages.resourceUpdateFailed.resolve(strings),
        strings.resourceUpdateFailed,
      );
      expect(
        messages.resourceUpdateStopped.resolve(strings),
        strings.resourceUpdateStopped,
      );
    }
  });

  test('descriptions round-trip through both channel and storage codecs', () {
    final message = AppMessage.withArgs('operationAndCleanupFailed', {
      'operation': messages.androidErrorTakeoverStartFailed,
      'cleanup': messages.androidErrorReleaseUnconfirmed,
    });
    final encoded = message.toMap();
    const codec = StandardMessageCodec();
    expect(
      AppMessage.fromMap(codec.decodeMessage(codec.encodeMessage(encoded))),
      message,
    );
    expect(AppMessage.fromMap(jsonDecode(jsonEncode(encoded))), message);
    expect(AppMessage.fromNullable(null), isNull);
    expect(message.toString(), 'operationAndCleanupFailed');
    expect(
      message.resolve(en),
      en.operationAndCleanupFailed(
        en.androidErrorTakeoverStartFailed,
        en.androidErrorReleaseUnconfirmed,
      ),
    );
    expect(
      message.resolve(zh),
      zh.operationAndCleanupFailed(
        zh.androidErrorTakeoverStartFailed,
        zh.androidErrorReleaseUnconfirmed,
      ),
    );
    expect(
      encodeAppMessages({
        'success': false,
        'message': message,
        'results': [messages.settingsSaved, null],
      }),
      {
        'success': false,
        'message': encoded,
        'results': [messages.settingsSaved.toMap(), null],
      },
    );
  });

  test(
    'message arguments are copied and decoded with their primitive types',
    () {
      final args = <String, Object?>{
        'name': 'original',
        'count': 2,
        'enabled': true,
      };
      final message = AppMessage.withArgs('sourceUsedBy', args);
      args['name'] = 'changed';
      expect(message.args['name'], 'original');
      expect(() => message.args['name'] = 'changed', throwsUnsupportedError);
      final restored = AppMessage.fromMap(message.toMap());
      expect(restored, message);
      expect(restored.hashCode, message.hashCode);
      expect(restored.args['count'], isA<int>());
      expect(restored.args['enabled'], isA<bool>());
      expect(restored.resolve(en), en.sourceUsedBy('original'));
    },
  );

  test(
    'invalid messages are rejected rather than treated as old display text',
    () {
      for (final value in <Object?>[
        null,
        'Settings saved.',
        <String, Object?>{},
        {'id': '', 'args': <String, Object?>{}},
        {'id': 1, 'args': <String, Object?>{}},
        {'id': 'settingsSaved'},
        {'id': 'settingsSaved', 'args': null},
        {
          'id': 'settingsSaved',
          'args': <int, String>{1: 'invalid'},
        },
        {
          'id': 'settingsSaved',
          'args': {'value': null},
        },
        {
          'id': 'settingsSaved',
          'args': {'value': 1.5},
        },
        {
          'id': 'settingsSaved',
          'args': {'value': <String>[]},
        },
        {
          'id': 'settingsSaved',
          'args': {
            'value': {'raw': 'diagnostic'},
          },
        },
      ]) {
        expect(() => AppMessage.fromMap(value), throwsFormatException);
      }
      Object nested = messages.settingsSaved.toMap();
      for (var depth = 0; depth < 4; depth++) {
        nested = {
          'id': 'androidErrorStageFailed',
          'args': {'stage': nested},
        };
      }
      expect(AppMessage.fromMap(nested), isA<AppMessage>());
      nested = {
        'id': 'androidErrorStageFailed',
        'args': {'stage': nested},
      };
      expect(() => AppMessage.fromMap(nested), throwsFormatException);
    },
  );

  test(
    'unknown IDs and invalid named parameters use the owned localized fallback',
    () {
      for (final strings in [en, zh]) {
        for (final message in [
          const AppMessage('unrecognized-private-diagnostic'),
          const AppMessage('sourceUsedBy'),
          AppMessage.withArgs('downloadHttpStatus', {'status': true}),
        ]) {
          expect(message.resolve(strings), strings.operationNotCompletedRetry);
        }
        final platformError = PlatformException(
          code: 'native',
          message: 'private native diagnostic',
          details: 'old translated text',
        );
        expect(
          messageFromPlatform(
            platformError,
            fallback: messages.requestNotAccepted,
          ).resolve(strings),
          strings.requestNotAccepted,
        );
        expect(
          messageFromPlatform(
            PlatformException(
              code: 'native',
              details: messages.androidErrorBusy.toMap(),
            ),
            fallback: messages.requestNotAccepted,
          ),
          messages.androidErrorBusy,
        );
      }
    },
  );

  test('fresh isolates produce the same descriptions without UI localization initialization', () async {
    Future<Object?> produce() => Isolate.run(
      () => encodeAppMessages({
        'message': messages.settingsSaved,
        'error': messages.sourceUsedBy('named configuration'),
      }),
    );
    setMessageLanguage(AppLanguage.zh);
    final first = await produce();
    setMessageLanguage(AppLanguage.en);
    final recreated = await produce();
    expect(recreated, first);
    expect(first, {
      'message': messages.settingsSaved.toMap(),
      'error': messages.sourceUsedBy('named configuration').toMap(),
    });
    final message = AppMessage.fromMap((first as Map)['message']);
    expect(message.resolve(en), en.settingsSaved);
    expect(message.resolve(zh), zh.settingsSaved);
  });

  test('retained controller failures follow the UI language without being replaced', () {
    final controller = _FeedbackController();
    addTearDown(controller.dispose);
    controller.platformErrorMessage = messages.androidErrorBusy;
    controller.configErrorMessage = messages.configSaveFailed;
    controller.preferencesErrorMessage = messages.preferencesUnreadable;
    controller.commandErrorMessage = messages.requestNotAccepted;
    for (final (language, strings) in [
      (AppLanguage.en, en),
      (AppLanguage.zh, zh),
    ]) {
      setMessageLanguage(language);
      expect(controller.error, strings.androidErrorBusy);
      expect(controller.configError, strings.configSaveFailed);
      expect(controller.preferencesError, strings.preferencesUnreadable);
      expect(controller.commandError, strings.requestNotAccepted);
      expect(controller.errorMessage, messages.androidErrorBusy);
      expect(controller.commandErrorMessage, messages.requestNotAccepted);
      expect(controller.loading, isFalse);
      expect(controller.dispatching, isFalse);
    }
  });

  test('retained snapshots reproject stages and failures without changing result identity', () {
    final wire = {
      'phase': 'RUNNING',
      'generation': 3,
      'configId': 'local',
      'revision': 2,
      'runningSinceElapsedMs': 100,
      'elapsedRealtimeMs': 500,
      'operation': messages.stageStartingTunnel.toMap(),
      'error': messages.androidErrorReleaseUnconfirmed.toMap(),
      'resultMessage': messages.configSavedApplyReleasePending.toMap(),
      'resultId': 'save-owner',
      'resultSuccess': false,
      'configStatus': 'applyFailed',
      'targetId': 'local',
      'savedRevision': 2,
      'modeError': messages.androidErrorModeUnconfirmed.toMap(),
    };
    final snapshot = AppSnapshot.fromMap(wire);
    for (final (language, strings) in [
      (AppLanguage.en, en),
      (AppLanguage.zh, zh),
    ]) {
      setMessageLanguage(language);
      expect(snapshot.operation, strings.stageStartingTunnel);
      expect(snapshot.error, strings.androidErrorReleaseUnconfirmed);
      expect(snapshot.modeError, strings.androidErrorModeUnconfirmed);
      expect(snapshot.resultMessage, strings.configSavedApplyReleasePending);
      expect(
        snapshot.resultMessageDescription,
        messages.configSavedApplyReleasePending,
      );
      expect(snapshot.resultId, 'save-owner');
      expect(snapshot.configStatus, 'applyFailed');
      expect(snapshot.targetId, 'local');
      expect(snapshot.savedRevision, 2);
      expect(snapshot.resultSuccess, isFalse);
      expect(snapshot.uptimeMilliseconds, 400);
      expect(snapshot.busy, isTrue);
    }
    expect(
      wire['resultMessage'],
      messages.configSavedApplyReleasePending.toMap(),
    );
  });

  test('persisted configuration and plugin failures retain descriptions across language changes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pseudo-message-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final configs = ConfigStore(directory);
    final overrides = OverrideStore(directory);
    final error = messages.downloadHttpStatus('404');
    await configs.save(
      ConfigCollection(
        entries: [
          ConfigEntry(
            id: 'main',
            name: 'Main',
            source: 'https://fixture.test/main',
            revision: 1,
            body: 'rules: []',
            error: error,
          ),
        ],
        selectedId: 'main',
      ),
    );
    await overrides.save([
      OverrideEntry(
        id: 'part',
        name: 'Part',
        kind: ConfigKind.remote,
        source: 'https://fixture.test/part',
        revision: 1,
        body: '{}',
        error: error,
      ),
    ]);
    final config = (await configs.read()).selected!;
    final plugin = (await overrides.read()).single;
    final originalJson = jsonEncode([config.toJson(), plugin.toJson()]);
    expect(config.toJson()['error'], error.toMap());
    expect(plugin.toJson()['error'], error.toMap());
    for (final (language, strings) in [
      (AppLanguage.zh, zh),
      (AppLanguage.en, en),
    ]) {
      setMessageLanguage(language);
      expect(config.error, strings.downloadHttpStatus('404'));
      expect(plugin.error, strings.downloadHttpStatus('404'));
      expect(config.renamed('Renamed').errorMessage, error);
      expect(
        plugin.withUpdate(const UpdatePolicy(hours: 12)).errorMessage,
        error,
      );
      expect(jsonEncode([config.toJson(), plugin.toJson()]), originalJson);
    }
  });

  for (final scale in [1.0, 2.0]) {
    for (final success in [false, true]) {
      testWidgets(
        'open ${success ? 'snackbar' : 'failure dialog'} follows UI locale without replay at scale $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final controller = _FeedbackController();
          addTearDown(controller.dispose);
          final locale = ValueNotifier(const Locale('en'));
          addTearDown(locale.dispose);
          setMessageLanguage(AppLanguage.en);
          await tester.pumpWidget(
            ValueListenableBuilder<Locale>(
              valueListenable: locale,
              builder: (context, value, _) => MaterialApp(
                locale: value,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: OperationFeedback(
                  controller: controller,
                  child: const Scaffold(
                    body: Center(child: Text('Reader anchor')),
                  ),
                ),
              ),
            ),
          );
          final anchor = tester.getRect(find.text('Reader anchor'));
          final message = success
              ? messages.settingsSaved
              : messages.sourceUsedBy(
                  List.filled(18, 'long configuration name').join(' '),
                );
          controller.lastCommand = {'action': 'setPreference'};
          controller.state = AppSnapshot(
            phase: 'STOPPED',
            resultId: 'retained-result',
            resultSuccess: success,
            resultMessage: message,
          );
          controller.changed();
          await tester.pumpAndSettle();
          expect(find.text(message.resolve(en)), findsOneWidget);
          expect(tester.getRect(find.text('Reader anchor')), anchor);
          locale.value = const Locale('zh');
          setMessageLanguage(AppLanguage.zh);
          await tester.pumpAndSettle();
          expect(find.text(message.resolve(zh)), findsOneWidget);
          expect(find.text(message.resolve(en)), findsNothing);
          expect(tester.getRect(find.text('Reader anchor')), anchor);
          expect(controller.state.resultId, 'retained-result');
          expect(controller.state.resultMessageDescription, message);
          if (success) {
            expect(find.byType(SnackBar), findsOneWidget);
            ScaffoldMessenger.of(tester.element(find.text('Reader anchor')))
                .removeCurrentSnackBar();
          } else {
            expect(find.byType(AlertDialog), findsOneWidget);
            final close = find.widgetWithText(TextButton, zh.close);
            expect(tester.getRect(close).bottom, lessThanOrEqualTo(568));
            expect(find.text(zh.operationNotCompleted), findsOneWidget);
            await tester.tap(close);
          }
          await tester.pumpAndSettle();
          controller.changed();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(SnackBar), findsNothing);
          expect(tester.getRect(find.text('Reader anchor')), anchor);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
