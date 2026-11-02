import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// 隐私告知的完整中英文文本。
const _englishNotice = '''Clash Pseudo is free and open source. It does not collect or report user data and does not provide any proxy nodes or subscription services.

Data processing

The app does not include usage analytics, behavioral analysis, or automatic crash reporting. Configurations, plugins, and app settings are stored on the device. Proxying and rule matching process traffic, domains, and IP addresses on the device. Connection information and logs support display and diagnostics; the installed app list is used to choose which apps the VPN handles.

Network communication

Configuration and plugin downloads, DNS queries, proxy connections, latency tests, remote icons, and rule or geographic database updates contact their respective network services. Destinations come from configurations and application defaults. Turning off VPN traffic handling does not disable network access for these features.

Requests send the content and authentication information needed by the feature, and the receiving service sees the connection's source IP address. Downloads from HTTP sources have no transport encryption.

Permission purposes

- Internet access and network state: establish connections, download content, and check the network.
- Foreground services and notifications: run the VPN, local network proxy service, and background tasks and display their status.
- Installed app visibility: display the app list and choose which apps the VPN handles.
- VPN authorization: create a VPN interface after Android authorization and handle traffic within the selected scope.

Files and backups

Configuration and plugin contents, source addresses, and credentials saved in them are stored in the app's private directory without additional application-level encryption. Exported ZIP files are not encrypted and include configurations, plugins, app settings, and the source addresses and credentials saved in them. Backup import and export are available under Settings → Storage and data and use Android's file picker; you choose where exported files are saved.

Android system backup and device transfer can copy configurations, plugins, and app settings. Whether they are enabled depends on system settings and the backup service in use. A file provider's synchronization features can also keep cloud copies of selected files.

Connection records, core logs, and original content

Recent connection records and logs are held only in device memory, within bounded capacities and retention windows. They are not saved as history files. You can clear them on their respective pages; they disappear when the process ends.

Settings → Diagnostics → Core logs displays core operation, connection, and error messages. Retained logs show original core messages. When capacity is insufficient, whole entries are removed or skipped and omissions are reported; message content is not truncated or rewritten. The configuration editor and backups retain original content.

Deleting data and viewing this notice

You can delete configurations and plugins, clear recent records and logs, and individually select the cache database and rebuildable geographic data files for cleanup. The core must stop before cleanup. Only confirmed files are deleted; protocol identities, custom provider files, and other user files are retained.

You can also revoke VPN authorization or clear app data in Android settings. Clearing app data or uninstalling does not delete exported files, system backups, or other external copies.

This notice is updated as features change. The version included with your installation is available under Settings → About.

Project repository

https://github.com/MonadBoxLab/ClashPseudo

See GPLv3 for more information.''';

const _chineseNotice = '''Clash Pseudo 开源、免费，不进行用户数据采集或上报，不提供任何代理节点或订阅服务。

数据处理

应用不统计用户的使用情况，不分析用户行为，也不自动上报崩溃信息。配置、插件与应用设置保存在设备上。代理和规则匹配在设备上处理流量、域名及 IP；连接信息与日志用于显示和诊断，已安装应用列表用于设置哪些应用的流量由 VPN 接管。

网络通信

配置和插件下载、DNS 查询、代理连接、测速、远程图标及规则／地理数据更新会访问相应网络服务，目标由配置和程序默认值确定。关闭 VPN 接管不关闭这些功能的网络访问。

请求会向目标服务发送功能所需的内容和认证信息，服务也会看到连接来源的 IP。HTTP 来源的下载没有传输加密。

权限用途

- 网络访问与网络状态：建立连接、下载内容和检查网络。
- 前台服务与通知：运行 VPN、局域网代理服务和后台任务，显示运行状态。
- 已安装应用可见性：显示应用列表，设置哪些应用的流量由 VPN 接管。
- VPN 授权：经 Android 授权后建立 VPN 接口，接管选定范围的网络流量。

文件与备份

配置和插件正文、来源地址及其中保存的凭据存放在应用私有目录，应用未另行加密。导出的 ZIP 未加密，包含配置、插件、应用设置及其中保存的来源地址和凭据。备份的导入、导出位于“设置 → 存储与数据”，通过 Android 文件选择器完成；保存位置由您选择。

Android 系统备份和设备迁移可复制配置、插件与应用设置，是否启用由系统设置与所用备份服务决定。文件提供方的同步功能也可保存所选文件的云端副本。

连接记录、内核日志与原始正文

近期连接记录与日志只暂存在设备内存中，受容量和保留时间限制，不保存为历史文件；可在相应页面清除，进程结束后消失。

可在“设置 → 诊断工具 → 内核日志”查看内核运行、连接和错误信息。保留的日志按内核原文显示；容量不足时移除或略过整条记录，并显示遗漏情况，不截断或改写正文。配置编辑器和备份保留原始正文。

删除与查看

您可在应用内删除配置与插件、清除近期记录和日志，并逐项清理缓存数据库及可重建的地理数据文件。清理前需停止内核；只删除已确认的文件，协议身份、provider自定义文件和其他用户文件继续保留。

您也可在系统设置中撤销 VPN 授权或清除应用数据。清除应用数据或卸载不会删除已导出的文件、系统备份或其他外部副本。

完整说明随功能变化更新，可在“设置 → 关于”查看当前安装版本的内容。

项目仓库

https://github.com/MonadBoxLab/ClashPseudo

更多请参见 GPLv3 协议。''';

void main() {
  test('英文隐私告知全文与预期文本完全一致', () {
    final strings = lookupAppLocalizations(const Locale('en'));
    expect(strings.privacyNoticeBody, _englishNotice);
  });

  test('中文隐私告知全文与预期文本完全一致', () {
    final strings = lookupAppLocalizations(const Locale('zh'));
    expect(strings.privacyNoticeBody, _chineseNotice);
  });

  test('本页略过的日志数量使用带整数参数的中英文文案', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final zh = lookupAppLocalizations(const Locale('zh'));
    for (final count in [0, 1, 1001]) {
      expect(en.logLocalDropped(count), 'Omitted $count log entries');
      expect(zh.logLocalDropped(count), '已略过 $count 条日志');
    }
  });

  test('DNS 操作与详情标题使用不同的中英文文案', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final zh = lookupAppLocalizations(const Locale('zh'));
    for (final (actualEn, actualZh, expectedEn, expectedZh) in [
      (en.dnsQuery, zh.dnsQuery, 'Query', '查询'),
      (
        en.dnsRefreshCoreStatus,
        zh.dnsRefreshCoreStatus,
        'Refresh core status',
        '刷新内核状态',
      ),
      (
        en.dnsViewQueryResults,
        zh.dnsViewQueryResults,
        'View query results',
        '查看查询结果',
      ),
      (en.dnsQueryResults, zh.dnsQueryResults, 'Query results', '查询结果'),
      (en.dnsPreviousQuery, zh.dnsPreviousQuery, 'Previous query', '上次查询'),
      (
        en.dnsViewPreviousQuery,
        zh.dnsViewPreviousQuery,
        'View previous query',
        '查看上次查询',
      ),
      (
        en.dnsQueryRawData,
        zh.dnsQueryRawData,
        'DNS query raw data',
        'DNS 查询原始数据',
      ),
      (
        en.dnsCacheOperationDetails,
        zh.dnsCacheOperationDetails,
        'Cache operation details',
        '缓存操作详情',
      ),
      (
        en.dnsCacheRawData,
        zh.dnsCacheRawData,
        'Cache operation raw data',
        '缓存操作原始数据',
      ),
      (en.errorDetails, zh.errorDetails, 'Error details', '错误详情'),
      (en.viewError, zh.viewError, 'View error', '查看错误'),
      (en.technicalDetails, zh.technicalDetails, 'Technical details', '技术详情'),
      (
        en.copyTechnicalDetails,
        zh.copyTechnicalDetails,
        'Copy technical details',
        '复制技术详情',
      ),
      (en.saveFailed, zh.saveFailed, 'Save failed', '保存失败'),
    ]) {
      expect(actualEn, expectedEn);
      expect(actualZh, expectedZh);
    }
    expect(en.saveUnconfirmed, isNot(en.saveFailed));
    expect(zh.saveUnconfirmed, isNot(zh.saveFailed));
  });

  test('DNS 响应显示发起查询时的名称、类型和来源', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final zh = lookupAppLocalizations(const Locale('zh'));
    const name = '例子.example.';
    const type = 'TYPE65400';
    expect(en.dnsQueryIdentity(name, type), 'Query: $name · $type');
    expect(zh.dnsQueryIdentity(name, type), '查询：$name · $type');
    for (final (strings, prefix) in [(en, 'Source: '), (zh, '来源：')]) {
      for (final source in [
        strings.runtimeConfigLive,
        strings.runtimeConfigPreview,
      ]) {
        expect(strings.dnsResponseSource(source), '$prefix$source');
      }
    }
  });
}
