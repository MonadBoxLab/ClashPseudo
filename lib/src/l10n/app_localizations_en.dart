// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get selectDetails => 'Select an item to view its details.';

  @override
  String get selectionOutsideList =>
      'The selected item is outside the current list.';

  @override
  String get editLocalDefinition => 'Edit local definition';

  @override
  String get definitionFormName => 'Name';

  @override
  String get nodeRuntimePropertiesOnly =>
      'Runtime capabilities and test history are available here. The core does not provide the complete original node options.';

  @override
  String get strategyRejectStatus => 'Reject';

  @override
  String strategyCardDelayNotice(String result) {
    return 'Latest HTTP-target test for the current member: $result.';
  }

  @override
  String get overview => 'Overview';

  @override
  String get connectionsNavigation => 'Connections';

  @override
  String get configurationsNavigation => 'Configs';

  @override
  String get enlargeWindow =>
      'Enlarge the window to continue. Your current task and edits are kept.';

  @override
  String get strategies => 'Strategies';

  @override
  String get settings => 'Settings';

  @override
  String get appearanceAndLanguage => 'Appearance & language';

  @override
  String get appearance => 'Appearance';

  @override
  String get followSystem => 'System default';

  @override
  String get lightAppearance => 'Light';

  @override
  String get darkAppearance => 'Dark';

  @override
  String get brandColor => 'Accent color';

  @override
  String get cinnabar => 'Cinnabar';

  @override
  String get jade => 'Jade';

  @override
  String get cobalt => 'Cobalt';

  @override
  String get language => 'Language';

  @override
  String get configurationsAndPlugins => 'Configurations & plugins';

  @override
  String get routingAndResources => 'Routing & resources';

  @override
  String get diagnosticTools => 'Diagnostics';

  @override
  String get configurations => 'Configurations';

  @override
  String get recentConnections => 'Recent connections';

  @override
  String get overrides => 'Plugins (overrides)';

  @override
  String get proxyNodes => 'Proxy nodes';

  @override
  String get rules => 'Rules';

  @override
  String get externalResources => 'External resources';

  @override
  String get runtimeConfiguration => 'Runtime configuration';

  @override
  String get coreLogs => 'Core logs';

  @override
  String get coreLogsRecentWindow => 'Recent session';

  @override
  String get applicationAccess => 'App VPN access';

  @override
  String get alwaysOnVpn => 'Always-on VPN';

  @override
  String get about => 'About';

  @override
  String get licenses => 'Open-source licenses';

  @override
  String get retry => 'Retry';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get close => 'Close';

  @override
  String get changeSource => 'Change source';

  @override
  String get settingsLoadFailed => 'Reading the saved settings failed.';

  @override
  String get project => 'Project';

  @override
  String get applicationVersion => 'App version';

  @override
  String get legalSummary =>
      'Original code is licensed under GPL-3.0-only. You may copy, modify and redistribute it under the GNU General Public License version 3. No warranty is provided to the extent permitted by law. Third-party components retain their own copyrights and licenses.';

  @override
  String get sourceDistributionNotice =>
      'Corresponding source and build materials must accompany distribution as required by the licenses. This is an unpublished development build.';

  @override
  String get versionUnavailable => 'Version information is unavailable.';

  @override
  String get coreVersion => 'mihomo version';

  @override
  String get refresh => 'Refresh';

  @override
  String get runtimeConfigExplanation =>
      'Live JSON settings returned by the core’s public interface.';

  @override
  String get runtimeConfigSearch => 'Find fields or values';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get runtimeConfigLoading => 'Reading core configuration…';

  @override
  String get runtimeConfigLive => 'Running';

  @override
  String get runtimeConfigPreview => 'Preview · VPN off';

  @override
  String get runtimeConfigStale => 'Previous snapshot · refresh to confirm';

  @override
  String get runtimeConfigEmpty =>
      'Select a configuration with saved content first.';

  @override
  String get runtimeConfigFailed => 'Read failed · check core status and retry';

  @override
  String get noSearchResults => 'No matching lines';

  @override
  String get nodeSearch => 'Name, provider or type';

  @override
  String get coreReadLoading => 'Reading core data…';

  @override
  String get coreReadFailed => 'Read failed · refresh to retry';

  @override
  String get coreSnapshotStale => 'Previous snapshot · not current';

  @override
  String get sourceConfiguration => 'Configuration';

  @override
  String get builtinNode => 'Built-in';

  @override
  String get nodeHistoryNotice =>
      'Node capabilities and test-history snapshot, with test URLs redacted.';

  @override
  String get previousPage => 'Previous page';

  @override
  String get nextPage => 'Next page';

  @override
  String get noNodes => 'No matching nodes';

  @override
  String get details => 'Details';

  @override
  String get mainRules => 'Main rules';

  @override
  String get subRules => 'Sub-rules';

  @override
  String get ruleSets => 'Rule sets';

  @override
  String get ruleScope => 'Rule scope';

  @override
  String get ruleSearch => 'Type, content or target';

  @override
  String get noRules => 'No matching rules';

  @override
  String get compiledRules => 'Effective declaration order';

  @override
  String get normalizedRules => 'Normalized rule-set entries';

  @override
  String get sourceRules => 'Source entries · not compiled rules';

  @override
  String get ruleSourceNotice =>
      'Domain and IP-CIDR sets contain normalized entries. Classical sets display inline payload, cached content, or the configured fallback.';

  @override
  String get ruleTarget => 'Target';

  @override
  String get ruleContent => 'Content';

  @override
  String get ruleSourceUnavailable =>
      'Reading the local source for this rule set failed.';

  @override
  String get ruleSourceInvalid =>
      'The provider\'s local source is unreadable or malformed.';

  @override
  String get ruleSourceChanged =>
      'The rule source changed while reading. Refresh to read a consistent snapshot.';

  @override
  String get ruleSourceUnsupported =>
      'This source format is not readable through the public API.';

  @override
  String get resourcesExplanation =>
      'Lists the core’s proxy providers, rule providers, and Geo databases. Sources show scheme and host. Update times come from core records or local file modification times; counts show current entries.';

  @override
  String get resourceSearch => 'Name, type or source';

  @override
  String get noResources => 'No matching resources';

  @override
  String get resourceProxyProvider => 'Proxy provider';

  @override
  String get resourceRuleProvider => 'Rule provider';

  @override
  String get resourceGeo => 'Geo database';

  @override
  String resourceCountValue(int count) {
    return '$count entries';
  }

  @override
  String resourceUpdatedAt(String time) {
    return 'Core-reported update time: $time';
  }

  @override
  String get resourceUpdateUnknown => 'The core reported no update time';

  @override
  String get resourceFilePresent => 'Local file present';

  @override
  String get resourceAutoTarget => 'Core auto-update target';

  @override
  String get resourceNotAutoTarget => 'Not an auto-update target';

  @override
  String get resourceAutoScope =>
      'Update targets follow the core process records and can include databases used by earlier configurations.';

  @override
  String resourceFileModifiedAt(String time) {
    return 'File modified: $time';
  }

  @override
  String resourceLastCheckAt(String time) {
    return 'Last successful check: $time';
  }

  @override
  String resourceUpdateInterval(String interval) {
    return 'Update interval: $interval';
  }

  @override
  String get resourceWatchFile => 'Watch local file changes';

  @override
  String get resourceFileMissing => 'Local file missing';

  @override
  String get resourceFileUnreadable => 'Local file unreadable';

  @override
  String get resourceEnabled => 'Enabled';

  @override
  String get resourceDisabled => 'Disabled';

  @override
  String resourceBuiltInBehavior(String behavior) {
    return 'Behavior: $behavior';
  }

  @override
  String get resourceUpdate => 'Update';

  @override
  String get resourceUpdating => 'Updating…';

  @override
  String get resourceUpdateStopped =>
      'The core stopped before the update finished';

  @override
  String get resourceUpdateFailed =>
      'Update did not finish; previous data was kept';

  @override
  String get resourceUpdateSuccess =>
      'Update finished; refresh to see the core\'s new state';

  @override
  String get resourceNoExternalSource =>
      'Inline or built-in resources have no external source';

  @override
  String get coreLogsExplanation =>
      'The current session keeps up to 1,000 log entries / 1 MiB in memory. Field redaction and marked truncation are applied; review sensitive information when reading or copying.';

  @override
  String get logLevel => 'Level';

  @override
  String get logSearch => 'Search log text';

  @override
  String get logLevelDebug => 'Debug and above';

  @override
  String get logLevelInfo => 'Info and above';

  @override
  String get logLevelWarning => 'Warning and above';

  @override
  String get logLevelError => 'Errors only';

  @override
  String get noLogs => 'No log entries in this session yet';

  @override
  String logDropped(int count) {
    return '$count entries dropped due to buffer limits';
  }

  @override
  String logTotal(int count) {
    return '$count in buffer';
  }

  @override
  String get logClearLocal => 'Clear local window';

  @override
  String get logBackToLatest => 'Back to latest';

  @override
  String get logClearNotice =>
      'Clearing affects only this page\'s buffer; it does not change system logs or core settings.';

  @override
  String get logTruncated => 'Truncated';

  @override
  String get delayTestGroup => 'Test group';

  @override
  String get delayTestMember => 'Test this member';

  @override
  String get delayTesting => 'Testing…';

  @override
  String delayTarget(String url) {
    return 'Target: $url · HTTP delay, not ICMP';
  }

  @override
  String get delayPending => 'Not tested';

  @override
  String get delayRunning => 'Testing';

  @override
  String get delayFailed => 'Failed';

  @override
  String get delayTimeout => 'Timed out';

  @override
  String get delayExpired => 'Result expired';

  @override
  String get delayStartFailed => 'Could not start the delay test';

  @override
  String get delayReadFailed => 'Could not read the delay results';

  @override
  String delayProgress(int done, int total) {
    return '$done/$total tested';
  }

  @override
  String get delayDone => 'Test complete';

  @override
  String delayTargetOnly(String url) {
    return 'Test target: $url';
  }

  @override
  String get delayUnavailable => 'This group cannot be tested';

  @override
  String get delayBatchFailed => 'Batch expired; test again';

  @override
  String get overridePlugins => 'Plugins (override)';

  @override
  String get addOverride => 'Add plugin';

  @override
  String get newOverride => 'New local plugin';

  @override
  String get remoteOverride => 'Add from URL';

  @override
  String get overrideLocal => 'Local';

  @override
  String get overrideRemote => 'Remote';

  @override
  String get overrideEnabled => 'Enabled';

  @override
  String get overrideDisabled => 'Disabled';

  @override
  String get overridePrepend => 'Prepend merge';

  @override
  String get overrideReplace => 'Replace same settings';

  @override
  String get overrideMoveUp => 'Move up';

  @override
  String get overrideMoveDown => 'Move down';

  @override
  String get overrideReadOnly => 'Remote plugin text is read-only';

  @override
  String get overrideEmpty => 'No plugins added yet.';

  @override
  String get overrideNotice =>
      'Higher items take priority. Changes to running content reconnect the tunnel.';

  @override
  String get loonProxyName => 'Proxy name';

  @override
  String get loonProxyNameHint =>
      'Only for Loon rules. Leave blank to keep explicit targets and comment out targetless rules. Built-in targets stay unchanged.';

  @override
  String get loonAddNoResolve => 'Add no-resolve to Loon IP rules';

  @override
  String get overrideContentUnsupported =>
      'The remote plugin is not a valid YAML configuration fragment or a recognizable Loon plugin.';

  @override
  String get loonProxyNameInvalid =>
      'The proxy name must not contain commas, line breaks or control characters.';

  @override
  String loonConvertedResult(String result, int rules, int comments) {
    return '$result\n\nExtracted $rules compatible rules; retained $comments source lines as comments.';
  }

  @override
  String loonNoRulesResult(String result, int comments) {
    return '$result\n\nNo compatible rules were extracted. The plugin leaves existing rules unchanged; $comments source lines were retained as comments.';
  }

  @override
  String get overrideName => 'Plugin name';

  @override
  String get overrideSource => 'Plugin URL';

  @override
  String get overrideUpdate => 'Update';

  @override
  String get overrideDelete => 'Delete';

  @override
  String get overrideDeleteTitle => 'Delete plugin?';

  @override
  String get overrideDeleteMessage =>
      'This plugin will be removed from the saved list. If the active tunnel uses it, the tunnel reconnects and existing connections close. Deleting it does not start a stopped tunnel.';

  @override
  String get localYamlInvalid =>
      'The content is not a valid single YAML object. Correct it in the text editor first.';

  @override
  String get localYamlInvalidStructure =>
      'The target definition has an invalid structure or field type. The content was not changed.';

  @override
  String get localYamlDuplicateName =>
      'A definition with this name already exists in local customizations.';

  @override
  String get localYamlAliasTarget =>
      'The target uses a shared YAML anchor or alias. Edit it in the text editor.';

  @override
  String get localYamlInheritedTarget =>
      'The target is inherited through a YAML merge. Edit it in the text editor.';

  @override
  String get localYamlUnsafeStructure =>
      'The content is nested too deeply or expands too many aliases to edit safely.';

  @override
  String get localYamlUnsupportedEdit =>
      'This definition cannot be changed while preserving the rest of the content. Use the text editor.';

  @override
  String get localYamlUnsupportedField =>
      'This field\'s original value cannot be represented by this form. It is preserved unchanged; use the text editor to modify it.';

  @override
  String get definitionFormUnsetField => 'Unset field';

  @override
  String definitionFormEditItem(String label, int index) {
    return 'Edit $label item $index';
  }

  @override
  String definitionFormValueCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count values',
      one: '1 value',
    );
    return '$_temp0';
  }

  @override
  String provenancePlugins(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count contributing plugins',
      one: '1 contributing plugin',
    );
    return '$_temp0';
  }

  @override
  String get provenanceHeading => 'Contributing plugins';

  @override
  String get provenanceProviderHeading => 'Definition contributors';

  @override
  String get strategyGroupFormTitle => 'Add strategy group';

  @override
  String get strategyGroupFormType => 'Group type';

  @override
  String get strategyGroupFormMembers => 'Members';

  @override
  String get strategyGroupFormProviders => 'Proxy provider references';

  @override
  String get strategyGroupEditTitle => 'Edit local strategy group';

  @override
  String get strategyGroupDefinitionTitle => 'Group properties';

  @override
  String get strategyGroupSourceConfiguration => 'Main configuration';

  @override
  String get strategyGroupSourceCore => 'Generated by the core';

  @override
  String get strategyGroupSourceUnknown => 'Source unconfirmed';

  @override
  String get strategyGroupPluginContribution => 'Plugin contribution';

  @override
  String get strategyGroupSourceReadOnly =>
      'These attributes come from the strategy group’s actual runtime data. This page is read-only.';

  @override
  String get strategyGroupAttributesHeading => 'Actual attributes';

  @override
  String get strategyGroupNoMembers => 'No members';

  @override
  String get strategyGroupInlineIcon => 'Configured icon';

  @override
  String strategyGroupFixedValue(String name) {
    return 'Pinned: $name';
  }

  @override
  String strategyGroupLoadedValue(String name) {
    return 'Current: $name';
  }

  @override
  String get strategyGroupNotSelected => 'No current member';

  @override
  String get providerProxyFormTitle => 'Add proxy provider';

  @override
  String get providerRuleFormTitle => 'Add rule provider';

  @override
  String get providerFormType => 'Source type';

  @override
  String get providerFormSource => 'Source & download';

  @override
  String get providerFormHeaders => 'Request headers';

  @override
  String get providerFormDownloadProxy => 'Download proxy';

  @override
  String get providerFormHealthCheck => 'Health check';

  @override
  String get providerFormOverride => 'Proxy overrides';

  @override
  String get providerFormPayload => 'Inline payload';

  @override
  String get providerFormAddProxy => 'Add inline proxy';

  @override
  String get providerFormEditProxy => 'Edit inline proxy';

  @override
  String get providerFormProxyNames => 'Name replacements';

  @override
  String get providerFormExpressions => 'Override expressions';

  @override
  String get providerFormPattern => 'Pattern';

  @override
  String get providerFormReplacement => 'Replacement';

  @override
  String get providerFormPathHint =>
      'Relative to managed resource storage; absolute and parent paths are not accepted.';

  @override
  String get providerFormInvalidPath => 'Invalid path';

  @override
  String get providerFormInvalidUrl => 'Enter an HTTP or HTTPS URL';

  @override
  String get providerFormMRSClassical => 'MRS does not support classical';

  @override
  String get providerFormAndroidIgnored =>
      'The current Android integration does not use interface-name, routing-mark or TFO.';

  @override
  String get ruleFormTitle => 'Add rule';

  @override
  String get ruleFormType => 'Rule type';

  @override
  String get ruleFormMatch => 'Match value';

  @override
  String get ruleFormTarget => 'Target';

  @override
  String get ruleFormProvider => 'Rule provider';

  @override
  String get ruleFormSubRule => 'Sub-rule set';

  @override
  String get ruleFormCondition => 'Native condition expression';

  @override
  String get ruleFormUnrepresentable =>
      'This field cannot be preserved by the rule format';

  @override
  String get ruleFormTargetHint =>
      'Target names cannot contain commas or surrounding spaces.';

  @override
  String get ruleFormSrcHint => 'src already implies no-resolve.';

  @override
  String get ruleFormIdentityNotice =>
      'The current Android integration does not provide per-connection process or UID identity; these rules may not match.';

  @override
  String get definitionFormMoveUp => 'Move up';

  @override
  String get definitionFormMoveDown => 'Move down';

  @override
  String get providerFormFallbackPayload => 'Fallback inline payload';

  @override
  String get definitionFormSuggestions => 'Choose a suggestion';

  @override
  String get proxyFormTitle => 'Add proxy';

  @override
  String get proxyFormType => 'Proxy type';

  @override
  String get proxyFormBasic => 'Basics';

  @override
  String get proxyFormProtocol => 'Protocol';

  @override
  String get proxyFormAdvanced => 'Advanced';

  @override
  String get proxyCategoryStandard => 'Standard proxy protocols';

  @override
  String get proxyCategoryCommunity => 'Community proxy protocols';

  @override
  String get proxyCategoryVpn => 'VPN protocols';

  @override
  String get proxyCategoryBuiltin => 'Built-in handlers';

  @override
  String get proxyBuiltinDescription => 'Core handlers, not proxy protocols.';

  @override
  String get proxyOptional => 'Optional';

  @override
  String get proxyUnset => 'Not set';

  @override
  String get proxyTrue => 'On';

  @override
  String get proxyFalse => 'Off';

  @override
  String get proxyRequired => 'Enter a value.';

  @override
  String get proxyInvalidInteger => 'Enter a valid integer.';

  @override
  String get proxyInvalidDecimal => 'Enter a valid number.';

  @override
  String get proxyInvalidPort => 'Use an integer port from 0 to 65535.';

  @override
  String get proxyInvalidByte => 'Use an integer from 0 to 255.';

  @override
  String get proxyDuplicateKey => 'Duplicate key.';

  @override
  String get proxyMapKey => 'Key';

  @override
  String get proxyMapValue => 'Value';

  @override
  String get proxyPlatformIgnored =>
      'This field is not applied by the current Android integration.';

  @override
  String get proxySaveFailed =>
      'Saving or connecting did not complete. Your input is kept.';

  @override
  String get proxyServer => 'Server';

  @override
  String get proxyUsername => 'Username';

  @override
  String get proxyShowSecret => 'Show sensitive value';

  @override
  String get proxyHideSecret => 'Hide sensitive value';

  @override
  String get proxyPassword => 'Password';

  @override
  String get proxyName => 'Proxy name';

  @override
  String get proxyUnitBytes => 'bytes';

  @override
  String get proxyUnitSeconds => 's';

  @override
  String get proxyUnitMilliseconds => 'ms';

  @override
  String get proxyUnitNanoseconds => 'ns';

  @override
  String get proxyUnitMbps => 'Mbps';

  @override
  String get proxyUnitPackets => 'packets';

  @override
  String proxyAddItem(String field) {
    return 'Add $field';
  }

  @override
  String proxyRemoveItem(String field, int index) {
    return 'Remove $field item $index';
  }

  @override
  String get localCustomTitle => 'Local customizations';

  @override
  String get localCustomDisabled =>
      'This plugin is disabled. Saving does not enable it.';

  @override
  String get moreLabel => 'More';

  @override
  String get continueLabel => 'Continue';

  @override
  String get operationFailed => 'Operation not completed';

  @override
  String get applicationListFailed =>
      'Could not read the installed application list.';

  @override
  String get applicationAllowEmpty =>
      'Select at least one application in the selected-only mode.';

  @override
  String get applicationReconnectTitle => 'Save and reconnect?';

  @override
  String get applicationReconnectMessage =>
      'Saving will normally stop the current tunnel and reconnect with the current configuration and mode. Existing connections will drop. The setting is kept if reconnecting fails.';

  @override
  String get applicationReconnect => 'Save and reconnect';

  @override
  String get applicationSavedReconnected =>
      'Application access saved and the tunnel reconnected.';

  @override
  String get applicationSaved =>
      'Application access saved; it applies on the next connection.';

  @override
  String get applicationAccessNotice =>
      'The selected application scope is routed through the VPN; other applications use the system network. Reconnect after saving to apply the new settings.';

  @override
  String get searchApplications => 'Search name or package';

  @override
  String get accessAll => 'All applications';

  @override
  String get accessOnly => 'Only selected';

  @override
  String get accessExcept => 'Exclude selected';

  @override
  String get showSystemApps => 'Show system applications';

  @override
  String selectedCount(int count) {
    return '$count selected';
  }

  @override
  String get discardChanges => 'Discard unsaved changes?';

  @override
  String get discardApplicationChanges =>
      'This selection only exists on this page and will not be saved.';

  @override
  String get discard => 'Discard';

  @override
  String get continueEditing => 'Continue editing';

  @override
  String get alwaysOnTitle => 'Always-on VPN';

  @override
  String get alwaysOnNotice =>
      'Always-on is managed by Android. When enabled, the system starts this app as needed and can restore the most recently saved configuration after unlock. The app cannot bypass the system to disable it.';

  @override
  String get alwaysOnUnknown => 'Confirm the current state in system settings.';

  @override
  String get alwaysOnEnabled => 'System state: on';

  @override
  String get alwaysOnDisabled => 'System state: off';

  @override
  String get lockdownEnabled => 'Block connections without VPN: on';

  @override
  String get lockdownDisabled => 'Block connections without VPN: off';

  @override
  String get lockdownTitle => 'Block connections without VPN';

  @override
  String get lockdownNotice =>
      'Lockdown is managed by Android; the app never enables it.';

  @override
  String get openVpnSettings => 'Open system VPN settings';

  @override
  String get alwaysOnRestoreNotice =>
      'System restore uses the most recently saved main configuration, mode, plugins and application access. No tunnel is established before unlock.';

  @override
  String get alwaysOnOpenFailed =>
      'Could not open system VPN settings; find VPN in system settings.';

  @override
  String get androidSection => 'Android';

  @override
  String get autoUpdate => 'Auto-update';

  @override
  String get autoUpdateOff => 'Off';

  @override
  String autoUpdateEvery(int hours) {
    return 'Every $hours hours';
  }

  @override
  String get autoUpdateInterval => 'Interval';

  @override
  String get autoUpdateNotice =>
      'System scheduling may be delayed and use mobile data. Failed downloads keep existing content.';

  @override
  String get autoUpdateEnabled => 'Auto-update enabled';

  @override
  String get autoUpdateDisabled => 'Auto-update off';

  @override
  String get autoUpdateSaved => 'Updated and saved';

  @override
  String get autoUpdateApplied => 'Updated and applied';

  @override
  String get autoUpdateApplyFailed => 'Updated and saved; connection failed';

  @override
  String get autoUpdateFailed => 'Last auto-update failed';

  @override
  String get autoUpdateUnchanged => 'No change at last check';

  @override
  String get autoUpdateAttempt => 'Last check';

  @override
  String get autoUpdateNever => 'Not checked yet';

  @override
  String get applicationPolicyNextConnection =>
      'The saved policy will be used on the next connection.';

  @override
  String get applicationPolicyApplied => 'The saved policy is in use.';

  @override
  String get applicationPolicyPending =>
      'Saved policy is not in use. Save again to retry reconnecting.';

  @override
  String get applicationPolicyUnknown =>
      'Running policy is unconfirmed. Save again to reconnect and verify.';

  @override
  String get strategyGroupMissing => 'Group no longer exists';

  @override
  String get strategyTypeChanged => 'Group type changed';

  @override
  String get strategyNotSelectable => 'Group does not support selection';

  @override
  String get strategyMemberMissing => 'Selected member no longer exists';

  @override
  String get statusLoading => 'Fetching status';

  @override
  String get statusSubmitting => 'Submitting request';

  @override
  String get statusProcessing => 'Working';

  @override
  String get stateRunning => 'Tunnel running';

  @override
  String get stateStopped => 'Tunnel stopped';

  @override
  String get stateStarting => 'Starting';

  @override
  String get stateStopping => 'Stopping';

  @override
  String get stateUnknown => 'Status unconfirmed';

  @override
  String get statusIssue => 'Status issue · View details';

  @override
  String get statusPending => 'Unavailable until status is confirmed';

  @override
  String get statusAutoRetry => 'Cannot read status yet, retrying';

  @override
  String get statusPlatformUnconfirmed =>
      'Platform has not confirmed resources';

  @override
  String get statusWaiting => 'Waiting for the tunnel result';

  @override
  String get statusConfigFailed =>
      'Cannot read configurations; management is still available';

  @override
  String get statusConfigLoading => 'Reading saved configurations';

  @override
  String get statusImportPrompt => 'Import a full configuration to start';

  @override
  String get statusReimport => 'The current configuration must be re-imported';

  @override
  String get statusReady => 'Ready to start';

  @override
  String get identityUnconfirmed => 'Configuration unconfirmed';

  @override
  String get identityLoading => 'Reading configuration';

  @override
  String get identityNoConfig => 'No configuration imported';

  @override
  String identitySelected(String name) {
    return 'Selected: $name';
  }

  @override
  String get identityNone => 'None';

  @override
  String get identityRevisionDiff =>
      'Running version differs from the saved version';

  @override
  String get identitySelectedUnconfirmed => 'Selected · not confirmed in use';

  @override
  String get actionUnavailable => 'Unavailable';

  @override
  String get actionBusy => 'Working…';

  @override
  String get actionStarting => 'Starting…';

  @override
  String get actionStopping => 'Stopping…';

  @override
  String get actionStop => 'Stop tunnel';

  @override
  String get actionStart => 'Start tunnel';

  @override
  String get importConfig => 'Import configuration';

  @override
  String get configManage => 'Configurations';

  @override
  String get tunnelStatus => 'Tunnel status';

  @override
  String get modeUnconfirmed => 'Mode · Unconfirmed';

  @override
  String get modeRunningUnconfirmed => 'Running mode unconfirmed';

  @override
  String modeRunning(String mode) {
    return '$mode mode';
  }

  @override
  String modeSavedIdle(String mode) {
    return '$mode mode · Not running';
  }

  @override
  String get modeSavedUnconfirmed => 'Saved mode unconfirmed';

  @override
  String get modeRule => 'Rule';

  @override
  String get modeGlobal => 'Global';

  @override
  String get modeDirect => 'Direct';

  @override
  String get modeRuleDescription => 'Route by the rules in your configuration.';

  @override
  String get modeGlobalDescription => 'Route through the global policy.';

  @override
  String get modeDirectDescription => 'Connect directly and keep the tunnel.';

  @override
  String get networkActivity => 'Network activity';

  @override
  String get waitingTakeover => 'Waiting for the tunnel';

  @override
  String get waitingStatusSync => 'Waiting for status';

  @override
  String get updateFailed => 'Update failed';

  @override
  String get waitingUpdate => 'Waiting for update';

  @override
  String get waitingSample => 'Waiting for samples';

  @override
  String get trafficConnections => 'Connections';

  @override
  String get download => 'Download';

  @override
  String get upload => 'Upload';

  @override
  String activitySummary(String label, String value, String unit) {
    return '$label $value $unit, recent connections';
  }

  @override
  String get modeTitle => 'Tunnel mode';

  @override
  String get modeReadFailed => 'Cannot read the mode';

  @override
  String get modeDiffers => 'Running mode and saved fallback';

  @override
  String modeSaved(String mode) {
    return 'Saved fallback: $mode; used only if the configuration does not specify a mode.';
  }

  @override
  String modeActualDiffers(String mode) {
    return 'Running: $mode. A configuration-defined mode can differ from the saved fallback.';
  }

  @override
  String get modeHint =>
      'Choosing a mode switches the running tunnel immediately. When stopped, only a fallback is saved; it is used only if the configuration does not specify a mode.';

  @override
  String get modeFollowConfigIdle => 'Configuration mode · Not running';

  @override
  String get notProvided => 'Not provided';

  @override
  String get allRules => 'All rules';

  @override
  String get allConnections => 'All connections';

  @override
  String get activeOnly => 'Active';

  @override
  String get inactiveOnly => 'Inactive';

  @override
  String get recordLimitReached => 'Record limit reached';

  @override
  String get connectionUpdating => 'Updating';

  @override
  String get connectionRefreshFailed => 'Refresh failed';

  @override
  String get connectionRefreshRetrying => 'Refresh failed, retrying';

  @override
  String get takeoverStopped => 'Tunnel stopped';

  @override
  String get statusUnconfirmed => 'Status unconfirmed';

  @override
  String get exitSearch => 'Exit search';

  @override
  String get searchConnections => 'Search connections';

  @override
  String get searchStrategies => 'Search strategies';

  @override
  String get noMatchingStrategies => 'No matching strategy groups';

  @override
  String get filterMatchedRule => 'Filter by matched rule';

  @override
  String get noMatchingConnections => 'No matching connections';

  @override
  String get noRecentConnections => 'No recent connections';

  @override
  String get noConnections => 'No connections yet';

  @override
  String get connectionActive => 'Active';

  @override
  String get connectionPending => 'Unconfirmed';

  @override
  String get connectionInactive => 'Inactive';

  @override
  String get disconnectFailedTitle => 'Disconnect not completed';

  @override
  String get targetIp => 'Destination IP';

  @override
  String get sourceAddress => 'Source';

  @override
  String get inbound => 'Inbound';

  @override
  String get connectionDetails => 'Connection details';

  @override
  String get disconnecting => 'Disconnecting';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get fieldsTruncated => 'Some long fields are truncated';

  @override
  String get connectionStatus => 'Connection status';

  @override
  String portLabel(String port) {
    return 'Port $port';
  }

  @override
  String get routingResult => 'Routing result';

  @override
  String get matchedRule => 'Matched rule';

  @override
  String get traffic => 'Traffic';

  @override
  String get startTime => 'Started';

  @override
  String get durationLabel => 'Duration';

  @override
  String get connectionInfo => 'Connection information';

  @override
  String get connectionClosed => 'Disconnected';

  @override
  String get connectionReplaced => 'Session changed';

  @override
  String cumulative(String bytes) {
    return 'Total $bytes';
  }

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String durationMinutesSeconds(int minutes, int seconds) {
    return '$minutes min $seconds s';
  }

  @override
  String durationSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String get connectionInfoTimeTitle => 'Time';

  @override
  String get showHiddenGroups => 'Show hidden groups';

  @override
  String get hideHiddenGroups => 'Hide hidden groups';

  @override
  String get strategyGroups => 'Strategies';

  @override
  String get actualConfigUnconfirmed => 'Actual configuration unconfirmed';

  @override
  String get noConfigSelected => 'No configuration selected';

  @override
  String get confirmingConfig => 'Confirming configuration';

  @override
  String get strategiesNotUpdated => 'Strategies not updated';

  @override
  String get loadingStrategies => 'Loading strategies…';

  @override
  String get selectionsNotRestored => 'Some selections were not restored';

  @override
  String get underTakeover => 'Under tunnel';

  @override
  String get notUnderTakeover => 'Not under tunnel · Preselected';

  @override
  String get viewUnrestored => 'View selections not restored';

  @override
  String get viewStrategyError => 'View strategy error';

  @override
  String get strategyStatus => 'Strategy status';

  @override
  String get waitingTakeoverConfig =>
      'Waiting for the tunnel and configuration status.';

  @override
  String get importConfigForStrategies =>
      'Import and select a full configuration to view strategies.';

  @override
  String get preparingStrategies => 'Preparing strategies…';

  @override
  String get strategiesNotLoaded => 'Strategies have not loaded.';

  @override
  String get strategiesLoadFailed =>
      'Strategies did not load; check the error and retry.';

  @override
  String get loadStrategies => 'Load strategies';

  @override
  String get noVisibleGroups =>
      'No strategy groups are visible in the current mode.';

  @override
  String unrestoredLine(String name, String value) {
    return '$name: $value';
  }

  @override
  String fixedTo(String name) {
    return 'Pinned: $name';
  }

  @override
  String get notUpdated => 'Not updated';

  @override
  String get unconfirmed => 'Unconfirmed';

  @override
  String get popupExpired =>
      'This strategy is no longer valid. Close and reopen it; this content is read-only.';

  @override
  String popupSavedDiffers(String name) {
    return 'Saved: $name; the actual selection is still shown by the current mark.';
  }

  @override
  String get popupSavedDiffersAuto =>
      'Saved: auto; the actual selection is still shown by the current mark.';

  @override
  String popupNotRestored(String reason) {
    return 'Original selection not restored: $reason';
  }

  @override
  String get popupExpiredShort => 'Expired · Reopen';

  @override
  String get popupSwitching => 'Switching…';

  @override
  String get popupUpdateFailed => 'Update failed · View reason';

  @override
  String get popupSavedDiffersShort =>
      'Saved differs from actual · View details';

  @override
  String get popupNotRestoredShort =>
      'Original selection not restored · View details';

  @override
  String get popupStale => 'Status not updated';

  @override
  String get popupReading => 'Reading strategy';

  @override
  String get autoLabel => 'Auto';

  @override
  String get restoreAuto => 'Restore auto';

  @override
  String get sameNameMember => 'Same-name member';

  @override
  String get pinned => 'Pinned';

  @override
  String get closeStrategyPopup => 'Close strategy popup';

  @override
  String get strategyChoiceSelect => 'Manual select';

  @override
  String get strategyChoiceUrlTest => 'Auto test';

  @override
  String get strategyChoiceFallback => 'Fallback';

  @override
  String get strategyChoiceLoadBalance => 'Load balance';

  @override
  String get strategyReadStale =>
      'Strategy status has not refreshed; the foreground will retry automatically. Old records cannot be used to switch.';

  @override
  String get strategyContextChanged =>
      'The strategy context changed; wait for the current configuration to be read again.';

  @override
  String get strategyGroupChanged =>
      'The strategy group or member changed; this selection was not saved.';

  @override
  String get applyingStrategy => 'Applying the strategy selection';

  @override
  String get strategySelectionUnconfirmed =>
      'The selection was saved for the next load; this switch was not confirmed.';

  @override
  String get operationNotCompleted => 'Operation not completed';

  @override
  String get configUpdated => 'Configuration updated.';

  @override
  String get settingsSaved => 'Settings saved.';

  @override
  String get operationInProgress => 'Another operation is already running.';

  @override
  String get platformOperationFailed =>
      'The platform operation did not finish; verify the tunnel state.';

  @override
  String get operationNotCompletedRetry =>
      'Operation not completed; verify the state and retry.';

  @override
  String get configTitle => 'Configurations';

  @override
  String get configReading => 'Configurations · Reading';

  @override
  String get configStale => 'Configurations · Not updated';

  @override
  String get configReadFailed => 'Could not read configurations';

  @override
  String get noSavedConfigs => 'No saved configurations';

  @override
  String get importOrCreateHint =>
      'Import from a URL or file, or create a local configuration.';

  @override
  String get importFromUrl => 'Import from URL';

  @override
  String get importFromFile => 'Import from file';

  @override
  String get newLocalConfig => 'New local configuration';

  @override
  String get addConfig => 'Add configuration';

  @override
  String get localConfig => 'Local configuration';

  @override
  String nativeConfigurationUnsupported(String field, String reason) {
    return 'Unsupported configuration field $field: $reason';
  }

  @override
  String get nativeReasonTunDisabled =>
      'A VPN connection requires TUN to be enabled.';

  @override
  String get nativeReasonControllerUnavailable =>
      'External controller interfaces and their web UI are currently unsupported.';

  @override
  String get nativeReasonRootRedirection =>
      'This traffic redirection requires privileged system access that the app does not provide.';

  @override
  String get nativeReasonTransparentSockets =>
      'Transparent proxy sockets require privileged system access that the app does not provide.';

  @override
  String get nativeReasonInterfaceBinding =>
      'The app\'s socket protection does not support binding to a specified physical network interface.';

  @override
  String get nativeReasonRoutingMark =>
      'Linux routing marks are not supported by this Android VPN integration.';

  @override
  String get nativeReasonTcpFastOpen =>
      'The app\'s socket integration does not provide TCP Fast Open.';

  @override
  String get nativeReasonFirewall =>
      'Managing iptables requires root access and is not supported by the app.';

  @override
  String get nativeReasonSystemClock =>
      'The app cannot change the system clock through NTP.';

  @override
  String get nativeReasonExternalFd =>
      'Only the file descriptor created for this VPN session by Android VpnService is allowed.';

  @override
  String get nativeReasonInterfaceName =>
      'The Android VPN interface is created by the system and cannot be renamed using this setting.';

  @override
  String get nativeReasonGso =>
      'The Android VPN interface does not expose a configurable GSO option.';

  @override
  String get nativeReasonAutoRedirect =>
      'Automatic redirection requires netlink and firewall operations that this Android VPN integration does not provide.';

  @override
  String get nativeReasonLinuxRouting =>
      'This setting requires privileged Linux routing table or routing rule operations that the app does not provide.';

  @override
  String get nativeReasonInterfaceFilter =>
      'This Android VPN integration cannot apply network interface filters at this layer.';

  @override
  String get nativeReasonMacFilter =>
      'This Android VPN integration cannot apply MAC address filters at this layer.';

  @override
  String get nativeReasonPortFilter =>
      'This Android VPN integration cannot apply source or destination port filters at this layer.';

  @override
  String get nativeReasonStrictRoute =>
      'Android VpnService cannot implement the Linux strict-routing rules required by this setting.';

  @override
  String get nativeReasonDnsHijackConflict =>
      'DNS hijacking cannot be configured while DNS is disabled.';

  @override
  String get nativeReasonIpv6Unavailable =>
      'The requested IPv6 address or address pool is unavailable because IPv6 is disabled or unavailable on this device.';

  @override
  String get nativeReasonInvalidMtu =>
      'The MTU must be between 1 and 65535, and at least 1280 when IPv6 is used.';

  @override
  String get nativeReasonInvalidAddress =>
      'The derived VPN interface address or its required next address is invalid.';

  @override
  String get nativeReasonSystemDnsUnavailable =>
      'DNS servers from the underlying non-VPN network are unavailable; public DNS is not used as a fallback.';

  @override
  String get nativeReasonPrivateDnsUnavailable =>
      'Strict Android Private DNS has no verified equivalent secure channel here; falling back to plaintext DNS is not allowed.';

  @override
  String get nativeReasonProviderPath =>
      'The provider path failed directory, symbolic-link, protected-file, or target-identity safety checks.';

  @override
  String get nativeReasonAndroidUserUnavailable =>
      'The app can enumerate and manage applications only for the current Android user; filters for other users or their UIDs are not supported.';

  @override
  String get storageContextChanged =>
      'The data was restored or replaced. Reopen this page. Unsubmitted input can still be copied and kept.';

  @override
  String get storageSyncUnconfirmed =>
      'The content was saved, but storage synchronization could not be confirmed. This change may be lost if power is suddenly interrupted.';

  @override
  String storageSyncWarning(String result) {
    return '$result\n\nThe content was saved, but storage synchronization could not be confirmed. This change may be lost if power is suddenly interrupted.';
  }

  @override
  String get storageUnavailable =>
      'Configurations, plugins and settings are temporarily unavailable. Wait for data recovery to be confirmed before continuing. Stopping the connection is still available.';

  @override
  String get trustedRootsUnavailable =>
      'Could not read or parse the default trusted root certificates. Try again.';

  @override
  String get nameInvalid =>
      'Enter a non-empty configuration name of at most 80 UTF-8 bytes.';

  @override
  String get operationBusyFile =>
      'Another operation is running; the file was not submitted. Wait and choose again.';

  @override
  String get importResultUnconfirmed =>
      'The import result was not confirmed. The list was re-read and the import was not retried; verify whether it was saved.';

  @override
  String get fileUnreadable =>
      'Could not read the selected file; no configuration was created. Check the file and retry.';

  @override
  String get runningOldBody => 'In use · Previous content';

  @override
  String get runningConfig => 'In use';

  @override
  String get updateConfig => 'Update configuration';

  @override
  String get editConfig => 'Edit configuration';

  @override
  String get moreActions => 'More actions';

  @override
  String get configActionFailed => 'Configuration action not completed';

  @override
  String get viewConfigError => 'View configuration error';

  @override
  String get rename => 'Rename';

  @override
  String get changeSourceUpdate => 'Change source and update';

  @override
  String autoUpdateHours(int hours) {
    return 'Auto-update: every $hours hours';
  }

  @override
  String get autoUpdateClosed => 'Auto-update (off)';

  @override
  String get viewBody => 'View content';

  @override
  String get delete => 'Delete';

  @override
  String updatedAt(String date, String time) {
    return 'Updated $date $time';
  }

  @override
  String savedAt(String date, String time) {
    return 'Saved $date $time';
  }

  @override
  String get updateTimeUnknown => 'Update time unknown';

  @override
  String get saveTimeUnknown => 'Save time unknown';

  @override
  String get deleteConfigTitle => 'Delete configuration?';

  @override
  String get deleteKeepsSelection =>
      'The current selection and tunnel are unchanged.';

  @override
  String get deleteNoSelection =>
      'After deletion there is no current configuration.';

  @override
  String deleteSelects(String name) {
    return 'After deletion \"$name\" is selected; the tunnel does not start automatically.';
  }

  @override
  String get deleteRemoteBody =>
      'The saved content and source will be deleted.';

  @override
  String get deleteLocalBody => 'The saved local content will be deleted.';

  @override
  String get renameConfig => 'Rename configuration';

  @override
  String get changeConfigSource => 'Change configuration source';

  @override
  String get configName => 'Configuration name';

  @override
  String get configUrl => 'Full configuration URL';

  @override
  String get configUrlInvalid => 'Full configuration URL, invalid input';

  @override
  String get configUrlHint =>
      'Enter a complete HTTP or HTTPS configuration URL.';

  @override
  String get showUrl => 'Show URL';

  @override
  String get hideUrl => 'Hide URL';

  @override
  String get nameOptional => 'Name (optional)';

  @override
  String get nameOptionalHint => 'Leave empty to use the source host name';

  @override
  String get importFullConfig => 'Import full configuration';

  @override
  String get importFullConfigNotice =>
      'Saves a complete mihomo configuration; the core parses it at start. Node subscriptions are not converted.';

  @override
  String get downloadAndSave => 'Download and save';

  @override
  String get saveAndUpdate => 'Save and update';

  @override
  String get overwriteConfigTitle => 'Overwrite configuration?';

  @override
  String get overwriteConfigMessage =>
      'This source is already saved. The existing entry will be updated.';

  @override
  String get overwriteKeepsOnFailure =>
      'The existing content and connection are kept if the download fails.';

  @override
  String get overwriteStopTunnel =>
      'If the running content changes, this configuration’s tunnel reconnects after the update succeeds.';

  @override
  String get overwriteNoOtherTunnel =>
      'Other configurations’ tunnels are not switched or stopped.';

  @override
  String get overwriteNotStart =>
      'The tunnel does not start automatically after updating.';

  @override
  String get overwriteUnconfirmed =>
      'Connection status is not yet confirmed. Applying the update depends on the actual running state.';

  @override
  String get overwrite => 'Overwrite';

  @override
  String get leaveBodyTitle => 'Leave the content?';

  @override
  String get leaveBodyMessage =>
      'A submitted save is not cancelled by leaving. The result is unconfirmed; check the configuration list and do not submit again.';

  @override
  String get leave => 'Leave';

  @override
  String get discardEditsTitle => 'Discard unsaved changes?';

  @override
  String get discardEditsMessage =>
      'This input exists only on this page and will not be saved.';

  @override
  String get nameRequired => 'Enter a configuration name.';

  @override
  String get normalizeNewlinesTitle => 'Normalize mixed line endings?';

  @override
  String get normalizeNewlinesMessage =>
      'This content uses more than one line ending style. Saving will normalize it to the primary style; the BOM is preserved.';

  @override
  String get normalizeAndSave => 'Normalize and save';

  @override
  String get submittedSavedTitle => 'Submitted version saved';

  @override
  String get submittedSavedMessage =>
      'The submitted content was saved; later edits remain in the editor and are not saved.';

  @override
  String get saveUnconfirmed =>
      'Save result unconfirmed. Configurations were re-read; check the list. The current input is kept and was not retried automatically.';

  @override
  String get savedApplyFailed => 'Saved, apply not completed';

  @override
  String get saveFailed => 'Save not completed';

  @override
  String get findBody => 'Find in content';

  @override
  String get previousMatch => 'Previous';

  @override
  String get nextMatch => 'Next';

  @override
  String get closeFind => 'Close find';

  @override
  String get readOnly => 'Read-only';

  @override
  String get saving => 'Saving';

  @override
  String get resultUnconfirmed => 'Result unconfirmed';

  @override
  String get tooLarge => 'Over 16 MiB · Not truncated';

  @override
  String get sizePending => 'Size pending · Recheck on save';

  @override
  String get unsavedChanges => 'Unsaved changes';

  @override
  String get configBody => 'Configuration content';

  @override
  String get find => 'Find';

  @override
  String get softWrap => 'Soft wrap';

  @override
  String get saveAndApply => 'Save and apply';

  @override
  String get bodyUnreadable => 'No usable content; update the source first.';

  @override
  String get bodyPrepFailed =>
      'Could not prepare the configuration content; go back and retry.';

  @override
  String editorLineTooLong(int line, int limit) {
    return 'Line $line exceeds $limit UTF-16 code units. Editing and wrapped preview are unavailable; the text is unchanged.';
  }

  @override
  String editorQueryTooLong(int limit) {
    return 'Find text is limited to $limit UTF-16 code units.';
  }

  @override
  String editorChangeTooLong(int line, int limit) {
    return 'Change rejected: line $line would exceed $limit UTF-16 code units. Existing input is unchanged.';
  }

  @override
  String get editorContextChanged =>
      'Editing is unavailable. Finish the current operation or reopen this content.';

  @override
  String get aboutTitle => 'About Clash Pseudo';

  @override
  String get licensesAndNotices => 'Licenses and third-party notices';

  @override
  String get goNativeDependencies => 'Go native runtime dependencies';

  @override
  String get androidDependencies => 'Android runtime dependencies';

  @override
  String get materialIconsFont => 'Material Icons font';

  @override
  String get legalBody =>
      'Original code is licensed under GPL-3.0-only. You may copy, modify and redistribute it under the GNU General Public License version 3. No warranty is provided to the extent permitted by law. Third-party components retain their own copyrights and licenses.\n\nLicense texts and bundled third-party notices are available below. Corresponding source and build materials must accompany any distribution; this is an unpublished development build.';

  @override
  String get projectTitle => 'Project';

  @override
  String get defaultLocalConfig =>
      '# Default direct configuration; the client still controls the mode and strategy choices.\nrules:\n  - MATCH,DIRECT\n';

  @override
  String get noUsableBodyReimport =>
      'This configuration has no usable content; update the source again.';

  @override
  String get noBodyUpdateSource =>
      'This configuration has no usable content; update the source first.';

  @override
  String get requestNotAccepted => 'The request was not accepted; try again.';

  @override
  String get temporaryModeUnknown =>
      'The running mode cannot be confirmed yet; the foreground will retry.';

  @override
  String get temporaryStatusUnavailable =>
      'Status is temporarily unavailable; the foreground will retry and will not start automatically.';

  @override
  String get temporaryConfigsUnreadable =>
      'Saved configurations cannot be read right now; the file was not changed.';

  @override
  String get temporaryOverridesUnreadable =>
      'Saved plugins cannot be read right now; the file was not changed.';

  @override
  String get temporarySettingsUnreadable =>
      'Saved settings cannot be read right now; the file was not changed.';

  @override
  String get failure => 'Failure';

  @override
  String get stageStopping => 'Stopping the tunnel';

  @override
  String get tunnelStopped => 'Tunnel stopped.';

  @override
  String get statusUnconfirmedVerify =>
      'Tunnel status is unconfirmed; verify the state first.';

  @override
  String get importAndSelectFirst => 'Import and select a configuration first.';

  @override
  String get configChangedWaitStrategies =>
      'The configuration changed; wait for strategies to reload.';

  @override
  String get coreNotReadyStrategies =>
      'Core resources are unconfirmed; strategies cannot load yet.';

  @override
  String get previewMismatch =>
      'The running configuration does not match the preview request.';

  @override
  String get stageLoadingStrategies => 'Loading the strategy configuration';

  @override
  String get localCannotRemoteUpdate =>
      'Local configurations cannot be updated remotely.';

  @override
  String get configRenamed => 'Configuration renamed.';

  @override
  String get alreadyRunning =>
      'The tunnel is already running; no need to start again.';

  @override
  String get tunnelStarted => 'Tunnel started.';

  @override
  String get unknownOperation => 'This operation is not recognized.';

  @override
  String get localCannotChangeRemote =>
      'Local configurations cannot change their remote source.';

  @override
  String sourceUsedBy(String name) {
    return 'This source is already used by \"$name\"; choose the existing configuration.';
  }

  @override
  String get sourceSavedConfirmOverwrite =>
      'This source is already saved; confirm that you want to overwrite it.';

  @override
  String get updateInterrupted =>
      'Update did not finish; update this source again.';

  @override
  String get stageDownloading => 'Downloading configuration';

  @override
  String get stageUpdatingConfig => 'Updating configuration';

  @override
  String get updateStateWriteFailed =>
      'The update state could not be saved, so the update did not start. The old record is unchanged; fix storage and retry.';

  @override
  String get stageStoppingOld => 'Stopping the previous tunnel';

  @override
  String get configUpdatedRestarted => 'Configuration updated and restarted.';

  @override
  String get configSavedParsedAtStart =>
      'Configuration saved; the core parses it at start.';

  @override
  String get configChangedReopen =>
      'The configuration was deleted, its content changed, or it is not editable. Reopen it; this input was not saved.';

  @override
  String get stageSavingConfig => 'Saving configuration';

  @override
  String get configSavedApplied => 'Configuration saved and applied.';

  @override
  String get configSavedApplyReleasePending =>
      'Configuration saved, but applying or releasing the old preview did not finish. Verify the tunnel state; the new content was kept.';

  @override
  String get configSaved => 'Configuration saved.';

  @override
  String get localNoAutoUpdate =>
      'Local configurations have no auto-update setting.';

  @override
  String get chooseUpdateInterval =>
      'Choose a 6, 12 or 24 hour update interval.';

  @override
  String get autoUpdateEnabledResult => 'Auto-update enabled.';

  @override
  String get autoUpdateDisabledResult => 'Auto-update off.';

  @override
  String get configNameInvalid =>
      'Enter a non-empty configuration name of at most 80 UTF-8 bytes.';

  @override
  String get switchedConfig => 'Running configuration switched.';

  @override
  String get configSelectedNotStarted =>
      'Configuration selected; the tunnel has not started.';

  @override
  String get stopBeforeDelete =>
      'Stop the tunnel before deleting the configuration in use.';

  @override
  String get configDeleted =>
      'Configuration deleted; the tunnel was not started.';

  @override
  String get modeSavedNextStart =>
      'Mode fallback saved; used on startup only if the configuration does not specify a mode.';

  @override
  String get modeConfirmed => 'Running mode confirmed.';

  @override
  String get stageSwitchingMode => 'Switching the running mode';

  @override
  String get modeNotConfirmed =>
      'Mode fallback saved, but this running-mode switch was not confirmed. The fallback is used on startup only if the configuration does not specify a mode.';

  @override
  String get modeSwitchedResult => 'Running mode switched.';

  @override
  String get alreadyRunningNoRestore =>
      'The tunnel is already running; no system restore is needed.';

  @override
  String get systemStartUnsupported =>
      'This platform does not support system start.';

  @override
  String get noConfigForSystemStart =>
      'No selected configuration is available; the system start was cancelled.';

  @override
  String get stagePreparingSystemStart => 'Preparing the system start';

  @override
  String get systemStartPrepared => 'System start prepared.';

  @override
  String get accessSavedNextConnection =>
      'Application access saved; it applies on the next connection.';

  @override
  String get accessSavedReconnectFailed =>
      'The running configuration is unavailable; the setting was saved but reconnecting did not finish.';

  @override
  String get stageReconnectAccess => 'Reconnecting to apply application access';

  @override
  String get accessSavedReconnected =>
      'Application access saved and the tunnel reconnected.';

  @override
  String get overridesSavedNextStart =>
      'Plugins saved; they apply on the next start.';

  @override
  String get runningConfigMissingOverrides =>
      'The running configuration is no longer in the list; plugins cannot be applied.';

  @override
  String get runningConfigNoBody =>
      'The running configuration has no usable content; it cannot restart.';

  @override
  String get overridesAppliedReconnected =>
      'Plugins applied and the tunnel reconnected.';

  @override
  String get stageWaitingVpnAuth => 'Waiting for VPN authorization';

  @override
  String get authorizationCancelled =>
      'Authorization was cancelled; the tunnel stays stopped.';

  @override
  String get stageStartingTunnel => 'Starting the tunnel';

  @override
  String get configMissingRefresh =>
      'The configuration no longer exists; refresh the list.';

  @override
  String get tunnelStartFailed => 'Tunnel did not start.';

  @override
  String get operationFinished => 'The operation has ended.';

  @override
  String get overrideMissingRefresh =>
      'The plugin no longer exists; refresh the list.';

  @override
  String get remoteOverrideReadOnly =>
      'Remote plugin text is read-only; change the source or create a local plugin.';

  @override
  String get overrideChangedReopen =>
      'The plugin text changed; reopen it before editing.';

  @override
  String get overrideSavedApplyLater => 'Plugin saved.';

  @override
  String get localOverrideNoRemoteUpdate =>
      'Local plugins cannot be updated remotely.';

  @override
  String get overrideNoBodyEnable =>
      'The plugin has no usable content; update it before enabling.';

  @override
  String get overrideSettingsSaved => 'Plugin settings saved.';

  @override
  String get overrideOrderChangedRefresh =>
      'The plugin list changed; refresh and reorder again.';

  @override
  String get overrideOrderSaved => 'Plugin order saved.';

  @override
  String get overrideDeleted => 'Plugin deleted.';

  @override
  String get unknownOverrideOperation =>
      'This plugin operation is not recognized.';

  @override
  String get localOverrideNoAutoUpdate =>
      'Local plugins have no auto-update setting.';

  @override
  String get overrideAutoUpdateEnabled => 'Plugin auto-update enabled.';

  @override
  String get overrideAutoUpdateDisabled => 'Plugin auto-update off.';

  @override
  String get overrideSourceExists =>
      'A plugin already uses this source; update the existing one.';

  @override
  String get overrideUpdateIncomplete => 'Update did not finish; try again.';

  @override
  String get overrideChangedNotApplied =>
      'The plugin changed; the download result was not applied.';

  @override
  String get overrideUpdatedApplyLater => 'Plugin updated.';

  @override
  String get overrideNameInvalid =>
      'Enter a non-empty plugin name of at most 80 UTF-8 bytes.';

  @override
  String get overridesUnreadable =>
      'Saved plugins could not be read; the file was not changed.';

  @override
  String get overridesSaveFailed =>
      'Saving plugins failed; check available storage and retry.';

  @override
  String get overrideBodyMissing =>
      'An enabled plugin has no usable content; update or disable it first.';

  @override
  String get overridesTooLarge =>
      'Enabled plugin content exceeds 16 MiB in total.';

  @override
  String get schedulesSynced => 'Auto-update schedules synced.';

  @override
  String get unknownUpdateTarget => 'This update target is not recognized.';

  @override
  String get targetGoneOrDisabled =>
      'The target no longer exists or auto-update is off.';

  @override
  String get configChangedDownloadUnapplied =>
      'The configuration changed; the download result was not applied.';

  @override
  String get configUnchanged => 'The configuration content did not change.';

  @override
  String get configUpdatedPending => 'Configuration updated and saved.';

  @override
  String get stageApplyingConfigUpdate => 'Applying the configuration update';

  @override
  String get configUpdatedReconnected =>
      'Configuration updated and reconnected.';

  @override
  String get configSavedReconnectIncomplete =>
      'Configuration saved, but reconnecting did not finish. Verify the tunnel state.';

  @override
  String get overrideUnchanged => 'The plugin content did not change.';

  @override
  String get overrideUpdatedEnableApply =>
      'Plugin updated; it takes effect when enabled.';

  @override
  String get overrideUpdatedPending => 'Plugin updated and saved.';

  @override
  String get runningConfigUnavailable =>
      'The running configuration is unavailable.';

  @override
  String get stageApplyingOverrideUpdate => 'Applying the plugin update';

  @override
  String get overrideUpdatedReconnected => 'Plugin updated and reconnected.';

  @override
  String get overrideSavedReconnectIncomplete =>
      'Plugin saved, but reconnecting did not finish. Verify the tunnel state.';

  @override
  String get urlRequired => 'Enter a complete HTTP or HTTPS configuration URL.';

  @override
  String get downloadTimeout =>
      'The download timed out; check the network and retry.';

  @override
  String get tlsFailed =>
      'HTTPS certificate or secure-connection verification failed; verification was not bypassed.';

  @override
  String get downloadNotUtf8 =>
      'The downloaded content is not valid UTF-8 text.';

  @override
  String get downloadFailed =>
      'Could not download the configuration; check the source and current network.';

  @override
  String get redirectInvalid =>
      'The configuration source redirect is invalid or too frequent.';

  @override
  String downloadHttpStatus(String status) {
    return 'Configuration download failed (HTTP $status).';
  }

  @override
  String get downloadTooLarge =>
      'The configuration content is too large and was not saved.';

  @override
  String get redirectTooMany =>
      'The configuration source redirected too many times.';

  @override
  String get configStoreUnreadable =>
      'Saved configurations could not be read; the file was not changed.';

  @override
  String get configSaveFailed =>
      'Saving the configuration failed; check available storage and retry.';

  @override
  String get preferencesUnreadable =>
      'Saved settings could not be read; the file was not changed.';

  @override
  String get preferencesSaveFailed =>
      'Saving settings failed; check available storage and retry.';

  @override
  String get textTooLargeSave =>
      'The configuration content exceeds 16 MiB and was not saved.';

  @override
  String get preparationOptionsTooLarge =>
      'Preparation metadata exceeds 16 MiB after UTF-8 JSON encoding. Changes were not applied.';

  @override
  String get preparationFragmentsTooLarge =>
      'Plugin JSON exceeds 128 MiB after UTF-8 encoding. Changes were not applied.';

  @override
  String get preparationMetadataInvalid =>
      'Configuration identity or source metadata contains invalid Unicode. Changes were not applied.';

  @override
  String get textNotUtf8 =>
      'The configuration content is not valid UTF-8 text.';

  @override
  String get textTooLargeImport =>
      'The configuration content exceeds 16 MiB and was not imported.';

  @override
  String get sessionChangedNoDisconnect =>
      'The session changed; the disconnect was not executed.';

  @override
  String get disconnectFailedShort => 'Disconnect failed';

  @override
  String get disconnectUnconfirmedShort => 'Disconnect result unconfirmed';

  @override
  String get pathUnavailable => 'Path unavailable';

  @override
  String get strategyStatusStale =>
      'Strategy status has not refreshed; the foreground will retry. Old records cannot be used to switch.';

  @override
  String get coreContextUnconfirmed => 'The core context is not confirmed yet.';

  @override
  String get strategyContextChangedRetry =>
      'The strategy context changed; wait for the current configuration to be read again.';

  @override
  String get applyingStrategySelection => 'Applying the strategy selection';

  @override
  String get trafficUpdateFailed => 'Update failed';

  @override
  String applicationSharedUidNotice(String packages) {
    return 'These apps share an Android UID. Selecting or excluding one also affects: $packages';
  }

  @override
  String get delayCancelled => 'Cancelled';

  @override
  String operationAndCleanupFailed(String operation, String cleanup) {
    return '$operation\n$cleanup';
  }

  @override
  String get androidStageLoading => 'Loading configuration';

  @override
  String get androidStageEstablishing => 'Establishing VPN';

  @override
  String get androidStageAttaching => 'Attaching virtual interface';

  @override
  String androidErrorStageFailed(String stage) {
    return '$stage failed. Check the configuration source and network, then try again.';
  }

  @override
  String get androidErrorAppInfoVersion =>
      'Unable to read version information.';

  @override
  String get androidErrorAppInfoNative => 'Unable to load the native core.';

  @override
  String get androidErrorApplications => 'Unable to read the application list.';

  @override
  String get androidErrorLogicExpired => 'The logic engine has ended.';

  @override
  String get androidErrorOperationEnded => 'The operation has ended.';

  @override
  String get androidErrorScheduleSave =>
      'Unable to save the automatic update schedule.';

  @override
  String get androidErrorBusy =>
      'Another operation is in progress. Wait for it to finish.';

  @override
  String get androidErrorUnknownCommand => 'Unrecognized operation.';

  @override
  String get androidOperationAccepting => 'Accepting operation';

  @override
  String get androidOperationPreparingSystemStart => 'Preparing system start';

  @override
  String get androidErrorServiceStart =>
      'The system did not allow starting the task. Return to the app and try again.';

  @override
  String get androidErrorServiceNotAllowed =>
      'The system did not allow starting the task.';

  @override
  String get androidErrorVpnPermissionReturn =>
      'Return to the app and restart to complete VPN authorization.';

  @override
  String get androidErrorVpnPermissionRequests =>
      'Too many authorization requests. Restart the app and try again.';

  @override
  String get androidErrorResultUnconfirmed =>
      'The operation has ended. Verify the current state.';

  @override
  String get androidErrorActivityReturn => 'Return to the app and try again.';

  @override
  String get androidErrorOpenVpnSettings =>
      'Unable to open system VPN settings.';

  @override
  String get androidErrorSystemStartPrepare =>
      'The run configuration could not be prepared for the system start.';

  @override
  String get androidErrorSessionChanged => 'The takeover session has changed.';

  @override
  String get androidErrorSessionModeChanged =>
      'The takeover session has changed; this mode change was not confirmed.';

  @override
  String get androidErrorBackgroundStart =>
      'Unable to start the background operation. Return to the app and try again.';

  @override
  String get androidErrorInvalidResult =>
      'The operation returned no valid result.';

  @override
  String get androidErrorOperationIncomplete =>
      'The business operation did not complete. Verify the current state and try again.';

  @override
  String get androidStatusUpdating => 'Updating';

  @override
  String get androidErrorUpdateFailed => 'Update failed';

  @override
  String get androidErrorUnknownMode => 'Unrecognized run mode.';

  @override
  String get androidErrorModeTimeout => 'Timed out confirming the run mode.';

  @override
  String get androidErrorModeUnconfirmed =>
      'Unable to confirm the run mode. Wait for the state to refresh.';

  @override
  String get androidErrorNativeModeUnavailable =>
      'The native mode interface is unavailable.';

  @override
  String get androidErrorTakeoverTimeout =>
      'The takeover operation timed out. Verify the actual state.';

  @override
  String get androidErrorTakeoverRunning =>
      'The current takeover has not stopped; a new configuration cannot start.';

  @override
  String get androidErrorCoreNotReady =>
      'Core resources are not ready; a new configuration cannot start.';

  @override
  String get androidErrorVpnPermissionInvalid =>
      'VPN authorization is incomplete or has expired.';

  @override
  String get androidErrorVpnServiceStart =>
      'The system did not allow starting the VPN service. Return to the app and try again.';

  @override
  String get androidErrorReleaseUnconfirmed =>
      'Resource release was not confirmed; stopped or restarted state cannot be reported.';

  @override
  String get androidErrorTakeoverStartFailed => 'The takeover could not start.';

  @override
  String get androidErrorTakeoverReleaseUnknown =>
      'Unable to confirm whether takeover resources were released.';

  @override
  String get androidErrorStopNotAccepted =>
      'The system did not accept the stop request; takeover state is unconfirmed.';

  @override
  String get androidErrorStrategyPrepare =>
      'Strategy configuration did not finish loading. Check the configuration and network, then try again.';

  @override
  String get androidErrorNativeReleaseUnconfirmed =>
      'Native resource release was not confirmed.';

  @override
  String get androidErrorStrategyParams => 'Invalid strategy load parameters.';

  @override
  String get androidErrorStrategyContext =>
      'The strategy context has changed; this result was not confirmed.';

  @override
  String get androidErrorStrategyTimeout =>
      'The strategy operation timed out. Wait for the actual state to refresh.';

  @override
  String get androidErrorStrategyUnconfirmed =>
      'The strategy operation was not confirmed. Verify the configuration, members, and core state.';

  @override
  String get androidErrorNativeStrategyUnavailable =>
      'The native strategy interface is unavailable.';

  @override
  String get androidErrorCoreContextRefresh =>
      'The core context has changed. Refresh and try again.';

  @override
  String get androidErrorCoreContextReread =>
      'The core context has changed. Read it again.';

  @override
  String get androidErrorGroupUntestable =>
      'The current strategy group cannot be tested.';

  @override
  String get androidErrorDelayStart => 'Unable to start the delay test.';

  @override
  String get androidErrorNativeDelayUnavailable =>
      'The native delay test interface is unavailable.';

  @override
  String get androidErrorBatchExpired =>
      'The delay test batch has expired. Test again.';

  @override
  String get androidErrorDelayRead => 'Unable to read delay test results.';

  @override
  String get androidErrorConnectionQuerySize =>
      'The connection query is too large.';

  @override
  String get androidErrorConnectionId => 'Invalid connection identifier.';

  @override
  String get androidErrorConnectionBusy =>
      'A connection operation has not finished.';

  @override
  String get androidErrorConnectionTimeout =>
      'The connection operation timed out.';

  @override
  String get androidErrorDisconnectUnconfirmed =>
      'The disconnect result was not confirmed.';

  @override
  String get androidErrorUpdateFailedShort => 'Update failed.';

  @override
  String get androidErrorNativeConnectionUnavailable =>
      'The native connection interface is unavailable.';

  @override
  String get androidErrorConnectionNotAccepted =>
      'The connection operation was not accepted.';

  @override
  String get androidErrorOperationWaitTimeout =>
      'The operation timed out. Verify the state and try again.';

  @override
  String get androidErrorSystemTimeoutTask =>
      'The system ended an overdue task. Verify the state and try again.';

  @override
  String get androidErrorOperationInterrupted =>
      'The operation was interrupted. Verify the state and try again.';

  @override
  String get androidErrorResourceUpdateSize =>
      'The resource update request exceeds the size limit.';

  @override
  String get androidErrorNodesQuerySize =>
      'The node query exceeds the size limit.';

  @override
  String get androidErrorRulesQuerySize =>
      'The rule query exceeds the size limit.';

  @override
  String get androidErrorLogsQuerySize =>
      'The log query exceeds the size limit.';

  @override
  String get androidErrorCoreBusy =>
      'The core is busy or its context changed. Refresh and try again.';

  @override
  String get androidErrorCoreReadTimeout =>
      'The core read timed out. Try again.';

  @override
  String get androidErrorCoreReadFailed =>
      'Unable to read core data. Refresh and try again.';

  @override
  String get androidErrorNativeReadUnavailable =>
      'The native read interface is unavailable.';

  @override
  String get androidErrorVpnInputMissing =>
      'VPN authorization has expired or the run input is missing.';

  @override
  String get androidErrorNotificationDenied =>
      'The system did not allow showing the takeover notification.';

  @override
  String get androidErrorNotificationUpdate =>
      'The takeover notification could not be updated.';

  @override
  String get androidErrorNativeCoreLoad =>
      'The native core could not be loaded. Check the installed package.';

  @override
  String get androidErrorSystemRevoked => 'The system revoked the VPN';

  @override
  String get androidErrorServiceDestroyed => 'The VPN service was destroyed';

  @override
  String get androidErrorApplicationAllowlistMissing =>
      'All apps in the allow list are no longer installed. Select apps again.';

  @override
  String resultRange(int start, int end, int total) {
    return '$start–$end of $total results';
  }

  @override
  String resultCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count results',
      one: '1 result',
    );
    return '$_temp0';
  }

  @override
  String uptimeClock(String hours, String minutes, String seconds) {
    return '${hours}h ${minutes}m ${seconds}s';
  }

  @override
  String get connectionBehavior => 'Connection behavior';

  @override
  String get reconnectOnRoutingChange => 'Reconnect after switching';

  @override
  String get routingReconnectNotice =>
      'Restart the core and close existing connections when changing mode or strategy.';

  @override
  String get applicationNotInstalled => 'Not installed';

  @override
  String get uptimeRunning => 'Running';

  @override
  String uptimeDays(String days) {
    return 'Running · $days days';
  }

  @override
  String get trafficDownloaded => 'Downloaded';

  @override
  String get trafficUploaded => 'Uploaded';

  @override
  String get processMemory => 'Memory';

  @override
  String get processMemoryUnavailable =>
      'Memory is unavailable. Try again shortly.';

  @override
  String get dnsTools => 'DNS tools';

  @override
  String get dnsName => 'Name or IP address';

  @override
  String get dnsRecordType => 'Record type';

  @override
  String get dnsQuery => 'Query';

  @override
  String get dnsResolverNotice =>
      'Current core resolver; may use cached data and does not reproduce client DNS responses.';

  @override
  String get dnsReady => 'Enter a name to query';

  @override
  String get dnsPreparing => 'Preparing core';

  @override
  String get dnsRunning => 'Querying';

  @override
  String get dnsExpired => 'Result expired · query again';

  @override
  String get dnsNoConfiguration => 'Select a configuration first';

  @override
  String get dnsUnavailable => 'Current resolver unavailable';

  @override
  String get dnsInvalidRequest =>
      'Invalid name or record type, or request exceeds the size limit.';

  @override
  String get dnsBusy => 'The previous query is still finishing. Please wait.';

  @override
  String get dnsTimeout => 'Query timed out. It was not retried.';

  @override
  String get dnsCancelled => 'Query cancelled';

  @override
  String get dnsQueryFailed => 'Query failed. Try again.';

  @override
  String get dnsResultTooLarge =>
      'Response exceeds the size limit. No incomplete result is shown.';

  @override
  String get dnsInvalidResponse =>
      'Could not read the query result. Try again.';

  @override
  String get dnsQuestion => 'Question';

  @override
  String get dnsAnswer => 'Answer';

  @override
  String get dnsAuthority => 'Authority';

  @override
  String get dnsAdditional => 'Additional';

  @override
  String get dnsNoRecords => 'No records';

  @override
  String get dnsTruncated => 'Response is marked truncated';

  @override
  String dnsElapsed(double milliseconds) {
    return 'Query time $milliseconds ms';
  }

  @override
  String dnsRcode(String name, int code) {
    return 'RCODE: $name ($code)';
  }

  @override
  String dnsRecordMeta(String type, String recordClass, int ttl) {
    return '$type · $recordClass · TTL $ttl s';
  }

  @override
  String get dnsClearCache => 'Clear DNS cache';

  @override
  String get dnsClearFakeIp => 'Clear fake-IP mappings';

  @override
  String get dnsFakeIpWarning =>
      'Old addresses may stop working. Clients may need to resolve them again.';

  @override
  String get dnsCacheCompleted =>
      'Existing DNS caches cleared; queries may refill them immediately.';

  @override
  String get dnsCacheEmpty => 'No caches to clear';

  @override
  String get dnsFakeIpCompleted => 'Fake-IP mappings cleared';

  @override
  String get dnsFakeIpEmpty => 'No active fake-IP pools to clear';

  @override
  String get dnsCachePartialOrFailed =>
      'Clearing was not fully confirmed and may have had partial effects.';

  @override
  String get dnsCacheFailed => 'Could not clear. Try again.';

  @override
  String get dnsPoolCleared => 'Cleared';

  @override
  String get dnsPoolInactive => 'Inactive pool';

  @override
  String get dnsPoolUnconfirmed => 'Clearing unconfirmed';

  @override
  String get dnsPersistentPoolEnabled => 'Persistent pool: enabled';

  @override
  String get dnsPersistentPoolDisabled => 'Persistent pool: disabled';

  @override
  String get providerFormFormatHint =>
      'format controls external content encoding; inline uses rule entries.';

  @override
  String get strategyGroupHashKeyInvalid =>
      'round-robin does not accept a non-empty hash-key';

  @override
  String get allStrategyGroups => 'All strategy groups';

  @override
  String get hiddenGroupAttribute => 'Hidden';

  @override
  String get globalGroupAttribute => 'Global group';

  @override
  String get noStrategyGroups => 'No strategy groups';

  @override
  String get trafficSessionScope =>
      'Core-counted traffic for this VPN session, not device-wide usage or billed traffic.';

  @override
  String get backupTitle => 'Backup and restore';

  @override
  String get backupExport => 'Export settings';

  @override
  String get backupImport => 'Import settings';

  @override
  String get backupRestore => 'Restore backup';

  @override
  String get backupSensitiveNotice =>
      'Backups are not encrypted and include sources and credentials. Keep them safe.';

  @override
  String get backupScopeNotice =>
      'Only configurations, plugins and app settings are included.';

  @override
  String backupCounts(int configurations, int overrides) {
    String _temp0 = intl.Intl.pluralLogic(
      configurations,
      locale: localeName,
      other: '$configurations configurations',
      one: '1 configuration',
    );
    String _temp1 = intl.Intl.pluralLogic(
      overrides,
      locale: localeName,
      other: '$overrides plugins',
      one: '1 plugin',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String backupSelected(String name) {
    return 'Selected configuration: $name';
  }

  @override
  String get backupNoSelection => 'No configuration selected';

  @override
  String backupCreatedAt(String value) {
    return 'Created: $value';
  }

  @override
  String get backupNotSelected => 'Choose a backup file first.';

  @override
  String get backupConfirmTitle => 'Replace app data?';

  @override
  String get backupConfirmMessage =>
      'The backup replaces existing data rather than merging it. Empty collections also clear existing content.';

  @override
  String get backupConfirmRunning =>
      'The current connection will first be stopped and its resources released. After restoration, the app will try connecting with the restored selected configuration. A newer disconnect request takes priority.';

  @override
  String get backupConfirmStopped => 'Restoration will not start a connection.';

  @override
  String get backupConfirmUnconfirmed =>
      'Connection state is unconfirmed. Restoration will proceed only when it is safe to replace the data.';

  @override
  String get backupPreparing => 'Preparing backup';

  @override
  String get backupExportSaved => 'Backup file saved.';

  @override
  String get backupCancelled => 'Operation cancelled.';

  @override
  String get backupInvalid =>
      'The backup file is invalid or its format is not supported.';

  @override
  String get backupTooLarge => 'The backup exceeds the allowed size limit.';

  @override
  String get backupCandidateExpired =>
      'The prepared backup is no longer valid. Prepare it again.';

  @override
  String get backupNotRestored => 'Backup data was not restored.';

  @override
  String get backupRestored => 'Backup data restored.';

  @override
  String get backupRestoreUnconfirmed =>
      'The restoration result is unconfirmed. Wait for the state to be read again.';

  @override
  String get backupConnectionStopped => 'The previous connection was stopped.';

  @override
  String get backupConnectionNotStarted => 'No connection was established.';

  @override
  String get backupConnectionRestored =>
      'Connected using the restored configuration.';

  @override
  String get backupConnectionCancelled =>
      'The follow-up connection was cancelled.';

  @override
  String get backupConnectionFailed =>
      'The connection after restoration could not be established.';

  @override
  String get backupSchedulesFailed =>
      'Automatic update tasks were not fully registered.';

  @override
  String get backupSettingsRefreshFailed =>
      'The displayed settings could not be read again.';

  @override
  String get localCustomNotice =>
      'Additions and deletions only change the local custom plugin. Removing a local override may reveal a lower-priority definition with the same name; references are not repaired automatically.';

  @override
  String get providerRuntimePropertiesOnly =>
      'These are the loaded provider\'s runtime properties. Complete original options, headers and credentials are not provided by the core.';

  @override
  String get strategyGroupRuntimePropertiesOnly =>
      'These are runtime group attributes and expanded members, not the complete original definition.';

  @override
  String get localSavedOriginal => 'Saved original';

  @override
  String get localOriginalContributes => 'Contributes to loaded data';

  @override
  String get localOriginalUnconfirmed => 'Not confirmed as loaded';

  @override
  String get localOriginalDisabled => 'Plugin disabled';

  @override
  String get localCustomDefinitionsEmpty =>
      'There are no directly defined local custom entries here.';

  @override
  String get localCustomDeleteConfirm =>
      'Delete this entry only from the local custom plugin? A lower-priority definition may reappear, and existing references will not be changed.';

  @override
  String get connectionRuleScope => 'Match scope';

  @override
  String get connectionRuleUnavailable =>
      'Current connection information cannot be used to add a rule.';

  @override
  String get connectionRuleTargetsFailed =>
      'Could not read current strategy groups. Try again.';

  @override
  String get backupFailed => 'The backup operation could not be completed.';

  @override
  String get backupDocumentWriteUnconfirmed =>
      'Saving the backup file was not confirmed. An incomplete file may remain at the chosen location.';

  @override
  String localCustomSavedVerificationFailed(String result, String reason) {
    return '$result\n\nThe current local custom entry could not be verified: $reason\nReopen before continuing. The draft was not submitted again.';
  }

  @override
  String backupRestoredWithIssue(String issue) {
    return 'Backup data restored. $issue';
  }
}
