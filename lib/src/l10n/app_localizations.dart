import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @memoryApplication.
  ///
  /// In en, this message translates to:
  /// **'App memory {value} MB'**
  String memoryApplication(String value);

  /// No description provided for @memoryCore.
  ///
  /// In en, this message translates to:
  /// **'Core memory {value} MB'**
  String memoryCore(String value);

  /// No description provided for @lanProxyTitle.
  ///
  /// In en, this message translates to:
  /// **'Local network proxy'**
  String get lanProxyTitle;

  /// No description provided for @lanProxyNotice.
  ///
  /// In en, this message translates to:
  /// **'Allow devices on the local network to connect through this device\'s HTTP or SOCKS5 proxy. This service can run independently of the VPN.'**
  String get lanProxyNotice;

  /// No description provided for @lanProxyEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enable local network proxy'**
  String get lanProxyEnabled;

  /// No description provided for @lanProxyAddresses.
  ///
  /// In en, this message translates to:
  /// **'Listening addresses'**
  String get lanProxyAddresses;

  /// No description provided for @lanProxyPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get lanProxyPort;

  /// No description provided for @lanProxyInvalidPort.
  ///
  /// In en, this message translates to:
  /// **'Enter an integer port from 1 to 65535.'**
  String get lanProxyInvalidPort;

  /// No description provided for @lanProxyUdp.
  ///
  /// In en, this message translates to:
  /// **'Allow UDP'**
  String get lanProxyUdp;

  /// No description provided for @lanProxyUnknownInterface.
  ///
  /// In en, this message translates to:
  /// **'The network type of this interface could not be identified. Select it only after confirming that it belongs to a trusted local network.'**
  String get lanProxyUnknownInterface;

  /// No description provided for @lanProxyNoAddress.
  ///
  /// In en, this message translates to:
  /// **'No local network address is available. Connect to Wi-Fi or Ethernet, then refresh.'**
  String get lanProxyNoAddress;

  /// No description provided for @lanProxyActual.
  ///
  /// In en, this message translates to:
  /// **'Actual listener status'**
  String get lanProxyActual;

  /// No description provided for @lanProxyNotRunning.
  ///
  /// In en, this message translates to:
  /// **'Not listening'**
  String get lanProxyNotRunning;

  /// No description provided for @lanProxyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Address unavailable'**
  String get lanProxyUnavailable;

  /// No description provided for @lanProxyRaw.
  ///
  /// In en, this message translates to:
  /// **'Edit YAML source'**
  String get lanProxyRaw;

  /// No description provided for @lanProxyFormUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This YAML cannot be fully represented by the form. Edit the source to preserve its contents.'**
  String get lanProxyFormUnavailable;

  /// No description provided for @coreInterruptedTitle.
  ///
  /// In en, this message translates to:
  /// **'Core interrupted'**
  String get coreInterruptedTitle;

  /// No description provided for @coreInterruptedMessage.
  ///
  /// In en, this message translates to:
  /// **'Automatic start is paused. The current page and edits are retained. Open Overview to restart, choose a configuration, or clean up files.'**
  String get coreInterruptedMessage;

  /// No description provided for @coreRecoveryRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get coreRecoveryRestart;

  /// No description provided for @coreRecoverySelect.
  ///
  /// In en, this message translates to:
  /// **'Choose configuration'**
  String get coreRecoverySelect;

  /// No description provided for @coreCleanupSelect.
  ///
  /// In en, this message translates to:
  /// **'Clean up core files'**
  String get coreCleanupSelect;

  /// No description provided for @coreCleanupSelectionNotice.
  ///
  /// In en, this message translates to:
  /// **'The core stops before deleting the selected cache database or geographic data files. Unselected files are kept.'**
  String get coreCleanupSelectionNotice;

  /// No description provided for @coreCleanupRestartLatest.
  ///
  /// In en, this message translates to:
  /// **'Start with the latest saved configuration after every selected file is cleaned up'**
  String get coreCleanupRestartLatest;

  /// No description provided for @coreCleanupNoCandidates.
  ///
  /// In en, this message translates to:
  /// **'No confirmed files are available for cleanup.'**
  String get coreCleanupNoCandidates;

  /// No description provided for @coreCleanupDeleteSelected.
  ///
  /// In en, this message translates to:
  /// **'Stop and clean selected files'**
  String get coreCleanupDeleteSelected;

  /// No description provided for @coreCleanupPartial.
  ///
  /// In en, this message translates to:
  /// **'Some files could not be cleaned up'**
  String get coreCleanupPartial;

  /// No description provided for @logClear.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get logClear;

  /// No description provided for @selectDetails.
  ///
  /// In en, this message translates to:
  /// **'Select an item to view its details.'**
  String get selectDetails;

  /// No description provided for @selectionOutsideList.
  ///
  /// In en, this message translates to:
  /// **'The selected item is outside the current list.'**
  String get selectionOutsideList;

  /// No description provided for @editLocalDefinition.
  ///
  /// In en, this message translates to:
  /// **'Edit local definition'**
  String get editLocalDefinition;

  /// No description provided for @definitionFormName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get definitionFormName;

  /// No description provided for @strategyRejectStatus.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get strategyRejectStatus;

  /// No description provided for @strategyCardDelayNotice.
  ///
  /// In en, this message translates to:
  /// **'Latest HTTP-target test for the current member: {result}.'**
  String strategyCardDelayNotice(String result);

  /// No description provided for @overview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get overview;

  /// No description provided for @connectionsNavigation.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get connectionsNavigation;

  /// No description provided for @configurationsNavigation.
  ///
  /// In en, this message translates to:
  /// **'Configs'**
  String get configurationsNavigation;

  /// No description provided for @strategies.
  ///
  /// In en, this message translates to:
  /// **'Strategies'**
  String get strategies;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @appearanceAndLanguage.
  ///
  /// In en, this message translates to:
  /// **'Appearance & language'**
  String get appearanceAndLanguage;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @followSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get followSystem;

  /// No description provided for @lightAppearance.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get lightAppearance;

  /// No description provided for @darkAppearance.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get darkAppearance;

  /// No description provided for @brandColor.
  ///
  /// In en, this message translates to:
  /// **'Accent color'**
  String get brandColor;

  /// No description provided for @cinnabar.
  ///
  /// In en, this message translates to:
  /// **'Cinnabar'**
  String get cinnabar;

  /// No description provided for @jade.
  ///
  /// In en, this message translates to:
  /// **'Jade'**
  String get jade;

  /// No description provided for @cobalt.
  ///
  /// In en, this message translates to:
  /// **'Cobalt'**
  String get cobalt;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @configurationsAndData.
  ///
  /// In en, this message translates to:
  /// **'Configurations & data'**
  String get configurationsAndData;

  /// No description provided for @routingAndResources.
  ///
  /// In en, this message translates to:
  /// **'Routing & resources'**
  String get routingAndResources;

  /// No description provided for @diagnosticTools.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnosticTools;

  /// No description provided for @configurations.
  ///
  /// In en, this message translates to:
  /// **'Configurations'**
  String get configurations;

  /// 选择这张卡片所代表的配置。
  ///
  /// In en, this message translates to:
  /// **'Select configuration'**
  String get selectConfig;

  /// No description provided for @recentConnections.
  ///
  /// In en, this message translates to:
  /// **'Recent connections'**
  String get recentConnections;

  /// No description provided for @overrides.
  ///
  /// In en, this message translates to:
  /// **'Plugins (overrides)'**
  String get overrides;

  /// No description provided for @proxyNodes.
  ///
  /// In en, this message translates to:
  /// **'Proxy nodes'**
  String get proxyNodes;

  /// No description provided for @rules.
  ///
  /// In en, this message translates to:
  /// **'Rules'**
  String get rules;

  /// No description provided for @externalResources.
  ///
  /// In en, this message translates to:
  /// **'External resources'**
  String get externalResources;

  /// No description provided for @runtimeConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Runtime configuration'**
  String get runtimeConfiguration;

  /// No description provided for @coreLogs.
  ///
  /// In en, this message translates to:
  /// **'Core logs'**
  String get coreLogs;

  /// No description provided for @applicationAccess.
  ///
  /// In en, this message translates to:
  /// **'App VPN access'**
  String get applicationAccess;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @licenses.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get licenses;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @changeSource.
  ///
  /// In en, this message translates to:
  /// **'Change source'**
  String get changeSource;

  /// No description provided for @settingsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Reading the saved settings failed.'**
  String get settingsLoadFailed;

  /// No description provided for @project.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get project;

  /// No description provided for @applicationVersion.
  ///
  /// In en, this message translates to:
  /// **'App version'**
  String get applicationVersion;

  /// No description provided for @legalSummary.
  ///
  /// In en, this message translates to:
  /// **'Clash Pseudo is free software; redistribution and modification are permitted under the terms of the GNU General Public License, version 3 only (GPL-3.0-only), as published by the Free Software Foundation.\n\nThis program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY.'**
  String get legalSummary;

  /// No description provided for @sourceDistributionNotice.
  ///
  /// In en, this message translates to:
  /// **'Corresponding source and build materials are provided with each release.'**
  String get sourceDistributionNotice;

  /// No description provided for @versionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Version information is unavailable.'**
  String get versionUnavailable;

  /// No description provided for @coreVersion.
  ///
  /// In en, this message translates to:
  /// **'mihomo version'**
  String get coreVersion;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @runtimeConfigSearch.
  ///
  /// In en, this message translates to:
  /// **'Find fields or values'**
  String get runtimeConfigSearch;

  /// No description provided for @clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// No description provided for @runtimeConfigLive.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get runtimeConfigLive;

  /// No description provided for @runtimeConfigPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview · VPN off'**
  String get runtimeConfigPreview;

  /// No description provided for @runtimeConfigEmpty.
  ///
  /// In en, this message translates to:
  /// **'Select a configuration with saved content first.'**
  String get runtimeConfigEmpty;

  /// No description provided for @noSearchResults.
  ///
  /// In en, this message translates to:
  /// **'No matching lines'**
  String get noSearchResults;

  /// No description provided for @nodeSearch.
  ///
  /// In en, this message translates to:
  /// **'Name, provider or type'**
  String get nodeSearch;

  /// No description provided for @coreReadLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading core data…'**
  String get coreReadLoading;

  /// No description provided for @coreReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Read failed · refresh to retry'**
  String get coreReadFailed;

  /// No description provided for @coreSnapshotStale.
  ///
  /// In en, this message translates to:
  /// **'Previous snapshot · not current'**
  String get coreSnapshotStale;

  /// No description provided for @builtinNode.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get builtinNode;

  /// No description provided for @previousPage.
  ///
  /// In en, this message translates to:
  /// **'Previous page'**
  String get previousPage;

  /// No description provided for @nextPage.
  ///
  /// In en, this message translates to:
  /// **'Next page'**
  String get nextPage;

  /// No description provided for @noNodes.
  ///
  /// In en, this message translates to:
  /// **'No matching nodes'**
  String get noNodes;

  /// No description provided for @details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get details;

  /// 打开错误详情的入口文字和详情标题。
  ///
  /// In en, this message translates to:
  /// **'Error details'**
  String get errorDetails;

  /// 查看相关操作或对象的错误。
  ///
  /// In en, this message translates to:
  /// **'View error'**
  String get viewError;

  /// 用于查看完整原始错误或诊断原文的入口文字和标题。
  ///
  /// In en, this message translates to:
  /// **'Technical details'**
  String get technicalDetails;

  /// 复制完整的原始错误或诊断原文。
  ///
  /// In en, this message translates to:
  /// **'Copy technical details'**
  String get copyTechnicalDetails;

  /// No description provided for @mainRules.
  ///
  /// In en, this message translates to:
  /// **'Main rules'**
  String get mainRules;

  /// No description provided for @subRules.
  ///
  /// In en, this message translates to:
  /// **'Sub-rules'**
  String get subRules;

  /// No description provided for @ruleSets.
  ///
  /// In en, this message translates to:
  /// **'Rule sets'**
  String get ruleSets;

  /// No description provided for @ruleScope.
  ///
  /// In en, this message translates to:
  /// **'Rule scope'**
  String get ruleScope;

  /// No description provided for @ruleSearch.
  ///
  /// In en, this message translates to:
  /// **'Type, content or target'**
  String get ruleSearch;

  /// No description provided for @noRules.
  ///
  /// In en, this message translates to:
  /// **'No matching rules'**
  String get noRules;

  /// No description provided for @ruleTarget.
  ///
  /// In en, this message translates to:
  /// **'Target'**
  String get ruleTarget;

  /// No description provided for @resourceSearch.
  ///
  /// In en, this message translates to:
  /// **'Name, type or source'**
  String get resourceSearch;

  /// No description provided for @noResources.
  ///
  /// In en, this message translates to:
  /// **'No matching resources'**
  String get noResources;

  /// No description provided for @resourceProxyProvider.
  ///
  /// In en, this message translates to:
  /// **'Proxy provider'**
  String get resourceProxyProvider;

  /// No description provided for @resourceRuleProvider.
  ///
  /// In en, this message translates to:
  /// **'Rule provider'**
  String get resourceRuleProvider;

  /// No description provided for @resourceGeo.
  ///
  /// In en, this message translates to:
  /// **'Geo database'**
  String get resourceGeo;

  /// No description provided for @resourceCountValue.
  ///
  /// In en, this message translates to:
  /// **'{count} entries'**
  String resourceCountValue(int count);

  /// No description provided for @resourceUpdatedAt.
  ///
  /// In en, this message translates to:
  /// **'Core-reported update time: {time}'**
  String resourceUpdatedAt(String time);

  /// No description provided for @resourceUpdateUnknown.
  ///
  /// In en, this message translates to:
  /// **'The core reported no update time'**
  String get resourceUpdateUnknown;

  /// No description provided for @resourceFilePresent.
  ///
  /// In en, this message translates to:
  /// **'Local file present'**
  String get resourceFilePresent;

  /// No description provided for @resourceAutoTarget.
  ///
  /// In en, this message translates to:
  /// **'Core auto-update target'**
  String get resourceAutoTarget;

  /// No description provided for @resourceNotAutoTarget.
  ///
  /// In en, this message translates to:
  /// **'Not an auto-update target'**
  String get resourceNotAutoTarget;

  /// No description provided for @resourceAutoScope.
  ///
  /// In en, this message translates to:
  /// **'Update targets follow the core process records and can include databases used by earlier configurations.'**
  String get resourceAutoScope;

  /// No description provided for @resourceFileModifiedAt.
  ///
  /// In en, this message translates to:
  /// **'File modified: {time}'**
  String resourceFileModifiedAt(String time);

  /// No description provided for @resourceLastCheckAt.
  ///
  /// In en, this message translates to:
  /// **'Last successful check: {time}'**
  String resourceLastCheckAt(String time);

  /// No description provided for @resourceUpdateInterval.
  ///
  /// In en, this message translates to:
  /// **'Update interval: {interval}'**
  String resourceUpdateInterval(String interval);

  /// No description provided for @resourceWatchFile.
  ///
  /// In en, this message translates to:
  /// **'Watch local file changes'**
  String get resourceWatchFile;

  /// No description provided for @resourceFileMissing.
  ///
  /// In en, this message translates to:
  /// **'Local file missing'**
  String get resourceFileMissing;

  /// No description provided for @resourceFileUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Local file unreadable'**
  String get resourceFileUnreadable;

  /// No description provided for @resourceBuiltInBehavior.
  ///
  /// In en, this message translates to:
  /// **'Behavior: {behavior}'**
  String resourceBuiltInBehavior(String behavior);

  /// No description provided for @resourceUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get resourceUpdate;

  /// No description provided for @resourceUpdating.
  ///
  /// In en, this message translates to:
  /// **'Updating…'**
  String get resourceUpdating;

  /// No description provided for @resourceUpdateStopped.
  ///
  /// In en, this message translates to:
  /// **'The core stopped before the update finished'**
  String get resourceUpdateStopped;

  /// No description provided for @resourceUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update did not finish; previous data was kept'**
  String get resourceUpdateFailed;

  /// No description provided for @resourceUpdateSuccess.
  ///
  /// In en, this message translates to:
  /// **'Update finished; refresh to see the core\'s new state'**
  String get resourceUpdateSuccess;

  /// No description provided for @resourceNoExternalSource.
  ///
  /// In en, this message translates to:
  /// **'Inline or built-in resources have no external source'**
  String get resourceNoExternalSource;

  /// No description provided for @logLevel.
  ///
  /// In en, this message translates to:
  /// **'Level'**
  String get logLevel;

  /// No description provided for @logSearch.
  ///
  /// In en, this message translates to:
  /// **'Search log text'**
  String get logSearch;

  /// No description provided for @logLevelDebug.
  ///
  /// In en, this message translates to:
  /// **'Debug and above'**
  String get logLevelDebug;

  /// No description provided for @logLevelInfo.
  ///
  /// In en, this message translates to:
  /// **'Info and above'**
  String get logLevelInfo;

  /// No description provided for @logLevelWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning and above'**
  String get logLevelWarning;

  /// No description provided for @logLevelError.
  ///
  /// In en, this message translates to:
  /// **'Errors only'**
  String get logLevelError;

  /// No description provided for @noLogs.
  ///
  /// In en, this message translates to:
  /// **'No log entries in this session yet'**
  String get noLogs;

  /// No description provided for @logLocalDropped.
  ///
  /// In en, this message translates to:
  /// **'Omitted {count} log entries'**
  String logLocalDropped(int count);

  /// No description provided for @logDropped.
  ///
  /// In en, this message translates to:
  /// **'{count} log entries omitted during transfer'**
  String logDropped(int count);

  /// No description provided for @logTotal.
  ///
  /// In en, this message translates to:
  /// **'Cached: {count} entries'**
  String logTotal(int count);

  /// No description provided for @logBackToLatest.
  ///
  /// In en, this message translates to:
  /// **'Back to latest'**
  String get logBackToLatest;

  /// No description provided for @delayTestGroup.
  ///
  /// In en, this message translates to:
  /// **'Test group'**
  String get delayTestGroup;

  /// No description provided for @delayTestMember.
  ///
  /// In en, this message translates to:
  /// **'Test this member'**
  String get delayTestMember;

  /// No description provided for @delayTarget.
  ///
  /// In en, this message translates to:
  /// **'Target: {url} · HTTP delay, not ICMP'**
  String delayTarget(String url);

  /// No description provided for @delayPending.
  ///
  /// In en, this message translates to:
  /// **'Not tested'**
  String get delayPending;

  /// No description provided for @delayRunning.
  ///
  /// In en, this message translates to:
  /// **'Testing'**
  String get delayRunning;

  /// No description provided for @delayFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get delayFailed;

  /// No description provided for @delayTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get delayTimeout;

  /// No description provided for @delayExpired.
  ///
  /// In en, this message translates to:
  /// **'Result expired'**
  String get delayExpired;

  /// No description provided for @delayStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start the delay test'**
  String get delayStartFailed;

  /// No description provided for @delayReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the delay results'**
  String get delayReadFailed;

  /// No description provided for @delayProgress.
  ///
  /// In en, this message translates to:
  /// **'{done}/{total} tested'**
  String delayProgress(int done, int total);

  /// No description provided for @delayDone.
  ///
  /// In en, this message translates to:
  /// **'Test complete'**
  String get delayDone;

  /// No description provided for @overridePlugins.
  ///
  /// In en, this message translates to:
  /// **'Plugins (override)'**
  String get overridePlugins;

  /// No description provided for @addOverride.
  ///
  /// In en, this message translates to:
  /// **'Add plugin'**
  String get addOverride;

  /// No description provided for @newOverride.
  ///
  /// In en, this message translates to:
  /// **'New local plugin'**
  String get newOverride;

  /// No description provided for @remoteOverride.
  ///
  /// In en, this message translates to:
  /// **'Add from URL'**
  String get remoteOverride;

  /// No description provided for @overrideLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get overrideLocal;

  /// No description provided for @overrideEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get overrideEnabled;

  /// No description provided for @overridePrepend.
  ///
  /// In en, this message translates to:
  /// **'Prepend merge'**
  String get overridePrepend;

  /// No description provided for @overrideReplace.
  ///
  /// In en, this message translates to:
  /// **'Replace same settings'**
  String get overrideReplace;

  /// No description provided for @overrideMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get overrideMoveUp;

  /// No description provided for @overrideMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get overrideMoveDown;

  /// No description provided for @overrideEmpty.
  ///
  /// In en, this message translates to:
  /// **'No plugins added yet.'**
  String get overrideEmpty;

  /// No description provided for @overrideNotice.
  ///
  /// In en, this message translates to:
  /// **'Higher items take priority. Changes to running content reconnect the tunnel.'**
  String get overrideNotice;

  /// No description provided for @loonProxyName.
  ///
  /// In en, this message translates to:
  /// **'Proxy name'**
  String get loonProxyName;

  /// No description provided for @loonProxyNameHint.
  ///
  /// In en, this message translates to:
  /// **'Only for Loon rules. Leave blank to keep explicit targets and comment out targetless rules. Built-in targets stay unchanged.'**
  String get loonProxyNameHint;

  /// No description provided for @loonAddNoResolve.
  ///
  /// In en, this message translates to:
  /// **'Add no-resolve to Loon IP rules'**
  String get loonAddNoResolve;

  /// No description provided for @overrideContentUnsupported.
  ///
  /// In en, this message translates to:
  /// **'The remote plugin is not a valid YAML configuration fragment or a recognizable Loon plugin.'**
  String get overrideContentUnsupported;

  /// No description provided for @loonProxyNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'The proxy name must not contain commas, line breaks or control characters.'**
  String get loonProxyNameInvalid;

  /// No description provided for @loonConvertedResult.
  ///
  /// In en, this message translates to:
  /// **'{result}\n\nExtracted {rules} compatible rules; retained {comments} source lines as comments.'**
  String loonConvertedResult(String result, int rules, int comments);

  /// No description provided for @loonNoRulesResult.
  ///
  /// In en, this message translates to:
  /// **'{result}\n\nNo compatible rules were extracted. The plugin leaves existing rules unchanged; {comments} source lines were retained as comments.'**
  String loonNoRulesResult(String result, int comments);

  /// No description provided for @overrideName.
  ///
  /// In en, this message translates to:
  /// **'Plugin name'**
  String get overrideName;

  /// No description provided for @overrideUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update plugin'**
  String get overrideUpdate;

  /// 打开当前插件的错误详情。
  ///
  /// In en, this message translates to:
  /// **'View plugin error'**
  String get viewOverrideError;

  /// 插件操作未完成时的反馈标题；详细说明保留实际保存结果、应用结果和原始错误。
  ///
  /// In en, this message translates to:
  /// **'Plugin action not completed'**
  String get overrideActionFailed;

  /// No description provided for @overrideDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get overrideDelete;

  /// No description provided for @overrideDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete plugin?'**
  String get overrideDeleteTitle;

  /// No description provided for @overrideDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'This plugin will be removed from the saved list. If the active tunnel uses it, the tunnel reconnects and existing connections close. Deleting it does not start a stopped tunnel.'**
  String get overrideDeleteMessage;

  /// No description provided for @localYamlInvalid.
  ///
  /// In en, this message translates to:
  /// **'The content is not a valid single YAML object. Correct it in the text editor first.'**
  String get localYamlInvalid;

  /// No description provided for @localYamlInvalidStructure.
  ///
  /// In en, this message translates to:
  /// **'The target definition has an invalid structure or field type. The content was not changed.'**
  String get localYamlInvalidStructure;

  /// No description provided for @localYamlDuplicateName.
  ///
  /// In en, this message translates to:
  /// **'A definition with this name already exists in local customizations.'**
  String get localYamlDuplicateName;

  /// No description provided for @localYamlAliasTarget.
  ///
  /// In en, this message translates to:
  /// **'The target uses a shared YAML anchor or alias. Edit it in the text editor.'**
  String get localYamlAliasTarget;

  /// No description provided for @localYamlInheritedTarget.
  ///
  /// In en, this message translates to:
  /// **'The target is inherited through a YAML merge. Edit it in the text editor.'**
  String get localYamlInheritedTarget;

  /// No description provided for @localYamlUnsafeStructure.
  ///
  /// In en, this message translates to:
  /// **'The content is nested too deeply or expands too many aliases to edit safely.'**
  String get localYamlUnsafeStructure;

  /// No description provided for @localYamlUnsupportedEdit.
  ///
  /// In en, this message translates to:
  /// **'This definition cannot be changed while preserving the rest of the content. Use the text editor.'**
  String get localYamlUnsupportedEdit;

  /// No description provided for @localYamlUnsupportedField.
  ///
  /// In en, this message translates to:
  /// **'This field\'s original value cannot be represented by this form. It is preserved unchanged; use the text editor to modify it.'**
  String get localYamlUnsupportedField;

  /// No description provided for @definitionFormUnsetField.
  ///
  /// In en, this message translates to:
  /// **'Unset field'**
  String get definitionFormUnsetField;

  /// No description provided for @definitionFormEditItem.
  ///
  /// In en, this message translates to:
  /// **'Edit {label} item {index}'**
  String definitionFormEditItem(String label, int index);

  /// No description provided for @definitionFormValueCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 value} other{{count} values}}'**
  String definitionFormValueCount(int count);

  /// No description provided for @provenancePlugins.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 contributing plugin} other{{count} contributing plugins}}'**
  String provenancePlugins(int count);

  /// No description provided for @provenanceHeading.
  ///
  /// In en, this message translates to:
  /// **'Contributing plugins'**
  String get provenanceHeading;

  /// No description provided for @provenanceProviderHeading.
  ///
  /// In en, this message translates to:
  /// **'Definition contributors'**
  String get provenanceProviderHeading;

  /// No description provided for @strategyGroupFormTitle.
  ///
  /// In en, this message translates to:
  /// **'Add strategy group'**
  String get strategyGroupFormTitle;

  /// No description provided for @strategyGroupFormType.
  ///
  /// In en, this message translates to:
  /// **'Group type'**
  String get strategyGroupFormType;

  /// No description provided for @strategyGroupFormMembers.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get strategyGroupFormMembers;

  /// No description provided for @strategyGroupFormProviders.
  ///
  /// In en, this message translates to:
  /// **'Proxy provider references'**
  String get strategyGroupFormProviders;

  /// No description provided for @strategyGroupEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit local strategy group'**
  String get strategyGroupEditTitle;

  /// No description provided for @strategyGroupDefinitionTitle.
  ///
  /// In en, this message translates to:
  /// **'Group properties'**
  String get strategyGroupDefinitionTitle;

  /// No description provided for @strategyGroupAttributesHeading.
  ///
  /// In en, this message translates to:
  /// **'Actual attributes'**
  String get strategyGroupAttributesHeading;

  /// No description provided for @strategyGroupNoMembers.
  ///
  /// In en, this message translates to:
  /// **'No members'**
  String get strategyGroupNoMembers;

  /// No description provided for @strategyGroupFixedValue.
  ///
  /// In en, this message translates to:
  /// **'Pinned: {name}'**
  String strategyGroupFixedValue(String name);

  /// No description provided for @strategyGroupLoadedValue.
  ///
  /// In en, this message translates to:
  /// **'Current: {name}'**
  String strategyGroupLoadedValue(String name);

  /// No description provided for @strategyGroupNotSelected.
  ///
  /// In en, this message translates to:
  /// **'No current member'**
  String get strategyGroupNotSelected;

  /// No description provided for @providerProxyFormTitle.
  ///
  /// In en, this message translates to:
  /// **'Add proxy provider'**
  String get providerProxyFormTitle;

  /// No description provided for @providerRuleFormTitle.
  ///
  /// In en, this message translates to:
  /// **'Add rule provider'**
  String get providerRuleFormTitle;

  /// No description provided for @providerFormType.
  ///
  /// In en, this message translates to:
  /// **'Source type'**
  String get providerFormType;

  /// No description provided for @providerFormSource.
  ///
  /// In en, this message translates to:
  /// **'Source & download'**
  String get providerFormSource;

  /// No description provided for @providerFormHeaders.
  ///
  /// In en, this message translates to:
  /// **'Request headers'**
  String get providerFormHeaders;

  /// No description provided for @providerFormDownloadProxy.
  ///
  /// In en, this message translates to:
  /// **'Download proxy'**
  String get providerFormDownloadProxy;

  /// No description provided for @providerFormHealthCheck.
  ///
  /// In en, this message translates to:
  /// **'Health check'**
  String get providerFormHealthCheck;

  /// No description provided for @providerFormOverride.
  ///
  /// In en, this message translates to:
  /// **'Proxy overrides'**
  String get providerFormOverride;

  /// No description provided for @providerFormPayload.
  ///
  /// In en, this message translates to:
  /// **'Inline payload'**
  String get providerFormPayload;

  /// No description provided for @providerFormAddProxy.
  ///
  /// In en, this message translates to:
  /// **'Add inline proxy'**
  String get providerFormAddProxy;

  /// No description provided for @providerFormEditProxy.
  ///
  /// In en, this message translates to:
  /// **'Edit inline proxy'**
  String get providerFormEditProxy;

  /// No description provided for @providerFormProxyNames.
  ///
  /// In en, this message translates to:
  /// **'Name replacements'**
  String get providerFormProxyNames;

  /// No description provided for @providerFormExpressions.
  ///
  /// In en, this message translates to:
  /// **'Override expressions'**
  String get providerFormExpressions;

  /// No description provided for @providerFormPattern.
  ///
  /// In en, this message translates to:
  /// **'Pattern'**
  String get providerFormPattern;

  /// No description provided for @providerFormReplacement.
  ///
  /// In en, this message translates to:
  /// **'Replacement'**
  String get providerFormReplacement;

  /// No description provided for @providerFormPathHint.
  ///
  /// In en, this message translates to:
  /// **'Relative to managed resource storage; absolute and parent paths are not accepted.'**
  String get providerFormPathHint;

  /// No description provided for @providerFormInvalidPath.
  ///
  /// In en, this message translates to:
  /// **'Invalid path'**
  String get providerFormInvalidPath;

  /// No description provided for @providerFormInvalidUrl.
  ///
  /// In en, this message translates to:
  /// **'Enter an HTTP or HTTPS URL'**
  String get providerFormInvalidUrl;

  /// No description provided for @providerFormMRSClassical.
  ///
  /// In en, this message translates to:
  /// **'MRS does not support classical'**
  String get providerFormMRSClassical;

  /// No description provided for @providerFormAndroidIgnored.
  ///
  /// In en, this message translates to:
  /// **'The current Android integration does not use interface-name, routing-mark or TFO.'**
  String get providerFormAndroidIgnored;

  /// No description provided for @ruleFormTitle.
  ///
  /// In en, this message translates to:
  /// **'Add rule'**
  String get ruleFormTitle;

  /// No description provided for @ruleFormType.
  ///
  /// In en, this message translates to:
  /// **'Rule type'**
  String get ruleFormType;

  /// No description provided for @ruleFormMatch.
  ///
  /// In en, this message translates to:
  /// **'Match value'**
  String get ruleFormMatch;

  /// No description provided for @ruleFormTarget.
  ///
  /// In en, this message translates to:
  /// **'Target'**
  String get ruleFormTarget;

  /// No description provided for @ruleFormProvider.
  ///
  /// In en, this message translates to:
  /// **'Rule provider'**
  String get ruleFormProvider;

  /// No description provided for @ruleFormSubRule.
  ///
  /// In en, this message translates to:
  /// **'Sub-rule set'**
  String get ruleFormSubRule;

  /// No description provided for @ruleFormCondition.
  ///
  /// In en, this message translates to:
  /// **'Native condition expression'**
  String get ruleFormCondition;

  /// No description provided for @ruleFormUnrepresentable.
  ///
  /// In en, this message translates to:
  /// **'This field cannot be preserved by the rule format'**
  String get ruleFormUnrepresentable;

  /// No description provided for @ruleFormTargetHint.
  ///
  /// In en, this message translates to:
  /// **'Target names cannot contain commas or surrounding spaces.'**
  String get ruleFormTargetHint;

  /// No description provided for @ruleFormSrcHint.
  ///
  /// In en, this message translates to:
  /// **'src already implies no-resolve.'**
  String get ruleFormSrcHint;

  /// No description provided for @definitionFormMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get definitionFormMoveUp;

  /// No description provided for @definitionFormMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get definitionFormMoveDown;

  /// No description provided for @providerFormFallbackPayload.
  ///
  /// In en, this message translates to:
  /// **'Fallback inline payload'**
  String get providerFormFallbackPayload;

  /// No description provided for @definitionFormSuggestions.
  ///
  /// In en, this message translates to:
  /// **'Choose a suggestion'**
  String get definitionFormSuggestions;

  /// No description provided for @proxyFormTitle.
  ///
  /// In en, this message translates to:
  /// **'Add proxy'**
  String get proxyFormTitle;

  /// No description provided for @proxyFormType.
  ///
  /// In en, this message translates to:
  /// **'Proxy type'**
  String get proxyFormType;

  /// No description provided for @proxyFormBasic.
  ///
  /// In en, this message translates to:
  /// **'Basics'**
  String get proxyFormBasic;

  /// No description provided for @proxyFormProtocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get proxyFormProtocol;

  /// No description provided for @proxyFormAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get proxyFormAdvanced;

  /// No description provided for @proxyCategoryStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard proxy protocols'**
  String get proxyCategoryStandard;

  /// No description provided for @proxyCategoryCommunity.
  ///
  /// In en, this message translates to:
  /// **'Community proxy protocols'**
  String get proxyCategoryCommunity;

  /// No description provided for @proxyCategoryVpn.
  ///
  /// In en, this message translates to:
  /// **'VPN protocols'**
  String get proxyCategoryVpn;

  /// No description provided for @proxyCategoryBuiltin.
  ///
  /// In en, this message translates to:
  /// **'Built-in handlers'**
  String get proxyCategoryBuiltin;

  /// No description provided for @proxyOptional.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get proxyOptional;

  /// No description provided for @proxyUnset.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get proxyUnset;

  /// No description provided for @proxyTrue.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get proxyTrue;

  /// No description provided for @proxyFalse.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get proxyFalse;

  /// No description provided for @proxyRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a value.'**
  String get proxyRequired;

  /// No description provided for @proxyInvalidInteger.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid integer.'**
  String get proxyInvalidInteger;

  /// No description provided for @proxyInvalidPort.
  ///
  /// In en, this message translates to:
  /// **'Use an integer port from 0 to 65535.'**
  String get proxyInvalidPort;

  /// No description provided for @proxyInvalidByte.
  ///
  /// In en, this message translates to:
  /// **'Use an integer from 0 to 255.'**
  String get proxyInvalidByte;

  /// No description provided for @proxyDuplicateKey.
  ///
  /// In en, this message translates to:
  /// **'Duplicate key.'**
  String get proxyDuplicateKey;

  /// No description provided for @proxyMapKey.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get proxyMapKey;

  /// No description provided for @proxyMapValue.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get proxyMapValue;

  /// No description provided for @proxyPlatformIgnored.
  ///
  /// In en, this message translates to:
  /// **'This field is not applied by the current Android integration.'**
  String get proxyPlatformIgnored;

  /// No description provided for @proxySaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Saving or connecting did not complete. Input is kept.'**
  String get proxySaveFailed;

  /// No description provided for @proxyServer.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get proxyServer;

  /// No description provided for @proxyUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get proxyUsername;

  /// No description provided for @proxyShowSecret.
  ///
  /// In en, this message translates to:
  /// **'Show sensitive value'**
  String get proxyShowSecret;

  /// No description provided for @proxyHideSecret.
  ///
  /// In en, this message translates to:
  /// **'Hide sensitive value'**
  String get proxyHideSecret;

  /// No description provided for @proxyPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get proxyPassword;

  /// No description provided for @proxyName.
  ///
  /// In en, this message translates to:
  /// **'Proxy name'**
  String get proxyName;

  /// No description provided for @proxyUnitBytes.
  ///
  /// In en, this message translates to:
  /// **'bytes'**
  String get proxyUnitBytes;

  /// No description provided for @proxyUnitSeconds.
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get proxyUnitSeconds;

  /// No description provided for @proxyUnitMilliseconds.
  ///
  /// In en, this message translates to:
  /// **'ms'**
  String get proxyUnitMilliseconds;

  /// No description provided for @proxyUnitNanoseconds.
  ///
  /// In en, this message translates to:
  /// **'ns'**
  String get proxyUnitNanoseconds;

  /// No description provided for @proxyUnitMbps.
  ///
  /// In en, this message translates to:
  /// **'Mbps'**
  String get proxyUnitMbps;

  /// No description provided for @proxyUnitPackets.
  ///
  /// In en, this message translates to:
  /// **'packets'**
  String get proxyUnitPackets;

  /// No description provided for @proxyAddItem.
  ///
  /// In en, this message translates to:
  /// **'Add {field}'**
  String proxyAddItem(String field);

  /// No description provided for @proxyRemoveItem.
  ///
  /// In en, this message translates to:
  /// **'Remove {field} item {index}'**
  String proxyRemoveItem(String field, int index);

  /// No description provided for @localCustomTitle.
  ///
  /// In en, this message translates to:
  /// **'Local customizations'**
  String get localCustomTitle;

  /// No description provided for @moreLabel.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get moreLabel;

  /// No description provided for @continueLabel.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// No description provided for @operationFailed.
  ///
  /// In en, this message translates to:
  /// **'Operation not completed'**
  String get operationFailed;

  /// No description provided for @applicationListFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the installed application list.'**
  String get applicationListFailed;

  /// No description provided for @applicationAllowEmpty.
  ///
  /// In en, this message translates to:
  /// **'Select at least one application in the selected-only mode.'**
  String get applicationAllowEmpty;

  /// No description provided for @applicationReconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Save and reconnect?'**
  String get applicationReconnectTitle;

  /// No description provided for @applicationReconnectMessage.
  ///
  /// In en, this message translates to:
  /// **'Saving will normally stop the current tunnel and reconnect with the current configuration and mode. Existing connections will drop. The setting is kept if reconnecting fails.'**
  String get applicationReconnectMessage;

  /// No description provided for @applicationReconnect.
  ///
  /// In en, this message translates to:
  /// **'Save and reconnect'**
  String get applicationReconnect;

  /// No description provided for @applicationAccessNotice.
  ///
  /// In en, this message translates to:
  /// **'The selected application scope is routed through the VPN; other applications use the system network. Reconnect after saving to apply the new settings.'**
  String get applicationAccessNotice;

  /// No description provided for @searchApplications.
  ///
  /// In en, this message translates to:
  /// **'Search name or package'**
  String get searchApplications;

  /// No description provided for @accessAll.
  ///
  /// In en, this message translates to:
  /// **'All applications'**
  String get accessAll;

  /// No description provided for @accessOnly.
  ///
  /// In en, this message translates to:
  /// **'Only selected'**
  String get accessOnly;

  /// No description provided for @accessExcept.
  ///
  /// In en, this message translates to:
  /// **'Exclude selected'**
  String get accessExcept;

  /// No description provided for @showSystemApps.
  ///
  /// In en, this message translates to:
  /// **'Show system applications'**
  String get showSystemApps;

  /// No description provided for @selectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String selectedCount(int count);

  /// No description provided for @discardChanges.
  ///
  /// In en, this message translates to:
  /// **'Discard unsaved changes?'**
  String get discardChanges;

  /// No description provided for @discardApplicationChanges.
  ///
  /// In en, this message translates to:
  /// **'This selection only exists on this page and will not be saved.'**
  String get discardApplicationChanges;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @continueEditing.
  ///
  /// In en, this message translates to:
  /// **'Continue editing'**
  String get continueEditing;

  /// No description provided for @alwaysOnTitle.
  ///
  /// In en, this message translates to:
  /// **'Always-on VPN'**
  String get alwaysOnTitle;

  /// No description provided for @alwaysOnNotice.
  ///
  /// In en, this message translates to:
  /// **'Always-on is managed by Android. When enabled, the system starts this app as needed and can restore the most recently saved configuration after unlock. The app cannot bypass the system to disable it.'**
  String get alwaysOnNotice;

  /// No description provided for @vpnStatusLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading VPN status'**
  String get vpnStatusLoading;

  /// No description provided for @vpnStatusReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read Android VPN status.'**
  String get vpnStatusReadFailed;

  /// No description provided for @alwaysOnUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unconfirmed'**
  String get alwaysOnUnknown;

  /// No description provided for @alwaysOnEnabled.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get alwaysOnEnabled;

  /// No description provided for @alwaysOnDisabled.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get alwaysOnDisabled;

  /// No description provided for @lockdownEnabled.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get lockdownEnabled;

  /// No description provided for @lockdownDisabled.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get lockdownDisabled;

  /// No description provided for @lockdownTitle.
  ///
  /// In en, this message translates to:
  /// **'Block connections without VPN'**
  String get lockdownTitle;

  /// No description provided for @lockdownNotice.
  ///
  /// In en, this message translates to:
  /// **'Lockdown is managed by Android; the app never enables it.'**
  String get lockdownNotice;

  /// No description provided for @openVpnSettings.
  ///
  /// In en, this message translates to:
  /// **'Open system VPN settings'**
  String get openVpnSettings;

  /// No description provided for @alwaysOnRestoreNotice.
  ///
  /// In en, this message translates to:
  /// **'System restore uses the most recently saved main configuration, mode, plugins and application access. No tunnel is established before unlock.'**
  String get alwaysOnRestoreNotice;

  /// No description provided for @alwaysOnOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open system VPN settings; find VPN in system settings.'**
  String get alwaysOnOpenFailed;

  /// No description provided for @androidSection.
  ///
  /// In en, this message translates to:
  /// **'Android'**
  String get androidSection;

  /// No description provided for @autoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Auto-update'**
  String get autoUpdate;

  /// No description provided for @autoUpdateEvery.
  ///
  /// In en, this message translates to:
  /// **'Every {hours} hours'**
  String autoUpdateEvery(int hours);

  /// No description provided for @autoUpdateInterval.
  ///
  /// In en, this message translates to:
  /// **'Interval'**
  String get autoUpdateInterval;

  /// No description provided for @autoUpdateEnabled.
  ///
  /// In en, this message translates to:
  /// **'Auto-update enabled'**
  String get autoUpdateEnabled;

  /// No description provided for @autoUpdateDisabled.
  ///
  /// In en, this message translates to:
  /// **'Auto-update off'**
  String get autoUpdateDisabled;

  /// No description provided for @autoUpdateSaved.
  ///
  /// In en, this message translates to:
  /// **'Updated and saved'**
  String get autoUpdateSaved;

  /// No description provided for @autoUpdateApplied.
  ///
  /// In en, this message translates to:
  /// **'Updated and applied'**
  String get autoUpdateApplied;

  /// No description provided for @autoUpdateApplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Updated and saved; connection failed'**
  String get autoUpdateApplyFailed;

  /// No description provided for @autoUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Last auto-update failed'**
  String get autoUpdateFailed;

  /// No description provided for @autoUpdateUnchanged.
  ///
  /// In en, this message translates to:
  /// **'No change at last check'**
  String get autoUpdateUnchanged;

  /// No description provided for @autoUpdateAttempt.
  ///
  /// In en, this message translates to:
  /// **'Last check'**
  String get autoUpdateAttempt;

  /// No description provided for @autoUpdateNever.
  ///
  /// In en, this message translates to:
  /// **'Not checked yet'**
  String get autoUpdateNever;

  /// No description provided for @applicationPolicyNextConnectionShort.
  ///
  /// In en, this message translates to:
  /// **'Next connection'**
  String get applicationPolicyNextConnectionShort;

  /// No description provided for @applicationPolicyAppliedShort.
  ///
  /// In en, this message translates to:
  /// **'In use'**
  String get applicationPolicyAppliedShort;

  /// No description provided for @applicationPolicyPendingShort.
  ///
  /// In en, this message translates to:
  /// **'Not applied'**
  String get applicationPolicyPendingShort;

  /// No description provided for @applicationPolicyUnknownShort.
  ///
  /// In en, this message translates to:
  /// **'Unconfirmed'**
  String get applicationPolicyUnknownShort;

  /// No description provided for @applicationPolicyNextConnection.
  ///
  /// In en, this message translates to:
  /// **'The saved policy will be used on the next connection.'**
  String get applicationPolicyNextConnection;

  /// No description provided for @applicationPolicyApplied.
  ///
  /// In en, this message translates to:
  /// **'The saved policy is in use.'**
  String get applicationPolicyApplied;

  /// No description provided for @applicationPolicyPending.
  ///
  /// In en, this message translates to:
  /// **'Saved policy is not in use. Save again to retry reconnecting.'**
  String get applicationPolicyPending;

  /// No description provided for @applicationPolicyUnknown.
  ///
  /// In en, this message translates to:
  /// **'Running policy is unconfirmed. Save again to reconnect and verify.'**
  String get applicationPolicyUnknown;

  /// No description provided for @strategyGroupMissing.
  ///
  /// In en, this message translates to:
  /// **'Group no longer exists'**
  String get strategyGroupMissing;

  /// No description provided for @strategyTypeChanged.
  ///
  /// In en, this message translates to:
  /// **'Group type changed'**
  String get strategyTypeChanged;

  /// No description provided for @strategyNotSelectable.
  ///
  /// In en, this message translates to:
  /// **'Group does not support selection'**
  String get strategyNotSelectable;

  /// No description provided for @strategyMemberMissing.
  ///
  /// In en, this message translates to:
  /// **'Selected member no longer exists'**
  String get strategyMemberMissing;

  /// No description provided for @statusLoading.
  ///
  /// In en, this message translates to:
  /// **'Fetching status'**
  String get statusLoading;

  /// No description provided for @statusSubmitting.
  ///
  /// In en, this message translates to:
  /// **'Submitting request'**
  String get statusSubmitting;

  /// No description provided for @statusProcessing.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get statusProcessing;

  /// No description provided for @stateRunning.
  ///
  /// In en, this message translates to:
  /// **'Tunnel running'**
  String get stateRunning;

  /// No description provided for @stateStopped.
  ///
  /// In en, this message translates to:
  /// **'Tunnel stopped'**
  String get stateStopped;

  /// No description provided for @stateStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting'**
  String get stateStarting;

  /// No description provided for @stateStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping'**
  String get stateStopping;

  /// No description provided for @stateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unconfirmed'**
  String get stateUnknown;

  /// No description provided for @statusIssue.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get statusIssue;

  /// No description provided for @statusPending.
  ///
  /// In en, this message translates to:
  /// **'Unconfirmed'**
  String get statusPending;

  /// No description provided for @statusAutoRetry.
  ///
  /// In en, this message translates to:
  /// **'Retrying'**
  String get statusAutoRetry;

  /// No description provided for @statusPlatformUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Resources unconfirmed'**
  String get statusPlatformUnconfirmed;

  /// No description provided for @statusWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for result'**
  String get statusWaiting;

  /// No description provided for @statusConfigFailed.
  ///
  /// In en, this message translates to:
  /// **'Configurations unavailable'**
  String get statusConfigFailed;

  /// No description provided for @statusConfigLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading configurations'**
  String get statusConfigLoading;

  /// No description provided for @statusImportPrompt.
  ///
  /// In en, this message translates to:
  /// **'No configuration selected'**
  String get statusImportPrompt;

  /// No description provided for @statusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready to start'**
  String get statusReady;

  /// No description provided for @identityUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Configuration unconfirmed'**
  String get identityUnconfirmed;

  /// No description provided for @identityLoading.
  ///
  /// In en, this message translates to:
  /// **'Reading configuration'**
  String get identityLoading;

  /// No description provided for @identityNoConfig.
  ///
  /// In en, this message translates to:
  /// **'No configuration imported'**
  String get identityNoConfig;

  /// No description provided for @identitySelected.
  ///
  /// In en, this message translates to:
  /// **'Selected: {name}'**
  String identitySelected(String name);

  /// No description provided for @identityNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get identityNone;

  /// No description provided for @identityRevisionDiff.
  ///
  /// In en, this message translates to:
  /// **'Running version differs from the saved version'**
  String get identityRevisionDiff;

  /// No description provided for @identitySelectedUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Selected · not confirmed in use'**
  String get identitySelectedUnconfirmed;

  /// No description provided for @actionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get actionUnavailable;

  /// No description provided for @actionBusy.
  ///
  /// In en, this message translates to:
  /// **'Working…'**
  String get actionBusy;

  /// No description provided for @actionStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get actionStarting;

  /// No description provided for @actionStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping…'**
  String get actionStopping;

  /// No description provided for @actionStop.
  ///
  /// In en, this message translates to:
  /// **'Stop tunnel'**
  String get actionStop;

  /// No description provided for @actionStart.
  ///
  /// In en, this message translates to:
  /// **'Start tunnel'**
  String get actionStart;

  /// No description provided for @importConfig.
  ///
  /// In en, this message translates to:
  /// **'Import configuration'**
  String get importConfig;

  /// No description provided for @configManage.
  ///
  /// In en, this message translates to:
  /// **'Configurations'**
  String get configManage;

  /// No description provided for @tunnelStatus.
  ///
  /// In en, this message translates to:
  /// **'Tunnel status'**
  String get tunnelStatus;

  /// No description provided for @modeUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Mode · Unconfirmed'**
  String get modeUnconfirmed;

  /// No description provided for @modeRunningUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Running mode unconfirmed'**
  String get modeRunningUnconfirmed;

  /// No description provided for @modeRunning.
  ///
  /// In en, this message translates to:
  /// **'{mode} mode'**
  String modeRunning(String mode);

  /// No description provided for @modeSavedIdle.
  ///
  /// In en, this message translates to:
  /// **'{mode} mode · Not running'**
  String modeSavedIdle(String mode);

  /// No description provided for @modeSavedUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Saved mode unconfirmed'**
  String get modeSavedUnconfirmed;

  /// No description provided for @modeRule.
  ///
  /// In en, this message translates to:
  /// **'Rule'**
  String get modeRule;

  /// No description provided for @modeGlobal.
  ///
  /// In en, this message translates to:
  /// **'Global'**
  String get modeGlobal;

  /// No description provided for @modeDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get modeDirect;

  /// No description provided for @modeRuleDescription.
  ///
  /// In en, this message translates to:
  /// **'Route connections by the rules in the configuration.'**
  String get modeRuleDescription;

  /// No description provided for @modeGlobalDescription.
  ///
  /// In en, this message translates to:
  /// **'Route through the global policy.'**
  String get modeGlobalDescription;

  /// No description provided for @modeDirectDescription.
  ///
  /// In en, this message translates to:
  /// **'Connect directly and keep the tunnel.'**
  String get modeDirectDescription;

  /// No description provided for @networkActivity.
  ///
  /// In en, this message translates to:
  /// **'Network activity'**
  String get networkActivity;

  /// No description provided for @trafficConnections.
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get trafficConnections;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// No description provided for @modeTitle.
  ///
  /// In en, this message translates to:
  /// **'Tunnel mode'**
  String get modeTitle;

  /// No description provided for @modeReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Cannot read the mode'**
  String get modeReadFailed;

  /// No description provided for @modeDiffers.
  ///
  /// In en, this message translates to:
  /// **'Running mode and saved fallback mode'**
  String get modeDiffers;

  /// No description provided for @modeSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved fallback mode: {mode}; used only if the configuration does not specify a mode.'**
  String modeSaved(String mode);

  /// No description provided for @modeActualDiffers.
  ///
  /// In en, this message translates to:
  /// **'Running: {mode}. A configuration-defined mode can differ from the saved fallback.'**
  String modeActualDiffers(String mode);

  /// No description provided for @modeHint.
  ///
  /// In en, this message translates to:
  /// **'Choosing a mode switches the running tunnel immediately. When stopped, only a fallback is saved; it is used only if the configuration does not specify a mode.'**
  String get modeHint;

  /// No description provided for @modeFollowConfigIdle.
  ///
  /// In en, this message translates to:
  /// **'Configuration mode · Not running'**
  String get modeFollowConfigIdle;

  /// No description provided for @notProvided.
  ///
  /// In en, this message translates to:
  /// **'Not provided'**
  String get notProvided;

  /// No description provided for @allRules.
  ///
  /// In en, this message translates to:
  /// **'All rules'**
  String get allRules;

  /// No description provided for @allConnections.
  ///
  /// In en, this message translates to:
  /// **'All connections'**
  String get allConnections;

  /// No description provided for @activeOnly.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get activeOnly;

  /// No description provided for @inactiveOnly.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get inactiveOnly;

  /// No description provided for @clearInactiveConnections.
  ///
  /// In en, this message translates to:
  /// **'Clear ended records'**
  String get clearInactiveConnections;

  /// No description provided for @connectionOmitted.
  ///
  /// In en, this message translates to:
  /// **'{count} whole records omitted by capacity limits'**
  String connectionOmitted(int count);

  /// No description provided for @rawData.
  ///
  /// In en, this message translates to:
  /// **'Original data'**
  String get rawData;

  /// No description provided for @copyOriginalText.
  ///
  /// In en, this message translates to:
  /// **'Copy original text'**
  String get copyOriginalText;

  /// 说明连接记录已达容量上限，并提示清除已结束的记录。
  ///
  /// In en, this message translates to:
  /// **'The record limit has been reached, so some connections are not shown. Clear ended records to make room.'**
  String get connectionLimitedNotice;

  /// No description provided for @connectionRefreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Refresh failed'**
  String get connectionRefreshFailed;

  /// No description provided for @exitSearch.
  ///
  /// In en, this message translates to:
  /// **'Exit search'**
  String get exitSearch;

  /// No description provided for @searchConnections.
  ///
  /// In en, this message translates to:
  /// **'Search connections'**
  String get searchConnections;

  /// No description provided for @searchStrategies.
  ///
  /// In en, this message translates to:
  /// **'Search strategies'**
  String get searchStrategies;

  /// No description provided for @noMatchingStrategies.
  ///
  /// In en, this message translates to:
  /// **'No matching strategy groups'**
  String get noMatchingStrategies;

  /// No description provided for @filterMatchedRule.
  ///
  /// In en, this message translates to:
  /// **'Filter by matched rule'**
  String get filterMatchedRule;

  /// No description provided for @noMatchingConnections.
  ///
  /// In en, this message translates to:
  /// **'No matching connections'**
  String get noMatchingConnections;

  /// No description provided for @noRecentConnections.
  ///
  /// In en, this message translates to:
  /// **'No recent connections'**
  String get noRecentConnections;

  /// No description provided for @noConnections.
  ///
  /// In en, this message translates to:
  /// **'No connections yet'**
  String get noConnections;

  /// No description provided for @connectionActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get connectionActive;

  /// No description provided for @connectionInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get connectionInactive;

  /// No description provided for @disconnectFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Disconnect not completed'**
  String get disconnectFailedTitle;

  /// No description provided for @targetIp.
  ///
  /// In en, this message translates to:
  /// **'Destination IP'**
  String get targetIp;

  /// No description provided for @sourceAddress.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get sourceAddress;

  /// No description provided for @inbound.
  ///
  /// In en, this message translates to:
  /// **'Inbound'**
  String get inbound;

  /// No description provided for @connectionDetails.
  ///
  /// In en, this message translates to:
  /// **'Connection details'**
  String get connectionDetails;

  /// No description provided for @disconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting'**
  String get disconnecting;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @portLabel.
  ///
  /// In en, this message translates to:
  /// **'Port {port}'**
  String portLabel(String port);

  /// No description provided for @routingResult.
  ///
  /// In en, this message translates to:
  /// **'Routing result'**
  String get routingResult;

  /// No description provided for @matchedRule.
  ///
  /// In en, this message translates to:
  /// **'Matched rule'**
  String get matchedRule;

  /// No description provided for @traffic.
  ///
  /// In en, this message translates to:
  /// **'Traffic'**
  String get traffic;

  /// No description provided for @startTime.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get startTime;

  /// No description provided for @durationLabel.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get durationLabel;

  /// No description provided for @connectionInfo.
  ///
  /// In en, this message translates to:
  /// **'Connection information'**
  String get connectionInfo;

  /// No description provided for @connectionClosed.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get connectionClosed;

  /// No description provided for @cumulative.
  ///
  /// In en, this message translates to:
  /// **'Total {bytes}'**
  String cumulative(String bytes);

  /// No description provided for @durationHoursMinutes.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String durationHoursMinutes(int hours, int minutes);

  /// No description provided for @durationMinutesSeconds.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min {seconds} s'**
  String durationMinutesSeconds(int minutes, int seconds);

  /// No description provided for @durationSeconds.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String durationSeconds(int seconds);

  /// No description provided for @connectionInfoTimeTitle.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get connectionInfoTimeTitle;

  /// No description provided for @showHiddenGroups.
  ///
  /// In en, this message translates to:
  /// **'Show hidden groups'**
  String get showHiddenGroups;

  /// No description provided for @hideHiddenGroups.
  ///
  /// In en, this message translates to:
  /// **'Hide hidden groups'**
  String get hideHiddenGroups;

  /// No description provided for @strategyGroups.
  ///
  /// In en, this message translates to:
  /// **'Strategies'**
  String get strategyGroups;

  /// No description provided for @selectionsNotRestored.
  ///
  /// In en, this message translates to:
  /// **'Some selections were not restored'**
  String get selectionsNotRestored;

  /// No description provided for @noVisibleGroups.
  ///
  /// In en, this message translates to:
  /// **'No strategy groups are visible in the current mode.'**
  String get noVisibleGroups;

  /// No description provided for @unrestoredLine.
  ///
  /// In en, this message translates to:
  /// **'{name}: {value}'**
  String unrestoredLine(String name, String value);

  /// No description provided for @fixedTo.
  ///
  /// In en, this message translates to:
  /// **'Pinned: {name}'**
  String fixedTo(String name);

  /// No description provided for @unconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Unconfirmed'**
  String get unconfirmed;

  /// No description provided for @popupExpired.
  ///
  /// In en, this message translates to:
  /// **'This strategy is no longer valid. Close and reopen it; this content is read-only.'**
  String get popupExpired;

  /// No description provided for @popupSavedDiffers.
  ///
  /// In en, this message translates to:
  /// **'Saved: {name}; the actual selection is still shown by the current mark.'**
  String popupSavedDiffers(String name);

  /// No description provided for @popupSavedDiffersAuto.
  ///
  /// In en, this message translates to:
  /// **'Saved: auto; the actual selection is still shown by the current mark.'**
  String get popupSavedDiffersAuto;

  /// No description provided for @popupNotRestored.
  ///
  /// In en, this message translates to:
  /// **'Original selection not restored: {reason}'**
  String popupNotRestored(String reason);

  /// No description provided for @popupExpiredShort.
  ///
  /// In en, this message translates to:
  /// **'Expired · Reopen'**
  String get popupExpiredShort;

  /// No description provided for @popupSwitching.
  ///
  /// In en, this message translates to:
  /// **'Switching…'**
  String get popupSwitching;

  /// No description provided for @popupUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed · View reason'**
  String get popupUpdateFailed;

  /// No description provided for @popupSavedDiffersShort.
  ///
  /// In en, this message translates to:
  /// **'Saved differs from actual · View details'**
  String get popupSavedDiffersShort;

  /// No description provided for @popupNotRestoredShort.
  ///
  /// In en, this message translates to:
  /// **'Original selection not restored · View details'**
  String get popupNotRestoredShort;

  /// No description provided for @popupStale.
  ///
  /// In en, this message translates to:
  /// **'Status not updated'**
  String get popupStale;

  /// No description provided for @popupReading.
  ///
  /// In en, this message translates to:
  /// **'Reading strategy'**
  String get popupReading;

  /// No description provided for @autoLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get autoLabel;

  /// No description provided for @restoreAuto.
  ///
  /// In en, this message translates to:
  /// **'Restore auto'**
  String get restoreAuto;

  /// No description provided for @sameNameMember.
  ///
  /// In en, this message translates to:
  /// **'Same-name member'**
  String get sameNameMember;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// No description provided for @closeStrategyPopup.
  ///
  /// In en, this message translates to:
  /// **'Close strategy popup'**
  String get closeStrategyPopup;

  /// No description provided for @strategyChoiceSelect.
  ///
  /// In en, this message translates to:
  /// **'Manual select'**
  String get strategyChoiceSelect;

  /// No description provided for @strategyChoiceUrlTest.
  ///
  /// In en, this message translates to:
  /// **'Auto test'**
  String get strategyChoiceUrlTest;

  /// No description provided for @strategyChoiceFallback.
  ///
  /// In en, this message translates to:
  /// **'Fallback'**
  String get strategyChoiceFallback;

  /// No description provided for @strategyChoiceLoadBalance.
  ///
  /// In en, this message translates to:
  /// **'Load balance'**
  String get strategyChoiceLoadBalance;

  /// No description provided for @strategyGroupChanged.
  ///
  /// In en, this message translates to:
  /// **'The strategy group or member changed; this selection was not saved.'**
  String get strategyGroupChanged;

  /// No description provided for @strategySelectionUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The selection was saved for the next load; this switch was not confirmed.'**
  String get strategySelectionUnconfirmed;

  /// No description provided for @operationNotCompleted.
  ///
  /// In en, this message translates to:
  /// **'Operation not completed'**
  String get operationNotCompleted;

  /// No description provided for @configUpdated.
  ///
  /// In en, this message translates to:
  /// **'Configuration updated.'**
  String get configUpdated;

  /// No description provided for @settingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved.'**
  String get settingsSaved;

  /// No description provided for @operationInProgress.
  ///
  /// In en, this message translates to:
  /// **'Another operation is already running.'**
  String get operationInProgress;

  /// No description provided for @platformOperationFailed.
  ///
  /// In en, this message translates to:
  /// **'The platform operation did not finish; verify the tunnel state.'**
  String get platformOperationFailed;

  /// No description provided for @operationNotCompletedRetry.
  ///
  /// In en, this message translates to:
  /// **'Operation not completed; verify the state and retry.'**
  String get operationNotCompletedRetry;

  /// No description provided for @configTitle.
  ///
  /// In en, this message translates to:
  /// **'Configurations'**
  String get configTitle;

  /// No description provided for @configReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read configurations'**
  String get configReadFailed;

  /// No description provided for @noSavedConfigs.
  ///
  /// In en, this message translates to:
  /// **'No saved configurations'**
  String get noSavedConfigs;

  /// No description provided for @importOrCreateHint.
  ///
  /// In en, this message translates to:
  /// **'Import from a URL or file, or create a local configuration.'**
  String get importOrCreateHint;

  /// No description provided for @importFromUrl.
  ///
  /// In en, this message translates to:
  /// **'Import from URL'**
  String get importFromUrl;

  /// No description provided for @importFromFile.
  ///
  /// In en, this message translates to:
  /// **'Import from file'**
  String get importFromFile;

  /// No description provided for @newLocalConfig.
  ///
  /// In en, this message translates to:
  /// **'New local configuration'**
  String get newLocalConfig;

  /// No description provided for @addConfig.
  ///
  /// In en, this message translates to:
  /// **'Add configuration'**
  String get addConfig;

  /// No description provided for @localConfig.
  ///
  /// In en, this message translates to:
  /// **'Local configuration'**
  String get localConfig;

  /// No description provided for @nativeConfigurationUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Unsupported configuration field {field}: {reason}'**
  String nativeConfigurationUnsupported(String field, String reason);

  /// No description provided for @nativeReasonTunDisabled.
  ///
  /// In en, this message translates to:
  /// **'A VPN connection requires TUN to be enabled.'**
  String get nativeReasonTunDisabled;

  /// No description provided for @nativeReasonControllerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'External controller interfaces and their web UI are currently unsupported.'**
  String get nativeReasonControllerUnavailable;

  /// No description provided for @nativeReasonRootRedirection.
  ///
  /// In en, this message translates to:
  /// **'This traffic redirection requires privileged system access that the app does not provide.'**
  String get nativeReasonRootRedirection;

  /// No description provided for @nativeReasonTransparentSockets.
  ///
  /// In en, this message translates to:
  /// **'Transparent proxy sockets require privileged system access that the app does not provide.'**
  String get nativeReasonTransparentSockets;

  /// No description provided for @nativeReasonInterfaceBinding.
  ///
  /// In en, this message translates to:
  /// **'The app\'s socket protection does not support binding to a specified physical network interface.'**
  String get nativeReasonInterfaceBinding;

  /// No description provided for @nativeReasonRoutingMark.
  ///
  /// In en, this message translates to:
  /// **'Linux routing marks are not supported by this Android VPN integration.'**
  String get nativeReasonRoutingMark;

  /// No description provided for @nativeReasonTcpFastOpen.
  ///
  /// In en, this message translates to:
  /// **'The app\'s socket integration does not provide TCP Fast Open.'**
  String get nativeReasonTcpFastOpen;

  /// No description provided for @nativeReasonFirewall.
  ///
  /// In en, this message translates to:
  /// **'Managing iptables requires root access and is not supported by the app.'**
  String get nativeReasonFirewall;

  /// No description provided for @nativeReasonSystemClock.
  ///
  /// In en, this message translates to:
  /// **'The app cannot change the system clock through NTP.'**
  String get nativeReasonSystemClock;

  /// No description provided for @nativeReasonExternalFd.
  ///
  /// In en, this message translates to:
  /// **'Only the file descriptor created for this VPN session by Android VpnService is allowed.'**
  String get nativeReasonExternalFd;

  /// No description provided for @nativeReasonInterfaceName.
  ///
  /// In en, this message translates to:
  /// **'The Android VPN interface is created by the system and cannot be renamed using this setting.'**
  String get nativeReasonInterfaceName;

  /// No description provided for @nativeReasonGso.
  ///
  /// In en, this message translates to:
  /// **'The Android VPN interface does not expose a configurable GSO option.'**
  String get nativeReasonGso;

  /// No description provided for @nativeReasonAutoRedirect.
  ///
  /// In en, this message translates to:
  /// **'Automatic redirection requires netlink and firewall operations that this Android VPN integration does not provide.'**
  String get nativeReasonAutoRedirect;

  /// No description provided for @nativeReasonLinuxRouting.
  ///
  /// In en, this message translates to:
  /// **'This setting requires privileged Linux routing table or routing rule operations that the app does not provide.'**
  String get nativeReasonLinuxRouting;

  /// No description provided for @nativeReasonInterfaceFilter.
  ///
  /// In en, this message translates to:
  /// **'This Android VPN integration cannot apply network interface filters at this layer.'**
  String get nativeReasonInterfaceFilter;

  /// No description provided for @nativeReasonMacFilter.
  ///
  /// In en, this message translates to:
  /// **'This Android VPN integration cannot apply MAC address filters at this layer.'**
  String get nativeReasonMacFilter;

  /// No description provided for @nativeReasonPortFilter.
  ///
  /// In en, this message translates to:
  /// **'This Android VPN integration cannot apply source or destination port filters at this layer.'**
  String get nativeReasonPortFilter;

  /// No description provided for @nativeReasonStrictRoute.
  ///
  /// In en, this message translates to:
  /// **'Android VpnService cannot implement the Linux strict-routing rules required by this setting.'**
  String get nativeReasonStrictRoute;

  /// No description provided for @nativeReasonDnsHijackConflict.
  ///
  /// In en, this message translates to:
  /// **'DNS hijacking cannot be configured while DNS is disabled.'**
  String get nativeReasonDnsHijackConflict;

  /// No description provided for @nativeReasonIpv6Unavailable.
  ///
  /// In en, this message translates to:
  /// **'The requested IPv6 address or address pool is unavailable because IPv6 is disabled or unavailable on this device.'**
  String get nativeReasonIpv6Unavailable;

  /// No description provided for @nativeReasonInvalidMtu.
  ///
  /// In en, this message translates to:
  /// **'The MTU must be between 1 and 65535, and at least 1280 when IPv6 is used.'**
  String get nativeReasonInvalidMtu;

  /// No description provided for @nativeReasonInvalidAddress.
  ///
  /// In en, this message translates to:
  /// **'The derived VPN interface address or its required next address is invalid.'**
  String get nativeReasonInvalidAddress;

  /// No description provided for @nativeReasonSystemDnsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'DNS servers from the underlying non-VPN network are unavailable; public DNS is not used as a fallback.'**
  String get nativeReasonSystemDnsUnavailable;

  /// No description provided for @nativeReasonPrivateDnsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Strict Android Private DNS has no verified equivalent secure channel here; falling back to plaintext DNS is not allowed.'**
  String get nativeReasonPrivateDnsUnavailable;

  /// No description provided for @nativeReasonProviderPath.
  ///
  /// In en, this message translates to:
  /// **'The provider path failed directory, symbolic-link, protected-file, or target-identity safety checks.'**
  String get nativeReasonProviderPath;

  /// No description provided for @nativeReasonAndroidUserUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The app can enumerate and manage applications only for the current Android user; filters for other users or their UIDs are not supported.'**
  String get nativeReasonAndroidUserUnavailable;

  /// No description provided for @storageContextChanged.
  ///
  /// In en, this message translates to:
  /// **'The data was restored or replaced. Reopen this page. Unsubmitted input can still be copied and kept.'**
  String get storageContextChanged;

  /// No description provided for @storageSyncUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The content was saved, but storage synchronization could not be confirmed. This change may be lost if power is suddenly interrupted.'**
  String get storageSyncUnconfirmed;

  /// No description provided for @storageSyncWarning.
  ///
  /// In en, this message translates to:
  /// **'{result}\n\nThe content was saved, but storage synchronization could not be confirmed. This change may be lost if power is suddenly interrupted.'**
  String storageSyncWarning(String result);

  /// No description provided for @storageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Configurations, plugins and settings are temporarily unavailable. Wait for data recovery to be confirmed before continuing. Stopping the connection is still available.'**
  String get storageUnavailable;

  /// No description provided for @trustedRootsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not read or parse the default trusted root certificates. Try again.'**
  String get trustedRootsUnavailable;

  /// No description provided for @nameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a non-empty configuration name of at most 80 UTF-8 bytes.'**
  String get nameInvalid;

  /// No description provided for @operationBusyFile.
  ///
  /// In en, this message translates to:
  /// **'Another operation is running; the file was not submitted. Wait and choose again.'**
  String get operationBusyFile;

  /// No description provided for @importResultUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The import result was not confirmed. The list was re-read and the import was not retried; verify whether it was saved.'**
  String get importResultUnconfirmed;

  /// No description provided for @fileUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Could not read the selected file; no configuration was created. Check the file and retry.'**
  String get fileUnreadable;

  /// No description provided for @runningOldBody.
  ///
  /// In en, this message translates to:
  /// **'In use · Previous content'**
  String get runningOldBody;

  /// No description provided for @runningConfig.
  ///
  /// In en, this message translates to:
  /// **'In use'**
  String get runningConfig;

  /// No description provided for @updateConfig.
  ///
  /// In en, this message translates to:
  /// **'Update configuration'**
  String get updateConfig;

  /// No description provided for @editConfig.
  ///
  /// In en, this message translates to:
  /// **'Edit configuration'**
  String get editConfig;

  /// No description provided for @moreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get moreActions;

  /// No description provided for @configActionFailed.
  ///
  /// In en, this message translates to:
  /// **'Configuration action not completed'**
  String get configActionFailed;

  /// No description provided for @viewConfigError.
  ///
  /// In en, this message translates to:
  /// **'View configuration error'**
  String get viewConfigError;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @changeSourceUpdate.
  ///
  /// In en, this message translates to:
  /// **'Change source and update'**
  String get changeSourceUpdate;

  /// No description provided for @autoUpdateHours.
  ///
  /// In en, this message translates to:
  /// **'Auto-update: every {hours} hours'**
  String autoUpdateHours(int hours);

  /// No description provided for @autoUpdateClosed.
  ///
  /// In en, this message translates to:
  /// **'Auto-update (off)'**
  String get autoUpdateClosed;

  /// No description provided for @viewBody.
  ///
  /// In en, this message translates to:
  /// **'View content'**
  String get viewBody;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @updatedAt.
  ///
  /// In en, this message translates to:
  /// **'Updated {date} {time}'**
  String updatedAt(String date, String time);

  /// No description provided for @savedAt.
  ///
  /// In en, this message translates to:
  /// **'Saved {date} {time}'**
  String savedAt(String date, String time);

  /// No description provided for @updateTimeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Update time unknown'**
  String get updateTimeUnknown;

  /// No description provided for @saveTimeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Save time unknown'**
  String get saveTimeUnknown;

  /// No description provided for @deleteConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete configuration?'**
  String get deleteConfigTitle;

  /// No description provided for @deleteKeepsSelection.
  ///
  /// In en, this message translates to:
  /// **'The current selection and tunnel are unchanged.'**
  String get deleteKeepsSelection;

  /// No description provided for @deleteNoSelection.
  ///
  /// In en, this message translates to:
  /// **'The saved selection will be cleared; no replacement will be selected.'**
  String get deleteNoSelection;

  /// No description provided for @deleteRemoteBody.
  ///
  /// In en, this message translates to:
  /// **'The saved content and source will be deleted. This does not stop the running tunnel.'**
  String get deleteRemoteBody;

  /// No description provided for @deleteLocalBody.
  ///
  /// In en, this message translates to:
  /// **'The saved local content will be deleted. This does not stop the running tunnel.'**
  String get deleteLocalBody;

  /// No description provided for @renameConfig.
  ///
  /// In en, this message translates to:
  /// **'Rename configuration'**
  String get renameConfig;

  /// No description provided for @changeConfigSource.
  ///
  /// In en, this message translates to:
  /// **'Change configuration source'**
  String get changeConfigSource;

  /// No description provided for @configName.
  ///
  /// In en, this message translates to:
  /// **'Configuration name'**
  String get configName;

  /// No description provided for @configUrl.
  ///
  /// In en, this message translates to:
  /// **'Full configuration URL'**
  String get configUrl;

  /// No description provided for @showUrl.
  ///
  /// In en, this message translates to:
  /// **'Show URL'**
  String get showUrl;

  /// No description provided for @hideUrl.
  ///
  /// In en, this message translates to:
  /// **'Hide URL'**
  String get hideUrl;

  /// No description provided for @nameOptional.
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get nameOptional;

  /// No description provided for @nameOptionalHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the source host name'**
  String get nameOptionalHint;

  /// No description provided for @importFullConfig.
  ///
  /// In en, this message translates to:
  /// **'Import full configuration'**
  String get importFullConfig;

  /// No description provided for @importFullConfigNotice.
  ///
  /// In en, this message translates to:
  /// **'Saves a complete mihomo configuration; the core parses it at start. Node subscriptions are not converted.'**
  String get importFullConfigNotice;

  /// No description provided for @downloadAndSave.
  ///
  /// In en, this message translates to:
  /// **'Download and save'**
  String get downloadAndSave;

  /// No description provided for @saveAndUpdate.
  ///
  /// In en, this message translates to:
  /// **'Save and update'**
  String get saveAndUpdate;

  /// No description provided for @overwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get overwrite;

  /// No description provided for @leaveBodyTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave the content?'**
  String get leaveBodyTitle;

  /// No description provided for @leaveBodyMessage.
  ///
  /// In en, this message translates to:
  /// **'A submitted save is not cancelled by leaving. The result is unconfirmed; check the configuration list and do not submit again.'**
  String get leaveBodyMessage;

  /// No description provided for @leave.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// No description provided for @discardEditsTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard unsaved changes?'**
  String get discardEditsTitle;

  /// No description provided for @discardEditsMessage.
  ///
  /// In en, this message translates to:
  /// **'This input exists only on this page and will not be saved.'**
  String get discardEditsMessage;

  /// No description provided for @nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a configuration name.'**
  String get nameRequired;

  /// No description provided for @normalizeNewlinesTitle.
  ///
  /// In en, this message translates to:
  /// **'Normalize mixed line endings?'**
  String get normalizeNewlinesTitle;

  /// No description provided for @normalizeNewlinesMessage.
  ///
  /// In en, this message translates to:
  /// **'This content uses more than one line ending style. Saving will normalize it to the primary style; the BOM is preserved.'**
  String get normalizeNewlinesMessage;

  /// No description provided for @normalizeAndSave.
  ///
  /// In en, this message translates to:
  /// **'Normalize and save'**
  String get normalizeAndSave;

  /// No description provided for @submittedSavedTitle.
  ///
  /// In en, this message translates to:
  /// **'Submitted version saved'**
  String get submittedSavedTitle;

  /// No description provided for @submittedSavedMessage.
  ///
  /// In en, this message translates to:
  /// **'The submitted content was saved; later edits remain in the editor and are not saved.'**
  String get submittedSavedMessage;

  /// No description provided for @saveUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Save result unconfirmed. Configurations were re-read; check the list. The current input is kept and was not retried automatically.'**
  String get saveUnconfirmed;

  /// No description provided for @savedApplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Saved, apply not completed'**
  String get savedApplyFailed;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get saveFailed;

  /// No description provided for @findBody.
  ///
  /// In en, this message translates to:
  /// **'Find in content'**
  String get findBody;

  /// No description provided for @previousMatch.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previousMatch;

  /// No description provided for @nextMatch.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get nextMatch;

  /// No description provided for @closeFind.
  ///
  /// In en, this message translates to:
  /// **'Close find'**
  String get closeFind;

  /// No description provided for @readOnly.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get readOnly;

  /// No description provided for @saving.
  ///
  /// In en, this message translates to:
  /// **'Saving'**
  String get saving;

  /// No description provided for @resultUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Result unconfirmed'**
  String get resultUnconfirmed;

  /// No description provided for @tooLarge.
  ///
  /// In en, this message translates to:
  /// **'Over 16 MiB · Not truncated'**
  String get tooLarge;

  /// No description provided for @sizePending.
  ///
  /// In en, this message translates to:
  /// **'Size pending · Recheck on save'**
  String get sizePending;

  /// No description provided for @unsavedChanges.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get unsavedChanges;

  /// No description provided for @configBody.
  ///
  /// In en, this message translates to:
  /// **'Configuration content'**
  String get configBody;

  /// No description provided for @find.
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get find;

  /// No description provided for @softWrap.
  ///
  /// In en, this message translates to:
  /// **'Soft wrap'**
  String get softWrap;

  /// No description provided for @saveAndApply.
  ///
  /// In en, this message translates to:
  /// **'Save and apply'**
  String get saveAndApply;

  /// No description provided for @bodyUnreadable.
  ///
  /// In en, this message translates to:
  /// **'No usable content; update the source first.'**
  String get bodyUnreadable;

  /// No description provided for @bodyPrepFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not prepare the configuration content; go back and retry.'**
  String get bodyPrepFailed;

  /// No description provided for @editorLineTooLong.
  ///
  /// In en, this message translates to:
  /// **'Line {line} exceeds the editing limit of {limit} UTF-16 code units. Showing the complete original text in read-only blocks.'**
  String editorLineTooLong(int line, int limit);

  /// No description provided for @editorQueryTooLong.
  ///
  /// In en, this message translates to:
  /// **'Find text is limited to {limit} UTF-16 code units.'**
  String editorQueryTooLong(int limit);

  /// No description provided for @editorChangeTooLong.
  ///
  /// In en, this message translates to:
  /// **'Change rejected: line {line} would exceed {limit} UTF-16 code units. Existing input is unchanged.'**
  String editorChangeTooLong(int line, int limit);

  /// No description provided for @editorContextChanged.
  ///
  /// In en, this message translates to:
  /// **'Saving is unavailable; the draft is retained.'**
  String get editorContextChanged;

  /// No description provided for @privacyNoticeTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy and license'**
  String get privacyNoticeTitle;

  /// No description provided for @privacyNoticeUnderstood.
  ///
  /// In en, this message translates to:
  /// **'Understood'**
  String get privacyNoticeUnderstood;

  /// No description provided for @privacyNoticeNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Could not confirm that the notice was recorded. It may appear again on next launch.'**
  String get privacyNoticeNotSaved;

  /// No description provided for @privacyNoticeBody.
  ///
  /// In en, this message translates to:
  /// **'Clash Pseudo is free and open source. It does not collect or report user data and does not provide any proxy nodes or subscription services.\n\nData processing\n\nThe app does not include usage analytics, behavioral analysis, or automatic crash reporting. Configurations, plugins, and app settings are stored on the device. Proxying and rule matching process traffic, domains, and IP addresses on the device. Connection information and logs support display and diagnostics; the installed app list is used to choose which apps the VPN handles.\n\nNetwork communication\n\nConfiguration and plugin downloads, DNS queries, proxy connections, latency tests, remote icons, and rule or geographic database updates contact their respective network services. Destinations come from configurations and application defaults. Turning off VPN traffic handling does not disable network access for these features.\n\nRequests send the content and authentication information needed by the feature, and the receiving service sees the connection\'s source IP address. Downloads from HTTP sources have no transport encryption.\n\nPermission purposes\n\n- Internet access and network state: establish connections, download content, and check the network.\n- Foreground services and notifications: run the VPN, local network proxy service, and background tasks and display their status.\n- Installed app visibility: display the app list and choose which apps the VPN handles.\n- VPN authorization: create a VPN interface after Android authorization and handle traffic within the selected scope.\n\nFiles and backups\n\nConfiguration and plugin contents, source addresses, and credentials saved in them are stored in the app\'s private directory without additional application-level encryption. Exported ZIP files are not encrypted and include configurations, plugins, app settings, and the source addresses and credentials saved in them. Backup import and export are available under Settings → Storage and data and use Android\'s file picker; the save location is chosen during export.\n\nAndroid system backup and device transfer can copy configurations, plugins, and app settings. Whether they are enabled depends on system settings and the backup service in use. A file provider\'s synchronization features can also keep cloud copies of selected files.\n\nConnection records, core logs, and original content\n\nRecent connection records and logs are held only in device memory, within bounded capacities and retention windows. They are not saved as history files. They can be cleared on their respective pages and disappear when the process ends.\n\nSettings → Diagnostics → Core logs displays core operation, connection, and error messages. Retained logs show original core messages. When capacity is insufficient, whole entries are removed or skipped and omissions are reported; message content is not truncated or rewritten. The configuration editor and backups retain original content.\n\nDeleting data and viewing this notice\n\nConfigurations and plugins can be deleted in the app, recent records and logs can be cleared, and the cache database and rebuildable geographic data files can be selected individually for cleanup. The core must stop before cleanup. Only confirmed files are deleted; protocol identities, custom provider files, and other user files are retained.\n\nVPN authorization can also be revoked and app data cleared in Android settings. Clearing app data or uninstalling does not delete exported files, system backups, or other external copies.\n\nThis notice is updated as features change. The version included with the current installation is available under Settings → About.\n\nProject repository\n\nhttps://github.com/MonadBoxLab/ClashPseudo\n\nSee GPLv3 for more information.'**
  String get privacyNoticeBody;

  /// No description provided for @privacyNoticeIntro.
  ///
  /// In en, this message translates to:
  /// **'Clash Pseudo is free and open source. It does not collect or report user data and does not provide any proxy nodes or subscription services.'**
  String get privacyNoticeIntro;

  /// No description provided for @privacyNoticeReadFull.
  ///
  /// In en, this message translates to:
  /// **'Full notice'**
  String get privacyNoticeReadFull;

  /// No description provided for @privacyNoticeLicenseNotice.
  ///
  /// In en, this message translates to:
  /// **'See GPLv3 for more information.'**
  String get privacyNoticeLicenseNotice;

  /// No description provided for @privacyNoticeLicenseName.
  ///
  /// In en, this message translates to:
  /// **'GPLv3'**
  String get privacyNoticeLicenseName;

  /// No description provided for @projectRepositoryUrl.
  ///
  /// In en, this message translates to:
  /// **'https://github.com/MonadBoxLab/ClashPseudo'**
  String get projectRepositoryUrl;

  /// No description provided for @privacyDataProcessingTitle.
  ///
  /// In en, this message translates to:
  /// **'Data processing'**
  String get privacyDataProcessingTitle;

  /// No description provided for @privacyDataProcessingBody.
  ///
  /// In en, this message translates to:
  /// **'The app does not include usage analytics, behavioral analysis, or automatic crash reporting. Configurations, plugins, and app settings are stored on the device. Proxying and rule matching process traffic, domains, and IP addresses on the device. Connection information and logs support display and diagnostics; the installed app list is used to choose which apps the VPN handles.'**
  String get privacyDataProcessingBody;

  /// No description provided for @privacyNetworkCommunicationTitle.
  ///
  /// In en, this message translates to:
  /// **'Network communication'**
  String get privacyNetworkCommunicationTitle;

  /// No description provided for @privacyNetworkCommunicationBody.
  ///
  /// In en, this message translates to:
  /// **'Configuration and plugin downloads, DNS queries, proxy connections, latency tests, remote icons, and rule or geographic database updates contact their respective network services. Destinations come from configurations and application defaults. Turning off VPN traffic handling does not disable network access for these features.\n\nRequests send the content and authentication information needed by the feature, and the receiving service sees the connection\'s source IP address. Downloads from HTTP sources have no transport encryption.'**
  String get privacyNetworkCommunicationBody;

  /// No description provided for @privacyPermissionPurposesTitle.
  ///
  /// In en, this message translates to:
  /// **'Permission purposes'**
  String get privacyPermissionPurposesTitle;

  /// No description provided for @privacyPermissionPurposesBody.
  ///
  /// In en, this message translates to:
  /// **'- Internet access and network state: establish connections, download content, and check the network.\n- Foreground services and notifications: run the VPN, local network proxy service, and background tasks and display their status.\n- Installed app visibility: display the app list and choose which apps the VPN handles.\n- VPN authorization: create a VPN interface after Android authorization and handle traffic within the selected scope.'**
  String get privacyPermissionPurposesBody;

  /// No description provided for @privacyFilesAndBackupsTitle.
  ///
  /// In en, this message translates to:
  /// **'Files and backups'**
  String get privacyFilesAndBackupsTitle;

  /// No description provided for @privacyFilesAndBackupsBody.
  ///
  /// In en, this message translates to:
  /// **'Configuration and plugin contents, source addresses, and credentials saved in them are stored in the app\'s private directory without additional application-level encryption. Exported ZIP files are not encrypted and include configurations, plugins, app settings, and the source addresses and credentials saved in them. Backup import and export are available under Settings → Storage and data and use Android\'s file picker; the save location is chosen during export.\n\nAndroid system backup and device transfer can copy configurations, plugins, and app settings. Whether they are enabled depends on system settings and the backup service in use. A file provider\'s synchronization features can also keep cloud copies of selected files.'**
  String get privacyFilesAndBackupsBody;

  /// No description provided for @privacyRecordsAndLogsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection records, core logs, and original content'**
  String get privacyRecordsAndLogsTitle;

  /// No description provided for @privacyRecordsAndLogsBody.
  ///
  /// In en, this message translates to:
  /// **'Recent connection records and logs are held only in device memory, within bounded capacities and retention windows. They are not saved as history files. They can be cleared on their respective pages and disappear when the process ends.\n\nSettings → Diagnostics → Core logs displays core operation, connection, and error messages. Retained logs show original core messages. When capacity is insufficient, whole entries are removed or skipped and omissions are reported; message content is not truncated or rewritten. The configuration editor and backups retain original content.'**
  String get privacyRecordsAndLogsBody;

  /// No description provided for @privacyDeletingDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Deleting data and viewing this notice'**
  String get privacyDeletingDataTitle;

  /// No description provided for @privacyDeletingDataBody.
  ///
  /// In en, this message translates to:
  /// **'Configurations and plugins can be deleted in the app, recent records and logs can be cleared, and the cache database and rebuildable geographic data files can be selected individually for cleanup. The core must stop before cleanup. Only confirmed files are deleted; protocol identities, custom provider files, and other user files are retained.\n\nVPN authorization can also be revoked and app data cleared in Android settings. Clearing app data or uninstalling does not delete exported files, system backups, or other external copies.\n\nThis notice is updated as features change. The version included with the current installation is available under Settings → About.'**
  String get privacyDeletingDataBody;

  /// No description provided for @privacyProjectRepositoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Project repository'**
  String get privacyProjectRepositoryTitle;

  /// No description provided for @noUsableBodyReimport.
  ///
  /// In en, this message translates to:
  /// **'This configuration has no usable content; update the source again.'**
  String get noUsableBodyReimport;

  /// No description provided for @requestNotAccepted.
  ///
  /// In en, this message translates to:
  /// **'The request was not accepted; try again.'**
  String get requestNotAccepted;

  /// No description provided for @temporaryModeUnknown.
  ///
  /// In en, this message translates to:
  /// **'The running mode cannot be confirmed yet; the app will retry while in the foreground.'**
  String get temporaryModeUnknown;

  /// No description provided for @temporaryStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Status is temporarily unavailable; the app will retry while in the foreground and will not start the tunnel automatically.'**
  String get temporaryStatusUnavailable;

  /// No description provided for @temporaryConfigsUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Saved configurations cannot be read right now; the file was not changed.'**
  String get temporaryConfigsUnreadable;

  /// No description provided for @temporaryOverridesUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Saved plugins cannot be read right now; the file was not changed.'**
  String get temporaryOverridesUnreadable;

  /// No description provided for @temporarySettingsUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Saved settings cannot be read right now; the file was not changed.'**
  String get temporarySettingsUnreadable;

  /// No description provided for @failure.
  ///
  /// In en, this message translates to:
  /// **'Failure'**
  String get failure;

  /// No description provided for @stageStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping the tunnel'**
  String get stageStopping;

  /// No description provided for @tunnelStopped.
  ///
  /// In en, this message translates to:
  /// **'Tunnel stopped.'**
  String get tunnelStopped;

  /// No description provided for @statusUnconfirmedVerify.
  ///
  /// In en, this message translates to:
  /// **'Tunnel status is unconfirmed; verify the state first.'**
  String get statusUnconfirmedVerify;

  /// No description provided for @importAndSelectFirst.
  ///
  /// In en, this message translates to:
  /// **'Import and select a configuration first.'**
  String get importAndSelectFirst;

  /// No description provided for @configChangedWaitStrategies.
  ///
  /// In en, this message translates to:
  /// **'The configuration changed; wait for strategies to reload.'**
  String get configChangedWaitStrategies;

  /// No description provided for @coreNotReadyStrategies.
  ///
  /// In en, this message translates to:
  /// **'Core resources are unconfirmed; strategies cannot load yet.'**
  String get coreNotReadyStrategies;

  /// No description provided for @previewMismatch.
  ///
  /// In en, this message translates to:
  /// **'The running configuration does not match the preview request.'**
  String get previewMismatch;

  /// No description provided for @stageLoadingStrategies.
  ///
  /// In en, this message translates to:
  /// **'Loading the strategy configuration'**
  String get stageLoadingStrategies;

  /// No description provided for @localCannotRemoteUpdate.
  ///
  /// In en, this message translates to:
  /// **'Local configurations cannot be updated remotely.'**
  String get localCannotRemoteUpdate;

  /// No description provided for @configRenamed.
  ///
  /// In en, this message translates to:
  /// **'Configuration renamed.'**
  String get configRenamed;

  /// No description provided for @alreadyRunning.
  ///
  /// In en, this message translates to:
  /// **'The tunnel is already running; no need to start again.'**
  String get alreadyRunning;

  /// No description provided for @tunnelStarted.
  ///
  /// In en, this message translates to:
  /// **'Tunnel started.'**
  String get tunnelStarted;

  /// No description provided for @unknownOperation.
  ///
  /// In en, this message translates to:
  /// **'This operation is not recognized.'**
  String get unknownOperation;

  /// No description provided for @localCannotChangeRemote.
  ///
  /// In en, this message translates to:
  /// **'Local configurations cannot change their remote source.'**
  String get localCannotChangeRemote;

  /// No description provided for @sourceUsedBy.
  ///
  /// In en, this message translates to:
  /// **'This source is already used by \"{name}\"; choose the existing configuration.'**
  String sourceUsedBy(String name);

  /// No description provided for @sourceSavedConfirmOverwrite.
  ///
  /// In en, this message translates to:
  /// **'This source is already saved; confirm whether to overwrite it.'**
  String get sourceSavedConfirmOverwrite;

  /// No description provided for @updateInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Update did not finish; update this source again.'**
  String get updateInterrupted;

  /// No description provided for @stageDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading configuration'**
  String get stageDownloading;

  /// No description provided for @stageUpdatingConfig.
  ///
  /// In en, this message translates to:
  /// **'Updating configuration'**
  String get stageUpdatingConfig;

  /// No description provided for @updateStateWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'The update state could not be saved, so the update did not start. The old record is unchanged; fix storage and retry.'**
  String get updateStateWriteFailed;

  /// No description provided for @stageStoppingOld.
  ///
  /// In en, this message translates to:
  /// **'Stopping the previous tunnel'**
  String get stageStoppingOld;

  /// No description provided for @configUpdatedRestarted.
  ///
  /// In en, this message translates to:
  /// **'Configuration updated and restarted.'**
  String get configUpdatedRestarted;

  /// No description provided for @configSavedParsedAtStart.
  ///
  /// In en, this message translates to:
  /// **'Configuration saved; the core parses it at start.'**
  String get configSavedParsedAtStart;

  /// No description provided for @configChangedReopen.
  ///
  /// In en, this message translates to:
  /// **'The configuration was deleted, its content changed, or it is not editable. Reopen it; this input was not saved.'**
  String get configChangedReopen;

  /// No description provided for @stageSavingConfig.
  ///
  /// In en, this message translates to:
  /// **'Saving configuration'**
  String get stageSavingConfig;

  /// No description provided for @configSavedApplied.
  ///
  /// In en, this message translates to:
  /// **'Configuration saved and applied.'**
  String get configSavedApplied;

  /// No description provided for @configSavedApplyReleasePending.
  ///
  /// In en, this message translates to:
  /// **'Configuration saved, but applying or releasing the old preview did not finish. Verify the tunnel state; the new content was kept.'**
  String get configSavedApplyReleasePending;

  /// No description provided for @configSaved.
  ///
  /// In en, this message translates to:
  /// **'Configuration saved.'**
  String get configSaved;

  /// No description provided for @localNoAutoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Local configurations have no auto-update setting.'**
  String get localNoAutoUpdate;

  /// No description provided for @chooseUpdateInterval.
  ///
  /// In en, this message translates to:
  /// **'Choose a 6, 12 or 24 hour update interval.'**
  String get chooseUpdateInterval;

  /// No description provided for @autoUpdateEnabledResult.
  ///
  /// In en, this message translates to:
  /// **'Auto-update enabled.'**
  String get autoUpdateEnabledResult;

  /// No description provided for @autoUpdateDisabledResult.
  ///
  /// In en, this message translates to:
  /// **'Auto-update off.'**
  String get autoUpdateDisabledResult;

  /// No description provided for @configNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a non-empty configuration name of at most 80 UTF-8 bytes.'**
  String get configNameInvalid;

  /// No description provided for @switchedConfig.
  ///
  /// In en, this message translates to:
  /// **'Running configuration switched.'**
  String get switchedConfig;

  /// No description provided for @configSelectedNotStarted.
  ///
  /// In en, this message translates to:
  /// **'Configuration selected; the tunnel has not started.'**
  String get configSelectedNotStarted;

  /// No description provided for @configDeleted.
  ///
  /// In en, this message translates to:
  /// **'Configuration deleted; the tunnel was not started.'**
  String get configDeleted;

  /// No description provided for @modeSavedNextStart.
  ///
  /// In en, this message translates to:
  /// **'Mode fallback saved; used on startup only if the configuration does not specify a mode.'**
  String get modeSavedNextStart;

  /// No description provided for @modeConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Running mode confirmed.'**
  String get modeConfirmed;

  /// No description provided for @stageSwitchingMode.
  ///
  /// In en, this message translates to:
  /// **'Switching the running mode'**
  String get stageSwitchingMode;

  /// No description provided for @modeNotConfirmed.
  ///
  /// In en, this message translates to:
  /// **'Mode fallback saved, but this running-mode switch was not confirmed. The fallback is used on startup only if the configuration does not specify a mode.'**
  String get modeNotConfirmed;

  /// No description provided for @modeSwitchedResult.
  ///
  /// In en, this message translates to:
  /// **'Running mode switched.'**
  String get modeSwitchedResult;

  /// No description provided for @alreadyRunningNoRestore.
  ///
  /// In en, this message translates to:
  /// **'The tunnel is already running; no system restore is needed.'**
  String get alreadyRunningNoRestore;

  /// No description provided for @systemStartUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This platform does not support system start.'**
  String get systemStartUnsupported;

  /// No description provided for @noConfigForSystemStart.
  ///
  /// In en, this message translates to:
  /// **'No selected configuration is available; the system start was cancelled.'**
  String get noConfigForSystemStart;

  /// No description provided for @stagePreparingSystemStart.
  ///
  /// In en, this message translates to:
  /// **'Preparing the system start'**
  String get stagePreparingSystemStart;

  /// No description provided for @systemStartPrepared.
  ///
  /// In en, this message translates to:
  /// **'System start prepared.'**
  String get systemStartPrepared;

  /// No description provided for @accessSavedNextConnection.
  ///
  /// In en, this message translates to:
  /// **'Application access saved; it applies on the next connection.'**
  String get accessSavedNextConnection;

  /// No description provided for @accessSavedReconnectFailed.
  ///
  /// In en, this message translates to:
  /// **'The running configuration is unavailable; the setting was saved but reconnecting did not finish.'**
  String get accessSavedReconnectFailed;

  /// No description provided for @stageReconnectAccess.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting to apply application access'**
  String get stageReconnectAccess;

  /// No description provided for @accessSavedReconnected.
  ///
  /// In en, this message translates to:
  /// **'Application access saved and the tunnel reconnected.'**
  String get accessSavedReconnected;

  /// No description provided for @overridesSavedNextStart.
  ///
  /// In en, this message translates to:
  /// **'Plugins saved; they apply on the next start.'**
  String get overridesSavedNextStart;

  /// No description provided for @runningConfigMissingOverrides.
  ///
  /// In en, this message translates to:
  /// **'The running configuration is no longer in the list; plugins cannot be applied.'**
  String get runningConfigMissingOverrides;

  /// No description provided for @runningConfigNoBody.
  ///
  /// In en, this message translates to:
  /// **'The running configuration has no usable content; it cannot restart.'**
  String get runningConfigNoBody;

  /// No description provided for @overridesAppliedReconnected.
  ///
  /// In en, this message translates to:
  /// **'Plugins applied and the tunnel reconnected.'**
  String get overridesAppliedReconnected;

  /// No description provided for @stageWaitingVpnAuth.
  ///
  /// In en, this message translates to:
  /// **'Waiting for VPN authorization'**
  String get stageWaitingVpnAuth;

  /// No description provided for @authorizationCancelled.
  ///
  /// In en, this message translates to:
  /// **'Authorization was cancelled; the tunnel stays stopped.'**
  String get authorizationCancelled;

  /// No description provided for @stageStartingTunnel.
  ///
  /// In en, this message translates to:
  /// **'Starting the tunnel'**
  String get stageStartingTunnel;

  /// No description provided for @configMissingRefresh.
  ///
  /// In en, this message translates to:
  /// **'The configuration no longer exists; refresh the list.'**
  String get configMissingRefresh;

  /// No description provided for @operationFinished.
  ///
  /// In en, this message translates to:
  /// **'The operation has ended.'**
  String get operationFinished;

  /// No description provided for @overrideMissingRefresh.
  ///
  /// In en, this message translates to:
  /// **'The plugin no longer exists; refresh the list.'**
  String get overrideMissingRefresh;

  /// No description provided for @remoteOverrideReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Remote plugin text is read-only; change the source or create a local plugin.'**
  String get remoteOverrideReadOnly;

  /// No description provided for @overrideChangedReopen.
  ///
  /// In en, this message translates to:
  /// **'The plugin text changed; reopen it before editing.'**
  String get overrideChangedReopen;

  /// No description provided for @overrideSavedApplyLater.
  ///
  /// In en, this message translates to:
  /// **'Plugin saved.'**
  String get overrideSavedApplyLater;

  /// No description provided for @localOverrideNoRemoteUpdate.
  ///
  /// In en, this message translates to:
  /// **'Local plugins cannot be updated remotely.'**
  String get localOverrideNoRemoteUpdate;

  /// No description provided for @overrideNoBodyEnable.
  ///
  /// In en, this message translates to:
  /// **'The plugin has no usable content; update it before enabling.'**
  String get overrideNoBodyEnable;

  /// No description provided for @overrideSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Plugin settings saved.'**
  String get overrideSettingsSaved;

  /// No description provided for @overrideOrderChangedRefresh.
  ///
  /// In en, this message translates to:
  /// **'The plugin list changed; refresh and reorder again.'**
  String get overrideOrderChangedRefresh;

  /// No description provided for @overrideOrderSaved.
  ///
  /// In en, this message translates to:
  /// **'Plugin order saved.'**
  String get overrideOrderSaved;

  /// No description provided for @overrideDeleted.
  ///
  /// In en, this message translates to:
  /// **'Plugin deleted.'**
  String get overrideDeleted;

  /// No description provided for @unknownOverrideOperation.
  ///
  /// In en, this message translates to:
  /// **'This plugin operation is not recognized.'**
  String get unknownOverrideOperation;

  /// No description provided for @localOverrideNoAutoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Local plugins have no auto-update setting.'**
  String get localOverrideNoAutoUpdate;

  /// No description provided for @overrideAutoUpdateEnabled.
  ///
  /// In en, this message translates to:
  /// **'Plugin auto-update enabled.'**
  String get overrideAutoUpdateEnabled;

  /// No description provided for @overrideAutoUpdateDisabled.
  ///
  /// In en, this message translates to:
  /// **'Plugin auto-update off.'**
  String get overrideAutoUpdateDisabled;

  /// No description provided for @overrideSourceExists.
  ///
  /// In en, this message translates to:
  /// **'A plugin already uses this source; update the existing one.'**
  String get overrideSourceExists;

  /// No description provided for @overrideUpdateIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Update did not finish; try again.'**
  String get overrideUpdateIncomplete;

  /// No description provided for @overrideChangedNotApplied.
  ///
  /// In en, this message translates to:
  /// **'The plugin changed; the download result was not applied.'**
  String get overrideChangedNotApplied;

  /// No description provided for @overrideUpdatedApplyLater.
  ///
  /// In en, this message translates to:
  /// **'Plugin updated.'**
  String get overrideUpdatedApplyLater;

  /// No description provided for @overrideNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a non-empty plugin name of at most 80 UTF-8 bytes.'**
  String get overrideNameInvalid;

  /// No description provided for @overridesUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Saved plugins could not be read; the file was not changed.'**
  String get overridesUnreadable;

  /// No description provided for @overridesSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Saving plugins failed; check available storage and retry.'**
  String get overridesSaveFailed;

  /// No description provided for @overrideBodyMissing.
  ///
  /// In en, this message translates to:
  /// **'An enabled plugin has no usable content; update or disable it first.'**
  String get overrideBodyMissing;

  /// No description provided for @overridesTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Enabled plugin content exceeds 16 MiB in total.'**
  String get overridesTooLarge;

  /// No description provided for @schedulesSynced.
  ///
  /// In en, this message translates to:
  /// **'Auto-update schedules synced.'**
  String get schedulesSynced;

  /// No description provided for @unknownUpdateTarget.
  ///
  /// In en, this message translates to:
  /// **'This update target is not recognized.'**
  String get unknownUpdateTarget;

  /// No description provided for @targetGoneOrDisabled.
  ///
  /// In en, this message translates to:
  /// **'The target no longer exists or auto-update is off.'**
  String get targetGoneOrDisabled;

  /// No description provided for @configChangedDownloadUnapplied.
  ///
  /// In en, this message translates to:
  /// **'The configuration changed; the download result was not applied.'**
  String get configChangedDownloadUnapplied;

  /// No description provided for @configUnchanged.
  ///
  /// In en, this message translates to:
  /// **'The configuration content did not change.'**
  String get configUnchanged;

  /// No description provided for @configUpdatedPending.
  ///
  /// In en, this message translates to:
  /// **'Configuration updated and saved.'**
  String get configUpdatedPending;

  /// No description provided for @stageApplyingConfigUpdate.
  ///
  /// In en, this message translates to:
  /// **'Applying the configuration update'**
  String get stageApplyingConfigUpdate;

  /// No description provided for @configUpdatedReconnected.
  ///
  /// In en, this message translates to:
  /// **'Configuration updated and reconnected.'**
  String get configUpdatedReconnected;

  /// No description provided for @configSavedReconnectIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Configuration saved, but reconnecting did not finish. Verify the tunnel state.'**
  String get configSavedReconnectIncomplete;

  /// No description provided for @overrideUnchanged.
  ///
  /// In en, this message translates to:
  /// **'The plugin content did not change.'**
  String get overrideUnchanged;

  /// No description provided for @overrideUpdatedEnableApply.
  ///
  /// In en, this message translates to:
  /// **'Plugin updated; it takes effect when enabled.'**
  String get overrideUpdatedEnableApply;

  /// No description provided for @overrideUpdatedPending.
  ///
  /// In en, this message translates to:
  /// **'Plugin updated and saved.'**
  String get overrideUpdatedPending;

  /// No description provided for @runningConfigUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The running configuration is unavailable.'**
  String get runningConfigUnavailable;

  /// No description provided for @stageApplyingOverrideUpdate.
  ///
  /// In en, this message translates to:
  /// **'Applying the plugin update'**
  String get stageApplyingOverrideUpdate;

  /// No description provided for @overrideUpdatedReconnected.
  ///
  /// In en, this message translates to:
  /// **'Plugin updated and reconnected.'**
  String get overrideUpdatedReconnected;

  /// No description provided for @overrideSavedReconnectIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Plugin saved, but reconnecting did not finish. Verify the tunnel state.'**
  String get overrideSavedReconnectIncomplete;

  /// No description provided for @urlRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a complete HTTP or HTTPS configuration URL.'**
  String get urlRequired;

  /// No description provided for @downloadTimeout.
  ///
  /// In en, this message translates to:
  /// **'The download timed out; check the network and retry.'**
  String get downloadTimeout;

  /// No description provided for @tlsFailed.
  ///
  /// In en, this message translates to:
  /// **'HTTPS certificate or secure-connection verification failed; verification was not bypassed.'**
  String get tlsFailed;

  /// No description provided for @downloadNotUtf8.
  ///
  /// In en, this message translates to:
  /// **'The downloaded content is not valid UTF-8 text.'**
  String get downloadNotUtf8;

  /// No description provided for @downloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not download the configuration; check the source and current network.'**
  String get downloadFailed;

  /// No description provided for @redirectInvalid.
  ///
  /// In en, this message translates to:
  /// **'The configuration source redirect is invalid or too frequent.'**
  String get redirectInvalid;

  /// No description provided for @downloadHttpStatus.
  ///
  /// In en, this message translates to:
  /// **'Configuration download failed (HTTP {status}).'**
  String downloadHttpStatus(String status);

  /// No description provided for @downloadTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The configuration content is too large and was not saved.'**
  String get downloadTooLarge;

  /// No description provided for @redirectTooMany.
  ///
  /// In en, this message translates to:
  /// **'The configuration source redirected too many times.'**
  String get redirectTooMany;

  /// No description provided for @configStoreUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Saved configurations could not be read; the file was not changed.'**
  String get configStoreUnreadable;

  /// No description provided for @configSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Saving the configuration failed; check available storage and retry.'**
  String get configSaveFailed;

  /// No description provided for @preferencesUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Saved settings could not be read; the file was not changed.'**
  String get preferencesUnreadable;

  /// No description provided for @preferencesSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Saving settings failed; check available storage and retry.'**
  String get preferencesSaveFailed;

  /// No description provided for @textTooLargeSave.
  ///
  /// In en, this message translates to:
  /// **'The configuration content exceeds 16 MiB and was not saved.'**
  String get textTooLargeSave;

  /// No description provided for @preparationOptionsTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Preparation metadata exceeds 16 MiB after UTF-8 JSON encoding. Changes were not applied.'**
  String get preparationOptionsTooLarge;

  /// No description provided for @preparationFragmentsTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Plugin JSON exceeds 128 MiB after UTF-8 encoding. Changes were not applied.'**
  String get preparationFragmentsTooLarge;

  /// No description provided for @preparationMetadataInvalid.
  ///
  /// In en, this message translates to:
  /// **'Configuration identity or source metadata contains invalid Unicode. Changes were not applied.'**
  String get preparationMetadataInvalid;

  /// No description provided for @textNotUtf8.
  ///
  /// In en, this message translates to:
  /// **'The configuration content is not valid UTF-8 text.'**
  String get textNotUtf8;

  /// No description provided for @textTooLargeImport.
  ///
  /// In en, this message translates to:
  /// **'The configuration content exceeds 16 MiB and was not imported.'**
  String get textTooLargeImport;

  /// No description provided for @sessionChangedNoDisconnect.
  ///
  /// In en, this message translates to:
  /// **'The session changed; the disconnect was not executed.'**
  String get sessionChangedNoDisconnect;

  /// No description provided for @disconnectFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Disconnect failed'**
  String get disconnectFailedShort;

  /// No description provided for @disconnectUnconfirmedShort.
  ///
  /// In en, this message translates to:
  /// **'Disconnect result unconfirmed'**
  String get disconnectUnconfirmedShort;

  /// No description provided for @pathUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Path unavailable'**
  String get pathUnavailable;

  /// No description provided for @strategyStatusStale.
  ///
  /// In en, this message translates to:
  /// **'Strategy status has not refreshed; the app will retry while in the foreground. Old records cannot be used to switch strategies.'**
  String get strategyStatusStale;

  /// No description provided for @coreContextUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The core context is not confirmed yet.'**
  String get coreContextUnconfirmed;

  /// No description provided for @strategyContextChangedRetry.
  ///
  /// In en, this message translates to:
  /// **'The strategy context changed; wait for the current configuration to be read again.'**
  String get strategyContextChangedRetry;

  /// No description provided for @applyingStrategySelection.
  ///
  /// In en, this message translates to:
  /// **'Applying the strategy selection'**
  String get applyingStrategySelection;

  /// No description provided for @trafficUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed'**
  String get trafficUpdateFailed;

  /// No description provided for @applicationSharedUidNotice.
  ///
  /// In en, this message translates to:
  /// **'These apps share an Android UID. Selecting or excluding one also affects: {packages}'**
  String applicationSharedUidNotice(String packages);

  /// No description provided for @delayCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get delayCancelled;

  /// No description provided for @operationAndCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'{operation}\n{cleanup}'**
  String operationAndCleanupFailed(String operation, String cleanup);

  /// No description provided for @androidStageLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading configuration'**
  String get androidStageLoading;

  /// No description provided for @androidStageEstablishing.
  ///
  /// In en, this message translates to:
  /// **'Establishing VPN'**
  String get androidStageEstablishing;

  /// No description provided for @androidStageAttaching.
  ///
  /// In en, this message translates to:
  /// **'Attaching virtual interface'**
  String get androidStageAttaching;

  /// No description provided for @androidErrorStageFailed.
  ///
  /// In en, this message translates to:
  /// **'{stage} failed. Check the configuration source and network, then try again.'**
  String androidErrorStageFailed(String stage);

  /// No description provided for @androidErrorAppInfoVersion.
  ///
  /// In en, this message translates to:
  /// **'Unable to read version information.'**
  String get androidErrorAppInfoVersion;

  /// No description provided for @androidErrorAppInfoNative.
  ///
  /// In en, this message translates to:
  /// **'Unable to load the native core.'**
  String get androidErrorAppInfoNative;

  /// No description provided for @androidErrorApplications.
  ///
  /// In en, this message translates to:
  /// **'Unable to read the application list.'**
  String get androidErrorApplications;

  /// No description provided for @androidErrorLogicExpired.
  ///
  /// In en, this message translates to:
  /// **'The logic engine has ended.'**
  String get androidErrorLogicExpired;

  /// No description provided for @androidErrorOperationEnded.
  ///
  /// In en, this message translates to:
  /// **'The operation has ended.'**
  String get androidErrorOperationEnded;

  /// No description provided for @androidErrorScheduleSave.
  ///
  /// In en, this message translates to:
  /// **'Unable to save the automatic update schedule.'**
  String get androidErrorScheduleSave;

  /// No description provided for @androidErrorBusy.
  ///
  /// In en, this message translates to:
  /// **'Another operation is in progress. Wait for it to finish.'**
  String get androidErrorBusy;

  /// No description provided for @androidErrorUnknownCommand.
  ///
  /// In en, this message translates to:
  /// **'Unrecognized operation.'**
  String get androidErrorUnknownCommand;

  /// No description provided for @androidOperationAccepting.
  ///
  /// In en, this message translates to:
  /// **'Accepting operation'**
  String get androidOperationAccepting;

  /// No description provided for @androidOperationPreparingSystemStart.
  ///
  /// In en, this message translates to:
  /// **'Preparing system start'**
  String get androidOperationPreparingSystemStart;

  /// No description provided for @androidErrorServiceStart.
  ///
  /// In en, this message translates to:
  /// **'The system did not allow starting the task. Return to the app and try again.'**
  String get androidErrorServiceStart;

  /// No description provided for @androidErrorServiceNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'The system did not allow starting the task.'**
  String get androidErrorServiceNotAllowed;

  /// No description provided for @androidErrorVpnPermissionReturn.
  ///
  /// In en, this message translates to:
  /// **'Return to the app and restart to complete VPN authorization.'**
  String get androidErrorVpnPermissionReturn;

  /// No description provided for @androidErrorVpnPermissionRequests.
  ///
  /// In en, this message translates to:
  /// **'Too many authorization requests. Restart the app and try again.'**
  String get androidErrorVpnPermissionRequests;

  /// No description provided for @androidErrorResultUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The operation has ended. Verify the current state.'**
  String get androidErrorResultUnconfirmed;

  /// No description provided for @androidErrorActivityReturn.
  ///
  /// In en, this message translates to:
  /// **'Return to the app and try again.'**
  String get androidErrorActivityReturn;

  /// No description provided for @androidErrorOpenVpnSettings.
  ///
  /// In en, this message translates to:
  /// **'Unable to open system VPN settings.'**
  String get androidErrorOpenVpnSettings;

  /// No description provided for @androidErrorSystemStartPrepare.
  ///
  /// In en, this message translates to:
  /// **'The run configuration could not be prepared for the system start.'**
  String get androidErrorSystemStartPrepare;

  /// No description provided for @androidErrorSessionChanged.
  ///
  /// In en, this message translates to:
  /// **'The tunnel session has changed.'**
  String get androidErrorSessionChanged;

  /// No description provided for @androidErrorSessionModeChanged.
  ///
  /// In en, this message translates to:
  /// **'The tunnel session has changed; this mode change was not confirmed.'**
  String get androidErrorSessionModeChanged;

  /// No description provided for @androidErrorBackgroundStart.
  ///
  /// In en, this message translates to:
  /// **'Unable to start the background operation. Return to the app and try again.'**
  String get androidErrorBackgroundStart;

  /// No description provided for @androidErrorInvalidResult.
  ///
  /// In en, this message translates to:
  /// **'The operation returned no valid result.'**
  String get androidErrorInvalidResult;

  /// No description provided for @androidErrorOperationIncomplete.
  ///
  /// In en, this message translates to:
  /// **'The operation did not complete. Verify the current state and try again.'**
  String get androidErrorOperationIncomplete;

  /// No description provided for @androidStatusUpdating.
  ///
  /// In en, this message translates to:
  /// **'Updating'**
  String get androidStatusUpdating;

  /// No description provided for @androidErrorUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed'**
  String get androidErrorUpdateFailed;

  /// No description provided for @androidErrorUnknownMode.
  ///
  /// In en, this message translates to:
  /// **'Unrecognized run mode.'**
  String get androidErrorUnknownMode;

  /// No description provided for @androidErrorModeTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timed out confirming the run mode.'**
  String get androidErrorModeTimeout;

  /// No description provided for @androidErrorModeUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Unable to confirm the run mode. Wait for the state to refresh.'**
  String get androidErrorModeUnconfirmed;

  /// No description provided for @androidErrorNativeModeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The native mode interface is unavailable.'**
  String get androidErrorNativeModeUnavailable;

  /// No description provided for @androidErrorTakeoverTimeout.
  ///
  /// In en, this message translates to:
  /// **'The tunnel operation timed out. Verify the actual state.'**
  String get androidErrorTakeoverTimeout;

  /// No description provided for @androidErrorTakeoverRunning.
  ///
  /// In en, this message translates to:
  /// **'The current tunnel has not stopped; a new configuration cannot start.'**
  String get androidErrorTakeoverRunning;

  /// No description provided for @androidErrorCoreNotReady.
  ///
  /// In en, this message translates to:
  /// **'Core resources are not ready; a new configuration cannot start.'**
  String get androidErrorCoreNotReady;

  /// No description provided for @androidErrorVpnPermissionInvalid.
  ///
  /// In en, this message translates to:
  /// **'VPN authorization is incomplete or has expired.'**
  String get androidErrorVpnPermissionInvalid;

  /// No description provided for @androidErrorVpnServiceStart.
  ///
  /// In en, this message translates to:
  /// **'The system did not allow starting the VPN service. Return to the app and try again.'**
  String get androidErrorVpnServiceStart;

  /// No description provided for @androidErrorReleaseUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Resource release has not been confirmed. It is not yet clear whether the tunnel stopped or restarted.'**
  String get androidErrorReleaseUnconfirmed;

  /// No description provided for @androidErrorTakeoverStartFailed.
  ///
  /// In en, this message translates to:
  /// **'The tunnel could not start.'**
  String get androidErrorTakeoverStartFailed;

  /// No description provided for @androidErrorTakeoverReleaseUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unable to confirm whether tunnel resources were released.'**
  String get androidErrorTakeoverReleaseUnknown;

  /// No description provided for @androidErrorStopNotAccepted.
  ///
  /// In en, this message translates to:
  /// **'The system did not accept the stop request; tunnel state is unconfirmed.'**
  String get androidErrorStopNotAccepted;

  /// No description provided for @androidErrorStrategyPrepare.
  ///
  /// In en, this message translates to:
  /// **'Strategy configuration did not finish loading. Check the configuration and network, then try again.'**
  String get androidErrorStrategyPrepare;

  /// No description provided for @androidErrorNativeReleaseUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Native resource release was not confirmed.'**
  String get androidErrorNativeReleaseUnconfirmed;

  /// No description provided for @androidErrorStrategyParams.
  ///
  /// In en, this message translates to:
  /// **'Invalid strategy load parameters.'**
  String get androidErrorStrategyParams;

  /// No description provided for @androidErrorStrategyContext.
  ///
  /// In en, this message translates to:
  /// **'The strategy context has changed; this result was not confirmed.'**
  String get androidErrorStrategyContext;

  /// No description provided for @androidErrorStrategyTimeout.
  ///
  /// In en, this message translates to:
  /// **'The strategy operation timed out. Wait for the actual state to refresh.'**
  String get androidErrorStrategyTimeout;

  /// No description provided for @androidErrorStrategyUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The strategy operation was not confirmed. Verify the configuration, members, and core state.'**
  String get androidErrorStrategyUnconfirmed;

  /// No description provided for @androidErrorNativeStrategyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The native strategy interface is unavailable.'**
  String get androidErrorNativeStrategyUnavailable;

  /// No description provided for @androidErrorCoreContextRefresh.
  ///
  /// In en, this message translates to:
  /// **'The core context has changed. Refresh and try again.'**
  String get androidErrorCoreContextRefresh;

  /// No description provided for @androidErrorCoreContextReread.
  ///
  /// In en, this message translates to:
  /// **'The core context has changed. Read it again.'**
  String get androidErrorCoreContextReread;

  /// No description provided for @androidErrorGroupUntestable.
  ///
  /// In en, this message translates to:
  /// **'The current strategy group cannot be tested.'**
  String get androidErrorGroupUntestable;

  /// No description provided for @androidErrorDelayStart.
  ///
  /// In en, this message translates to:
  /// **'Unable to start the delay test.'**
  String get androidErrorDelayStart;

  /// No description provided for @androidErrorNativeDelayUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The native delay test interface is unavailable.'**
  String get androidErrorNativeDelayUnavailable;

  /// No description provided for @androidErrorBatchExpired.
  ///
  /// In en, this message translates to:
  /// **'The delay test batch has expired. Test again.'**
  String get androidErrorBatchExpired;

  /// No description provided for @androidErrorDelayRead.
  ///
  /// In en, this message translates to:
  /// **'Unable to read delay test results.'**
  String get androidErrorDelayRead;

  /// No description provided for @androidErrorConnectionQuerySize.
  ///
  /// In en, this message translates to:
  /// **'The connection query is too large.'**
  String get androidErrorConnectionQuerySize;

  /// No description provided for @androidErrorConnectionId.
  ///
  /// In en, this message translates to:
  /// **'Invalid connection identifier.'**
  String get androidErrorConnectionId;

  /// No description provided for @androidErrorConnectionBusy.
  ///
  /// In en, this message translates to:
  /// **'A connection operation has not finished.'**
  String get androidErrorConnectionBusy;

  /// No description provided for @androidErrorConnectionTimeout.
  ///
  /// In en, this message translates to:
  /// **'The connection operation timed out.'**
  String get androidErrorConnectionTimeout;

  /// No description provided for @androidErrorDisconnectUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The disconnect result was not confirmed.'**
  String get androidErrorDisconnectUnconfirmed;

  /// No description provided for @androidErrorUpdateFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Update failed.'**
  String get androidErrorUpdateFailedShort;

  /// No description provided for @androidErrorNativeConnectionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The native connection interface is unavailable.'**
  String get androidErrorNativeConnectionUnavailable;

  /// No description provided for @androidErrorConnectionNotAccepted.
  ///
  /// In en, this message translates to:
  /// **'The connection operation was not accepted.'**
  String get androidErrorConnectionNotAccepted;

  /// No description provided for @androidErrorOperationWaitTimeout.
  ///
  /// In en, this message translates to:
  /// **'The operation timed out. Verify the state and try again.'**
  String get androidErrorOperationWaitTimeout;

  /// No description provided for @androidErrorSystemTimeoutTask.
  ///
  /// In en, this message translates to:
  /// **'The system ended an overdue task. Verify the state and try again.'**
  String get androidErrorSystemTimeoutTask;

  /// No description provided for @androidErrorOperationInterrupted.
  ///
  /// In en, this message translates to:
  /// **'The operation was interrupted. Verify the state and try again.'**
  String get androidErrorOperationInterrupted;

  /// No description provided for @androidErrorResourceUpdateSize.
  ///
  /// In en, this message translates to:
  /// **'The resource update request exceeds the size limit.'**
  String get androidErrorResourceUpdateSize;

  /// No description provided for @androidErrorNodesQuerySize.
  ///
  /// In en, this message translates to:
  /// **'The node query exceeds the size limit.'**
  String get androidErrorNodesQuerySize;

  /// No description provided for @androidErrorRulesQuerySize.
  ///
  /// In en, this message translates to:
  /// **'The rule query exceeds the size limit.'**
  String get androidErrorRulesQuerySize;

  /// No description provided for @androidErrorLogsQuerySize.
  ///
  /// In en, this message translates to:
  /// **'The log query exceeds the size limit.'**
  String get androidErrorLogsQuerySize;

  /// No description provided for @androidErrorCoreBusy.
  ///
  /// In en, this message translates to:
  /// **'The core is busy or its context changed. Refresh and try again.'**
  String get androidErrorCoreBusy;

  /// No description provided for @androidErrorCoreReadTimeout.
  ///
  /// In en, this message translates to:
  /// **'The core read timed out. Try again.'**
  String get androidErrorCoreReadTimeout;

  /// No description provided for @androidErrorCoreReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Unable to read core data. Refresh and try again.'**
  String get androidErrorCoreReadFailed;

  /// No description provided for @androidErrorNativeReadUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The native read interface is unavailable.'**
  String get androidErrorNativeReadUnavailable;

  /// No description provided for @androidErrorVpnInputMissing.
  ///
  /// In en, this message translates to:
  /// **'VPN authorization has expired or the run input is missing.'**
  String get androidErrorVpnInputMissing;

  /// No description provided for @androidErrorNotificationDenied.
  ///
  /// In en, this message translates to:
  /// **'The system did not allow showing the tunnel notification.'**
  String get androidErrorNotificationDenied;

  /// No description provided for @androidErrorNotificationUpdate.
  ///
  /// In en, this message translates to:
  /// **'The tunnel notification could not be updated.'**
  String get androidErrorNotificationUpdate;

  /// No description provided for @androidErrorNativeCoreLoad.
  ///
  /// In en, this message translates to:
  /// **'The native core could not be loaded. Check the installed package.'**
  String get androidErrorNativeCoreLoad;

  /// No description provided for @androidErrorSystemRevoked.
  ///
  /// In en, this message translates to:
  /// **'The system revoked the VPN'**
  String get androidErrorSystemRevoked;

  /// No description provided for @androidErrorServiceDestroyed.
  ///
  /// In en, this message translates to:
  /// **'The VPN service was destroyed'**
  String get androidErrorServiceDestroyed;

  /// No description provided for @androidErrorApplicationAllowlistMissing.
  ///
  /// In en, this message translates to:
  /// **'All apps in the allow list are no longer installed. Select apps again.'**
  String get androidErrorApplicationAllowlistMissing;

  /// No description provided for @resultRange.
  ///
  /// In en, this message translates to:
  /// **'{start}–{end} of {total} results'**
  String resultRange(int start, int end, int total);

  /// No description provided for @resultCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 result} other{{count} results}}'**
  String resultCount(int count);

  /// No description provided for @uptimeClock.
  ///
  /// In en, this message translates to:
  /// **'{hours}h {minutes}m {seconds}s'**
  String uptimeClock(String hours, String minutes, String seconds);

  /// No description provided for @connectionBehavior.
  ///
  /// In en, this message translates to:
  /// **'Connection behavior'**
  String get connectionBehavior;

  /// No description provided for @reconnectOnRoutingChange.
  ///
  /// In en, this message translates to:
  /// **'Reconnect after switching'**
  String get reconnectOnRoutingChange;

  /// No description provided for @routingReconnectNotice.
  ///
  /// In en, this message translates to:
  /// **'Restart the core and close existing connections when changing mode or strategy.'**
  String get routingReconnectNotice;

  /// No description provided for @applicationNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Not installed'**
  String get applicationNotInstalled;

  /// No description provided for @uptimeRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get uptimeRunning;

  /// No description provided for @uptimeDays.
  ///
  /// In en, this message translates to:
  /// **'Running · {days} days'**
  String uptimeDays(String days);

  /// No description provided for @trafficDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get trafficDownloaded;

  /// No description provided for @trafficUploaded.
  ///
  /// In en, this message translates to:
  /// **'Uploaded'**
  String get trafficUploaded;

  /// No description provided for @processMemoryUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Memory is unavailable. Try again shortly.'**
  String get processMemoryUnavailable;

  /// No description provided for @dnsTools.
  ///
  /// In en, this message translates to:
  /// **'DNS tools'**
  String get dnsTools;

  /// No description provided for @dnsName.
  ///
  /// In en, this message translates to:
  /// **'Name or IP address'**
  String get dnsName;

  /// No description provided for @dnsRecordType.
  ///
  /// In en, this message translates to:
  /// **'Record type'**
  String get dnsRecordType;

  /// No description provided for @dnsQuery.
  ///
  /// In en, this message translates to:
  /// **'Query'**
  String get dnsQuery;

  /// 刷新或准备内核状态的操作。
  ///
  /// In en, this message translates to:
  /// **'Refresh core status'**
  String get dnsRefreshCoreStatus;

  /// 在当前 DNS 对话框中查看按记录分组的查询结果。
  ///
  /// In en, this message translates to:
  /// **'View query results'**
  String get dnsViewQueryResults;

  /// DNS 查询结果区域的标题。
  ///
  /// In en, this message translates to:
  /// **'Query results'**
  String get dnsQueryResults;

  /// 标记页面保留的上次 DNS 查询结果。
  ///
  /// In en, this message translates to:
  /// **'Previous query'**
  String get dnsPreviousQuery;

  /// 查看页面保留的上次 DNS 查询结果。
  ///
  /// In en, this message translates to:
  /// **'View previous query'**
  String get dnsViewPreviousQuery;

  /// 查看完整 DNS 查询原始响应时使用的标题；入口文字使用 rawData。
  ///
  /// In en, this message translates to:
  /// **'DNS query raw data'**
  String get dnsQueryRawData;

  /// 显示这次响应对应的查询名称和记录类型；name 和 type 使用发起查询时保存的值。
  ///
  /// In en, this message translates to:
  /// **'Query: {name} · {type}'**
  String dnsQueryIdentity(String name, String type);

  /// 显示这次响应的内核来源；source 使用发起查询时保存的来源，并由界面翻译。
  ///
  /// In en, this message translates to:
  /// **'Source: {source}'**
  String dnsResponseSource(String source);

  /// 查看 DNS 缓存或 fake-IP 清理详情的入口文字和标题，包括清理对象、实际状态和各缓存池或映射池的结果。
  ///
  /// In en, this message translates to:
  /// **'Cache operation details'**
  String get dnsCacheOperationDetails;

  /// 查看 DNS 缓存操作完整原始响应时使用的标题。
  ///
  /// In en, this message translates to:
  /// **'Cache operation raw data'**
  String get dnsCacheRawData;

  /// No description provided for @dnsResolverNotice.
  ///
  /// In en, this message translates to:
  /// **'Current core resolver; may use cached data and does not reproduce client DNS responses.'**
  String get dnsResolverNotice;

  /// No description provided for @dnsExpired.
  ///
  /// In en, this message translates to:
  /// **'Result expired · query again'**
  String get dnsExpired;

  /// No description provided for @dnsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Current resolver unavailable'**
  String get dnsUnavailable;

  /// No description provided for @dnsInvalidRequest.
  ///
  /// In en, this message translates to:
  /// **'Invalid name or record type, or request exceeds the size limit.'**
  String get dnsInvalidRequest;

  /// No description provided for @dnsBusy.
  ///
  /// In en, this message translates to:
  /// **'The previous query is still finishing. Please wait.'**
  String get dnsBusy;

  /// No description provided for @dnsTimeout.
  ///
  /// In en, this message translates to:
  /// **'Query timed out. It was not retried.'**
  String get dnsTimeout;

  /// No description provided for @dnsCancelled.
  ///
  /// In en, this message translates to:
  /// **'Query cancelled'**
  String get dnsCancelled;

  /// No description provided for @dnsQueryFailed.
  ///
  /// In en, this message translates to:
  /// **'Query failed. Try again.'**
  String get dnsQueryFailed;

  /// No description provided for @dnsResultTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Response exceeds the size limit. No incomplete result is shown.'**
  String get dnsResultTooLarge;

  /// No description provided for @dnsInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'Could not read the query result. Try again.'**
  String get dnsInvalidResponse;

  /// No description provided for @dnsAnswer.
  ///
  /// In en, this message translates to:
  /// **'Answer'**
  String get dnsAnswer;

  /// No description provided for @dnsAuthority.
  ///
  /// In en, this message translates to:
  /// **'Authority'**
  String get dnsAuthority;

  /// No description provided for @dnsAdditional.
  ///
  /// In en, this message translates to:
  /// **'Additional'**
  String get dnsAdditional;

  /// No description provided for @dnsNoRecords.
  ///
  /// In en, this message translates to:
  /// **'No records'**
  String get dnsNoRecords;

  /// No description provided for @dnsTruncated.
  ///
  /// In en, this message translates to:
  /// **'Response is marked truncated'**
  String get dnsTruncated;

  /// No description provided for @dnsElapsed.
  ///
  /// In en, this message translates to:
  /// **'Query time {milliseconds} ms'**
  String dnsElapsed(double milliseconds);

  /// No description provided for @dnsRcode.
  ///
  /// In en, this message translates to:
  /// **'RCODE: {name} ({code})'**
  String dnsRcode(String name, int code);

  /// No description provided for @dnsRecordMeta.
  ///
  /// In en, this message translates to:
  /// **'{type} · {recordClass} · TTL {ttl} s'**
  String dnsRecordMeta(String type, String recordClass, int ttl);

  /// No description provided for @dnsClearCache.
  ///
  /// In en, this message translates to:
  /// **'Clear DNS cache'**
  String get dnsClearCache;

  /// No description provided for @dnsClearFakeIp.
  ///
  /// In en, this message translates to:
  /// **'Clear fake-IP mappings'**
  String get dnsClearFakeIp;

  /// No description provided for @dnsFakeIpWarning.
  ///
  /// In en, this message translates to:
  /// **'Old addresses may stop working. Clients may need to resolve them again.'**
  String get dnsFakeIpWarning;

  /// No description provided for @dnsCacheCompleted.
  ///
  /// In en, this message translates to:
  /// **'Existing DNS caches cleared; queries may refill them immediately.'**
  String get dnsCacheCompleted;

  /// No description provided for @dnsCacheEmpty.
  ///
  /// In en, this message translates to:
  /// **'No caches to clear'**
  String get dnsCacheEmpty;

  /// No description provided for @dnsFakeIpCompleted.
  ///
  /// In en, this message translates to:
  /// **'Fake-IP mappings cleared'**
  String get dnsFakeIpCompleted;

  /// No description provided for @dnsFakeIpEmpty.
  ///
  /// In en, this message translates to:
  /// **'No active fake-IP pools to clear'**
  String get dnsFakeIpEmpty;

  /// No description provided for @dnsCachePartialOrFailed.
  ///
  /// In en, this message translates to:
  /// **'Clearing was not fully confirmed and may have had partial effects.'**
  String get dnsCachePartialOrFailed;

  /// No description provided for @dnsCacheFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not clear. Try again.'**
  String get dnsCacheFailed;

  /// No description provided for @dnsPoolCleared.
  ///
  /// In en, this message translates to:
  /// **'Cleared'**
  String get dnsPoolCleared;

  /// No description provided for @dnsPoolInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive pool'**
  String get dnsPoolInactive;

  /// No description provided for @dnsPoolUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Clearing unconfirmed'**
  String get dnsPoolUnconfirmed;

  /// No description provided for @dnsPersistentPoolEnabled.
  ///
  /// In en, this message translates to:
  /// **'Persistent pool: enabled'**
  String get dnsPersistentPoolEnabled;

  /// No description provided for @dnsPersistentPoolDisabled.
  ///
  /// In en, this message translates to:
  /// **'Persistent pool: disabled'**
  String get dnsPersistentPoolDisabled;

  /// No description provided for @providerFormFormatHint.
  ///
  /// In en, this message translates to:
  /// **'format controls external content encoding; inline uses rule entries.'**
  String get providerFormFormatHint;

  /// No description provided for @strategyGroupHashKeyInvalid.
  ///
  /// In en, this message translates to:
  /// **'round-robin does not accept a non-empty hash-key'**
  String get strategyGroupHashKeyInvalid;

  /// No description provided for @allStrategyGroups.
  ///
  /// In en, this message translates to:
  /// **'All strategy groups'**
  String get allStrategyGroups;

  /// No description provided for @hiddenGroupAttribute.
  ///
  /// In en, this message translates to:
  /// **'Hidden'**
  String get hiddenGroupAttribute;

  /// No description provided for @globalGroupAttribute.
  ///
  /// In en, this message translates to:
  /// **'Global group'**
  String get globalGroupAttribute;

  /// No description provided for @noStrategyGroups.
  ///
  /// In en, this message translates to:
  /// **'No strategy groups'**
  String get noStrategyGroups;

  /// No description provided for @coreCleanupResource.
  ///
  /// In en, this message translates to:
  /// **'Delete local resource file'**
  String get coreCleanupResource;

  /// No description provided for @coreCleanupResourceMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete only the resource file shown below, not its configuration definition. It may need to be downloaded or imported again before use. Other files are not deleted.'**
  String get coreCleanupResourceMessage;

  /// No description provided for @coreCleanupScheduled.
  ///
  /// In en, this message translates to:
  /// **'Cleanup is scheduled for the next app start. No files have been deleted yet.'**
  String get coreCleanupScheduled;

  /// No description provided for @coreCleanupScheduledWithIssue.
  ///
  /// In en, this message translates to:
  /// **'{result}\n\n{issue}'**
  String coreCleanupScheduledWithIssue(String result, String issue);

  /// No description provided for @coreCleanupStopUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Could not confirm that the core stopped.'**
  String get coreCleanupStopUnconfirmed;

  /// No description provided for @coreCleanupInitializing.
  ///
  /// In en, this message translates to:
  /// **'Checking the core data cleanup request.'**
  String get coreCleanupInitializing;

  /// No description provided for @coreCleanupRequired.
  ///
  /// In en, this message translates to:
  /// **'Core directory cleanup is pending. Exit the app from Storage and data, then open it again.'**
  String get coreCleanupRequired;

  /// No description provided for @coreCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Core data cleanup did not complete.'**
  String get coreCleanupFailed;

  /// No description provided for @coreCleanupCompleted.
  ///
  /// In en, this message translates to:
  /// **'Selected core files were cleaned up. Using the core again may create new files.'**
  String get coreCleanupCompleted;

  /// No description provided for @coreCleanupNeedsSelection.
  ///
  /// In en, this message translates to:
  /// **'Select the core files to clean up first.'**
  String get coreCleanupNeedsSelection;

  /// No description provided for @resourceLocalFile.
  ///
  /// In en, this message translates to:
  /// **'Local file: {path}'**
  String resourceLocalFile(String path);

  /// No description provided for @storageData.
  ///
  /// In en, this message translates to:
  /// **'Storage and data'**
  String get storageData;

  /// No description provided for @storageUsage.
  ///
  /// In en, this message translates to:
  /// **'Storage usage'**
  String get storageUsage;

  /// No description provided for @storageCleanup.
  ///
  /// In en, this message translates to:
  /// **'Data cleanup'**
  String get storageCleanup;

  /// No description provided for @storageUsageFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read storage usage.'**
  String get storageUsageFailed;

  /// No description provided for @storageCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not finish removing temporary files from the previous run.'**
  String get storageCleanupFailed;

  /// No description provided for @coreDataDirectory.
  ///
  /// In en, this message translates to:
  /// **'Core working directory'**
  String get coreDataDirectory;

  /// No description provided for @storageMemoryNotice.
  ///
  /// In en, this message translates to:
  /// **'Recent connections and core logs are held only in memory. Clearing ended records does not close active connections.'**
  String get storageMemoryNotice;

  /// No description provided for @storageCoreNotice.
  ///
  /// In en, this message translates to:
  /// **'Core files are managed by mihomo and do not use configuration or plugin storage limits.'**
  String get storageCoreNotice;

  /// No description provided for @storageBytes.
  ///
  /// In en, this message translates to:
  /// **'{bytes}'**
  String storageBytes(String bytes);

  /// No description provided for @storageFileBytes.
  ///
  /// In en, this message translates to:
  /// **'{bytes} / {limit}'**
  String storageFileBytes(String bytes, String limit);

  /// No description provided for @storageLimitExceeded.
  ///
  /// In en, this message translates to:
  /// **'Exceeds the limit'**
  String get storageLimitExceeded;

  /// No description provided for @storageEntryCountUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Entries: —'**
  String get storageEntryCountUnavailable;

  /// No description provided for @storageEntryCount.
  ///
  /// In en, this message translates to:
  /// **'{count} / {limit} entries'**
  String storageEntryCount(int count, int limit);

  /// No description provided for @clearConfigurations.
  ///
  /// In en, this message translates to:
  /// **'Delete all configurations'**
  String get clearConfigurations;

  /// No description provided for @clearConfigurationsMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete all saved configurations, the saved selection and mode choice, and cancel configuration update schedules. The running connection will not be stopped automatically. Plugins, app settings and core files are not deleted.'**
  String get clearConfigurationsMessage;

  /// No description provided for @configurationsCleared.
  ///
  /// In en, this message translates to:
  /// **'All saved configurations deleted.'**
  String get configurationsCleared;

  /// No description provided for @clearOverrides.
  ///
  /// In en, this message translates to:
  /// **'Delete all plugins'**
  String get clearOverrides;

  /// No description provided for @clearOverridesMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete all saved plugins, including local custom definitions, and cancel plugin update schedules. The app will try removing plugins from the currently running configuration and reconnecting. A failure to apply the running change will not undo the local deletion. Configurations, app settings and core files are not deleted.'**
  String get clearOverridesMessage;

  /// No description provided for @overridesCleared.
  ///
  /// In en, this message translates to:
  /// **'All saved plugins deleted.'**
  String get overridesCleared;

  /// No description provided for @inactiveConnectionsCleared.
  ///
  /// In en, this message translates to:
  /// **'Ended connection records cleared.'**
  String get inactiveConnectionsCleared;

  /// No description provided for @inactiveConnectionsClearFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not clear ended connection records.'**
  String get inactiveConnectionsClearFailed;

  /// No description provided for @backupTitle.
  ///
  /// In en, this message translates to:
  /// **'Backup and restore'**
  String get backupTitle;

  /// No description provided for @backupExport.
  ///
  /// In en, this message translates to:
  /// **'Export backup'**
  String get backupExport;

  /// No description provided for @backupImport.
  ///
  /// In en, this message translates to:
  /// **'Import backup'**
  String get backupImport;

  /// No description provided for @backupRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore backup'**
  String get backupRestore;

  /// No description provided for @backupScopeNotice.
  ///
  /// In en, this message translates to:
  /// **'Only configurations, plugins and app settings are included.'**
  String get backupScopeNotice;

  /// No description provided for @backupCounts.
  ///
  /// In en, this message translates to:
  /// **'{configurations, plural, =1{1 configuration} other{{configurations} configurations}} · {overrides, plural, =1{1 plugin} other{{overrides} plugins}}'**
  String backupCounts(int configurations, int overrides);

  /// No description provided for @backupSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected configuration: {name}'**
  String backupSelected(String name);

  /// No description provided for @backupNoSelection.
  ///
  /// In en, this message translates to:
  /// **'No configuration selected'**
  String get backupNoSelection;

  /// No description provided for @backupConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace app data?'**
  String get backupConfirmTitle;

  /// No description provided for @backupConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'The backup replaces existing data rather than merging it. Empty collections also clear existing content.'**
  String get backupConfirmMessage;

  /// No description provided for @backupConfirmRunning.
  ///
  /// In en, this message translates to:
  /// **'The current connection will first be stopped and its resources released. After restoration, the app will try connecting with the restored selected configuration. A newer disconnect request takes priority.'**
  String get backupConfirmRunning;

  /// No description provided for @backupConfirmStopped.
  ///
  /// In en, this message translates to:
  /// **'Restoration will not start a connection.'**
  String get backupConfirmStopped;

  /// No description provided for @backupConfirmUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Connection state is unconfirmed. Restoration will proceed only when it is safe to replace the data.'**
  String get backupConfirmUnconfirmed;

  /// No description provided for @backupExportSaved.
  ///
  /// In en, this message translates to:
  /// **'Backup file saved.'**
  String get backupExportSaved;

  /// No description provided for @backupCancelled.
  ///
  /// In en, this message translates to:
  /// **'Operation cancelled.'**
  String get backupCancelled;

  /// No description provided for @backupInvalid.
  ///
  /// In en, this message translates to:
  /// **'The backup file is invalid or its format is not supported.'**
  String get backupInvalid;

  /// No description provided for @backupTooLarge.
  ///
  /// In en, this message translates to:
  /// **'The backup exceeds the allowed size limit.'**
  String get backupTooLarge;

  /// No description provided for @backupCandidateExpired.
  ///
  /// In en, this message translates to:
  /// **'The prepared backup is no longer valid. Prepare it again.'**
  String get backupCandidateExpired;

  /// No description provided for @backupNotRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup data was not restored.'**
  String get backupNotRestored;

  /// No description provided for @backupRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup data restored.'**
  String get backupRestored;

  /// No description provided for @backupRestoreUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'The restoration result is unconfirmed. Wait for the state to be read again.'**
  String get backupRestoreUnconfirmed;

  /// No description provided for @backupConnectionStopped.
  ///
  /// In en, this message translates to:
  /// **'The previous connection was stopped.'**
  String get backupConnectionStopped;

  /// No description provided for @backupConnectionNotStarted.
  ///
  /// In en, this message translates to:
  /// **'No connection was established.'**
  String get backupConnectionNotStarted;

  /// No description provided for @backupConnectionRestored.
  ///
  /// In en, this message translates to:
  /// **'Connected using the restored configuration.'**
  String get backupConnectionRestored;

  /// No description provided for @backupConnectionCancelled.
  ///
  /// In en, this message translates to:
  /// **'The follow-up connection was cancelled.'**
  String get backupConnectionCancelled;

  /// No description provided for @backupConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'The connection after restoration could not be established.'**
  String get backupConnectionFailed;

  /// No description provided for @backupSchedulesFailed.
  ///
  /// In en, this message translates to:
  /// **'Automatic update tasks were not fully registered.'**
  String get backupSchedulesFailed;

  /// No description provided for @backupSettingsRefreshFailed.
  ///
  /// In en, this message translates to:
  /// **'The displayed settings could not be read again.'**
  String get backupSettingsRefreshFailed;

  /// No description provided for @resourceRawData.
  ///
  /// In en, this message translates to:
  /// **'Original resource data'**
  String get resourceRawData;

  /// No description provided for @localCustomDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this entry only from the local custom plugin? A lower-priority definition may reappear, and existing references will not be changed.'**
  String get localCustomDeleteConfirm;

  /// No description provided for @connectionRuleScope.
  ///
  /// In en, this message translates to:
  /// **'Match scope'**
  String get connectionRuleScope;

  /// No description provided for @connectionRuleUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Current connection information cannot be used to add a rule.'**
  String get connectionRuleUnavailable;

  /// No description provided for @connectionRuleTargetsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read current strategy groups. Try again.'**
  String get connectionRuleTargetsFailed;

  /// No description provided for @backupFailed.
  ///
  /// In en, this message translates to:
  /// **'The backup operation could not be completed.'**
  String get backupFailed;

  /// No description provided for @backupDocumentWriteUnconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Saving the backup file was not confirmed. An incomplete file may remain at the chosen location.'**
  String get backupDocumentWriteUnconfirmed;

  /// No description provided for @localCustomSavedVerificationFailed.
  ///
  /// In en, this message translates to:
  /// **'{result}\n\nThe current local custom entry could not be verified: {reason}\nReopen before continuing. The draft was not submitted again.'**
  String localCustomSavedVerificationFailed(String result, String reason);

  /// No description provided for @backupRestoredWithIssue.
  ///
  /// In en, this message translates to:
  /// **'Backup data restored. {issue}'**
  String backupRestoredWithIssue(String issue);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
