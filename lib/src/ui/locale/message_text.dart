import 'dart:ui';

import 'package:flutter/widgets.dart' show basicLocaleListResolution;

import '../../l10n/app_localizations.dart';
import '../../model/app_message.dart';
import '../../model/app_preferences.dart';

AppLanguage _language = AppLanguage.system;
Locale? _locale;
AppLocalizations? _strings;

/// 显示消息时按当前界面语言翻译；后台生成和持久化的消息保留标识及参数。
AppLocalizations get localizedMessages =>
    messageLocalizationsFor(PlatformDispatcher.instance.locales);

AppLocalizations messageLocalizationsFor(List<Locale> systemLocales) {
  final locale = basicLocaleListResolution(switch (_language) {
    AppLanguage.zh => const [Locale('zh')],
    AppLanguage.en => const [Locale('en')],
    AppLanguage.system => systemLocales,
  }, AppLocalizations.supportedLocales);
  if (_locale != locale || _strings == null) {
    _locale = locale;
    _strings = lookupAppLocalizations(locale);
  }
  return _strings!;
}

void setMessageLanguage(AppLanguage language) => _language = language;

extension AppMessageText on AppMessage {
  String get text => resolveAppMessage(this, localizedMessages);
  String summary(AppLocalizations strings) =>
      resolveAppMessageSummary(this, strings);
  String resolve(AppLocalizations strings) => resolveAppMessage(this, strings);

  /// 从当前消息及嵌套消息中提取技术详情。
  String? technicalDetail(AppLocalizations strings) {
    final parts = <String>[];
    if (detail != null && detail!.isNotEmpty) parts.add(detail!);
    for (final entry in args.entries) {
      final value = entry.value;
      if (value is AppMessage) {
        final nested = value.technicalDetail(strings);
        if (nested != null) parts.add('${value.summary(strings)}\n$nested');
      } else if (id == 'operationAndCleanupFailed' &&
          const ['operation', 'cleanup'].contains(entry.key) &&
          value is String &&
          value.isNotEmpty) {
        parts.add(value);
      }
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }
}

String _textArg(
  AppMessage message,
  String name,
  AppLocalizations strings, {
  required bool includeDetail,
}) {
  final value = message.args[name];
  if (value is String) {
    if (!includeDetail && message.id == 'operationAndCleanupFailed') {
      return name == 'operation'
          ? strings.operationFailed
          : strings.androidErrorReleaseUnconfirmed;
    }
    return value;
  }
  if (value is AppMessage) {
    return includeDetail
        ? resolveAppMessage(value, strings)
        : resolveAppMessageSummary(value, strings);
  }
  throw const FormatException('Invalid message argument');
}

/// 按消息标识调用 Flutter 本地化 API，并附上原始技术详情。
String resolveAppMessage(AppMessage message, AppLocalizations strings) {
  final summary = _resolveAppMessageSummary(
    message,
    strings,
    includeDetail: true,
  );
  return message.detail == null ? summary : '$summary\n${message.detail}';
}

/// 返回当前消息的摘要，省略当前消息及嵌套消息中的技术详情。
String resolveAppMessageSummary(AppMessage message, AppLocalizations strings) =>
    _resolveAppMessageSummary(message, strings, includeDetail: false);

String _resolveAppMessageSummary(
  AppMessage message,
  AppLocalizations strings, {
  required bool includeDetail,
}) {
  try {
    return switch (message.id) {
      'privacyNoticeNotSaved' => strings.privacyNoticeNotSaved,
      'processMemoryUnavailable' => strings.processMemoryUnavailable,
      'coreCleanupCompleted' => strings.coreCleanupCompleted,
      'coreCleanupPartial' => strings.coreCleanupPartial,
      'coreCleanupNeedsSelection' => strings.coreCleanupNeedsSelection,
      'coreCleanupFailed' => strings.coreCleanupFailed,
      'coreCleanupInitializing' => strings.coreCleanupInitializing,
      'coreCleanupRequired' => strings.coreCleanupRequired,
      'coreCleanupScheduled' => strings.coreCleanupScheduled,
      'coreCleanupScheduledWithIssue' => strings.coreCleanupScheduledWithIssue(
        _textArg(message, 'result', strings, includeDetail: includeDetail),
        _textArg(message, 'issue', strings, includeDetail: includeDetail),
      ),
      'coreCleanupStopUnconfirmed' => strings.coreCleanupStopUnconfirmed,
      'coreReadFailed' => strings.coreReadFailed,
      'accessSavedNextConnection' => strings.accessSavedNextConnection,
      'accessSavedReconnectFailed' => strings.accessSavedReconnectFailed,
      'accessSavedReconnected' => strings.accessSavedReconnected,
      'alreadyRunning' => strings.alreadyRunning,
      'alreadyRunningNoRestore' => strings.alreadyRunningNoRestore,
      'alwaysOnOpenFailed' => strings.alwaysOnOpenFailed,
      'androidErrorActivityReturn' => strings.androidErrorActivityReturn,
      'androidErrorAppInfoNative' => strings.androidErrorAppInfoNative,
      'androidErrorAppInfoVersion' => strings.androidErrorAppInfoVersion,
      'androidErrorApplicationAllowlistMissing' =>
        strings.androidErrorApplicationAllowlistMissing,
      'androidErrorApplications' => strings.androidErrorApplications,
      'androidErrorBackgroundStart' => strings.androidErrorBackgroundStart,
      'androidErrorBatchExpired' => strings.androidErrorBatchExpired,
      'androidErrorBusy' => strings.androidErrorBusy,
      'androidErrorConnectionBusy' => strings.androidErrorConnectionBusy,
      'androidErrorConnectionId' => strings.androidErrorConnectionId,
      'androidErrorConnectionNotAccepted' =>
        strings.androidErrorConnectionNotAccepted,
      'androidErrorConnectionQuerySize' =>
        strings.androidErrorConnectionQuerySize,
      'androidErrorConnectionTimeout' => strings.androidErrorConnectionTimeout,
      'androidErrorCoreBusy' => strings.androidErrorCoreBusy,
      'androidErrorCoreContextRefresh' =>
        strings.androidErrorCoreContextRefresh,
      'androidErrorCoreContextReread' => strings.androidErrorCoreContextReread,
      'androidErrorCoreNotReady' => strings.androidErrorCoreNotReady,
      'androidErrorCoreReadFailed' => strings.androidErrorCoreReadFailed,
      'androidErrorCoreReadTimeout' => strings.androidErrorCoreReadTimeout,
      'androidErrorDelayRead' => strings.androidErrorDelayRead,
      'androidErrorDelayStart' => strings.androidErrorDelayStart,
      'androidErrorDisconnectUnconfirmed' =>
        strings.androidErrorDisconnectUnconfirmed,
      'androidErrorGroupUntestable' => strings.androidErrorGroupUntestable,
      'androidErrorInvalidResult' => strings.androidErrorInvalidResult,
      'androidErrorLogicExpired' => strings.androidErrorLogicExpired,
      'androidErrorLogsQuerySize' => strings.androidErrorLogsQuerySize,
      'androidErrorModeTimeout' => strings.androidErrorModeTimeout,
      'androidErrorModeUnconfirmed' => strings.androidErrorModeUnconfirmed,
      'androidErrorNativeConnectionUnavailable' =>
        strings.androidErrorNativeConnectionUnavailable,
      'androidErrorNativeCoreLoad' => strings.androidErrorNativeCoreLoad,
      'androidErrorNativeDelayUnavailable' =>
        strings.androidErrorNativeDelayUnavailable,
      'androidErrorNativeModeUnavailable' =>
        strings.androidErrorNativeModeUnavailable,
      'androidErrorNativeReadUnavailable' =>
        strings.androidErrorNativeReadUnavailable,
      'androidErrorNativeReleaseUnconfirmed' =>
        strings.androidErrorNativeReleaseUnconfirmed,
      'androidErrorNativeStrategyUnavailable' =>
        strings.androidErrorNativeStrategyUnavailable,
      'androidErrorNodesQuerySize' => strings.androidErrorNodesQuerySize,
      'androidErrorNotificationDenied' =>
        strings.androidErrorNotificationDenied,
      'androidErrorNotificationUpdate' =>
        strings.androidErrorNotificationUpdate,
      'androidErrorOpenVpnSettings' => strings.androidErrorOpenVpnSettings,
      'androidErrorOperationEnded' => strings.androidErrorOperationEnded,
      'androidErrorOperationIncomplete' =>
        strings.androidErrorOperationIncomplete,
      'androidErrorOperationInterrupted' =>
        strings.androidErrorOperationInterrupted,
      'androidErrorOperationWaitTimeout' =>
        strings.androidErrorOperationWaitTimeout,
      'androidErrorReleaseUnconfirmed' =>
        strings.androidErrorReleaseUnconfirmed,
      'androidErrorResourceUpdateSize' =>
        strings.androidErrorResourceUpdateSize,
      'androidErrorResultUnconfirmed' => strings.androidErrorResultUnconfirmed,
      'androidErrorRulesQuerySize' => strings.androidErrorRulesQuerySize,
      'androidErrorScheduleSave' => strings.androidErrorScheduleSave,
      'androidErrorServiceDestroyed' => strings.androidErrorServiceDestroyed,
      'androidErrorServiceNotAllowed' => strings.androidErrorServiceNotAllowed,
      'androidErrorServiceStart' => strings.androidErrorServiceStart,
      'androidErrorSessionChanged' => strings.androidErrorSessionChanged,
      'androidErrorSessionModeChanged' =>
        strings.androidErrorSessionModeChanged,
      'androidErrorStageFailed' => strings.androidErrorStageFailed(
        _textArg(message, 'stage', strings, includeDetail: includeDetail),
      ),
      'androidErrorStopNotAccepted' => strings.androidErrorStopNotAccepted,
      'androidErrorStrategyContext' => strings.androidErrorStrategyContext,
      'androidErrorStrategyParams' => strings.androidErrorStrategyParams,
      'androidErrorStrategyPrepare' => strings.androidErrorStrategyPrepare,
      'androidErrorStrategyTimeout' => strings.androidErrorStrategyTimeout,
      'androidErrorStrategyUnconfirmed' =>
        strings.androidErrorStrategyUnconfirmed,
      'androidErrorSystemRevoked' => strings.androidErrorSystemRevoked,
      'androidErrorSystemStartPrepare' =>
        strings.androidErrorSystemStartPrepare,
      'androidErrorSystemTimeoutTask' => strings.androidErrorSystemTimeoutTask,
      'androidErrorTakeoverReleaseUnknown' =>
        strings.androidErrorTakeoverReleaseUnknown,
      'androidErrorTakeoverRunning' => strings.androidErrorTakeoverRunning,
      'androidErrorTakeoverStartFailed' =>
        strings.androidErrorTakeoverStartFailed,
      'androidErrorTakeoverTimeout' => strings.androidErrorTakeoverTimeout,
      'androidErrorUnknownCommand' => strings.androidErrorUnknownCommand,
      'androidErrorUnknownMode' => strings.androidErrorUnknownMode,
      'androidErrorUpdateFailed' => strings.androidErrorUpdateFailed,
      'androidErrorUpdateFailedShort' => strings.androidErrorUpdateFailedShort,
      'androidErrorVpnInputMissing' => strings.androidErrorVpnInputMissing,
      'androidErrorVpnPermissionInvalid' =>
        strings.androidErrorVpnPermissionInvalid,
      'androidErrorVpnPermissionRequests' =>
        strings.androidErrorVpnPermissionRequests,
      'androidErrorVpnPermissionReturn' =>
        strings.androidErrorVpnPermissionReturn,
      'androidErrorVpnServiceStart' => strings.androidErrorVpnServiceStart,
      'androidOperationAccepting' => strings.androidOperationAccepting,
      'androidOperationPreparingSystemStart' =>
        strings.androidOperationPreparingSystemStart,
      'androidStageAttaching' => strings.androidStageAttaching,
      'androidStageEstablishing' => strings.androidStageEstablishing,
      'androidStageLoading' => strings.androidStageLoading,
      'androidStatusUpdating' => strings.androidStatusUpdating,
      'applicationAllowEmpty' => strings.applicationAllowEmpty,
      'applicationListFailed' => strings.applicationListFailed,
      'applicationSharedUidNotice' => strings.applicationSharedUidNotice(
        _textArg(message, 'packages', strings, includeDetail: includeDetail),
      ),
      'applyingStrategySelection' => strings.applyingStrategySelection,
      'authorizationCancelled' => strings.authorizationCancelled,
      'backupCancelled' => strings.backupCancelled,
      'backupCandidateExpired' => strings.backupCandidateExpired,
      'backupConnectionCancelled' => strings.backupConnectionCancelled,
      'backupConnectionFailed' => strings.backupConnectionFailed,
      'backupExportSaved' => strings.backupExportSaved,
      'backupFailed' => strings.backupFailed,
      'backupDocumentWriteUnconfirmed' =>
        strings.backupDocumentWriteUnconfirmed,
      'backupInvalid' => strings.backupInvalid,
      'backupNotRestored' => strings.backupNotRestored,
      'backupRestored' => strings.backupRestored,
      'backupRestoredWithIssue' when message.args['issue'] is AppMessage =>
        strings.backupRestoredWithIssue(
          _textArg(message, 'issue', strings, includeDetail: includeDetail),
        ),
      'backupRestoreUnconfirmed' => strings.backupRestoreUnconfirmed,
      'backupSchedulesFailed' => strings.backupSchedulesFailed,
      'backupSettingsRefreshFailed' => strings.backupSettingsRefreshFailed,
      'backupTooLarge' => strings.backupTooLarge,
      'autoUpdateDisabledResult' => strings.autoUpdateDisabledResult,
      'autoUpdateEnabledResult' => strings.autoUpdateEnabledResult,
      'bodyPrepFailed' => strings.bodyPrepFailed,
      'editorLineTooLong' => strings.editorLineTooLong(
        message.args['line'] as int,
        message.args['limit'] as int,
      ),
      'editorQueryTooLong' => strings.editorQueryTooLong(
        message.args['limit'] as int,
      ),
      'editorChangeTooLong' => strings.editorChangeTooLong(
        message.args['line'] as int,
        message.args['limit'] as int,
      ),
      'editorContextChanged' => strings.editorContextChanged,
      'bodyUnreadable' => strings.bodyUnreadable,
      'chooseUpdateInterval' => strings.chooseUpdateInterval,
      'configActionFailed' => strings.configActionFailed,
      'configChangedDownloadUnapplied' =>
        strings.configChangedDownloadUnapplied,
      'configChangedReopen' => strings.configChangedReopen,
      'configChangedWaitStrategies' => strings.configChangedWaitStrategies,
      'configDeleted' => strings.configDeleted,
      'configMissingRefresh' => strings.configMissingRefresh,
      'configNameInvalid' => strings.configNameInvalid,
      'configRenamed' => strings.configRenamed,
      'configSaveFailed' => strings.configSaveFailed,
      'configSaved' => strings.configSaved,
      'configSavedApplied' => strings.configSavedApplied,
      'configSavedApplyReleasePending' =>
        strings.configSavedApplyReleasePending,
      'configSavedParsedAtStart' => strings.configSavedParsedAtStart,
      'configSavedReconnectIncomplete' =>
        strings.configSavedReconnectIncomplete,
      'configSelectedNotStarted' => strings.configSelectedNotStarted,
      'configStoreUnreadable' => strings.configStoreUnreadable,
      'configUnchanged' => strings.configUnchanged,
      'configUpdated' => strings.configUpdated,
      'configUpdatedPending' => strings.configUpdatedPending,
      'configUpdatedReconnected' => strings.configUpdatedReconnected,
      'configUpdatedRestarted' => strings.configUpdatedRestarted,
      'connectionClosed' => strings.connectionClosed,
      'connectionInactive' => strings.connectionInactive,
      'connectionRuleTargetsFailed' => strings.connectionRuleTargetsFailed,
      'coreContextUnconfirmed' => strings.coreContextUnconfirmed,
      'coreNotReadyStrategies' => strings.coreNotReadyStrategies,
      'delayCancelled' => strings.delayCancelled,
      'disconnectFailedShort' => strings.disconnectFailedShort,
      'disconnectUnconfirmedShort' => strings.disconnectUnconfirmedShort,
      'downloadFailed' => strings.downloadFailed,
      'downloadHttpStatus' => strings.downloadHttpStatus(
        _textArg(message, 'status', strings, includeDetail: includeDetail),
      ),
      'downloadNotUtf8' => strings.downloadNotUtf8,
      'downloadTimeout' => strings.downloadTimeout,
      'downloadTooLarge' => strings.downloadTooLarge,
      'fileUnreadable' => strings.fileUnreadable,
      'importAndSelectFirst' => strings.importAndSelectFirst,
      'importResultUnconfirmed' => strings.importResultUnconfirmed,
      'localCannotChangeRemote' => strings.localCannotChangeRemote,
      'localCannotRemoteUpdate' => strings.localCannotRemoteUpdate,
      'localNoAutoUpdate' => strings.localNoAutoUpdate,
      'localOverrideNoAutoUpdate' => strings.localOverrideNoAutoUpdate,
      'localOverrideNoRemoteUpdate' => strings.localOverrideNoRemoteUpdate,
      'localYamlInvalid' => strings.localYamlInvalid,
      'localYamlInvalidStructure' => strings.localYamlInvalidStructure,
      'localYamlDuplicateName' => strings.localYamlDuplicateName,
      'localYamlAliasTarget' => strings.localYamlAliasTarget,
      'localYamlInheritedTarget' => strings.localYamlInheritedTarget,
      'localYamlUnsafeStructure' => strings.localYamlUnsafeStructure,
      'localYamlUnsupportedEdit' => strings.localYamlUnsupportedEdit,
      'loonConvertedResult' => switch (message.args) {
        {
          'result': AppMessage(),
          'rules': final int rules,
          'comments': final int comments,
        }
            when rules >= 0 && comments >= 0 =>
          strings.loonConvertedResult(
            _textArg(message, 'result', strings, includeDetail: includeDetail),
            rules,
            comments,
          ),
        _ => strings.operationNotCompletedRetry,
      },
      'loonNoRulesResult' => switch (message.args) {
        {'result': AppMessage(), 'comments': final int comments}
            when comments >= 0 =>
          strings.loonNoRulesResult(
            _textArg(message, 'result', strings, includeDetail: includeDetail),
            comments,
          ),
        _ => strings.operationNotCompletedRetry,
      },
      'loonProxyNameInvalid' => strings.loonProxyNameInvalid,
      'modeConfirmed' => strings.modeConfirmed,
      'modeNotConfirmed' => strings.modeNotConfirmed,
      'modeSavedNextStart' => strings.modeSavedNextStart,
      'modeSwitchedResult' => strings.modeSwitchedResult,
      'nameInvalid' => strings.nameInvalid,
      'nameRequired' => strings.nameRequired,
      'nativeConfigurationUnsupported'
          when message.args['field'] is String &&
              message.args['reason'] is AppMessage =>
        strings.nativeConfigurationUnsupported(
          _textArg(message, 'field', strings, includeDetail: includeDetail),
          _textArg(message, 'reason', strings, includeDetail: includeDetail),
        ),
      'nativeReasonTunDisabled' => strings.nativeReasonTunDisabled,
      'nativeReasonControllerUnavailable' =>
        strings.nativeReasonControllerUnavailable,
      'nativeReasonRootRedirection' => strings.nativeReasonRootRedirection,
      'nativeReasonTransparentSockets' =>
        strings.nativeReasonTransparentSockets,
      'nativeReasonInterfaceBinding' => strings.nativeReasonInterfaceBinding,
      'nativeReasonRoutingMark' => strings.nativeReasonRoutingMark,
      'nativeReasonTcpFastOpen' => strings.nativeReasonTcpFastOpen,
      'nativeReasonFirewall' => strings.nativeReasonFirewall,
      'nativeReasonSystemClock' => strings.nativeReasonSystemClock,
      'nativeReasonExternalFd' => strings.nativeReasonExternalFd,
      'nativeReasonInterfaceName' => strings.nativeReasonInterfaceName,
      'nativeReasonGso' => strings.nativeReasonGso,
      'nativeReasonAutoRedirect' => strings.nativeReasonAutoRedirect,
      'nativeReasonLinuxRouting' => strings.nativeReasonLinuxRouting,
      'nativeReasonInterfaceFilter' => strings.nativeReasonInterfaceFilter,
      'nativeReasonMacFilter' => strings.nativeReasonMacFilter,
      'nativeReasonPortFilter' => strings.nativeReasonPortFilter,
      'nativeReasonStrictRoute' => strings.nativeReasonStrictRoute,
      'nativeReasonDnsHijackConflict' => strings.nativeReasonDnsHijackConflict,
      'nativeReasonIpv6Unavailable' => strings.nativeReasonIpv6Unavailable,
      'nativeReasonInvalidMtu' => strings.nativeReasonInvalidMtu,
      'nativeReasonInvalidAddress' => strings.nativeReasonInvalidAddress,
      'nativeReasonSystemDnsUnavailable' =>
        strings.nativeReasonSystemDnsUnavailable,
      'nativeReasonPrivateDnsUnavailable' =>
        strings.nativeReasonPrivateDnsUnavailable,
      'nativeReasonProviderPath' => strings.nativeReasonProviderPath,
      'nativeReasonAndroidUserUnavailable' =>
        strings.nativeReasonAndroidUserUnavailable,
      'noConfigForSystemStart' => strings.noConfigForSystemStart,
      'noUsableBodyReimport' => strings.noUsableBodyReimport,
      'notProvided' => strings.notProvided,
      'operationAndCleanupFailed' => strings.operationAndCleanupFailed(
        _textArg(message, 'operation', strings, includeDetail: includeDetail),
        _textArg(message, 'cleanup', strings, includeDetail: includeDetail),
      ),
      'operationBusyFile' => strings.operationBusyFile,
      'operationFailed' => strings.operationFailed,
      'operationFinished' => strings.operationFinished,
      'operationInProgress' => strings.operationInProgress,
      'operationNotCompletedRetry' => strings.operationNotCompletedRetry,
      'overrideAutoUpdateDisabled' => strings.overrideAutoUpdateDisabled,
      'overrideAutoUpdateEnabled' => strings.overrideAutoUpdateEnabled,
      'overrideBodyMissing' => strings.overrideBodyMissing,
      'overrideChangedNotApplied' => strings.overrideChangedNotApplied,
      'overrideChangedReopen' => strings.overrideChangedReopen,
      'overrideContentUnsupported' => strings.overrideContentUnsupported,
      'overrideDeleted' => strings.overrideDeleted,
      'overrideMissingRefresh' => strings.overrideMissingRefresh,
      'overrideNameInvalid' => strings.overrideNameInvalid,
      'overrideNoBodyEnable' => strings.overrideNoBodyEnable,
      'overrideOrderChangedRefresh' => strings.overrideOrderChangedRefresh,
      'overrideOrderSaved' => strings.overrideOrderSaved,
      'overrideSavedApplyLater' => strings.overrideSavedApplyLater,
      'overrideSavedReconnectIncomplete' =>
        strings.overrideSavedReconnectIncomplete,
      'overrideSettingsSaved' => strings.overrideSettingsSaved,
      'overrideSourceExists' => strings.overrideSourceExists,
      'overrideUnchanged' => strings.overrideUnchanged,
      'overrideUpdateIncomplete' => strings.overrideUpdateIncomplete,
      'overrideUpdatedApplyLater' => strings.overrideUpdatedApplyLater,
      'overrideUpdatedEnableApply' => strings.overrideUpdatedEnableApply,
      'overrideUpdatedPending' => strings.overrideUpdatedPending,
      'overrideUpdatedReconnected' => strings.overrideUpdatedReconnected,
      'overridesAppliedReconnected' => strings.overridesAppliedReconnected,
      'overridesSaveFailed' => strings.overridesSaveFailed,
      'overridesSavedNextStart' => strings.overridesSavedNextStart,
      'overridesTooLarge' => strings.overridesTooLarge,
      'overridesUnreadable' => strings.overridesUnreadable,
      'pathUnavailable' => strings.pathUnavailable,
      'platformOperationFailed' => strings.platformOperationFailed,
      'preferencesSaveFailed' => strings.preferencesSaveFailed,
      'preferencesUnreadable' => strings.preferencesUnreadable,
      'previewMismatch' => strings.previewMismatch,
      'redirectInvalid' => strings.redirectInvalid,
      'redirectTooMany' => strings.redirectTooMany,
      'remoteOverrideReadOnly' => strings.remoteOverrideReadOnly,
      'requestNotAccepted' => strings.requestNotAccepted,
      'resourceUpdateFailed' => strings.resourceUpdateFailed,
      'resourceUpdateStopped' => strings.resourceUpdateStopped,
      'resourceUpdateSuccess' => strings.resourceUpdateSuccess,
      'runningConfigMissingOverrides' => strings.runningConfigMissingOverrides,
      'runningConfigNoBody' => strings.runningConfigNoBody,
      'runningConfigUnavailable' => strings.runningConfigUnavailable,
      'saveFailed' => strings.saveFailed,
      'saveUnconfirmed' => strings.saveUnconfirmed,
      'schedulesSynced' => strings.schedulesSynced,
      'sessionChangedNoDisconnect' => strings.sessionChangedNoDisconnect,
      'settingsSaved' => strings.settingsSaved,
      'sourceSavedConfirmOverwrite' => strings.sourceSavedConfirmOverwrite,
      'sourceUsedBy' => strings.sourceUsedBy(
        _textArg(message, 'name', strings, includeDetail: includeDetail),
      ),
      'stageApplyingConfigUpdate' => strings.stageApplyingConfigUpdate,
      'stageApplyingOverrideUpdate' => strings.stageApplyingOverrideUpdate,
      'stageDownloading' => strings.stageDownloading,
      'stageLoadingStrategies' => strings.stageLoadingStrategies,
      'stagePreparingSystemStart' => strings.stagePreparingSystemStart,
      'stageReconnectAccess' => strings.stageReconnectAccess,
      'stageSavingConfig' => strings.stageSavingConfig,
      'stageStartingTunnel' => strings.stageStartingTunnel,
      'stageStopping' => strings.stageStopping,
      'stageStoppingOld' => strings.stageStoppingOld,
      'stageSwitchingMode' => strings.stageSwitchingMode,
      'stageUpdatingConfig' => strings.stageUpdatingConfig,
      'stageWaitingVpnAuth' => strings.stageWaitingVpnAuth,
      'statusUnconfirmedVerify' => strings.statusUnconfirmedVerify,
      'storageContextChanged' => strings.storageContextChanged,
      'localCustomSavedVerificationFailed'
          when message.args['result'] is AppMessage &&
              message.args['reason'] is AppMessage =>
        strings.localCustomSavedVerificationFailed(
          _textArg(message, 'result', strings, includeDetail: includeDetail),
          _textArg(message, 'reason', strings, includeDetail: includeDetail),
        ),
      'storageUsageFailed' => strings.storageUsageFailed,
      'storageCleanupFailed' => strings.storageCleanupFailed,
      'configurationsCleared' => strings.configurationsCleared,
      'overridesCleared' => strings.overridesCleared,
      'inactiveConnectionsCleared' => strings.inactiveConnectionsCleared,
      'inactiveConnectionsClearFailed' =>
        strings.inactiveConnectionsClearFailed,
      'storageSyncUnconfirmed' => strings.storageSyncUnconfirmed,
      'storageSyncWarning' when message.args['result'] is AppMessage =>
        strings.storageSyncWarning(
          _textArg(message, 'result', strings, includeDetail: includeDetail),
        ),
      'storageUnavailable' => strings.storageUnavailable,
      'strategyContextChangedRetry' => strings.strategyContextChangedRetry,
      'strategyGroupChanged' => strings.strategyGroupChanged,
      'strategySelectionUnconfirmed' => strings.strategySelectionUnconfirmed,
      'strategyStatusStale' => strings.strategyStatusStale,
      'switchedConfig' => strings.switchedConfig,
      'systemStartPrepared' => strings.systemStartPrepared,
      'systemStartUnsupported' => strings.systemStartUnsupported,
      'targetGoneOrDisabled' => strings.targetGoneOrDisabled,
      'temporaryConfigsUnreadable' => strings.temporaryConfigsUnreadable,
      'temporaryModeUnknown' => strings.temporaryModeUnknown,
      'temporaryOverridesUnreadable' => strings.temporaryOverridesUnreadable,
      'temporarySettingsUnreadable' => strings.temporarySettingsUnreadable,
      'temporaryStatusUnavailable' => strings.temporaryStatusUnavailable,
      'textNotUtf8' => strings.textNotUtf8,
      'textTooLargeImport' => strings.textTooLargeImport,
      'textTooLargeSave' => strings.textTooLargeSave,
      'preparationOptionsTooLarge' => strings.preparationOptionsTooLarge,
      'preparationFragmentsTooLarge' => strings.preparationFragmentsTooLarge,
      'preparationMetadataInvalid' => strings.preparationMetadataInvalid,
      'tlsFailed' => strings.tlsFailed,
      'trafficUpdateFailed' => strings.trafficUpdateFailed,
      'trustedRootsUnavailable' => strings.trustedRootsUnavailable,
      'tunnelStarted' => strings.tunnelStarted,
      'tunnelStopped' => strings.tunnelStopped,
      'unknownOperation' => strings.unknownOperation,
      'unknownOverrideOperation' => strings.unknownOverrideOperation,
      'unknownUpdateTarget' => strings.unknownUpdateTarget,
      'updateInterrupted' => strings.updateInterrupted,
      'updateStateWriteFailed' => strings.updateStateWriteFailed,
      'urlRequired' => strings.urlRequired,
      _ => strings.operationNotCompletedRetry,
    };
  } on FormatException {
    return strings.operationNotCompletedRetry;
  }
}
