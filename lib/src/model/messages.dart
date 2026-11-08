import 'app_message.dart';

export 'app_message.dart';

/// Business logic constructs message descriptions; the UI resolves them in the current
/// language.
const messages = AppMessages();

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

  AppMessage get privacyNoticeNotSaved =>
      const AppMessage('privacyNoticeNotSaved');

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
