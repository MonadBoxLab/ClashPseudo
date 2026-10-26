// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get selectDetails => '选择列表项目以查看详情。';

  @override
  String get selectionOutsideList => '所选项目位于当前列表范围之外。';

  @override
  String get editLocalDefinition => '编辑本地定义';

  @override
  String get definitionFormName => '名称';

  @override
  String get nodeRuntimePropertiesOnly => '此处展示运行能力与测试历史；内核未提供完整原始节点字段。';

  @override
  String get strategyRejectStatus => '拒绝';

  @override
  String strategyCardDelayNotice(String result) {
    return '当前成员最近一次HTTP目标测试：$result。';
  }

  @override
  String get overview => '总览';

  @override
  String get connectionsNavigation => '连接';

  @override
  String get configurationsNavigation => '配置';

  @override
  String get enlargeWindow => '当前任务和未保存的修改已保留，放大窗口后即可继续操作。';

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
  String get configurationsAndPlugins => '配置与插件';

  @override
  String get routingAndResources => '分流与资源';

  @override
  String get diagnosticTools => '诊断工具';

  @override
  String get configurations => '配置管理';

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
  String get coreLogsRecentWindow => '最近会话';

  @override
  String get applicationAccess => '应用访问 VPN 控制';

  @override
  String get alwaysOnVpn => 'VPN 始终开启';

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
      '自有代码采用 GPL-3.0-only。您可以依照 GNU 通用公共许可证第 3 版复制、修改和分发。在适用法律允许范围内不提供担保。第三方部分保留各自版权与许可。';

  @override
  String get sourceDistributionNotice =>
      '对应源码与构建材料须按许可要求随实际分发版本提供；当前为未公开发布的开发版本。';

  @override
  String get versionUnavailable => '暂时无法读取版本信息。';

  @override
  String get coreVersion => 'mihomo 内核版本';

  @override
  String get refresh => '刷新';

  @override
  String get runtimeConfigExplanation => '当前内核公开接口返回的实时JSON设置。';

  @override
  String get runtimeConfigSearch => '查找字段或值';

  @override
  String get clearSearch => '清除搜索';

  @override
  String get runtimeConfigLoading => '正在读取内核运行配置…';

  @override
  String get runtimeConfigLive => '运行中';

  @override
  String get runtimeConfigPreview => '预览 · 未接管';

  @override
  String get runtimeConfigStale => '旧快照 · 请刷新确认';

  @override
  String get runtimeConfigEmpty => '请先选择一份已保存正文的配置。';

  @override
  String get runtimeConfigFailed => '读取失败 · 请核实内核状态后重试';

  @override
  String get noSearchResults => '没有匹配的行';

  @override
  String get nodeSearch => '名称、来源或类型';

  @override
  String get coreReadLoading => '正在读取内核数据…';

  @override
  String get coreReadFailed => '读取失败 · 请刷新重试';

  @override
  String get coreSnapshotStale => '旧快照 · 非当前状态';

  @override
  String get sourceConfiguration => '配置自身';

  @override
  String get builtinNode => '内置';

  @override
  String get nodeHistoryNotice => '节点能力与测试历史快照，测试URL已脱敏。';

  @override
  String get previousPage => '上一页';

  @override
  String get nextPage => '下一页';

  @override
  String get noNodes => '没有匹配的节点';

  @override
  String get details => '详情';

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
  String get compiledRules => '实际生效声明顺序';

  @override
  String get normalizedRules => '规则集规范化条目';

  @override
  String get sourceRules => '来源条目 · 并非编译后规则';

  @override
  String get ruleSourceNotice =>
      '域名与 IP-CIDR 规则集展示规范化条目，合并可能改变数量。classical 展示内联 payload、缓存内容或配置 fallback，并非编译后规则导出。';

  @override
  String get ruleTarget => '目标';

  @override
  String get ruleContent => '内容';

  @override
  String get ruleSourceUnavailable => '该规则集的本地来源读取失败。';

  @override
  String get ruleSourceInvalid => '规则集本地来源无法读取或格式无效。';

  @override
  String get ruleSourceChanged => '读取期间规则来源发生变化，请刷新以获得一致快照。';

  @override
  String get ruleSourceUnsupported => '该来源格式无法通过公开接口读取。';

  @override
  String get resourcesExplanation =>
      '列出内核使用的代理提供者、规则提供者和Geo数据库。来源显示协议与主机；更新时间来自内核记录或本地文件修改时间，数量为当前条目数。';

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
  String get resourceAutoScope => '更新目标沿用内核进程记录，可能包含先前配置使用过的数据库。';

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
  String get resourceEnabled => '已启用';

  @override
  String get resourceDisabled => '未启用';

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
  String get coreLogsExplanation =>
      '当前会话的内存日志最多1000条／1MiB。日志按字段脱敏，长条目截断并标记；阅读与复制时请注意敏感信息。';

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
  String logDropped(int count) {
    return '因容量限制已丢弃 $count 条';
  }

  @override
  String logTotal(int count) {
    return '缓冲内 $count 条';
  }

  @override
  String get logClearLocal => '清空本地窗口';

  @override
  String get logBackToLatest => '回到最新';

  @override
  String get logClearNotice => '清空仅影响当前页面缓冲，不修改系统日志或内核设置。';

  @override
  String get logTruncated => '已截断';

  @override
  String get delayTestGroup => '测试整组';

  @override
  String get delayTestMember => '测试此成员';

  @override
  String get delayTesting => '测试中…';

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
  String delayTargetOnly(String url) {
    return '测速目标：$url';
  }

  @override
  String get delayUnavailable => '当前策略组无法测试';

  @override
  String get delayBatchFailed => '批次已失效，请重新测试';

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
  String get overrideRemote => '远程';

  @override
  String get overrideEnabled => '启用';

  @override
  String get overrideDisabled => '停用';

  @override
  String get overridePrepend => '前置合并';

  @override
  String get overrideReplace => '覆盖同类设置';

  @override
  String get overrideMoveUp => '上移';

  @override
  String get overrideMoveDown => '下移';

  @override
  String get overrideReadOnly => '远程插件正文只读';

  @override
  String get overrideEmpty => '尚未添加插件。';

  @override
  String get overrideNotice => '上方优先；运行内容改变时重新连接。';

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
  String get overrideSource => '插件 URL';

  @override
  String get overrideUpdate => '更新';

  @override
  String get overrideDelete => '删除';

  @override
  String get overrideDeleteTitle => '删除插件？';

  @override
  String get overrideDeleteMessage =>
      '将从保存列表移除此插件；若当前接管正在使用它，将重新连接并中断已有连接。未连接时不会启动接管。';

  @override
  String get localYamlInvalid => '正文不是有效的单份 YAML 对象，请先在文本编辑器中修正。';

  @override
  String get localYamlInvalidStructure => '目标定义的结构或字段类型不正确，未修改正文。';

  @override
  String get localYamlDuplicateName => '本地自定义中已存在同名定义。';

  @override
  String get localYamlAliasTarget => '目标使用了共享 YAML 锚点或别名，请在文本编辑器中修改。';

  @override
  String get localYamlInheritedTarget => '目标来自 YAML 合并继承，请在文本编辑器中修改。';

  @override
  String get localYamlUnsafeStructure => '正文结构过深或别名展开过多，无法安全修改。';

  @override
  String get localYamlUnsupportedEdit => '无法在保留其他正文的情况下修改此定义，请使用文本编辑器。';

  @override
  String get localYamlUnsupportedField =>
      '此字段的原文形状无法由当前表单表达，将保留原值；请在文本编辑器中修改此字段。';

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
    return '$count 个插件参与';
  }

  @override
  String get provenanceHeading => '参与插件';

  @override
  String get provenanceProviderHeading => '定义参与插件';

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
  String get strategyGroupSourceConfiguration => '主配置';

  @override
  String get strategyGroupSourceCore => '内核生成';

  @override
  String get strategyGroupSourceUnknown => '来源未确认';

  @override
  String get strategyGroupPluginContribution => '由插件贡献';

  @override
  String get strategyGroupSourceReadOnly => '下列属性来自策略组的实际运行数据，当前页面为只读视图。';

  @override
  String get strategyGroupAttributesHeading => '实际属性';

  @override
  String get strategyGroupNoMembers => '没有成员';

  @override
  String get strategyGroupInlineIcon => '配置图标';

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
  String get providerFormPathHint => '相对于受管资源目录；不接受绝对路径或上级路径。';

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
  String get ruleFormUnrepresentable => '此字段无法按规则格式原样表达';

  @override
  String get ruleFormTargetHint => '目标名称不能含逗号或首尾空格。';

  @override
  String get ruleFormSrcHint => 'src 已包含 no-resolve 的效果。';

  @override
  String get ruleFormIdentityNotice =>
      '当前 Android 接入未提供连接所属进程或 UID，这些规则可能无法匹配。';

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
  String get proxyCategoryBuiltin => '内置处理项';

  @override
  String get proxyBuiltinDescription => '内核处理项，并非代理协议。';

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
  String get proxyInvalidDecimal => '请输入有效数值。';

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
  String get proxyUnitPackets => '包';

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
  String get localCustomDisabled => '此插件已停用，保存不会启用它。';

  @override
  String get moreLabel => '更多操作';

  @override
  String get continueLabel => '继续';

  @override
  String get operationFailed => '操作未完成';

  @override
  String get applicationListFailed => '无法读取已安装应用列表。';

  @override
  String get applicationAllowEmpty => '仅选中模式下至少需要选择一个应用。';

  @override
  String get applicationReconnectTitle => '保存并重新连接？';

  @override
  String get applicationReconnectMessage =>
      '保存后会正常停止当前接管，并按当前配置与模式重新连接；已有连接会中断。若重新连接失败，设置仍会保留。';

  @override
  String get applicationReconnect => '保存并重新连接';

  @override
  String get applicationSavedReconnected => '应用访问设置已保存，接管已重新连接。';

  @override
  String get applicationSaved => '应用访问设置已保存，下次连接时生效。';

  @override
  String get applicationAccessNotice =>
      '选中范围内的应用由VPN接管，其余应用沿系统网络连接。保存后重新连接，使新设置生效。';

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
  String get alwaysOnUnknown => '请在系统设置确认当前状态。';

  @override
  String get alwaysOnEnabled => '系统状态：已开启';

  @override
  String get alwaysOnDisabled => '系统状态：未开启';

  @override
  String get lockdownEnabled => '阻止不通过 VPN 的连接：已开启';

  @override
  String get lockdownDisabled => '阻止不通过 VPN 的连接：未开启';

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
  String get autoUpdateOff => '关闭';

  @override
  String autoUpdateEvery(int hours) {
    return '每 $hours 小时';
  }

  @override
  String get autoUpdateInterval => '检查周期';

  @override
  String get autoUpdateNotice => '系统调度可能延后或使用移动数据；下载失败保留原内容。';

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
  String get applicationPolicyNextConnection => '已保存策略将在下次连接时使用。';

  @override
  String get applicationPolicyApplied => '已保存策略正在使用。';

  @override
  String get applicationPolicyPending => '已保存策略尚未应用；再次保存可重连重试。';

  @override
  String get applicationPolicyUnknown => '运行策略未确认；再次保存可重连核实。';

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
  String get statusIssue => '状态异常 · 查看详情';

  @override
  String get statusPending => '状态确认前，暂不可启停';

  @override
  String get statusAutoRetry => '暂时无法获取状态，正在自动尝试';

  @override
  String get statusPlatformUnconfirmed => '平台尚未确认资源状态，暂不可启停';

  @override
  String get statusWaiting => '正在等待接管结果';

  @override
  String get statusConfigFailed => '配置读取失败，仍可查看管理页面';

  @override
  String get statusConfigLoading => '正在读取已保存配置';

  @override
  String get statusImportPrompt => '导入完整配置后，即可启动';

  @override
  String get statusReimport => '当前配置需要重新导入更新';

  @override
  String get statusReady => '准备好，即可开始';

  @override
  String get identityUnconfirmed => '配置身份未确认';

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
  String get modeSavedUnconfirmed => '保存模式未确认';

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
  String get waitingTakeover => '等待实际接管';

  @override
  String get waitingStatusSync => '等待状态同步';

  @override
  String get updateFailed => '更新失败';

  @override
  String get waitingUpdate => '等待更新';

  @override
  String get waitingSample => '等待采样';

  @override
  String get trafficConnections => '连接';

  @override
  String get download => '下载';

  @override
  String get upload => '上传';

  @override
  String activitySummary(String label, String value, String unit) {
    return '$label $value $unit，最近连接';
  }

  @override
  String get modeTitle => '运行模式';

  @override
  String get modeReadFailed => '模式读取失败';

  @override
  String get modeDiffers => '实际模式与保存回退';

  @override
  String modeSaved(String mode) {
    return '已保存回退：$mode；仅在配置未指定 mode 时使用。';
  }

  @override
  String modeActualDiffers(String mode) {
    return '实际运行：$mode；配置指定的模式可以与已保存的回退模式不同。';
  }

  @override
  String get modeHint => '运行中选择会立即切换实际模式；未运行时仅保存回退模式。配置未指定 mode 时才使用保存回退。';

  @override
  String get modeFollowConfigIdle => '随配置 · 未运行';

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
  String get recordLimitReached => '记录达上限';

  @override
  String get connectionUpdating => '正在更新';

  @override
  String get connectionRefreshFailed => '刷新失败';

  @override
  String get connectionRefreshRetrying => '刷新失败，正在重试';

  @override
  String get takeoverStopped => '接管已停止';

  @override
  String get statusUnconfirmed => '状态未确认';

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
  String get connectionPending => '待确认';

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
  String get fieldsTruncated => '部分长字段已截短';

  @override
  String get connectionStatus => '连接状态';

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
  String get connectionReplaced => '会话已切换';

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
  String get hideHiddenGroups => '隐藏隐藏策略组';

  @override
  String get strategyGroups => '策略组';

  @override
  String get actualConfigUnconfirmed => '实际配置未确认';

  @override
  String get noConfigSelected => '尚未选择配置';

  @override
  String get confirmingConfig => '正在确认配置';

  @override
  String get strategiesNotUpdated => '策略未更新';

  @override
  String get loadingStrategies => '正在加载策略…';

  @override
  String get selectionsNotRestored => '原选择未恢复';

  @override
  String get underTakeover => '接管中';

  @override
  String get notUnderTakeover => '未接管 · 预选';

  @override
  String get viewUnrestored => '查看未恢复的选择';

  @override
  String get viewStrategyError => '查看策略错误';

  @override
  String get strategyStatus => '策略状态';

  @override
  String get waitingTakeoverConfig => '正在等待接管与配置状态确认。';

  @override
  String get importConfigForStrategies => '导入并选择完整配置后即可查看策略。';

  @override
  String get preparingStrategies => '正在准备策略…';

  @override
  String get strategiesNotLoaded => '策略尚未加载。';

  @override
  String get strategiesLoadFailed => '策略未加载，请查看错误后重试。';

  @override
  String get loadStrategies => '加载策略';

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
  String get notUpdated => '未更新';

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
  String get popupSavedDiffersShort => '保存与实际不一致 · 查看详情';

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
  String get strategyReadStale => '策略状态暂未更新，前台将自动重试；旧记录不能用于切换。';

  @override
  String get strategyContextChanged => '策略上下文已变化，请等待当前配置重新读取。';

  @override
  String get strategyGroupChanged => '策略组或成员已变化，本次选择未保存。';

  @override
  String get applyingStrategy => '正在应用策略选择';

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
  String get configReading => '配置 · 读取中';

  @override
  String get configStale => '配置 · 未更新';

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
  String get nativeReasonInvalidAddress => '派生的 VPN 接口地址或其所需的下一个地址无效。';

  @override
  String get nativeReasonSystemDnsUnavailable =>
      '无法取得底层非 VPN 网络的 DNS 服务器，不会改用公共 DNS。';

  @override
  String get nativeReasonPrivateDnsUnavailable =>
      '严格模式 Android 私人 DNS 没有已验证的等价安全通道，不能降级为明文 DNS。';

  @override
  String get nativeReasonProviderPath =>
      'provider 路径未通过目录范围、符号链接、受保护文件或目标身份校验。';

  @override
  String get nativeReasonAndroidUserUnavailable =>
      '应用只能枚举和管理当前 Android 用户的应用，不支持其他用户及其 UID 的过滤条件。';

  @override
  String get storageContextChanged => '数据已恢复或替换，请重新打开此页面。未提交的输入仍可复制保留。';

  @override
  String get storageSyncUnconfirmed => '内容已保存，但未能确认存储同步完成；突然断电可能丢失本次修改。';

  @override
  String storageSyncWarning(String result) {
    return '$result\n\n内容已保存，但未能确认存储同步完成；突然断电可能丢失本次修改。';
  }

  @override
  String get storageUnavailable => '配置、插件和设置暂时不可用，数据恢复确认后才能继续。停止连接不受影响。';

  @override
  String get trustedRootsUnavailable => '无法读取或解析默认受信根证书，请重试。';

  @override
  String get nameInvalid => '请输入非空且不超过 80 个 UTF-8 字节的配置名称。';

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
    return '自动更新：$hours 小时';
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
  String get deleteNoSelection => '删除后没有当前配置。';

  @override
  String deleteSelects(String name) {
    return '删除后选择“$name”，不会自动启动。';
  }

  @override
  String get deleteRemoteBody => '将删除保存的正文与来源。';

  @override
  String get deleteLocalBody => '将删除保存的本地正文。';

  @override
  String get renameConfig => '重命名配置';

  @override
  String get changeConfigSource => '修改配置来源';

  @override
  String get configName => '配置名称';

  @override
  String get configUrl => '完整配置 URL';

  @override
  String get configUrlInvalid => '完整配置 URL，输入无效';

  @override
  String get configUrlHint => '请输入完整的 HTTP 或 HTTPS 配置 URL。';

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
  String get overwriteConfigTitle => '覆盖更新配置？';

  @override
  String get overwriteConfigMessage => '此来源已保存，将更新既有条目。';

  @override
  String get overwriteKeepsOnFailure => '下载失败将保留原正文与连接。';

  @override
  String get overwriteStopTunnel => '更新成功后，若运行内容改变，将重新连接此配置的接管。';

  @override
  String get overwriteNoOtherTunnel => '不会切换或停止其他配置的接管。';

  @override
  String get overwriteNotStart => '更新后不会自动启动接管。';

  @override
  String get overwriteUnconfirmed => '连接状态尚未确认；更新将按实际运行状态处理。';

  @override
  String get overwrite => '覆盖更新';

  @override
  String get leaveBodyTitle => '离开正文？';

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
  String get normalizeNewlinesTitle => '统一混合换行？';

  @override
  String get normalizeNewlinesMessage => '此正文包含多种换行。保存修改将统一为主要换行风格，BOM 保持不变。';

  @override
  String get normalizeAndSave => '统一并保存';

  @override
  String get submittedSavedTitle => '提交版本已保存';

  @override
  String get submittedSavedMessage => '提交的正文已保存，此后产生的修改仍保留在编辑器中，尚未保存。';

  @override
  String get saveUnconfirmed => '保存结果尚未确认，已重新读取配置。请返回列表核实；当前输入保留，未自动重试。';

  @override
  String get savedApplyFailed => '已保存，应用未完成';

  @override
  String get saveFailed => '保存未完成';

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
  String get sizePending => '大小待确认 · 保存时重检';

  @override
  String get unsavedChanges => '未保存修改';

  @override
  String get configBody => '配置正文';

  @override
  String get find => '查找';

  @override
  String get softWrap => '软换行';

  @override
  String get saveAndApply => '保存并应用';

  @override
  String get bodyUnreadable => '该配置没有可用正文，请先更新来源。';

  @override
  String get bodyPrepFailed => '无法准备配置正文，请返回后重试。';

  @override
  String editorLineTooLong(int line, int limit) {
    return '第 $line 行超过 $limit 个 UTF-16 代码单元，无法编辑或软换行预览；原文未改动。';
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
  String get editorContextChanged => '暂时无法编辑，请先完成当前操作或重新打开正文。';

  @override
  String get aboutTitle => '关于 Clash Pseudo';

  @override
  String get licensesAndNotices => '许可与第三方通知';

  @override
  String get goNativeDependencies => 'Go 原生运行依赖';

  @override
  String get androidDependencies => 'Android 运行依赖';

  @override
  String get materialIconsFont => 'Material Icons 字体';

  @override
  String get legalBody =>
      '自有代码采用 GPL-3.0-only。您可以依照 GNU 通用公共许可证第 3 版复制、修改和分发。在适用法律允许范围内不提供担保。第三方部分保留各自版权与许可。\n\n许可全文与随包第三方通知可在下方查看。对应源码与构建材料须随实际分发版本提供；当前为未公开发布的开发版本。';

  @override
  String get projectTitle => '项目';

  @override
  String get defaultLocalConfig =>
      '# 默认直连配置；运行模式和策略选择仍以客户端为准。\nrules:\n  - MATCH,DIRECT\n';

  @override
  String get noUsableBodyReimport => '该配置没有可用正文，请重新导入更新。';

  @override
  String get noBodyUpdateSource => '该配置没有可用正文，请先更新来源。';

  @override
  String get requestNotAccepted => '请求未被受理，请重试。';

  @override
  String get temporaryModeUnknown => '暂时无法确认运行模式，前台将自动重试。';

  @override
  String get temporaryStatusUnavailable => '暂时无法获取接管状态，前台将自动重试，不会自动启动。';

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
  String get stageStoppingOld => '正在停止旧接管';

  @override
  String get configUpdatedRestarted => '配置已更新并重新启动。';

  @override
  String get configSavedParsedAtStart => '配置已保存，启动时由内核解析。';

  @override
  String get configChangedReopen => '配置已删除、正文已变化或不可编辑，请重新打开；当前输入未覆盖保存。';

  @override
  String get stageSavingConfig => '正在保存配置';

  @override
  String get configSavedApplied => '配置已保存并应用。';

  @override
  String get configSavedApplyReleasePending =>
      '配置已保存，但应用或旧预览释放未完成。请核实接管状态；新正文已保留。';

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
  String get configNameInvalid => '请输入非空且不超过 80 个 UTF-8 字节的配置名称。';

  @override
  String get switchedConfig => '已切换接管配置。';

  @override
  String get configSelectedNotStarted => '已选择配置，尚未启动接管。';

  @override
  String get stopBeforeDelete => '请先停止接管，再删除当前使用的配置。';

  @override
  String get configDeleted => '配置已删除，未启动接管。';

  @override
  String get modeSavedNextStart => '回退模式已保存；启动时仅在配置未指定 mode 时使用。';

  @override
  String get modeConfirmed => '运行模式已确认。';

  @override
  String get stageSwitchingMode => '正在切换运行模式';

  @override
  String get modeNotConfirmed =>
      '回退模式已保存，但本次运行模式切换未确认；启动时仅在配置未指定 mode 时使用回退模式。';

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
  String get stageReconnectAccess => '正在重新连接以应用访问设置';

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
  String get tunnelStartFailed => '接管未能启动。';

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
  String get overrideSourceExists => '该来源已有插件，请更新已有项。';

  @override
  String get overrideUpdateIncomplete => '更新未完成，请重试。';

  @override
  String get overrideChangedNotApplied => '插件已变化，下载结果未应用。';

  @override
  String get overrideUpdatedApplyLater => '插件已更新。';

  @override
  String get overrideNameInvalid => '请输入非空且不超过 80 个 UTF-8 字节的插件名称。';

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
  String get preparationMetadataInvalid => '配置身份或来源信息包含无效的 Unicode 编码，未应用本次修改。';

  @override
  String get textNotUtf8 => '配置正文不是有效的 UTF-8 文本。';

  @override
  String get textTooLargeImport => '配置正文超过 16 MiB，未导入。';

  @override
  String get sessionChangedNoDisconnect => '会话已变化，未执行断开。';

  @override
  String get disconnectFailedShort => '断开失败';

  @override
  String get disconnectUnconfirmedShort => '断开结果未确认';

  @override
  String get pathUnavailable => '路径未提供';

  @override
  String get strategyStatusStale => '策略状态暂未更新，前台将自动重试；旧记录不能用于切换。';

  @override
  String get coreContextUnconfirmed => '内核上下文尚未确认。';

  @override
  String get strategyContextChangedRetry => '策略上下文已变化，请等待当前配置重新读取。';

  @override
  String get applyingStrategySelection => '正在应用策略选择';

  @override
  String get trafficUpdateFailed => '更新失败';

  @override
  String applicationSharedUidNotice(String packages) {
    return '这些应用共享 Android UID，选择或排除其中一个会同时作用于：$packages';
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
  String get androidErrorLogicExpired => '逻辑引擎已结束。';

  @override
  String get androidErrorOperationEnded => '操作已结束。';

  @override
  String get androidErrorScheduleSave => '无法保存自动更新计划。';

  @override
  String get androidErrorBusy => '已有操作正在处理，请等待确认。';

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
  String get androidErrorOperationIncomplete => '业务操作未完成，请核实状态后重试。';

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
  String get androidErrorReleaseUnconfirmed => '资源释放未确认，不能报告已停止或重新启动。';

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
  String get androidErrorStrategyContext => '策略上下文已变化，本次结果未确认。';

  @override
  String get androidErrorStrategyTimeout => '策略操作等待超时，请等待实际状态重新读取。';

  @override
  String get androidErrorStrategyUnconfirmed => '策略操作未确认，请核实当前配置、成员与内核状态。';

  @override
  String get androidErrorNativeStrategyUnavailable => '原生策略接口不可用。';

  @override
  String get androidErrorCoreContextRefresh => '内核上下文已变化，请刷新后重试。';

  @override
  String get androidErrorCoreContextReread => '内核上下文已变化，请重新读取。';

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
  String get androidErrorCoreBusy => '内核忙碌或上下文已变化，请刷新后重试。';

  @override
  String get androidErrorCoreReadTimeout => '内核读取超时，请重试。';

  @override
  String get androidErrorCoreReadFailed => '无法读取内核数据，请刷新后重试。';

  @override
  String get androidErrorNativeReadUnavailable => '原生读取接口不可用。';

  @override
  String get androidErrorVpnInputMissing => 'VPN 授权已失效或运行输入缺失。';

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
  String get processMemory => '内存';

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
  String get dnsResolverNotice => '当前内核解析器；可能命中缓存，不等同于客户端 DNS 响应。';

  @override
  String get dnsReady => '输入名称并查询';

  @override
  String get dnsPreparing => '正在准备内核';

  @override
  String get dnsRunning => '正在查询';

  @override
  String get dnsExpired => '结果已过期，请重新查询';

  @override
  String get dnsNoConfiguration => '请先选择配置';

  @override
  String get dnsUnavailable => '当前解析器不可用';

  @override
  String get dnsInvalidRequest => '名称或记录类型无效，或请求超出大小限制。';

  @override
  String get dnsBusy => '上次查询仍在结束，请稍候。';

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
  String get dnsQuestion => '问题';

  @override
  String get dnsAnswer => '回答';

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
  String get dnsPersistentPoolEnabled => '持久池：已启用';

  @override
  String get dnsPersistentPoolDisabled => '持久池：未启用';

  @override
  String get providerFormFormatHint => 'format 控制外部内容编码；inline 使用规则条目。';

  @override
  String get strategyGroupHashKeyInvalid => 'round-robin 不接受非空 hash-key';

  @override
  String get allStrategyGroups => '全部策略组';

  @override
  String get hiddenGroupAttribute => '隐藏';

  @override
  String get globalGroupAttribute => '全局组';

  @override
  String get noStrategyGroups => '没有策略组';

  @override
  String get trafficSessionScope => '本次 VPN 连接的内核统计，并非设备总量或计费流量。';

  @override
  String get backupTitle => '备份与恢复';

  @override
  String get backupExport => '导出设置';

  @override
  String get backupImport => '导入设置';

  @override
  String get backupRestore => '恢复备份';

  @override
  String get backupSensitiveNotice => '备份未加密，含来源与凭据，请妥善保管。';

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
  String backupCreatedAt(String value) {
    return '创建时间：$value';
  }

  @override
  String get backupNotSelected => '请先选择备份文件。';

  @override
  String get backupConfirmTitle => '覆盖应用数据？';

  @override
  String get backupConfirmMessage => '备份将覆盖而非合并现有数据，空集合也会清空现有内容。';

  @override
  String get backupConfirmRunning => '先停止当前连接并释放资源；恢复后尝试按恢复的所选配置连接，新的断开意图优先。';

  @override
  String get backupConfirmStopped => '恢复后不会主动建立连接。';

  @override
  String get backupConfirmUnconfirmed => '连接状态尚未确认，恢复只会在可安全覆盖数据时执行。';

  @override
  String get backupPreparing => '正在准备备份';

  @override
  String get backupExportSaved => '备份文件已保存。';

  @override
  String get backupCancelled => '操作已取消。';

  @override
  String get backupInvalid => '备份文件无效或格式不受支持。';

  @override
  String get backupTooLarge => '备份超过允许的大小限制。';

  @override
  String get backupCandidateExpired => '备份准备结果已失效，请重新准备。';

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
  String get backupSettingsRefreshFailed => '界面设置未能重新读取。';

  @override
  String get localCustomNotice =>
      '新增与删除仅修改本地自定义插件。删除本地覆盖后，较低优先级的同名定义可能重新生效；不会自动修复引用。';

  @override
  String get providerRuntimePropertiesOnly =>
      '此处展示已加载提供者的运行属性；内核未提供完整原始选项、请求头与凭据。';

  @override
  String get strategyGroupRuntimePropertiesOnly =>
      '此处展示策略组的运行属性与展开成员，并非完整原始定义。';

  @override
  String get localSavedOriginal => '已保存原文';

  @override
  String get localOriginalContributes => '参与当前加载';

  @override
  String get localOriginalUnconfirmed => '未确认已加载';

  @override
  String get localOriginalDisabled => '插件已停用';

  @override
  String get localCustomDefinitionsEmpty => '此处没有直接定义的本地自定义条目。';

  @override
  String get localCustomDeleteConfirm =>
      '仅从本地自定义插件删除此项。下层同名定义可能恢复，已有引用不会自动修改。是否继续？';

  @override
  String get connectionRuleScope => '匹配范围';

  @override
  String get connectionRuleUnavailable => '当前连接信息不可用于新增规则。';

  @override
  String get connectionRuleTargetsFailed => '无法读取当前策略组，请重试。';

  @override
  String get backupFailed => '备份操作未完成。';

  @override
  String get backupDocumentWriteUnconfirmed => '备份文件未确认保存完成；所选位置可能留有不完整文件。';

  @override
  String localCustomSavedVerificationFailed(String result, String reason) {
    return '$result\n\n无法核对当前本地自定义条目：$reason\n请重新打开后继续。未再次提交草稿。';
  }

  @override
  String backupRestoredWithIssue(String issue) {
    return '数据已恢复。$issue';
  }
}
