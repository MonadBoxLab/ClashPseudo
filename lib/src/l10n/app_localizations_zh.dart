// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String memoryApplication(String value) {
    return '应用内存 $value MB';
  }

  @override
  String memoryCore(String value) {
    return '内核内存 $value MB';
  }

  @override
  String get lanProxyTitle => '局域网代理';

  @override
  String get lanProxyNotice =>
      '让同一局域网的设备通过本机的 HTTP 或 SOCKS5 代理访问网络。此服务可独立于 VPN 运行。';

  @override
  String get lanProxyEnabled => '开启局域网代理';

  @override
  String get lanProxyAddresses => '监听地址';

  @override
  String get lanProxyPort => '端口';

  @override
  String get lanProxyInvalidPort => '端口必须为 1 到 65535 之间的整数。';

  @override
  String get lanProxyUdp => '允许 UDP';

  @override
  String get lanProxyUnknownInterface => '无法确认此接口的网络类型。请确认接口属于受信任的局域网后再选择。';

  @override
  String get lanProxyNoAddress => '没有可用的局域网接口地址。连接 Wi-Fi 或以太网后刷新。';

  @override
  String get lanProxyActual => '实际监听状态';

  @override
  String get lanProxyNotRunning => '未监听';

  @override
  String get lanProxyUnavailable => '地址已失效';

  @override
  String get lanProxyRaw => '编辑 YAML 原文';

  @override
  String get lanProxyFormUnavailable => '当前 YAML 无法完整显示为表单。请编辑原文；保存会保留原始内容。';

  @override
  String get coreInterruptedTitle => '内核运行中断';

  @override
  String get coreInterruptedMessage =>
      '已暂停自动启动。当前页面和编辑内容继续保留。请在总览重新启动、更换配置或清理文件。';

  @override
  String get coreRecoveryRestart => '重新启动';

  @override
  String get coreRecoverySelect => '更换配置';

  @override
  String get coreCleanupSelect => '清理内核文件';

  @override
  String get coreCleanupSelectionNotice =>
      '先停止内核，再删除勾选的缓存数据库或地理数据文件。未勾选的文件保持不变。';

  @override
  String get coreCleanupRestartLatest => '全部清理完成后，使用最新保存的配置启动';

  @override
  String get coreCleanupNoCandidates => '没有已确认的可清理文件。';

  @override
  String get coreCleanupDeleteSelected => '停止并清理所选文件';

  @override
  String get coreCleanupPartial => '部分文件未清理完成';

  @override
  String get logClear => '清空日志';

  @override
  String get selectDetails => '选择列表中的项目以查看详情。';

  @override
  String get selectionOutsideList => '当前列表中没有所选项目。';

  @override
  String get editLocalDefinition => '编辑本地定义';

  @override
  String get definitionFormName => '名称';

  @override
  String get strategyRejectStatus => '拒绝';

  @override
  String strategyCardDelayNotice(String result) {
    return '当前成员最近一次 HTTP 目标延迟测试：$result。';
  }

  @override
  String get overview => '总览';

  @override
  String get connectionsNavigation => '连接';

  @override
  String get configurationsNavigation => '配置';

  @override
  String get strategies => '策略';

  @override
  String get settings => '设置';

  @override
  String get appearanceAndLanguage => '外观与语言';

  @override
  String get appearance => '主题模式';

  @override
  String get followSystem => '跟随系统';

  @override
  String get lightAppearance => '浅色';

  @override
  String get darkAppearance => '深色';

  @override
  String get brandColor => '主强调色';

  @override
  String get cinnabar => '朱砂';

  @override
  String get jade => '石绿';

  @override
  String get cobalt => '钴蓝';

  @override
  String get language => '语言';

  @override
  String get configurationsAndData => '配置与数据';

  @override
  String get routingAndResources => '分流与资源';

  @override
  String get diagnosticTools => '诊断工具';

  @override
  String get configurations => '配置管理';

  @override
  String get selectConfig => '选择配置';

  @override
  String get recentConnections => '最近连接';

  @override
  String get overrides => '插件（复写）';

  @override
  String get proxyNodes => '代理节点';

  @override
  String get rules => '规则';

  @override
  String get externalResources => '外部资源';

  @override
  String get runtimeConfiguration => '内核运行时配置';

  @override
  String get coreLogs => '内核日志';

  @override
  String get applicationAccess => '应用 VPN 接管范围';

  @override
  String get about => '关于';

  @override
  String get licenses => '开源许可';

  @override
  String get retry => '重试';

  @override
  String get cancel => '取消';

  @override
  String get save => '保存';

  @override
  String get close => '关闭';

  @override
  String get changeSource => '修改来源';

  @override
  String get settingsLoadFailed => '已保存设置读取失败。';

  @override
  String get project => '项目';

  @override
  String get applicationVersion => '应用版本';

  @override
  String get legalSummary =>
      'Clash Pseudo 是自由软件；可依照自由软件基金会发布的 GNU 通用公共许可证第 3 版（GPL-3.0-only）复制、修改和分发。\n\n本程序按“现状”提供，不附带任何明示或暗示担保。';

  @override
  String get sourceDistributionNotice => '对应源码与构建材料随发行版本提供。';

  @override
  String get versionUnavailable => '暂时无法读取版本信息。';

  @override
  String get coreVersion => 'mihomo 内核版本';

  @override
  String get refresh => '刷新';

  @override
  String get runtimeConfigSearch => '查找字段或值';

  @override
  String get clearSearch => '清除搜索';

  @override
  String get runtimeConfigLive => '运行中';

  @override
  String get runtimeConfigPreview => '预览 · 未接管';

  @override
  String get runtimeConfigEmpty => '请先选择一份已保存正文的配置。';

  @override
  String get noSearchResults => '没有匹配的行';

  @override
  String get nodeSearch => '名称、来源或类型';

  @override
  String get coreReadLoading => '正在读取内核数据…';

  @override
  String get coreReadFailed => '读取失败 · 请刷新重试';

  @override
  String get coreSnapshotStale => '上次读取结果 · 非当前状态';

  @override
  String get builtinNode => '内置';

  @override
  String get previousPage => '上一页';

  @override
  String get nextPage => '下一页';

  @override
  String get noNodes => '没有匹配的节点';

  @override
  String get details => '详情';

  @override
  String get errorDetails => '错误详情';

  @override
  String get viewError => '查看错误';

  @override
  String get technicalDetails => '技术详情';

  @override
  String get copyTechnicalDetails => '复制技术详情';

  @override
  String get mainRules => '主规则';

  @override
  String get subRules => '子规则';

  @override
  String get ruleSets => '规则集';

  @override
  String get ruleScope => '规则范围';

  @override
  String get ruleSearch => '类型、内容或目标';

  @override
  String get noRules => '没有匹配的规则';

  @override
  String get ruleTarget => '目标';

  @override
  String get resourceSearch => '名称、类型或来源';

  @override
  String get noResources => '没有匹配的外部资源';

  @override
  String get resourceProxyProvider => '代理提供者';

  @override
  String get resourceRuleProvider => '规则提供者';

  @override
  String get resourceGeo => 'Geo 数据库';

  @override
  String resourceCountValue(int count) {
    return '$count 条';
  }

  @override
  String resourceUpdatedAt(String time) {
    return '内核报告更新时间：$time';
  }

  @override
  String get resourceUpdateUnknown => '内核未报告更新时间';

  @override
  String get resourceFilePresent => '本地文件存在';

  @override
  String get resourceAutoTarget => '内核自动更新目标';

  @override
  String get resourceNotAutoTarget => '非自动更新目标';

  @override
  String get resourceAutoScope => '更新对象以内核进程记录为准，可能包括先前配置使用过的数据库。';

  @override
  String resourceFileModifiedAt(String time) {
    return '文件修改时间：$time';
  }

  @override
  String resourceLastCheckAt(String time) {
    return '上次检查成功：$time';
  }

  @override
  String resourceUpdateInterval(String interval) {
    return '更新间隔：$interval';
  }

  @override
  String get resourceWatchFile => '监视本地文件变化';

  @override
  String get resourceFileMissing => '本地文件缺失';

  @override
  String get resourceFileUnreadable => '本地文件无法读取';

  @override
  String resourceBuiltInBehavior(String behavior) {
    return '行为：$behavior';
  }

  @override
  String get resourceUpdate => '更新';

  @override
  String get resourceUpdating => '正在更新…';

  @override
  String get resourceUpdateStopped => '内核已停止，未完成更新';

  @override
  String get resourceUpdateFailed => '更新未完成，保留原有数据';

  @override
  String get resourceUpdateSuccess => '更新已完成，刷新以查看内核新状态';

  @override
  String get resourceNoExternalSource => '内联或内置资源没有外部来源';

  @override
  String get logLevel => '级别';

  @override
  String get logSearch => '查找日志文本';

  @override
  String get logLevelDebug => '调试及以上';

  @override
  String get logLevelInfo => '信息及以上';

  @override
  String get logLevelWarning => '警告及以上';

  @override
  String get logLevelError => '仅错误';

  @override
  String get noLogs => '当前会话还没有日志';

  @override
  String logLocalDropped(int count) {
    return '已略过 $count 条日志';
  }

  @override
  String logDropped(int count) {
    return '传输中遗漏 $count 条日志';
  }

  @override
  String logTotal(int count) {
    return '已缓存 $count 条';
  }

  @override
  String get logBackToLatest => '回到最新';

  @override
  String get delayTestGroup => '测试整组';

  @override
  String get delayTestMember => '测试此成员';

  @override
  String delayTarget(String url) {
    return '目标：$url · HTTP 延迟，非 ICMP';
  }

  @override
  String get delayPending => '未测';

  @override
  String get delayRunning => '测试中';

  @override
  String get delayFailed => '失败';

  @override
  String get delayTimeout => '超时';

  @override
  String get delayExpired => '结果已失效';

  @override
  String get delayStartFailed => '无法启动延迟测试';

  @override
  String get delayReadFailed => '测速结果读取失败';

  @override
  String delayProgress(int done, int total) {
    return '已完成 $done/$total';
  }

  @override
  String get delayDone => '测试完成';

  @override
  String get overridePlugins => '插件（复写）';

  @override
  String get addOverride => '添加插件';

  @override
  String get newOverride => '新建本地插件';

  @override
  String get remoteOverride => '从 URL 添加';

  @override
  String get overrideLocal => '本地';

  @override
  String get overrideEnabled => '启用';

  @override
  String get overridePrepend => '前置合并';

  @override
  String get overrideReplace => '覆盖同类设置';

  @override
  String get overrideMoveUp => '上移';

  @override
  String get overrideMoveDown => '下移';

  @override
  String get overrideEmpty => '尚未添加插件。';

  @override
  String get overrideNotice => '列表中位置越靠上的插件优先级越高。正在运行的配置内容改变时，会重新连接。';

  @override
  String get loonProxyName => '代理名称';

  @override
  String get loonProxyNameHint => '仅用于 Loon 规则。留空保留显式目标，无目标规则仅保留为注释；内置目标不替换。';

  @override
  String get loonAddNoResolve => 'Loon IP 规则添加 no-resolve';

  @override
  String get overrideContentUnsupported => '远程插件不是有效的 YAML 配置片段或可识别的 Loon 插件。';

  @override
  String get loonProxyNameInvalid => '代理名称不能包含逗号、换行或控制字符。';

  @override
  String loonConvertedResult(String result, int rules, int comments) {
    return '$result\n\n已提取 $rules 条兼容规则，$comments 行保留为注释。';
  }

  @override
  String loonNoRulesResult(String result, int comments) {
    return '$result\n\n未提取到兼容规则；插件不改变现有规则，$comments 行保留为注释。';
  }

  @override
  String get overrideName => '插件名称';

  @override
  String get overrideUpdate => '更新插件';

  @override
  String get viewOverrideError => '查看插件错误';

  @override
  String get overrideActionFailed => '插件操作未完成';

  @override
  String get overrideDelete => '删除';

  @override
  String get overrideDeleteTitle => '删除插件？';

  @override
  String get overrideDeleteMessage =>
      '将从保存列表移除此插件；若当前接管正在使用它，将重新连接并中断已有连接。未连接时不会启动接管。';

  @override
  String get localYamlInvalid => '正文必须是单个有效的 YAML 对象，请先在文本编辑器中修正。';

  @override
  String get localYamlInvalidStructure => '目标定义的结构或字段类型不正确，未修改正文。';

  @override
  String get localYamlDuplicateName => '本地自定义中已存在同名定义。';

  @override
  String get localYamlAliasTarget => '目标使用了共享 YAML 锚点或别名，请在文本编辑器中修改。';

  @override
  String get localYamlInheritedTarget => '此定义通过 YAML 合并继承而来，请在文本编辑器中修改。';

  @override
  String get localYamlUnsafeStructure => '正文嵌套过深或展开的别名过多，无法安全修改。';

  @override
  String get localYamlUnsupportedEdit => '无法在保留其他正文的情况下修改此定义，请使用文本编辑器。';

  @override
  String get localYamlUnsupportedField =>
      '当前表单无法表示此字段原始值的格式，将保留原值；请在文本编辑器中修改此字段。';

  @override
  String get definitionFormUnsetField => '移除此字段';

  @override
  String definitionFormEditItem(String label, int index) {
    return '编辑$label第 $index 项';
  }

  @override
  String definitionFormValueCount(int count) {
    return '$count 个值';
  }

  @override
  String provenancePlugins(int count) {
    return '由 $count 个插件提供';
  }

  @override
  String get provenanceHeading => '提供内容的插件';

  @override
  String get provenanceProviderHeading => '提供此定义的插件';

  @override
  String get strategyGroupFormTitle => '新增策略组';

  @override
  String get strategyGroupFormType => '策略组类型';

  @override
  String get strategyGroupFormMembers => '成员';

  @override
  String get strategyGroupFormProviders => '节点来源引用';

  @override
  String get strategyGroupEditTitle => '编辑本地策略组';

  @override
  String get strategyGroupDefinitionTitle => '策略组属性';

  @override
  String get strategyGroupAttributesHeading => '实际属性';

  @override
  String get strategyGroupNoMembers => '没有成员';

  @override
  String strategyGroupFixedValue(String name) {
    return '固定：$name';
  }

  @override
  String strategyGroupLoadedValue(String name) {
    return '当前：$name';
  }

  @override
  String get strategyGroupNotSelected => '没有当前成员';

  @override
  String get providerProxyFormTitle => '新增节点来源';

  @override
  String get providerRuleFormTitle => '新增规则集来源';

  @override
  String get providerFormType => '来源类型';

  @override
  String get providerFormSource => '来源与下载';

  @override
  String get providerFormHeaders => '请求头';

  @override
  String get providerFormDownloadProxy => '下载代理';

  @override
  String get providerFormHealthCheck => '健康检查';

  @override
  String get providerFormOverride => '覆盖节点设置';

  @override
  String get providerFormPayload => '内联内容';

  @override
  String get providerFormAddProxy => '新增内联节点';

  @override
  String get providerFormEditProxy => '修改内联节点';

  @override
  String get providerFormProxyNames => '名称替换';

  @override
  String get providerFormExpressions => '覆盖表达式';

  @override
  String get providerFormPattern => '匹配表达式';

  @override
  String get providerFormReplacement => '替换内容';

  @override
  String get providerFormPathHint => '路径相对于应用管理的资源目录；不能使用绝对路径或指向上级目录的路径。';

  @override
  String get providerFormInvalidPath => '路径无效';

  @override
  String get providerFormInvalidUrl => '请输入 HTTP 或 HTTPS URL';

  @override
  String get providerFormMRSClassical => 'MRS 不支持 classical';

  @override
  String get providerFormAndroidIgnored =>
      '当前 Android 接入不使用 interface-name、routing-mark 和 TFO。';

  @override
  String get ruleFormTitle => '新增规则';

  @override
  String get ruleFormType => '规则类型';

  @override
  String get ruleFormMatch => '匹配值';

  @override
  String get ruleFormTarget => '目标';

  @override
  String get ruleFormProvider => '规则集来源';

  @override
  String get ruleFormSubRule => '子规则集';

  @override
  String get ruleFormCondition => '原生条件表达式';

  @override
  String get ruleFormUnrepresentable => '规则格式无法原样保存此字段';

  @override
  String get ruleFormTargetHint => '目标名称不能含逗号或首尾空格。';

  @override
  String get ruleFormSrcHint => 'src 已包含 no-resolve 的效果。';

  @override
  String get definitionFormMoveUp => '上移';

  @override
  String get definitionFormMoveDown => '下移';

  @override
  String get providerFormFallbackPayload => '后备内联内容';

  @override
  String get definitionFormSuggestions => '选择建议项';

  @override
  String get proxyFormTitle => '新增节点';

  @override
  String get proxyFormType => '节点类型';

  @override
  String get proxyFormBasic => '基本信息';

  @override
  String get proxyFormProtocol => '协议设置';

  @override
  String get proxyFormAdvanced => '高级设置';

  @override
  String get proxyCategoryStandard => '标准代理协议';

  @override
  String get proxyCategoryCommunity => '社区代理协议';

  @override
  String get proxyCategoryVpn => 'VPN 协议';

  @override
  String get proxyCategoryBuiltin => '内置连接处理方式';

  @override
  String get proxyOptional => '可选';

  @override
  String get proxyUnset => '未设置';

  @override
  String get proxyTrue => '开启';

  @override
  String get proxyFalse => '关闭';

  @override
  String get proxyRequired => '请填写此字段。';

  @override
  String get proxyInvalidInteger => '请输入有效整数。';

  @override
  String get proxyInvalidPort => '端口须为 0–65535 的整数。';

  @override
  String get proxyInvalidByte => '须为 0–255 的整数。';

  @override
  String get proxyDuplicateKey => '键名重复。';

  @override
  String get proxyMapKey => '键';

  @override
  String get proxyMapValue => '值';

  @override
  String get proxyPlatformIgnored => '当前 Android 接入不会应用此字段。';

  @override
  String get proxySaveFailed => '未能完成保存或连接，输入已保留。';

  @override
  String get proxyServer => '服务器';

  @override
  String get proxyUsername => '用户名';

  @override
  String get proxyShowSecret => '显示敏感内容';

  @override
  String get proxyHideSecret => '隐藏敏感内容';

  @override
  String get proxyPassword => '密码';

  @override
  String get proxyName => '节点名称';

  @override
  String get proxyUnitBytes => '字节';

  @override
  String get proxyUnitSeconds => '秒';

  @override
  String get proxyUnitMilliseconds => '毫秒';

  @override
  String get proxyUnitNanoseconds => '纳秒';

  @override
  String get proxyUnitMbps => 'Mbps';

  @override
  String get proxyUnitPackets => '数据包';

  @override
  String proxyAddItem(String field) {
    return '添加 $field';
  }

  @override
  String proxyRemoveItem(String field, int index) {
    return '移除 $field 第 $index 项';
  }

  @override
  String get localCustomTitle => '本地自定义';

  @override
  String get moreLabel => '更多操作';

  @override
  String get continueLabel => '继续';

  @override
  String get operationFailed => '操作未完成';

  @override
  String get applicationListFailed => '无法读取已安装应用列表。';

  @override
  String get applicationAllowEmpty => '选择“仅选中应用”时，至少需要选择一个应用。';

  @override
  String get applicationReconnectTitle => '保存并重新连接？';

  @override
  String get applicationReconnectMessage =>
      '保存后会先正常停止当前接管，再按当前配置和模式重新连接，已有连接会中断。若重新连接失败，设置仍会保留。';

  @override
  String get applicationReconnect => '保存并重新连接';

  @override
  String get applicationAccessNotice =>
      '选定范围内应用的流量由 VPN 接管，其余应用使用系统网络连接。保存后重新连接，新设置才会生效。';

  @override
  String get searchApplications => '搜索应用名称或包名';

  @override
  String get accessAll => '所有应用';

  @override
  String get accessOnly => '仅选中应用';

  @override
  String get accessExcept => '排除选中应用';

  @override
  String get showSystemApps => '显示系统应用';

  @override
  String selectedCount(int count) {
    return '已选择 $count 个应用';
  }

  @override
  String get discardChanges => '放弃未保存的修改？';

  @override
  String get discardApplicationChanges => '当前选择仅保留在此页，离开后不会保存。';

  @override
  String get discard => '放弃修改';

  @override
  String get continueEditing => '继续编辑';

  @override
  String get alwaysOnTitle => 'VPN 始终开启';

  @override
  String get alwaysOnNotice =>
      '始终开启由 Android 系统管理。开启后系统会在需要时启动本应用，并可在解锁后恢复最近保存的配置。应用不能绕过系统关闭它。';

  @override
  String get vpnStatusLoading => '正在读取 VPN 状态';

  @override
  String get vpnStatusReadFailed => '无法读取 Android VPN 状态。';

  @override
  String get alwaysOnUnknown => '未确认';

  @override
  String get alwaysOnEnabled => '已开启';

  @override
  String get alwaysOnDisabled => '未开启';

  @override
  String get lockdownEnabled => '已开启';

  @override
  String get lockdownDisabled => '未开启';

  @override
  String get lockdownTitle => '阻止不通过 VPN 的连接';

  @override
  String get lockdownNotice => '锁定模式由 Android 系统管理，应用不会自动开启。';

  @override
  String get openVpnSettings => '打开系统 VPN 设置';

  @override
  String get alwaysOnRestoreNotice => '系统恢复使用最近保存的主配置、模式、插件与应用访问设置；解锁前不会建立隧道。';

  @override
  String get alwaysOnOpenFailed => '无法打开系统 VPN 设置，请在系统设置中查找 VPN。';

  @override
  String get androidSection => 'Android';

  @override
  String get autoUpdate => '自动更新';

  @override
  String autoUpdateEvery(int hours) {
    return '每 $hours 小时';
  }

  @override
  String get autoUpdateInterval => '检查周期';

  @override
  String get autoUpdateEnabled => '已开启自动更新';

  @override
  String get autoUpdateDisabled => '已关闭自动更新';

  @override
  String get autoUpdateSaved => '已更新并保存';

  @override
  String get autoUpdateApplied => '已更新并应用';

  @override
  String get autoUpdateApplyFailed => '已更新并保存，连接失败';

  @override
  String get autoUpdateFailed => '上次自动更新失败';

  @override
  String get autoUpdateUnchanged => '上次检查无变化';

  @override
  String get autoUpdateAttempt => '上次检查';

  @override
  String get autoUpdateNever => '尚未检查';

  @override
  String get applicationPolicyNextConnectionShort => '下次连接生效';

  @override
  String get applicationPolicyAppliedShort => '已生效';

  @override
  String get applicationPolicyPendingShort => '尚未生效';

  @override
  String get applicationPolicyUnknownShort => '未确认';

  @override
  String get applicationPolicyNextConnection => '已保存的应用接管范围设置将在下次连接时生效。';

  @override
  String get applicationPolicyApplied => '已保存的应用接管范围设置正在使用。';

  @override
  String get applicationPolicyPending => '已保存的应用接管范围设置尚未生效；再次保存可重新连接并重试。';

  @override
  String get applicationPolicyUnknown => '尚未确认正在使用的应用接管范围；再次保存可重新连接并核实。';

  @override
  String get strategyGroupMissing => '策略组已不存在';

  @override
  String get strategyTypeChanged => '策略组类型已改变';

  @override
  String get strategyNotSelectable => '策略组不支持手动选择';

  @override
  String get strategyMemberMissing => '已选成员已不存在';

  @override
  String get statusLoading => '正在获取状态';

  @override
  String get statusSubmitting => '正在提交请求';

  @override
  String get statusProcessing => '正在处理';

  @override
  String get stateRunning => '接管运行中';

  @override
  String get stateStopped => '接管已关闭';

  @override
  String get stateStarting => '正在启动';

  @override
  String get stateStopping => '正在停止';

  @override
  String get stateUnknown => '状态未确认';

  @override
  String get statusIssue => '状态异常';

  @override
  String get statusPending => '状态未确认';

  @override
  String get statusAutoRetry => '正在重试';

  @override
  String get statusPlatformUnconfirmed => '资源状态未确认';

  @override
  String get statusWaiting => '正在等待结果';

  @override
  String get statusConfigFailed => '无法读取配置';

  @override
  String get statusConfigLoading => '正在读取配置';

  @override
  String get statusImportPrompt => '未选择配置';

  @override
  String get statusReady => '已准备就绪，可以启动';

  @override
  String get identityUnconfirmed => '尚未确认所用配置';

  @override
  String get identityLoading => '正在读取配置';

  @override
  String get identityNoConfig => '尚未导入配置';

  @override
  String identitySelected(String name) {
    return '当前选择：$name';
  }

  @override
  String get identityNone => '无';

  @override
  String get identityRevisionDiff => '运行中版本与已保存版本不同';

  @override
  String get identitySelectedUnconfirmed => '已选配置 · 未确认实际使用';

  @override
  String get actionUnavailable => '暂不可用';

  @override
  String get actionBusy => '处理中…';

  @override
  String get actionStarting => '启动中…';

  @override
  String get actionStopping => '停止中…';

  @override
  String get actionStop => '停止接管';

  @override
  String get actionStart => '启动接管';

  @override
  String get importConfig => '导入配置';

  @override
  String get configManage => '配置管理';

  @override
  String get tunnelStatus => '接管状态';

  @override
  String get modeUnconfirmed => '运行模式 · 未确认';

  @override
  String get modeRunningUnconfirmed => '运行模式未确认';

  @override
  String modeRunning(String mode) {
    return '$mode模式';
  }

  @override
  String modeSavedIdle(String mode) {
    return '$mode模式 · 未运行';
  }

  @override
  String get modeSavedUnconfirmed => '已保存的模式尚未确认';

  @override
  String get modeRule => '规则';

  @override
  String get modeGlobal => '全局';

  @override
  String get modeDirect => '直连';

  @override
  String get modeRuleDescription => '按配置规则选择连接去向。';

  @override
  String get modeGlobalDescription => '按全局策略选择连接去向。';

  @override
  String get modeDirectDescription => '直接连接目标并保持接管。';

  @override
  String get networkActivity => '网络活动';

  @override
  String get trafficConnections => '连接';

  @override
  String get download => '下载';

  @override
  String get upload => '上传';

  @override
  String get modeTitle => '运行模式';

  @override
  String get modeReadFailed => '模式读取失败';

  @override
  String get modeDiffers => '当前模式与已保存的备用模式';

  @override
  String modeSaved(String mode) {
    return '已保存的备用模式：$mode；仅在配置未指定 mode 字段时使用。';
  }

  @override
  String modeActualDiffers(String mode) {
    return '当前运行模式：$mode；配置指定的模式可能与已保存的备用模式不同。';
  }

  @override
  String get modeHint =>
      '运行时选择模式会立即切换当前模式；未运行时只保存备用模式。配置未指定 mode 字段时，才使用已保存的备用模式。';

  @override
  String get modeFollowConfigIdle => '使用配置中的模式 · 未运行';

  @override
  String get notProvided => '未提供';

  @override
  String get allRules => '全部规则';

  @override
  String get allConnections => '全部连接';

  @override
  String get activeOnly => '活跃中';

  @override
  String get inactiveOnly => '不活跃';

  @override
  String get clearInactiveConnections => '清除已结束记录';

  @override
  String connectionOmitted(int count) {
    return '因容量限制略过 $count 条完整记录';
  }

  @override
  String get rawData => '原始数据';

  @override
  String get copyOriginalText => '复制原文';

  @override
  String get connectionLimitedNotice => '记录容量已达上限，部分连接未显示。可清除已结束记录以腾出空间。';

  @override
  String get connectionRefreshFailed => '刷新失败';

  @override
  String get exitSearch => '退出搜索';

  @override
  String get searchConnections => '搜索连接';

  @override
  String get searchStrategies => '搜索策略组';

  @override
  String get noMatchingStrategies => '没有匹配的策略组';

  @override
  String get filterMatchedRule => '筛选命中规则';

  @override
  String get noMatchingConnections => '没有匹配的连接';

  @override
  String get noRecentConnections => '暂无近期连接';

  @override
  String get noConnections => '暂无连接';

  @override
  String get connectionActive => '活跃';

  @override
  String get connectionInactive => '已不活跃';

  @override
  String get disconnectFailedTitle => '断开连接未完成';

  @override
  String get targetIp => '目标 IP';

  @override
  String get sourceAddress => '源地址';

  @override
  String get inbound => '入站';

  @override
  String get connectionDetails => '连接详情';

  @override
  String get disconnecting => '正在断开';

  @override
  String get disconnect => '断开连接';

  @override
  String portLabel(String port) {
    return '端口 $port';
  }

  @override
  String get routingResult => '分流结果';

  @override
  String get matchedRule => '命中规则';

  @override
  String get traffic => '流量';

  @override
  String get startTime => '开始时间';

  @override
  String get durationLabel => '持续时长';

  @override
  String get connectionInfo => '连接信息';

  @override
  String get connectionClosed => '已断开';

  @override
  String cumulative(String bytes) {
    return '累计 $bytes';
  }

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String durationMinutesSeconds(int minutes, int seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String durationSeconds(int seconds) {
    return '$seconds 秒';
  }

  @override
  String get connectionInfoTimeTitle => '时间';

  @override
  String get showHiddenGroups => '显示隐藏策略组';

  @override
  String get hideHiddenGroups => '不显示隐藏策略组';

  @override
  String get strategyGroups => '策略组';

  @override
  String get selectionsNotRestored => '部分选择未恢复';

  @override
  String get noVisibleGroups => '当前模式下没有可显示的策略组。';

  @override
  String unrestoredLine(String name, String value) {
    return '$name：$value';
  }

  @override
  String fixedTo(String name) {
    return '固定：$name';
  }

  @override
  String get unconfirmed => '未确认';

  @override
  String get popupExpired => '策略已失效，请关闭后重新打开。当前内容仅供查看。';

  @override
  String popupSavedDiffers(String name) {
    return '已保存：$name；实际选择仍以当前标记为准。';
  }

  @override
  String get popupSavedDiffersAuto => '已保存：自动；实际选择仍以当前标记为准。';

  @override
  String popupNotRestored(String reason) {
    return '原选择未恢复：$reason';
  }

  @override
  String get popupExpiredShort => '已失效 · 请重新打开';

  @override
  String get popupSwitching => '正在切换…';

  @override
  String get popupUpdateFailed => '更新失败 · 查看原因';

  @override
  String get popupSavedDiffersShort => '已保存选择与实际选择不同 · 查看详情';

  @override
  String get popupNotRestoredShort => '原选择未恢复 · 查看详情';

  @override
  String get popupStale => '状态未更新';

  @override
  String get popupReading => '正在读取策略';

  @override
  String get autoLabel => '自动';

  @override
  String get restoreAuto => '恢复自动';

  @override
  String get sameNameMember => '同名成员';

  @override
  String get pinned => '已固定';

  @override
  String get closeStrategyPopup => '关闭策略浮窗';

  @override
  String get strategyChoiceSelect => '手动选择';

  @override
  String get strategyChoiceUrlTest => '自动测速';

  @override
  String get strategyChoiceFallback => '故障转移';

  @override
  String get strategyChoiceLoadBalance => '负载均衡';

  @override
  String get strategyGroupChanged => '策略组或成员已变化，本次选择未保存。';

  @override
  String get strategySelectionUnconfirmed => '选择已保存供下次加载使用；本次策略切换未确认。';

  @override
  String get operationNotCompleted => '操作未完成';

  @override
  String get configUpdated => '配置已更新。';

  @override
  String get settingsSaved => '应用设置已保存。';

  @override
  String get operationInProgress => '已有操作正在处理。';

  @override
  String get platformOperationFailed => '平台操作未完成，请核实接管状态。';

  @override
  String get operationNotCompletedRetry => '操作未完成，请核实状态后重试。';

  @override
  String get configTitle => '配置';

  @override
  String get configReadFailed => '配置读取失败';

  @override
  String get noSavedConfigs => '尚未保存配置';

  @override
  String get importOrCreateHint => '从 URL、文件导入，或新建本地配置。';

  @override
  String get importFromUrl => '从 URL 导入';

  @override
  String get importFromFile => '从文件导入';

  @override
  String get newLocalConfig => '新建本地配置';

  @override
  String get addConfig => '添加配置';

  @override
  String get localConfig => '本地配置';

  @override
  String nativeConfigurationUnsupported(String field, String reason) {
    return '无法使用配置项 $field：$reason';
  }

  @override
  String get nativeReasonTunDisabled => '建立 VPN 连接需要启用 TUN。';

  @override
  String get nativeReasonControllerUnavailable => '当前不支持外部控制接口及其网页界面。';

  @override
  String get nativeReasonRootRedirection => '此流量重定向需要系统特权，应用不提供此能力。';

  @override
  String get nativeReasonTransparentSockets => '透明代理套接字需要系统特权，应用不提供此能力。';

  @override
  String get nativeReasonInterfaceBinding => '应用的套接字保护机制不支持绑定指定的物理网络接口。';

  @override
  String get nativeReasonRoutingMark => '当前 Android VPN 接入不支持 Linux 路由标记。';

  @override
  String get nativeReasonTcpFastOpen => '应用的套接字接入不提供 TCP Fast Open。';

  @override
  String get nativeReasonFirewall => '管理 iptables 需要 root 权限，应用不支持此操作。';

  @override
  String get nativeReasonSystemClock => '应用不能通过 NTP 修改系统时钟。';

  @override
  String get nativeReasonExternalFd =>
      '只允许使用 Android VpnService 为当前 VPN 会话创建的文件描述符。';

  @override
  String get nativeReasonInterfaceName => 'Android VPN 接口由系统创建，不能通过此设置重命名。';

  @override
  String get nativeReasonGso => 'Android VPN 接口没有可配置的 GSO 选项。';

  @override
  String get nativeReasonAutoRedirect =>
      '自动重定向需要 netlink 与防火墙操作，当前 Android VPN 接入不提供此能力。';

  @override
  String get nativeReasonLinuxRouting => '此设置需要特权 Linux 路由表或路由规则操作，应用不提供此能力。';

  @override
  String get nativeReasonInterfaceFilter => '当前 Android VPN 接入不能在此层执行网络接口过滤。';

  @override
  String get nativeReasonMacFilter => '当前 Android VPN 接入不能在此层执行 MAC 地址过滤。';

  @override
  String get nativeReasonPortFilter => '当前 Android VPN 接入不能在此层执行源端口或目标端口过滤。';

  @override
  String get nativeReasonStrictRoute =>
      'Android VpnService 无法实现此设置所需的 Linux 严格路由规则。';

  @override
  String get nativeReasonDnsHijackConflict => '关闭 DNS 时不能配置 DNS 劫持。';

  @override
  String get nativeReasonIpv6Unavailable =>
      'IPv6 已关闭或当前设备无法使用 IPv6，所需的 IPv6 地址或地址池不可用。';

  @override
  String get nativeReasonInvalidMtu =>
      'MTU 必须介于 1 至 65535 之间，使用 IPv6 时至少为 1280。';

  @override
  String get nativeReasonInvalidAddress => '计算得到的 VPN 接口地址或所需的下一个地址无效。';

  @override
  String get nativeReasonSystemDnsUnavailable =>
      '无法取得底层非 VPN 网络的 DNS 服务器，不会改用公共 DNS。';

  @override
  String get nativeReasonPrivateDnsUnavailable =>
      '当前无法为 Android 严格模式的私人 DNS 提供经过验证的等效安全连接，不能改用明文 DNS。';

  @override
  String get nativeReasonProviderPath =>
      '资源提供者（provider）的路径未通过目录范围、符号链接、受保护文件或目标文件标识检查。';

  @override
  String get nativeReasonAndroidUserUnavailable =>
      '应用只能列出和管理当前 Android 用户安装的应用，不支持按其他用户或其 UID 筛选。';

  @override
  String get storageContextChanged => '数据已恢复或替换，请重新打开此页面。未提交的输入仍可复制保留。';

  @override
  String get storageSyncUnconfirmed => '内容已保存，但未能确认存储同步完成；突然断电可能丢失本次修改。';

  @override
  String storageSyncWarning(String result) {
    return '$result\n\n内容已保存，但未能确认存储同步完成；突然断电可能丢失本次修改。';
  }

  @override
  String get storageUnavailable => '配置、插件和设置暂时不可用，请等待数据恢复得到确认后再继续。仍可停止连接。';

  @override
  String get trustedRootsUnavailable => '无法读取或解析默认受信根证书，请重试。';

  @override
  String get nameInvalid => '配置名称不能为空，且 UTF-8 编码后不能超过 80 字节。';

  @override
  String get operationBusyFile => '当前有操作正在处理，文件未提交。请等待操作完成后重新选择。';

  @override
  String get importResultUnconfirmed => '导入结果未确认，已重新读取配置列表；未自动重复导入，请先核实是否已经保存。';

  @override
  String get fileUnreadable => '无法读取所选文件，未创建配置。请检查文件后重试。';

  @override
  String get runningOldBody => '接管中 · 旧正文';

  @override
  String get runningConfig => '接管中';

  @override
  String get updateConfig => '更新配置';

  @override
  String get editConfig => '编辑配置';

  @override
  String get moreActions => '更多操作';

  @override
  String get configActionFailed => '配置操作未完成';

  @override
  String get viewConfigError => '查看配置错误';

  @override
  String get rename => '重命名';

  @override
  String get changeSourceUpdate => '修改来源并更新';

  @override
  String autoUpdateHours(int hours) {
    return '自动更新：每 $hours 小时';
  }

  @override
  String get autoUpdateClosed => '自动更新（关闭）';

  @override
  String get viewBody => '查看正文';

  @override
  String get delete => '删除';

  @override
  String updatedAt(String date, String time) {
    return '更新于 $date $time';
  }

  @override
  String savedAt(String date, String time) {
    return '保存于 $date $time';
  }

  @override
  String get updateTimeUnknown => '更新时间未知';

  @override
  String get saveTimeUnknown => '保存时间未知';

  @override
  String get deleteConfigTitle => '删除配置？';

  @override
  String get deleteKeepsSelection => '当前选择与接管不变。';

  @override
  String get deleteNoSelection => '删除后取消当前选择，不会自动选择其他配置。';

  @override
  String get deleteRemoteBody => '将删除保存的正文与来源，不会自动停止正在运行的连接。';

  @override
  String get deleteLocalBody => '将删除保存的本地正文，不会自动停止正在运行的连接。';

  @override
  String get renameConfig => '重命名配置';

  @override
  String get changeConfigSource => '修改配置来源';

  @override
  String get configName => '配置名称';

  @override
  String get configUrl => '完整配置 URL';

  @override
  String get showUrl => '显示 URL';

  @override
  String get hideUrl => '隐藏 URL';

  @override
  String get nameOptional => '名称（可选）';

  @override
  String get nameOptionalHint => '留空使用来源主机名';

  @override
  String get importFullConfig => '导入完整配置';

  @override
  String get importFullConfigNotice => '保存完整 mihomo 配置，实际启动时由内核解析。不转换节点订阅。';

  @override
  String get downloadAndSave => '下载并保存';

  @override
  String get saveAndUpdate => '保存并更新';

  @override
  String get overwrite => '覆盖更新';

  @override
  String get leaveBodyTitle => '离开正文编辑页？';

  @override
  String get leaveBodyMessage => '已提交的保存不会因离开而取消。结果尚未确认，请回配置列表核实，不要重复提交。';

  @override
  String get leave => '离开';

  @override
  String get discardEditsTitle => '放弃未保存修改？';

  @override
  String get discardEditsMessage => '当前输入仅保留在此页，离开后不会保存。';

  @override
  String get nameRequired => '请输入配置名称。';

  @override
  String get normalizeNewlinesTitle => '统一换行格式？';

  @override
  String get normalizeNewlinesMessage =>
      '正文中使用了多种换行格式。保存时将统一为主要使用的格式，并保留字节顺序标记（BOM）。';

  @override
  String get normalizeAndSave => '统一并保存';

  @override
  String get submittedSavedTitle => '已保存提交的版本';

  @override
  String get submittedSavedMessage => '提交的正文已保存，此后产生的修改仍保留在编辑器中，尚未保存。';

  @override
  String get saveUnconfirmed => '保存结果尚未确认，已重新读取配置。请返回列表核实；当前输入保留，未自动重试。';

  @override
  String get savedApplyFailed => '已保存，应用未完成';

  @override
  String get saveFailed => '保存失败';

  @override
  String get findBody => '查找正文';

  @override
  String get previousMatch => '上一个';

  @override
  String get nextMatch => '下一个';

  @override
  String get closeFind => '关闭查找';

  @override
  String get readOnly => '只读';

  @override
  String get saving => '正在保存';

  @override
  String get resultUnconfirmed => '结果未确认';

  @override
  String get tooLarge => '超过 16 MiB · 未截断';

  @override
  String get sizePending => '大小尚未确认 · 保存时重新检查';

  @override
  String get unsavedChanges => '未保存修改';

  @override
  String get configBody => '配置正文';

  @override
  String get find => '查找';

  @override
  String get softWrap => '自动换行';

  @override
  String get saveAndApply => '保存并应用';

  @override
  String get bodyUnreadable => '该配置没有可用正文，请先更新来源。';

  @override
  String get bodyPrepFailed => '配置正文尚未准备好，请返回后重试。';

  @override
  String editorLineTooLong(int line, int limit) {
    return '第 $line 行超过 $limit 个 UTF-16 代码单元的编辑上限，现按只读文本块显示完整原文。';
  }

  @override
  String editorQueryTooLong(int limit) {
    return '查找输入最多 $limit 个 UTF-16 代码单元。';
  }

  @override
  String editorChangeTooLong(int line, int limit) {
    return '未接受本次修改：第 $line 行将超过 $limit 个 UTF-16 代码单元，已有输入未改动。';
  }

  @override
  String get editorContextChanged => '暂时无法保存，草稿仍保留。';

  @override
  String get privacyNoticeTitle => '隐私与许可';

  @override
  String get privacyNoticeUnderstood => '我已了解';

  @override
  String get privacyNoticeNotSaved => '未能确认提示记录已保存。下次打开可能再次显示。';

  @override
  String get privacyNoticeBody =>
      'Clash Pseudo 开源、免费，不进行用户数据采集或上报，不提供任何代理节点或订阅服务。\n\n数据处理\n\n应用不统计用户的使用情况，不分析用户行为，也不自动上报崩溃信息。配置、插件与应用设置保存在设备上。代理和规则匹配在设备上处理流量、域名及 IP；连接信息与日志用于显示和诊断，已安装应用列表用于设置哪些应用的流量由 VPN 接管。\n\n网络通信\n\n配置和插件下载、DNS 查询、代理连接、测速、远程图标及规则／地理数据更新会访问相应网络服务，目标由配置和程序默认值确定。关闭 VPN 接管不关闭这些功能的网络访问。\n\n请求会向目标服务发送功能所需的内容和认证信息，服务也会看到连接来源的 IP。HTTP 来源的下载没有传输加密。\n\n权限用途\n\n- 网络访问与网络状态：建立连接、下载内容和检查网络。\n- 前台服务与通知：运行 VPN、局域网代理服务和后台任务，显示运行状态。\n- 已安装应用可见性：显示应用列表，设置哪些应用的流量由 VPN 接管。\n- VPN 授权：经 Android 授权后建立 VPN 接口，接管选定范围的网络流量。\n\n文件与备份\n\n配置和插件正文、来源地址及其中保存的凭据存放在应用私有目录，应用未另行加密。导出的 ZIP 未加密，包含配置、插件、应用设置及其中保存的来源地址和凭据。备份的导入、导出位于“设置 → 存储与数据”，通过 Android 文件选择器完成；保存位置在导出时选择。\n\nAndroid 系统备份和设备迁移可复制配置、插件与应用设置，是否启用由系统设置与所用备份服务决定。文件提供方的同步功能也可保存所选文件的云端副本。\n\n连接记录、内核日志与原始正文\n\n近期连接记录与日志只暂存在设备内存中，受容量和保留时间限制，不保存为历史文件；可在相应页面清除，进程结束后消失。\n\n可在“设置 → 诊断工具 → 内核日志”查看内核运行、连接和错误信息。保留的日志按内核原文显示；容量不足时移除或略过整条记录，并显示遗漏情况，不截断或改写正文。配置编辑器和备份保留原始正文。\n\n删除与查看\n\n可在应用内删除配置与插件、清除近期记录和日志，并逐项清理缓存数据库及可重建的地理数据文件。清理前需停止内核；只删除已确认的文件，协议身份、provider自定义文件和其他用户文件继续保留。\n\n也可在系统设置中撤销 VPN 授权或清除应用数据。清除应用数据或卸载不会删除已导出的文件、系统备份或其他外部副本。\n\n完整说明随功能变化更新，可在“设置 → 关于”查看当前安装版本的内容。\n\n项目仓库\n\nhttps://github.com/MonadBoxLab/ClashPseudo\n\n更多请参见 GPLv3 协议。';

  @override
  String get privacyNoticeIntro =>
      'Clash Pseudo 开源、免费，不进行用户数据采集或上报，不提供任何代理节点或订阅服务。';

  @override
  String get privacyNoticeReadFull => '完整说明';

  @override
  String get privacyNoticeLicenseNotice => '更多请参见 GPLv3 协议。';

  @override
  String get privacyNoticeLicenseName => 'GPLv3';

  @override
  String get projectRepositoryUrl =>
      'https://github.com/MonadBoxLab/ClashPseudo';

  @override
  String get privacyDataProcessingTitle => '数据处理';

  @override
  String get privacyDataProcessingBody =>
      '应用不统计用户的使用情况，不分析用户行为，也不自动上报崩溃信息。配置、插件与应用设置保存在设备上。代理和规则匹配在设备上处理流量、域名及 IP；连接信息与日志用于显示和诊断，已安装应用列表用于设置哪些应用的流量由 VPN 接管。';

  @override
  String get privacyNetworkCommunicationTitle => '网络通信';

  @override
  String get privacyNetworkCommunicationBody =>
      '配置和插件下载、DNS 查询、代理连接、测速、远程图标及规则／地理数据更新会访问相应网络服务，目标由配置和程序默认值确定。关闭 VPN 接管不关闭这些功能的网络访问。\n\n请求会向目标服务发送功能所需的内容和认证信息，服务也会看到连接来源的 IP。HTTP 来源的下载没有传输加密。';

  @override
  String get privacyPermissionPurposesTitle => '权限用途';

  @override
  String get privacyPermissionPurposesBody =>
      '- 网络访问与网络状态：建立连接、下载内容和检查网络。\n- 前台服务与通知：运行 VPN、局域网代理服务和后台任务，显示运行状态。\n- 已安装应用可见性：显示应用列表，设置哪些应用的流量由 VPN 接管。\n- VPN 授权：经 Android 授权后建立 VPN 接口，接管选定范围的网络流量。';

  @override
  String get privacyFilesAndBackupsTitle => '文件与备份';

  @override
  String get privacyFilesAndBackupsBody =>
      '配置和插件正文、来源地址及其中保存的凭据存放在应用私有目录，应用未另行加密。导出的 ZIP 未加密，包含配置、插件、应用设置及其中保存的来源地址和凭据。备份的导入、导出位于“设置 → 存储与数据”，通过 Android 文件选择器完成；保存位置在导出时选择。\n\nAndroid 系统备份和设备迁移可复制配置、插件与应用设置，是否启用由系统设置与所用备份服务决定。文件提供方的同步功能也可保存所选文件的云端副本。';

  @override
  String get privacyRecordsAndLogsTitle => '连接记录、内核日志与原始正文';

  @override
  String get privacyRecordsAndLogsBody =>
      '近期连接记录与日志只暂存在设备内存中，受容量和保留时间限制，不保存为历史文件；可在相应页面清除，进程结束后消失。\n\n可在“设置 → 诊断工具 → 内核日志”查看内核运行、连接和错误信息。保留的日志按内核原文显示；容量不足时移除或略过整条记录，并显示遗漏情况，不截断或改写正文。配置编辑器和备份保留原始正文。';

  @override
  String get privacyDeletingDataTitle => '删除与查看';

  @override
  String get privacyDeletingDataBody =>
      '可在应用内删除配置与插件、清除近期记录和日志，并逐项清理缓存数据库及可重建的地理数据文件。清理前需停止内核；只删除已确认的文件，协议身份、provider自定义文件和其他用户文件继续保留。\n\n也可在系统设置中撤销 VPN 授权或清除应用数据。清除应用数据或卸载不会删除已导出的文件、系统备份或其他外部副本。\n\n完整说明随功能变化更新，可在“设置 → 关于”查看当前安装版本的内容。';

  @override
  String get privacyProjectRepositoryTitle => '项目仓库';

  @override
  String get noUsableBodyReimport => '该配置没有可用正文，请重新更新来源。';

  @override
  String get requestNotAccepted => '请求未被受理，请重试。';

  @override
  String get temporaryModeUnknown => '暂时无法确认运行模式，应用在前台时会自动重试。';

  @override
  String get temporaryStatusUnavailable => '暂时无法获取接管状态，应用在前台时会自动重试，不会自动启动。';

  @override
  String get temporaryConfigsUnreadable => '暂时无法读取已保存配置，原文件未被修改。';

  @override
  String get temporaryOverridesUnreadable => '暂时无法读取已保存插件，原文件未被修改。';

  @override
  String get temporarySettingsUnreadable => '暂时无法读取应用设置，原文件未被修改。';

  @override
  String get failure => '失败';

  @override
  String get stageStopping => '正在停止接管';

  @override
  String get tunnelStopped => '接管已停止。';

  @override
  String get statusUnconfirmedVerify => '接管状态尚未确认，请先核实状态。';

  @override
  String get importAndSelectFirst => '请先导入并选择配置。';

  @override
  String get configChangedWaitStrategies => '当前配置已变化，请等待策略重新加载。';

  @override
  String get coreNotReadyStrategies => '内核资源尚未确认，暂时无法加载策略。';

  @override
  String get previewMismatch => '当前运行配置与预览请求不一致。';

  @override
  String get stageLoadingStrategies => '正在加载策略配置';

  @override
  String get localCannotRemoteUpdate => '本地配置不能远程更新。';

  @override
  String get configRenamed => '配置已重命名。';

  @override
  String get alreadyRunning => '接管已经运行，无需重复启动。';

  @override
  String get tunnelStarted => '接管已启动。';

  @override
  String get unknownOperation => '无法识别此操作。';

  @override
  String get localCannotChangeRemote => '本地配置不能修改远程来源。';

  @override
  String sourceUsedBy(String name) {
    return '该来源已由“$name”使用，请选择已有配置。';
  }

  @override
  String get sourceSavedConfirmOverwrite => '该来源已保存，请先确认是否覆盖更新。';

  @override
  String get updateInterrupted => '更新未完成，请重新更新此来源。';

  @override
  String get stageDownloading => '正在下载配置';

  @override
  String get stageUpdatingConfig => '正在更新配置';

  @override
  String get updateStateWriteFailed => '无法保存更新状态，更新未开始；旧记录未修改，请修复存储问题后重试。';

  @override
  String get stageStoppingOld => '正在停止先前的接管';

  @override
  String get configUpdatedRestarted => '配置已更新并重新启动。';

  @override
  String get configSavedParsedAtStart => '配置已保存，启动时由内核解析。';

  @override
  String get configChangedReopen => '配置已删除、正文已变化或不可编辑，请重新打开；当前输入未保存。';

  @override
  String get stageSavingConfig => '正在保存配置';

  @override
  String get configSavedApplied => '配置已保存并应用。';

  @override
  String get configSavedApplyReleasePending =>
      '配置已保存，但应用新配置或释放上次预览资源尚未完成。请核实接管状态；新正文已保留。';

  @override
  String get configSaved => '配置已保存。';

  @override
  String get localNoAutoUpdate => '本地配置没有自动更新设置。';

  @override
  String get chooseUpdateInterval => '请选择 6、12 或 24 小时的更新间隔。';

  @override
  String get autoUpdateEnabledResult => '自动更新已开启。';

  @override
  String get autoUpdateDisabledResult => '自动更新已关闭。';

  @override
  String get configNameInvalid => '配置名称不能为空，且 UTF-8 编码后不能超过 80 字节。';

  @override
  String get switchedConfig => '已切换接管配置。';

  @override
  String get configSelectedNotStarted => '已选择配置，尚未启动接管。';

  @override
  String get configDeleted => '配置已删除，未启动接管。';

  @override
  String get modeSavedNextStart => '备用模式已保存；启动时仅在配置未指定 mode 字段时使用。';

  @override
  String get modeConfirmed => '运行模式已确认。';

  @override
  String get stageSwitchingMode => '正在切换运行模式';

  @override
  String get modeNotConfirmed =>
      '备用模式已保存，但本次运行模式切换未确认；启动时仅在配置未指定 mode 字段时使用备用模式。';

  @override
  String get modeSwitchedResult => '运行模式已切换。';

  @override
  String get alreadyRunningNoRestore => '接管已在运行，无需系统恢复。';

  @override
  String get systemStartUnsupported => '此平台不支持系统启动。';

  @override
  String get noConfigForSystemStart => '没有可用的已选配置，系统启动已取消。';

  @override
  String get stagePreparingSystemStart => '正在准备系统启动';

  @override
  String get systemStartPrepared => '已准备系统启动。';

  @override
  String get accessSavedNextConnection => '应用访问设置已保存，下次连接时生效。';

  @override
  String get accessSavedReconnectFailed => '运行中的配置不可用，设置已保存但未能重新连接。';

  @override
  String get stageReconnectAccess => '正在重新连接以应用新的接管范围设置';

  @override
  String get accessSavedReconnected => '应用访问设置已保存并重新连接。';

  @override
  String get overridesSavedNextStart => '插件已保存，下次启动时应用。';

  @override
  String get runningConfigMissingOverrides => '当前运行的配置已不在列表中，无法应用插件。';

  @override
  String get runningConfigNoBody => '当前运行的配置没有可用正文，无法重新启动。';

  @override
  String get overridesAppliedReconnected => '插件已应用并重新连接。';

  @override
  String get stageWaitingVpnAuth => '正在等待 VPN 授权';

  @override
  String get authorizationCancelled => '授权已取消，接管保持停止。';

  @override
  String get stageStartingTunnel => '正在启动接管';

  @override
  String get configMissingRefresh => '配置已不存在，请刷新列表。';

  @override
  String get operationFinished => '操作已结束。';

  @override
  String get overrideMissingRefresh => '插件已不存在，请刷新列表。';

  @override
  String get remoteOverrideReadOnly => '远程插件正文只读，请修改来源或新建本地插件。';

  @override
  String get overrideChangedReopen => '插件正文已变化，请重新打开后编辑。';

  @override
  String get overrideSavedApplyLater => '插件已保存。';

  @override
  String get localOverrideNoRemoteUpdate => '本地插件不能远程更新。';

  @override
  String get overrideNoBodyEnable => '插件没有可用正文，请先更新后启用。';

  @override
  String get overrideSettingsSaved => '插件设置已保存。';

  @override
  String get overrideOrderChangedRefresh => '插件列表已变化，请刷新后重新排序。';

  @override
  String get overrideOrderSaved => '插件顺序已保存。';

  @override
  String get overrideDeleted => '插件已删除。';

  @override
  String get unknownOverrideOperation => '无法识别此插件操作。';

  @override
  String get localOverrideNoAutoUpdate => '本地插件没有自动更新设置。';

  @override
  String get overrideAutoUpdateEnabled => '插件自动更新已开启。';

  @override
  String get overrideAutoUpdateDisabled => '插件自动更新已关闭。';

  @override
  String get overrideSourceExists => '已有插件使用此来源，请更新该插件。';

  @override
  String get overrideUpdateIncomplete => '更新未完成，请重试。';

  @override
  String get overrideChangedNotApplied => '插件已变化，下载结果未应用。';

  @override
  String get overrideUpdatedApplyLater => '插件已更新。';

  @override
  String get overrideNameInvalid => '插件名称不能为空，且 UTF-8 编码后不能超过 80 字节。';

  @override
  String get overridesUnreadable => '无法读取已保存插件，原文件未被修改。';

  @override
  String get overridesSaveFailed => '保存插件失败，请检查可用存储空间后重试。';

  @override
  String get overrideBodyMissing => '启用的插件没有可用正文，请先更新或停用。';

  @override
  String get overridesTooLarge => '启用的插件正文合计超过 16 MiB。';

  @override
  String get schedulesSynced => '自动更新计划已同步。';

  @override
  String get unknownUpdateTarget => '无法识别此更新目标。';

  @override
  String get targetGoneOrDisabled => '目标已不存在或自动更新已关闭。';

  @override
  String get configChangedDownloadUnapplied => '配置已变化，下载结果未应用。';

  @override
  String get configUnchanged => '配置内容未变化。';

  @override
  String get configUpdatedPending => '配置已更新并保存。';

  @override
  String get stageApplyingConfigUpdate => '正在应用配置更新';

  @override
  String get configUpdatedReconnected => '配置已更新并重新连接。';

  @override
  String get configSavedReconnectIncomplete => '配置已保存，但重新连接未完成，请核实接管状态。';

  @override
  String get overrideUnchanged => '插件内容未变化。';

  @override
  String get overrideUpdatedEnableApply => '插件已更新，启用后生效。';

  @override
  String get overrideUpdatedPending => '插件已更新并保存。';

  @override
  String get runningConfigUnavailable => '运行中的配置不可用。';

  @override
  String get stageApplyingOverrideUpdate => '正在应用插件更新';

  @override
  String get overrideUpdatedReconnected => '插件已更新并重新连接。';

  @override
  String get overrideSavedReconnectIncomplete => '插件已保存，但重新连接未完成，请核实接管状态。';

  @override
  String get urlRequired => '请输入完整的 HTTP 或 HTTPS 配置 URL。';

  @override
  String get downloadTimeout => '下载超时，请检查网络后重试。';

  @override
  String get tlsFailed => 'HTTPS 证书或安全连接验证失败，未绕过验证。';

  @override
  String get downloadNotUtf8 => '下载内容不是有效的 UTF-8 文本。';

  @override
  String get downloadFailed => '无法下载配置，请检查来源和当前网络。';

  @override
  String get redirectInvalid => '配置来源的重定向无效或次数过多。';

  @override
  String downloadHttpStatus(String status) {
    return '配置下载失败（HTTP $status）。';
  }

  @override
  String get downloadTooLarge => '配置正文过大，未保存。';

  @override
  String get redirectTooMany => '配置来源的重定向次数过多。';

  @override
  String get configStoreUnreadable => '无法读取已保存配置，原文件未被修改。';

  @override
  String get configSaveFailed => '保存配置失败，请检查可用存储空间后重试。';

  @override
  String get preferencesUnreadable => '无法读取应用设置，原文件未被修改。';

  @override
  String get preferencesSaveFailed => '保存应用设置失败，请检查可用存储空间后重试。';

  @override
  String get textTooLargeSave => '配置正文超过 16 MiB，未保存。';

  @override
  String get preparationOptionsTooLarge =>
      '准备参数的 UTF-8 JSON 编码超过 16 MiB，未应用本次修改。';

  @override
  String get preparationFragmentsTooLarge =>
      '插件 JSON 的 UTF-8 编码超过 128 MiB，未应用本次修改。';

  @override
  String get preparationMetadataInvalid => '配置标识或来源信息包含无效的 Unicode 编码，未应用本次修改。';

  @override
  String get textNotUtf8 => '配置正文不是有效的 UTF-8 文本。';

  @override
  String get textTooLargeImport => '配置正文超过 16 MiB，未导入。';

  @override
  String get sessionChangedNoDisconnect => '会话已变化，未执行断开连接操作。';

  @override
  String get disconnectFailedShort => '断开失败';

  @override
  String get disconnectUnconfirmedShort => '断开结果未确认';

  @override
  String get pathUnavailable => '路径未提供';

  @override
  String get strategyStatusStale => '策略状态尚未更新，应用在前台时会自动重试；不能使用旧记录切换策略。';

  @override
  String get coreContextUnconfirmed => '尚未确认内核运行状态。';

  @override
  String get strategyContextChangedRetry => '策略运行状态已变化，请等待重新读取当前配置。';

  @override
  String get applyingStrategySelection => '正在应用策略选择';

  @override
  String get trafficUpdateFailed => '更新失败';

  @override
  String applicationSharedUidNotice(String packages) {
    return '这些应用共享同一个 Android UID。选择或排除其中一个应用，也会影响：$packages';
  }

  @override
  String get delayCancelled => '已取消';

  @override
  String operationAndCleanupFailed(String operation, String cleanup) {
    return '$operation\n$cleanup';
  }

  @override
  String get androidStageLoading => '加载配置';

  @override
  String get androidStageEstablishing => '建立 VPN';

  @override
  String get androidStageAttaching => '接入虚拟网卡';

  @override
  String androidErrorStageFailed(String stage) {
    return '$stage失败，请检查配置来源与网络后重试。';
  }

  @override
  String get androidErrorAppInfoVersion => '无法读取版本信息。';

  @override
  String get androidErrorAppInfoNative => '无法加载原生内核。';

  @override
  String get androidErrorApplications => '无法读取应用列表。';

  @override
  String get androidErrorLogicExpired => '后台业务处理已结束。';

  @override
  String get androidErrorOperationEnded => '操作已结束。';

  @override
  String get androidErrorScheduleSave => '无法保存自动更新计划。';

  @override
  String get androidErrorBusy => '已有操作正在处理，请等待操作完成。';

  @override
  String get androidErrorUnknownCommand => '无法识别此操作。';

  @override
  String get androidOperationAccepting => '正在受理操作';

  @override
  String get androidOperationPreparingSystemStart => '正在准备系统启动';

  @override
  String get androidErrorServiceStart => '系统未允许启动任务，请返回应用后重试。';

  @override
  String get androidErrorServiceNotAllowed => '系统未允许启动任务。';

  @override
  String get androidErrorVpnPermissionReturn => '请返回应用并重新启动以完成 VPN 授权。';

  @override
  String get androidErrorVpnPermissionRequests => '授权请求次数过多，请重启应用后再试。';

  @override
  String get androidErrorResultUnconfirmed => '操作已结束，请核实状态。';

  @override
  String get androidErrorActivityReturn => '请返回应用后重试。';

  @override
  String get androidErrorOpenVpnSettings => '无法打开系统 VPN 设置。';

  @override
  String get androidErrorSystemStartPrepare => '系统启动时未能准备运行配置。';

  @override
  String get androidErrorSessionChanged => '接管会话已变化。';

  @override
  String get androidErrorSessionModeChanged => '接管会话已变化，本次模式未确认。';

  @override
  String get androidErrorBackgroundStart => '无法启动后台操作，请返回应用重试。';

  @override
  String get androidErrorInvalidResult => '操作未返回有效结果。';

  @override
  String get androidErrorOperationIncomplete => '操作未完成，请核实状态后重试。';

  @override
  String get androidStatusUpdating => '正在更新';

  @override
  String get androidErrorUpdateFailed => '更新失败';

  @override
  String get androidErrorUnknownMode => '无法识别运行模式。';

  @override
  String get androidErrorModeTimeout => '运行模式确认超时。';

  @override
  String get androidErrorModeUnconfirmed => '无法确认运行模式，请等待状态重新读取。';

  @override
  String get androidErrorNativeModeUnavailable => '原生模式接口不可用。';

  @override
  String get androidErrorTakeoverTimeout => '接管操作等待超时，请核实实际状态。';

  @override
  String get androidErrorTakeoverRunning => '当前接管未停止，不能启动新配置。';

  @override
  String get androidErrorCoreNotReady => '内核资源未就绪，不能启动新配置。';

  @override
  String get androidErrorVpnPermissionInvalid => 'VPN 授权未完成或已失效。';

  @override
  String get androidErrorVpnServiceStart => '系统未允许启动 VPN 服务，请返回应用后重试。';

  @override
  String get androidErrorReleaseUnconfirmed => '尚未确认资源是否已释放，当前停止或重启的结果仍未确认。';

  @override
  String get androidErrorTakeoverStartFailed => '接管未能启动。';

  @override
  String get androidErrorTakeoverReleaseUnknown => '无法确认接管资源是否已释放。';

  @override
  String get androidErrorStopNotAccepted => '系统未受理停止请求，接管状态未确认。';

  @override
  String get androidErrorStrategyPrepare => '策略配置加载未完成，请检查配置与网络后重试。';

  @override
  String get androidErrorNativeReleaseUnconfirmed => '原生资源释放未确认。';

  @override
  String get androidErrorStrategyParams => '策略加载参数无效。';

  @override
  String get androidErrorStrategyContext => '策略运行状态已变化，本次结果未确认。';

  @override
  String get androidErrorStrategyTimeout => '策略操作等待超时，请等待实际状态重新读取。';

  @override
  String get androidErrorStrategyUnconfirmed => '策略操作未确认，请核实当前配置、成员与内核状态。';

  @override
  String get androidErrorNativeStrategyUnavailable => '原生策略接口不可用。';

  @override
  String get androidErrorCoreContextRefresh => '内核运行状态已变化，请刷新后重试。';

  @override
  String get androidErrorCoreContextReread => '内核运行状态已变化，请重新读取。';

  @override
  String get androidErrorGroupUntestable => '当前策略组无法测试。';

  @override
  String get androidErrorDelayStart => '无法启动延迟测试。';

  @override
  String get androidErrorNativeDelayUnavailable => '原生测速接口不可用。';

  @override
  String get androidErrorBatchExpired => '测速批次已失效，请重新测试。';

  @override
  String get androidErrorDelayRead => '无法读取测速结果。';

  @override
  String get androidErrorConnectionQuerySize => '连接查询参数过大。';

  @override
  String get androidErrorConnectionId => '连接标识无效。';

  @override
  String get androidErrorConnectionBusy => '连接操作尚未完成。';

  @override
  String get androidErrorConnectionTimeout => '连接操作等待超时。';

  @override
  String get androidErrorDisconnectUnconfirmed => '断开结果未确认。';

  @override
  String get androidErrorUpdateFailedShort => '更新失败。';

  @override
  String get androidErrorNativeConnectionUnavailable => '原生连接接口不可用。';

  @override
  String get androidErrorConnectionNotAccepted => '连接操作未被受理。';

  @override
  String get androidErrorOperationWaitTimeout => '操作等待超时，请核实状态后重试。';

  @override
  String get androidErrorSystemTimeoutTask => '系统结束了超时任务，请核实状态后重试。';

  @override
  String get androidErrorOperationInterrupted => '操作已中断，请核实状态后重试。';

  @override
  String get androidErrorResourceUpdateSize => '资源更新请求超出大小限制。';

  @override
  String get androidErrorNodesQuerySize => '节点查询超出大小限制。';

  @override
  String get androidErrorRulesQuerySize => '规则查询超出大小限制。';

  @override
  String get androidErrorLogsQuerySize => '日志查询超出大小限制。';

  @override
  String get androidErrorCoreBusy => '内核正在处理其他操作，或运行状态已变化，请刷新后重试。';

  @override
  String get androidErrorCoreReadTimeout => '内核读取超时，请重试。';

  @override
  String get androidErrorCoreReadFailed => '无法读取内核数据，请刷新后重试。';

  @override
  String get androidErrorNativeReadUnavailable => '原生读取接口不可用。';

  @override
  String get androidErrorVpnInputMissing => 'VPN 授权已失效，或缺少运行所需的数据。';

  @override
  String get androidErrorNotificationDenied => '系统未允许显示接管通知。';

  @override
  String get androidErrorNotificationUpdate => '接管通知无法更新。';

  @override
  String get androidErrorNativeCoreLoad => '原生内核无法加载，请检查安装包。';

  @override
  String get androidErrorSystemRevoked => '系统已撤销 VPN';

  @override
  String get androidErrorServiceDestroyed => 'VPN 服务已销毁';

  @override
  String get androidErrorApplicationAllowlistMissing =>
      '仅接管列表中的应用均已卸载，请重新选择应用。';

  @override
  String resultRange(int start, int end, int total) {
    return '第 $start–$end 条，共 $total 条';
  }

  @override
  String resultCount(int count) {
    return '$count 条结果';
  }

  @override
  String uptimeClock(String hours, String minutes, String seconds) {
    return '$hours 时 $minutes 分 $seconds 秒';
  }

  @override
  String get connectionBehavior => '连接行为';

  @override
  String get reconnectOnRoutingChange => '切换后重新连接';

  @override
  String get routingReconnectNotice => '切换模式或策略时重启内核，断开现有连接。';

  @override
  String get applicationNotInstalled => '未安装';

  @override
  String get uptimeRunning => '连续运行';

  @override
  String uptimeDays(String days) {
    return '连续运行 · $days 天';
  }

  @override
  String get trafficDownloaded => '累计下载';

  @override
  String get trafficUploaded => '累计上传';

  @override
  String get processMemoryUnavailable => '无法读取内存，请稍后重试。';

  @override
  String get dnsTools => 'DNS 工具';

  @override
  String get dnsName => '名称或 IP 地址';

  @override
  String get dnsRecordType => '记录类型';

  @override
  String get dnsQuery => '查询';

  @override
  String get dnsRefreshCoreStatus => '刷新内核状态';

  @override
  String get dnsViewQueryResults => '查看查询结果';

  @override
  String get dnsQueryResults => '查询结果';

  @override
  String get dnsPreviousQuery => '上次查询';

  @override
  String get dnsViewPreviousQuery => '查看上次查询';

  @override
  String get dnsQueryRawData => 'DNS 查询原始数据';

  @override
  String dnsQueryIdentity(String name, String type) {
    return '查询：$name · $type';
  }

  @override
  String dnsResponseSource(String source) {
    return '来源：$source';
  }

  @override
  String get dnsCacheOperationDetails => '缓存操作详情';

  @override
  String get dnsCacheRawData => '缓存操作原始数据';

  @override
  String get dnsResolverNotice => '使用当前内核的解析器查询，可能读取缓存，结果不等同于客户端实际收到的 DNS 响应。';

  @override
  String get dnsExpired => '结果已过期，请重新查询';

  @override
  String get dnsUnavailable => '当前解析器不可用';

  @override
  String get dnsInvalidRequest => '名称或记录类型无效，或请求超出大小限制。';

  @override
  String get dnsBusy => '上次查询尚未完全结束，请稍候。';

  @override
  String get dnsTimeout => '查询超时，未自动重试。';

  @override
  String get dnsCancelled => '查询已取消';

  @override
  String get dnsQueryFailed => '查询失败，请重试。';

  @override
  String get dnsResultTooLarge => '响应超出大小限制，未显示不完整结果。';

  @override
  String get dnsInvalidResponse => '无法读取查询结果，请重试。';

  @override
  String get dnsAnswer => '应答记录';

  @override
  String get dnsAuthority => '权威记录';

  @override
  String get dnsAdditional => '附加记录';

  @override
  String get dnsNoRecords => '无记录';

  @override
  String get dnsTruncated => '响应带截断标记';

  @override
  String dnsElapsed(double milliseconds) {
    return '查询耗时 $milliseconds ms';
  }

  @override
  String dnsRcode(String name, int code) {
    return '返回码：$name ($code)';
  }

  @override
  String dnsRecordMeta(String type, String recordClass, int ttl) {
    return '$type · $recordClass · TTL $ttl s';
  }

  @override
  String get dnsClearCache => '清理 DNS 解析缓存';

  @override
  String get dnsClearFakeIp => '清理 fake-IP 映射';

  @override
  String get dnsFakeIpWarning => '旧地址可能失效，客户端可能需要重新解析。';

  @override
  String get dnsCacheCompleted => '已清理现有 DNS 解析缓存；查询可立即回填。';

  @override
  String get dnsCacheEmpty => '没有可清理的缓存';

  @override
  String get dnsFakeIpCompleted => '已清理 fake-IP 映射';

  @override
  String get dnsFakeIpEmpty => '没有可清理的 fake-IP 映射池';

  @override
  String get dnsCachePartialOrFailed => '清理未完全确认，可能已产生部分影响。';

  @override
  String get dnsCacheFailed => '清理失败，请重试。';

  @override
  String get dnsPoolCleared => '已清理';

  @override
  String get dnsPoolInactive => '映射池未启用';

  @override
  String get dnsPoolUnconfirmed => '清理结果未确认';

  @override
  String get dnsPersistentPoolEnabled => '持久化映射池：已启用';

  @override
  String get dnsPersistentPoolDisabled => '持久化映射池：未启用';

  @override
  String get providerFormFormatHint => 'format 指定外部内容的编码格式；inline 类型直接使用规则条目。';

  @override
  String get strategyGroupHashKeyInvalid => '使用 round-robin 时，hash-key 必须为空';

  @override
  String get allStrategyGroups => '全部策略组';

  @override
  String get hiddenGroupAttribute => '隐藏';

  @override
  String get globalGroupAttribute => '全局组';

  @override
  String get noStrategyGroups => '没有策略组';

  @override
  String get coreCleanupResource => '删除本地资源文件';

  @override
  String get coreCleanupResourceMessage =>
      '只删除下列资源文件，不删除其配置定义。再次使用时可能需要重新下载或导入。不删除其他文件。';

  @override
  String get coreCleanupScheduled => '已安排清理，将在下次启动时执行。当前尚未删除文件。';

  @override
  String coreCleanupScheduledWithIssue(String result, String issue) {
    return '$result\n\n$issue';
  }

  @override
  String get coreCleanupStopUnconfirmed => '未能确认内核已停止。';

  @override
  String get coreCleanupInitializing => '正在检查内核数据清理安排。';

  @override
  String get coreCleanupRequired => '内核目录清理尚未执行。请在“存储与数据”中退出应用后重新打开。';

  @override
  String get coreCleanupFailed => '内核数据清理未完成。';

  @override
  String get coreCleanupCompleted => '所选内核文件已清理。再次使用内核时，可能会生成新文件。';

  @override
  String get coreCleanupNeedsSelection => '请先选择要清理的内核文件。';

  @override
  String resourceLocalFile(String path) {
    return '本地文件：$path';
  }

  @override
  String get storageData => '存储与数据';

  @override
  String get storageUsage => '存储占用';

  @override
  String get storageCleanup => '数据清理';

  @override
  String get storageUsageFailed => '无法读取存储占用。';

  @override
  String get storageCleanupFailed => '上次运行遗留的临时文件未能全部清理。';

  @override
  String get coreDataDirectory => '内核工作目录';

  @override
  String get storageMemoryNotice => '近期连接与内核日志仅暂存在内存中。清除已结束记录不会关闭活跃连接。';

  @override
  String get storageCoreNotice => '内核文件由 mihomo 管理，不适用配置与插件的容量上限。';

  @override
  String storageBytes(String bytes) {
    return '$bytes';
  }

  @override
  String storageFileBytes(String bytes, String limit) {
    return '$bytes / $limit';
  }

  @override
  String get storageLimitExceeded => '已超出上限';

  @override
  String get storageEntryCountUnavailable => '条目：—';

  @override
  String storageEntryCount(int count, int limit) {
    return '$count / $limit 条';
  }

  @override
  String get clearConfigurations => '删除全部配置';

  @override
  String get clearConfigurationsMessage =>
      '将删除所有已保存的配置、所选配置及保存的模式选择，并取消配置自动更新任务。正在运行的连接不会自动停止。不删除插件、应用设置或内核文件。';

  @override
  String get configurationsCleared => '已保存的配置已全部删除。';

  @override
  String get clearOverrides => '删除全部插件';

  @override
  String get clearOverridesMessage =>
      '将删除所有已保存的插件（包括本地自定义）并取消插件自动更新任务；应用会尝试从当前运行的配置中移除插件，再重新连接。即使未能应用这些运行配置变更，本地删除也不会撤销。不删除配置、应用设置或内核文件。';

  @override
  String get overridesCleared => '已保存的插件已全部删除。';

  @override
  String get inactiveConnectionsCleared => '已清除已结束的连接记录。';

  @override
  String get inactiveConnectionsClearFailed => '未能清除已结束的连接记录。';

  @override
  String get backupTitle => '备份与恢复';

  @override
  String get backupExport => '导出备份';

  @override
  String get backupImport => '导入备份';

  @override
  String get backupRestore => '恢复备份';

  @override
  String get backupScopeNotice => '仅包含配置、插件和应用设置。';

  @override
  String backupCounts(int configurations, int overrides) {
    return '$configurations 个配置 · $overrides 个插件';
  }

  @override
  String backupSelected(String name) {
    return '所选配置：$name';
  }

  @override
  String get backupNoSelection => '未选择配置';

  @override
  String get backupConfirmTitle => '覆盖应用数据？';

  @override
  String get backupConfirmMessage => '备份会覆盖现有数据，而不是与现有数据合并；备份中的空列表也会清空对应的现有内容。';

  @override
  String get backupConfirmRunning =>
      '先停止当前连接并释放资源；恢复后尝试使用备份中选定的配置连接。之后收到的断开请求优先执行。';

  @override
  String get backupConfirmStopped => '恢复后不会主动建立连接。';

  @override
  String get backupConfirmUnconfirmed => '连接状态尚未确认，恢复只会在可安全覆盖数据时执行。';

  @override
  String get backupExportSaved => '备份文件已保存。';

  @override
  String get backupCancelled => '操作已取消。';

  @override
  String get backupInvalid => '备份文件无效或格式不受支持。';

  @override
  String get backupTooLarge => '备份超过允许的大小限制。';

  @override
  String get backupCandidateExpired => '先前准备的备份已失效，请重新准备。';

  @override
  String get backupNotRestored => '备份数据未恢复。';

  @override
  String get backupRestored => '备份数据已恢复。';

  @override
  String get backupRestoreUnconfirmed => '恢复结果尚未确认，请等待重新读取状态。';

  @override
  String get backupConnectionStopped => '原连接已停止。';

  @override
  String get backupConnectionNotStarted => '未建立连接。';

  @override
  String get backupConnectionRestored => '已按恢复后的配置建立连接。';

  @override
  String get backupConnectionCancelled => '后续连接已取消。';

  @override
  String get backupConnectionFailed => '恢复后的连接未能建立。';

  @override
  String get backupSchedulesFailed => '自动更新任务登记未完成。';

  @override
  String get backupSettingsRefreshFailed => '未能重新读取界面所显示的设置。';

  @override
  String get resourceRawData => '原始资源数据';

  @override
  String get localCustomDeleteConfirm =>
      '仅从本地自定义插件删除此项。优先级较低的同名定义可能重新生效，已有引用不会自动修改。是否继续？';

  @override
  String get connectionRuleScope => '匹配范围';

  @override
  String get connectionRuleUnavailable => '当前连接信息不可用于新增规则。';

  @override
  String get connectionRuleTargetsFailed => '无法读取当前策略组，请重试。';

  @override
  String get backupFailed => '备份操作未完成。';

  @override
  String get backupDocumentWriteUnconfirmed => '尚未确认备份文件是否保存完成；所选位置可能留有不完整文件。';

  @override
  String localCustomSavedVerificationFailed(String result, String reason) {
    return '$result\n\n无法核对当前本地自定义条目：$reason\n请重新打开后继续。未再次提交草稿。';
  }

  @override
  String backupRestoredWithIssue(String issue) {
    return '数据已恢复。$issue';
  }
}
