import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show basicLocaleListResolution;

import '../model/app_preferences.dart';
import 'app_localizations.dart';
import 'app_message.dart';

export 'app_message.dart';

/// Business code creates message descriptors; the display layer resolves locale.
const messages = AppMessages();

AppLanguage _language = AppLanguage.system;
Locale? _locale;
AppLocalizations? _strings;

/// UI-only projection. Saved messages are re-resolved rather than translated
/// when they are produced by a headless engine or first read from storage.
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

AppMessage messageFromPlatform(
  PlatformException error, {
  required AppMessage fallback,
}) {
  try {
    return AppMessage.fromMap(error.details);
  } on FormatException {
    // Map platform/native diagnostics to application-owned display messages.
    return fallback;
  }
}

extension AppMessageText on AppMessage {
  String get text => resolveAppMessage(this, localizedMessages);
  String resolve(AppLocalizations strings) => resolveAppMessage(this, strings);
}

String _textArg(AppMessage message, String name, AppLocalizations strings) {
  final value = message.args[name];
  if (value is String) return value;
  if (value is AppMessage) return resolveAppMessage(value, strings);
  throw const FormatException('Invalid message argument');
}

/// The public Flutter localization API has typed getters rather than an ID
/// lookup. This switch is the small adapter for messages that cross engines.
String resolveAppMessage(AppMessage message, AppLocalizations strings) {
  try {
    return switch (message.id) {
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
        _textArg(message, 'stage', strings),
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
        _textArg(message, 'packages', strings),
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
        strings.backupRestoredWithIssue(_textArg(message, 'issue', strings)),
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
      'coreContextUnconfirmed' => strings.coreContextUnconfirmed,
      'coreNotReadyStrategies' => strings.coreNotReadyStrategies,
      'delayCancelled' => strings.delayCancelled,
      'disconnectFailedShort' => strings.disconnectFailedShort,
      'disconnectUnconfirmedShort' => strings.disconnectUnconfirmedShort,
      'downloadFailed' => strings.downloadFailed,
      'downloadHttpStatus' => strings.downloadHttpStatus(
        _textArg(message, 'status', strings),
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
            _textArg(message, 'result', strings),
            rules,
            comments,
          ),
        _ => strings.operationNotCompletedRetry,
      },
      'loonNoRulesResult' => switch (message.args) {
        {'result': AppMessage(), 'comments': final int comments}
            when comments >= 0 =>
          strings.loonNoRulesResult(
            _textArg(message, 'result', strings),
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
          _textArg(message, 'field', strings),
          _textArg(message, 'reason', strings),
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
        _textArg(message, 'operation', strings),
        _textArg(message, 'cleanup', strings),
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
        _textArg(message, 'name', strings),
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
      'stopBeforeDelete' => strings.stopBeforeDelete,
      'storageContextChanged' => strings.storageContextChanged,
      'localCustomSavedVerificationFailed'
          when message.args['result'] is AppMessage &&
              message.args['reason'] is AppMessage =>
        strings.localCustomSavedVerificationFailed(
          _textArg(message, 'result', strings),
          _textArg(message, 'reason', strings),
        ),
      'storageSyncUnconfirmed' => strings.storageSyncUnconfirmed,
      'storageSyncWarning' when message.args['result'] is AppMessage =>
        strings.storageSyncWarning(_textArg(message, 'result', strings)),
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

/// Only the messages currently produced outside a localized widget are listed.
class AppMessages {
  const AppMessages();

  AppMessage get accessSavedNextConnection =>
      const AppMessage('accessSavedNextConnection');

  AppMessage get accessSavedReconnectFailed =>
      const AppMessage('accessSavedReconnectFailed');

  AppMessage get accessSavedReconnected =>
      const AppMessage('accessSavedReconnected');

  AppMessage get alreadyRunning => const AppMessage('alreadyRunning');

  AppMessage get alreadyRunningNoRestore =>
      const AppMessage('alreadyRunningNoRestore');

  AppMessage get alwaysOnOpenFailed => const AppMessage('alwaysOnOpenFailed');

  AppMessage get androidErrorActivityReturn =>
      const AppMessage('androidErrorActivityReturn');

  AppMessage get androidErrorAppInfoNative =>
      const AppMessage('androidErrorAppInfoNative');

  AppMessage get androidErrorAppInfoVersion =>
      const AppMessage('androidErrorAppInfoVersion');

  AppMessage get androidErrorApplicationAllowlistMissing =>
      const AppMessage('androidErrorApplicationAllowlistMissing');

  AppMessage get androidErrorApplications =>
      const AppMessage('androidErrorApplications');

  AppMessage get androidErrorBackgroundStart =>
      const AppMessage('androidErrorBackgroundStart');

  AppMessage get androidErrorBatchExpired =>
      const AppMessage('androidErrorBatchExpired');

  AppMessage get androidErrorBusy => const AppMessage('androidErrorBusy');

  AppMessage get androidErrorConnectionBusy =>
      const AppMessage('androidErrorConnectionBusy');

  AppMessage get androidErrorConnectionId =>
      const AppMessage('androidErrorConnectionId');

  AppMessage get androidErrorConnectionNotAccepted =>
      const AppMessage('androidErrorConnectionNotAccepted');

  AppMessage get androidErrorConnectionQuerySize =>
      const AppMessage('androidErrorConnectionQuerySize');

  AppMessage get androidErrorConnectionTimeout =>
      const AppMessage('androidErrorConnectionTimeout');

  AppMessage get androidErrorCoreBusy =>
      const AppMessage('androidErrorCoreBusy');

  AppMessage get androidErrorCoreContextRefresh =>
      const AppMessage('androidErrorCoreContextRefresh');

  AppMessage get androidErrorCoreContextReread =>
      const AppMessage('androidErrorCoreContextReread');

  AppMessage get androidErrorCoreNotReady =>
      const AppMessage('androidErrorCoreNotReady');

  AppMessage get androidErrorCoreReadFailed =>
      const AppMessage('androidErrorCoreReadFailed');

  AppMessage get androidErrorCoreReadTimeout =>
      const AppMessage('androidErrorCoreReadTimeout');

  AppMessage get androidErrorDelayRead =>
      const AppMessage('androidErrorDelayRead');

  AppMessage get androidErrorDelayStart =>
      const AppMessage('androidErrorDelayStart');

  AppMessage get androidErrorDisconnectUnconfirmed =>
      const AppMessage('androidErrorDisconnectUnconfirmed');

  AppMessage get androidErrorGroupUntestable =>
      const AppMessage('androidErrorGroupUntestable');

  AppMessage get androidErrorInvalidResult =>
      const AppMessage('androidErrorInvalidResult');

  AppMessage get androidErrorLogicExpired =>
      const AppMessage('androidErrorLogicExpired');

  AppMessage get androidErrorLogsQuerySize =>
      const AppMessage('androidErrorLogsQuerySize');

  AppMessage get androidErrorModeTimeout =>
      const AppMessage('androidErrorModeTimeout');

  AppMessage get androidErrorModeUnconfirmed =>
      const AppMessage('androidErrorModeUnconfirmed');

  AppMessage get androidErrorNativeConnectionUnavailable =>
      const AppMessage('androidErrorNativeConnectionUnavailable');

  AppMessage get androidErrorNativeCoreLoad =>
      const AppMessage('androidErrorNativeCoreLoad');

  AppMessage get androidErrorNativeDelayUnavailable =>
      const AppMessage('androidErrorNativeDelayUnavailable');

  AppMessage get androidErrorNativeModeUnavailable =>
      const AppMessage('androidErrorNativeModeUnavailable');

  AppMessage get androidErrorNativeReadUnavailable =>
      const AppMessage('androidErrorNativeReadUnavailable');

  AppMessage get androidErrorNativeReleaseUnconfirmed =>
      const AppMessage('androidErrorNativeReleaseUnconfirmed');

  AppMessage get androidErrorNativeStrategyUnavailable =>
      const AppMessage('androidErrorNativeStrategyUnavailable');

  AppMessage get androidErrorNodesQuerySize =>
      const AppMessage('androidErrorNodesQuerySize');

  AppMessage get androidErrorNotificationDenied =>
      const AppMessage('androidErrorNotificationDenied');

  AppMessage get androidErrorNotificationUpdate =>
      const AppMessage('androidErrorNotificationUpdate');

  AppMessage get androidErrorOpenVpnSettings =>
      const AppMessage('androidErrorOpenVpnSettings');

  AppMessage get androidErrorOperationEnded =>
      const AppMessage('androidErrorOperationEnded');

  AppMessage get androidErrorOperationIncomplete =>
      const AppMessage('androidErrorOperationIncomplete');

  AppMessage get androidErrorOperationInterrupted =>
      const AppMessage('androidErrorOperationInterrupted');

  AppMessage get androidErrorOperationWaitTimeout =>
      const AppMessage('androidErrorOperationWaitTimeout');

  AppMessage get androidErrorReleaseUnconfirmed =>
      const AppMessage('androidErrorReleaseUnconfirmed');

  AppMessage get androidErrorResourceUpdateSize =>
      const AppMessage('androidErrorResourceUpdateSize');

  AppMessage get androidErrorResultUnconfirmed =>
      const AppMessage('androidErrorResultUnconfirmed');

  AppMessage get androidErrorRulesQuerySize =>
      const AppMessage('androidErrorRulesQuerySize');

  AppMessage get androidErrorScheduleSave =>
      const AppMessage('androidErrorScheduleSave');

  AppMessage get androidErrorServiceDestroyed =>
      const AppMessage('androidErrorServiceDestroyed');

  AppMessage get androidErrorServiceNotAllowed =>
      const AppMessage('androidErrorServiceNotAllowed');

  AppMessage get androidErrorServiceStart =>
      const AppMessage('androidErrorServiceStart');

  AppMessage get androidErrorSessionChanged =>
      const AppMessage('androidErrorSessionChanged');

  AppMessage get androidErrorSessionModeChanged =>
      const AppMessage('androidErrorSessionModeChanged');

  AppMessage androidErrorStageFailed(String stage) =>
      AppMessage.withArgs('androidErrorStageFailed', {'stage': stage});

  AppMessage get androidErrorStopNotAccepted =>
      const AppMessage('androidErrorStopNotAccepted');

  AppMessage get androidErrorStrategyContext =>
      const AppMessage('androidErrorStrategyContext');

  AppMessage get androidErrorStrategyParams =>
      const AppMessage('androidErrorStrategyParams');

  AppMessage get androidErrorStrategyPrepare =>
      const AppMessage('androidErrorStrategyPrepare');

  AppMessage get androidErrorStrategyTimeout =>
      const AppMessage('androidErrorStrategyTimeout');

  AppMessage get androidErrorStrategyUnconfirmed =>
      const AppMessage('androidErrorStrategyUnconfirmed');

  AppMessage get androidErrorSystemRevoked =>
      const AppMessage('androidErrorSystemRevoked');

  AppMessage get androidErrorSystemStartPrepare =>
      const AppMessage('androidErrorSystemStartPrepare');

  AppMessage get androidErrorSystemTimeoutTask =>
      const AppMessage('androidErrorSystemTimeoutTask');

  AppMessage get androidErrorTakeoverReleaseUnknown =>
      const AppMessage('androidErrorTakeoverReleaseUnknown');

  AppMessage get androidErrorTakeoverRunning =>
      const AppMessage('androidErrorTakeoverRunning');

  AppMessage get androidErrorTakeoverStartFailed =>
      const AppMessage('androidErrorTakeoverStartFailed');

  AppMessage get androidErrorTakeoverTimeout =>
      const AppMessage('androidErrorTakeoverTimeout');

  AppMessage get androidErrorUnknownCommand =>
      const AppMessage('androidErrorUnknownCommand');

  AppMessage get androidErrorUnknownMode =>
      const AppMessage('androidErrorUnknownMode');

  AppMessage get androidErrorUpdateFailed =>
      const AppMessage('androidErrorUpdateFailed');

  AppMessage get androidErrorUpdateFailedShort =>
      const AppMessage('androidErrorUpdateFailedShort');

  AppMessage get androidErrorVpnInputMissing =>
      const AppMessage('androidErrorVpnInputMissing');

  AppMessage get androidErrorVpnPermissionInvalid =>
      const AppMessage('androidErrorVpnPermissionInvalid');

  AppMessage get androidErrorVpnPermissionRequests =>
      const AppMessage('androidErrorVpnPermissionRequests');

  AppMessage get androidErrorVpnPermissionReturn =>
      const AppMessage('androidErrorVpnPermissionReturn');

  AppMessage get androidErrorVpnServiceStart =>
      const AppMessage('androidErrorVpnServiceStart');

  AppMessage get androidOperationAccepting =>
      const AppMessage('androidOperationAccepting');

  AppMessage get androidOperationPreparingSystemStart =>
      const AppMessage('androidOperationPreparingSystemStart');

  AppMessage get androidStageAttaching =>
      const AppMessage('androidStageAttaching');

  AppMessage get androidStageEstablishing =>
      const AppMessage('androidStageEstablishing');

  AppMessage get androidStageLoading => const AppMessage('androidStageLoading');

  AppMessage get androidStatusUpdating =>
      const AppMessage('androidStatusUpdating');

  AppMessage get applicationAllowEmpty =>
      const AppMessage('applicationAllowEmpty');

  AppMessage get applicationListFailed =>
      const AppMessage('applicationListFailed');

  AppMessage applicationSharedUidNotice(String packages) =>
      AppMessage.withArgs('applicationSharedUidNotice', {'packages': packages});

  AppMessage get applyingStrategySelection =>
      const AppMessage('applyingStrategySelection');

  AppMessage get authorizationCancelled =>
      const AppMessage('authorizationCancelled');

  AppMessage get autoUpdateDisabledResult =>
      const AppMessage('autoUpdateDisabledResult');

  AppMessage get autoUpdateEnabledResult =>
      const AppMessage('autoUpdateEnabledResult');

  AppMessage get bodyPrepFailed => const AppMessage('bodyPrepFailed');
  AppMessage get bodyUnreadable => const AppMessage('bodyUnreadable');

  AppMessage get chooseUpdateInterval =>
      const AppMessage('chooseUpdateInterval');

  AppMessage get configActionFailed => const AppMessage('configActionFailed');

  AppMessage get configChangedDownloadUnapplied =>
      const AppMessage('configChangedDownloadUnapplied');

  AppMessage get configChangedReopen => const AppMessage('configChangedReopen');

  AppMessage get configChangedWaitStrategies =>
      const AppMessage('configChangedWaitStrategies');

  AppMessage get configDeleted => const AppMessage('configDeleted');

  AppMessage get configMissingRefresh =>
      const AppMessage('configMissingRefresh');

  AppMessage get configNameInvalid => const AppMessage('configNameInvalid');

  AppMessage get configRenamed => const AppMessage('configRenamed');

  AppMessage get configSaveFailed => const AppMessage('configSaveFailed');

  AppMessage get configSaved => const AppMessage('configSaved');

  AppMessage get configSavedApplied => const AppMessage('configSavedApplied');

  AppMessage get configSavedApplyReleasePending =>
      const AppMessage('configSavedApplyReleasePending');

  AppMessage get configSavedParsedAtStart =>
      const AppMessage('configSavedParsedAtStart');

  AppMessage get configSavedReconnectIncomplete =>
      const AppMessage('configSavedReconnectIncomplete');

  AppMessage get configSelectedNotStarted =>
      const AppMessage('configSelectedNotStarted');

  AppMessage get configStoreUnreadable =>
      const AppMessage('configStoreUnreadable');

  AppMessage get configUnchanged => const AppMessage('configUnchanged');

  AppMessage get configUpdated => const AppMessage('configUpdated');

  AppMessage get configUpdatedPending =>
      const AppMessage('configUpdatedPending');

  AppMessage get configUpdatedReconnected =>
      const AppMessage('configUpdatedReconnected');

  AppMessage get configUpdatedRestarted =>
      const AppMessage('configUpdatedRestarted');

  AppMessage get connectionClosed => const AppMessage('connectionClosed');

  AppMessage get connectionInactive => const AppMessage('connectionInactive');

  AppMessage get coreContextUnconfirmed =>
      const AppMessage('coreContextUnconfirmed');

  AppMessage get coreNotReadyStrategies =>
      const AppMessage('coreNotReadyStrategies');

  AppMessage get delayCancelled => const AppMessage('delayCancelled');

  AppMessage get disconnectFailedShort =>
      const AppMessage('disconnectFailedShort');

  AppMessage get disconnectUnconfirmedShort =>
      const AppMessage('disconnectUnconfirmedShort');

  AppMessage get downloadFailed => const AppMessage('downloadFailed');

  AppMessage downloadHttpStatus(String status) =>
      AppMessage.withArgs('downloadHttpStatus', {'status': status});

  AppMessage get downloadNotUtf8 => const AppMessage('downloadNotUtf8');

  AppMessage get downloadTimeout => const AppMessage('downloadTimeout');

  AppMessage get downloadTooLarge => const AppMessage('downloadTooLarge');

  AppMessage get fileUnreadable => const AppMessage('fileUnreadable');

  AppMessage get importAndSelectFirst =>
      const AppMessage('importAndSelectFirst');

  AppMessage get importResultUnconfirmed =>
      const AppMessage('importResultUnconfirmed');

  AppMessage get localCannotChangeRemote =>
      const AppMessage('localCannotChangeRemote');

  AppMessage get localCannotRemoteUpdate =>
      const AppMessage('localCannotRemoteUpdate');

  AppMessage get localNoAutoUpdate => const AppMessage('localNoAutoUpdate');

  AppMessage get localOverrideNoAutoUpdate =>
      const AppMessage('localOverrideNoAutoUpdate');

  AppMessage get localOverrideNoRemoteUpdate =>
      const AppMessage('localOverrideNoRemoteUpdate');

  AppMessage get localYamlInvalid => const AppMessage('localYamlInvalid');
  AppMessage get localYamlInvalidStructure =>
      const AppMessage('localYamlInvalidStructure');
  AppMessage get localYamlDuplicateName =>
      const AppMessage('localYamlDuplicateName');
  AppMessage get localYamlAliasTarget =>
      const AppMessage('localYamlAliasTarget');
  AppMessage get localYamlInheritedTarget =>
      const AppMessage('localYamlInheritedTarget');
  AppMessage get localYamlUnsafeStructure =>
      const AppMessage('localYamlUnsafeStructure');
  AppMessage get localYamlUnsupportedEdit =>
      const AppMessage('localYamlUnsupportedEdit');

  AppMessage loonConvertedResult({
    required AppMessage result,
    required int rules,
    required int comments,
  }) => AppMessage.withArgs('loonConvertedResult', {
    'result': result,
    'rules': rules,
    'comments': comments,
  });

  AppMessage loonNoRulesResult({
    required AppMessage result,
    required int comments,
  }) => AppMessage.withArgs('loonNoRulesResult', {
    'result': result,
    'comments': comments,
  });

  AppMessage get loonProxyNameInvalid =>
      const AppMessage('loonProxyNameInvalid');

  AppMessage get modeConfirmed => const AppMessage('modeConfirmed');

  AppMessage get modeNotConfirmed => const AppMessage('modeNotConfirmed');

  AppMessage get modeSavedNextStart => const AppMessage('modeSavedNextStart');

  AppMessage get modeSwitchedResult => const AppMessage('modeSwitchedResult');

  AppMessage get nameInvalid => const AppMessage('nameInvalid');

  AppMessage get nameRequired => const AppMessage('nameRequired');

  AppMessage get noConfigForSystemStart =>
      const AppMessage('noConfigForSystemStart');

  AppMessage get noUsableBodyReimport =>
      const AppMessage('noUsableBodyReimport');

  AppMessage nativeConfigurationUnsupported(String field, AppMessage reason) =>
      AppMessage.withArgs('nativeConfigurationUnsupported', {
        'field': field,
        'reason': reason,
      });

  AppMessage get nativeReasonTunDisabled =>
      const AppMessage('nativeReasonTunDisabled');
  AppMessage get nativeReasonControllerUnavailable =>
      const AppMessage('nativeReasonControllerUnavailable');
  AppMessage get nativeReasonRootRedirection =>
      const AppMessage('nativeReasonRootRedirection');
  AppMessage get nativeReasonTransparentSockets =>
      const AppMessage('nativeReasonTransparentSockets');
  AppMessage get nativeReasonInterfaceBinding =>
      const AppMessage('nativeReasonInterfaceBinding');
  AppMessage get nativeReasonRoutingMark =>
      const AppMessage('nativeReasonRoutingMark');
  AppMessage get nativeReasonTcpFastOpen =>
      const AppMessage('nativeReasonTcpFastOpen');
  AppMessage get nativeReasonFirewall =>
      const AppMessage('nativeReasonFirewall');
  AppMessage get nativeReasonSystemClock =>
      const AppMessage('nativeReasonSystemClock');
  AppMessage get nativeReasonExternalFd =>
      const AppMessage('nativeReasonExternalFd');
  AppMessage get nativeReasonInterfaceName =>
      const AppMessage('nativeReasonInterfaceName');
  AppMessage get nativeReasonGso => const AppMessage('nativeReasonGso');
  AppMessage get nativeReasonAutoRedirect =>
      const AppMessage('nativeReasonAutoRedirect');
  AppMessage get nativeReasonLinuxRouting =>
      const AppMessage('nativeReasonLinuxRouting');
  AppMessage get nativeReasonInterfaceFilter =>
      const AppMessage('nativeReasonInterfaceFilter');
  AppMessage get nativeReasonMacFilter =>
      const AppMessage('nativeReasonMacFilter');
  AppMessage get nativeReasonPortFilter =>
      const AppMessage('nativeReasonPortFilter');
  AppMessage get nativeReasonStrictRoute =>
      const AppMessage('nativeReasonStrictRoute');
  AppMessage get nativeReasonDnsHijackConflict =>
      const AppMessage('nativeReasonDnsHijackConflict');
  AppMessage get nativeReasonIpv6Unavailable =>
      const AppMessage('nativeReasonIpv6Unavailable');
  AppMessage get nativeReasonInvalidMtu =>
      const AppMessage('nativeReasonInvalidMtu');
  AppMessage get nativeReasonInvalidAddress =>
      const AppMessage('nativeReasonInvalidAddress');
  AppMessage get nativeReasonSystemDnsUnavailable =>
      const AppMessage('nativeReasonSystemDnsUnavailable');
  AppMessage get nativeReasonPrivateDnsUnavailable =>
      const AppMessage('nativeReasonPrivateDnsUnavailable');
  AppMessage get nativeReasonProviderPath =>
      const AppMessage('nativeReasonProviderPath');

  AppMessage get nativeReasonAndroidUserUnavailable =>
      const AppMessage('nativeReasonAndroidUserUnavailable');

  AppMessage get notProvided => const AppMessage('notProvided');

  AppMessage operationAndCleanupFailed(String operation, String cleanup) =>
      AppMessage.withArgs('operationAndCleanupFailed', {
        'operation': operation,
        'cleanup': cleanup,
      });

  AppMessage get operationBusyFile => const AppMessage('operationBusyFile');

  AppMessage get operationFailed => const AppMessage('operationFailed');

  AppMessage get operationFinished => const AppMessage('operationFinished');

  AppMessage get operationInProgress => const AppMessage('operationInProgress');

  AppMessage get operationNotCompletedRetry =>
      const AppMessage('operationNotCompletedRetry');

  AppMessage get overrideAutoUpdateDisabled =>
      const AppMessage('overrideAutoUpdateDisabled');

  AppMessage get overrideAutoUpdateEnabled =>
      const AppMessage('overrideAutoUpdateEnabled');

  AppMessage get overrideBodyMissing => const AppMessage('overrideBodyMissing');

  AppMessage get overrideChangedNotApplied =>
      const AppMessage('overrideChangedNotApplied');

  AppMessage get overrideChangedReopen =>
      const AppMessage('overrideChangedReopen');

  AppMessage get overrideContentUnsupported =>
      const AppMessage('overrideContentUnsupported');

  AppMessage get overrideDeleted => const AppMessage('overrideDeleted');

  AppMessage get overrideMissingRefresh =>
      const AppMessage('overrideMissingRefresh');

  AppMessage get overrideNameInvalid => const AppMessage('overrideNameInvalid');

  AppMessage get overrideNoBodyEnable =>
      const AppMessage('overrideNoBodyEnable');

  AppMessage get overrideOrderChangedRefresh =>
      const AppMessage('overrideOrderChangedRefresh');

  AppMessage get overrideOrderSaved => const AppMessage('overrideOrderSaved');

  AppMessage get overrideSavedApplyLater =>
      const AppMessage('overrideSavedApplyLater');

  AppMessage get overrideSavedReconnectIncomplete =>
      const AppMessage('overrideSavedReconnectIncomplete');

  AppMessage get overrideSettingsSaved =>
      const AppMessage('overrideSettingsSaved');

  AppMessage get overrideSourceExists =>
      const AppMessage('overrideSourceExists');

  AppMessage get overrideUnchanged => const AppMessage('overrideUnchanged');

  AppMessage get overrideUpdateIncomplete =>
      const AppMessage('overrideUpdateIncomplete');

  AppMessage get overrideUpdatedApplyLater =>
      const AppMessage('overrideUpdatedApplyLater');

  AppMessage get overrideUpdatedEnableApply =>
      const AppMessage('overrideUpdatedEnableApply');

  AppMessage get overrideUpdatedPending =>
      const AppMessage('overrideUpdatedPending');

  AppMessage get overrideUpdatedReconnected =>
      const AppMessage('overrideUpdatedReconnected');

  AppMessage get overridesAppliedReconnected =>
      const AppMessage('overridesAppliedReconnected');

  AppMessage get overridesSaveFailed => const AppMessage('overridesSaveFailed');

  AppMessage get overridesSavedNextStart =>
      const AppMessage('overridesSavedNextStart');

  AppMessage get overridesTooLarge => const AppMessage('overridesTooLarge');

  AppMessage get overridesUnreadable => const AppMessage('overridesUnreadable');

  AppMessage get pathUnavailable => const AppMessage('pathUnavailable');

  AppMessage get platformOperationFailed =>
      const AppMessage('platformOperationFailed');

  AppMessage get preferencesSaveFailed =>
      const AppMessage('preferencesSaveFailed');

  AppMessage get preferencesUnreadable =>
      const AppMessage('preferencesUnreadable');

  AppMessage get previewMismatch => const AppMessage('previewMismatch');

  AppMessage get redirectInvalid => const AppMessage('redirectInvalid');

  AppMessage get redirectTooMany => const AppMessage('redirectTooMany');

  AppMessage get remoteOverrideReadOnly =>
      const AppMessage('remoteOverrideReadOnly');

  AppMessage get requestNotAccepted => const AppMessage('requestNotAccepted');

  AppMessage get resourceUpdateFailed =>
      const AppMessage('resourceUpdateFailed');

  AppMessage get resourceUpdateStopped =>
      const AppMessage('resourceUpdateStopped');

  AppMessage get resourceUpdateSuccess =>
      const AppMessage('resourceUpdateSuccess');

  AppMessage get runningConfigMissingOverrides =>
      const AppMessage('runningConfigMissingOverrides');

  AppMessage get runningConfigNoBody => const AppMessage('runningConfigNoBody');

  AppMessage get runningConfigUnavailable =>
      const AppMessage('runningConfigUnavailable');

  AppMessage get saveFailed => const AppMessage('saveFailed');

  AppMessage get saveUnconfirmed => const AppMessage('saveUnconfirmed');

  AppMessage get schedulesSynced => const AppMessage('schedulesSynced');

  AppMessage get sessionChangedNoDisconnect =>
      const AppMessage('sessionChangedNoDisconnect');

  AppMessage get settingsSaved => const AppMessage('settingsSaved');

  AppMessage get sourceSavedConfirmOverwrite =>
      const AppMessage('sourceSavedConfirmOverwrite');

  AppMessage sourceUsedBy(String name) =>
      AppMessage.withArgs('sourceUsedBy', {'name': name});

  AppMessage get stageApplyingConfigUpdate =>
      const AppMessage('stageApplyingConfigUpdate');

  AppMessage get stageApplyingOverrideUpdate =>
      const AppMessage('stageApplyingOverrideUpdate');

  AppMessage get stageDownloading => const AppMessage('stageDownloading');

  AppMessage get stageLoadingStrategies =>
      const AppMessage('stageLoadingStrategies');

  AppMessage get stagePreparingSystemStart =>
      const AppMessage('stagePreparingSystemStart');

  AppMessage get stageReconnectAccess =>
      const AppMessage('stageReconnectAccess');

  AppMessage get stageSavingConfig => const AppMessage('stageSavingConfig');

  AppMessage get stageStartingTunnel => const AppMessage('stageStartingTunnel');

  AppMessage get stageStopping => const AppMessage('stageStopping');

  AppMessage get stageStoppingOld => const AppMessage('stageStoppingOld');

  AppMessage get stageSwitchingMode => const AppMessage('stageSwitchingMode');

  AppMessage get stageUpdatingConfig => const AppMessage('stageUpdatingConfig');

  AppMessage get stageWaitingVpnAuth => const AppMessage('stageWaitingVpnAuth');

  AppMessage get statusUnconfirmedVerify =>
      const AppMessage('statusUnconfirmedVerify');

  AppMessage get stopBeforeDelete => const AppMessage('stopBeforeDelete');

  AppMessage get strategyContextChangedRetry =>
      const AppMessage('strategyContextChangedRetry');

  AppMessage get strategyGroupChanged =>
      const AppMessage('strategyGroupChanged');

  AppMessage get strategySelectionUnconfirmed =>
      const AppMessage('strategySelectionUnconfirmed');

  AppMessage get strategyStatusStale => const AppMessage('strategyStatusStale');

  AppMessage get switchedConfig => const AppMessage('switchedConfig');

  AppMessage get systemStartPrepared => const AppMessage('systemStartPrepared');

  AppMessage get systemStartUnsupported =>
      const AppMessage('systemStartUnsupported');

  AppMessage get targetGoneOrDisabled =>
      const AppMessage('targetGoneOrDisabled');

  AppMessage get temporaryConfigsUnreadable =>
      const AppMessage('temporaryConfigsUnreadable');

  AppMessage get temporaryModeUnknown =>
      const AppMessage('temporaryModeUnknown');

  AppMessage get temporaryOverridesUnreadable =>
      const AppMessage('temporaryOverridesUnreadable');

  AppMessage get temporarySettingsUnreadable =>
      const AppMessage('temporarySettingsUnreadable');

  AppMessage get temporaryStatusUnavailable =>
      const AppMessage('temporaryStatusUnavailable');

  AppMessage get textNotUtf8 => const AppMessage('textNotUtf8');

  AppMessage get textTooLargeImport => const AppMessage('textTooLargeImport');

  AppMessage get textTooLargeSave => const AppMessage('textTooLargeSave');

  AppMessage get tlsFailed => const AppMessage('tlsFailed');

  AppMessage get trafficUpdateFailed => const AppMessage('trafficUpdateFailed');

  AppMessage get storageSyncUnconfirmed =>
      const AppMessage('storageSyncUnconfirmed');

  AppMessage localCustomSavedVerificationFailed({
    required AppMessage result,
    required AppMessage reason,
  }) => AppMessage.withArgs('localCustomSavedVerificationFailed', {
    'result': result,
    'reason': reason,
  });

  AppMessage backupRestoredWithIssue({required AppMessage issue}) =>
      AppMessage.withArgs('backupRestoredWithIssue', {'issue': issue});

  AppMessage storageSyncWarning(AppMessage result) =>
      AppMessage.withArgs('storageSyncWarning', {'result': result});

  AppMessage get storageContextChanged =>
      const AppMessage('storageContextChanged');

  AppMessage get storageUnavailable => const AppMessage('storageUnavailable');

  AppMessage get trustedRootsUnavailable =>
      const AppMessage('trustedRootsUnavailable');

  AppMessage get tunnelStarted => const AppMessage('tunnelStarted');

  AppMessage get tunnelStopped => const AppMessage('tunnelStopped');

  AppMessage get unknownOperation => const AppMessage('unknownOperation');

  AppMessage get unknownOverrideOperation =>
      const AppMessage('unknownOverrideOperation');

  AppMessage get unknownUpdateTarget => const AppMessage('unknownUpdateTarget');

  AppMessage get updateInterrupted => const AppMessage('updateInterrupted');

  AppMessage get updateStateWriteFailed =>
      const AppMessage('updateStateWriteFailed');

  AppMessage get urlRequired => const AppMessage('urlRequired');
}
