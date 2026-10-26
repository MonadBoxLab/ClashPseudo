import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../l10n/app_localizations.dart';
import 'dns_controller.dart';
import 'dns_snapshot.dart';

Future<void> showDnsTool(
  BuildContext context, {
  required AppController app,
  DnsController? controller,
}) => showDialog<void>(
  context: context,
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (_) => DnsTool(app: app, controller: controller),
);

String _failure(AppLocalizations strings, String code) => switch (code) {
  'invalidRequest' => strings.dnsInvalidRequest,
  'busy' => strings.dnsBusy,
  'unavailable' => strings.dnsUnavailable,
  'timeout' => strings.dnsTimeout,
  'cancelled' => strings.dnsCancelled,
  'obsolete' => strings.dnsExpired,
  'resultTooLarge' => strings.dnsResultTooLarge,
  'invalidResponse' => strings.dnsInvalidResponse,
  _ => strings.dnsQueryFailed,
};

String _cacheStatus(AppLocalizations strings, DnsCacheResult cache) =>
    switch (cache.status) {
      DnsCacheStatus.completed =>
        cache.persistent != null
            ? strings.dnsFakeIpCompleted
            : strings.dnsCacheCompleted,
      DnsCacheStatus.empty =>
        cache.persistent != null
            ? strings.dnsFakeIpEmpty
            : strings.dnsCacheEmpty,
      DnsCacheStatus.partialOrFailed => strings.dnsCachePartialOrFailed,
    };

String _cacheDetails(AppLocalizations strings, DnsCacheResult cache) {
  String outcome(DnsCachePool pool) => switch (pool.outcome) {
    DnsCacheOutcome.cleared => strings.dnsPoolCleared,
    DnsCacheOutcome.inactive => strings.dnsPoolInactive,
    DnsCacheOutcome.unconfirmed => strings.dnsPoolUnconfirmed,
  };
  return [
    _cacheStatus(strings, cache),
    if (cache.ipv4 case final pool?) 'IPv4 · ${outcome(pool)}',
    if (cache.ipv6 case final pool?) 'IPv6 · ${outcome(pool)}',
    if (cache.persistent case final enabled?)
      enabled
          ? strings.dnsPersistentPoolEnabled
          : strings.dnsPersistentPoolDisabled,
  ].join('\n');
}

class DnsTool extends StatefulWidget {
  const DnsTool({super.key, required this.app, this.controller});

  final AppController app;
  final DnsController? controller;

  @override
  State<DnsTool> createState() => _DnsToolState();
}

class _DnsToolState extends State<DnsTool> {
  late final _controller = widget.controller ?? DnsController(widget.app);
  late final _name = TextEditingController(text: _controller.name);
  final _scroll = ScrollController();
  final _localOverlays = <ModalRoute<dynamic>>{};
  DnsCacheResult? _cacheResult;
  bool _results = false;
  bool _confirming = false;
  bool? _routeVisible;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncVisibility();
  }

  void _syncVisibility() {
    final visible =
        _localOverlays.any((route) => route.isCurrent) ||
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (_routeVisible == visible) return;
    _routeVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.setVisible(_routeVisible!);
    });
  }

  Future<T?> _showLocalDialog<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(
      context: context,
      builder: (dialogContext) {
        ModalRoute.of(dialogContext);
        _syncVisibility();
        return builder(dialogContext);
      },
    );
    _localOverlays.add(route);
    try {
      return await Navigator.of(context, rootNavigator: true).push(route);
    } finally {
      _localOverlays.remove(route);
      if (mounted) _syncVisibility();
    }
  }

  Future<bool> _canPresent(int version) async {
    if (!await widget.app.waitUntilInteractive()) return false;
    return mounted &&
        _controller.active &&
        version == _controller.contextVersion;
  }

  Future<void> _details(String message) async {
    if (!await _canPresent(_controller.contextVersion)) return;
    await _showLocalDialog<void>(
      (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).details),
        scrollable: true,
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).close),
          ),
        ],
      ),
    );
  }

  Future<void> _clear(bool fakeIp) async {
    if (!_controller.canQuery || _confirming) return;
    final version = _controller.contextVersion;
    if (fakeIp) {
      setState(() => _confirming = true);
      final confirmed = await _showLocalDialog<bool>((context) {
        final strings = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(strings.dnsClearFakeIp),
          scrollable: true,
          content: Text(strings.dnsFakeIpWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.dnsClearFakeIp),
            ),
          ],
        );
      });
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true ||
          version != _controller.contextVersion ||
          !_controller.canQuery) {
        return;
      }
    }
    try {
      final result = await _controller.clearCache(fakeIp: fakeIp);
      if (!mounted ||
          !_controller.active ||
          version != _controller.contextVersion ||
          result == null) {
        return;
      }
      setState(() => _cacheResult = result);
      if (result.status == DnsCacheStatus.partialOrFailed) {
        await _details(_cacheDetails(AppLocalizations.of(context), result));
      }
    } catch (error) {
      if (!mounted ||
          !_controller.active ||
          version != _controller.contextVersion) {
        return;
      }
      final strings = AppLocalizations.of(context);
      await _details(
        error is DnsFailure
            ? _failure(strings, error.code)
            : strings.dnsCacheFailed,
      );
    }
  }

  Future<void> _query() async {
    setState(() => _cacheResult = null);
    final pending = _controller.query();
    final version = _controller.contextVersion;
    await pending;
    if (!await _canPresent(version) || !mounted) return;
    final code = _controller.errorCode;
    if (code == null && _controller.response != null && !_controller.stale) {
      final draft = _name.value;
      FocusScope.of(context).unfocus();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      setState(() => _results = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _results && _name.text == draft.text) {
          _name.value = draft;
        }
      });
    } else if (code != null &&
        !const ['invalidRequest', 'obsolete', 'cancelled'].contains(code)) {
      await _details(_failure(AppLocalizations.of(context), code));
    }
  }

  void _close() {
    _controller.setVisible(false);
    Navigator.of(context).pop();
  }

  void _edit() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _results = false);
  }

  String _status(AppLocalizations strings) {
    final cache = _cacheResult;
    if (cache != null &&
        cache.source.matchesIdentity(widget.app.state.core) &&
        cache.networkEpoch == widget.app.state.networkEpoch &&
        _controller.active) {
      return _cacheStatus(strings, cache);
    }
    final code = _controller.errorCode;
    if (code == 'invalidRequest') return '';
    if (code != null) return _failure(strings, code);
    return switch (_controller.status) {
      DnsStatus.ready =>
        _controller.stale
            ? strings.dnsExpired
            : _controller.response == null
            ? strings.dnsReady
            : _controller.response!.source.purpose == 'VPN'
            ? strings.runtimeConfigLive
            : strings.runtimeConfigPreview,
      DnsStatus.preparing => strings.dnsPreparing,
      DnsStatus.unavailable => strings.dnsUnavailable,
      DnsStatus.empty => strings.dnsNoConfiguration,
      DnsStatus.querying => strings.dnsRunning,
      DnsStatus.stale => strings.dnsExpired,
      DnsStatus.failed => strings.dnsQueryFailed,
    };
  }

  Widget _actions(
    AppLocalizations strings,
    BoxConstraints bounds,
    bool enabled,
  ) => ChoiceMenuButton<bool>(
    key: const ValueKey('dns-actions'),
    identity: _controller.contextVersion,
    tooltip: MaterialLocalizations.of(context).showMenuTooltip,
    enabled: enabled,
    maxHeight: bounds.maxHeight * .5,
    options: {false: strings.dnsClearCache, true: strings.dnsClearFakeIp},
    onSelected: _clear,
    buttonBuilder: (context, onPressed, focusNode) => IconButton(
      focusNode: focusNode,
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      onPressed: onPressed,
      icon: SizedBox.square(
        dimension: 18,
        child: _controller.clearing
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const Icon(Icons.more_vert, size: 18),
      ),
    ),
  );

  Widget _form(AppLocalizations strings, BoxConstraints bounds) {
    final enabled = _controller.canQuery && !_confirming;
    final cache = _cacheResult;
    final cacheCurrent =
        cache != null &&
        cache.source.matchesIdentity(widget.app.state.core) &&
        cache.networkEpoch == widget.app.state.networkEpoch &&
        _controller.active;
    final failed =
        (_controller.errorCode != null &&
            !const [
              'invalidRequest',
              'obsolete',
              'cancelled',
            ].contains(_controller.errorCode)) ||
        cacheCurrent && cache.status == DnsCacheStatus.partialOrFailed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('dns-name'),
            controller: _name,
            onChanged: _controller.setName,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: strings.dnsName,
              suffixIcon: Visibility(
                visible: _controller.errorCode == 'invalidRequest',
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: IconButton(
                  tooltip: strings.dnsInvalidRequest,
                  onPressed: () => _details(strings.dnsInvalidRequest),
                  icon: Icon(
                    Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
            onSubmitted: (_) {
              if (enabled) _query();
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IntrinsicWidth(
                child: ChoiceMenuButton<String>(
                  key: const ValueKey('dns-type'),
                  identity: _controller.contextVersion,
                  maxHeight: bounds.maxHeight * .5,
                  tooltip: strings.dnsRecordType,
                  value: _controller.type,
                  enabled: !_controller.busy && !_confirming,
                  onSelected: _controller.setType,
                  options: {for (final type in dnsRecordTypes) type: type},
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: strings.dnsRecordType,
                    ),
                    child: SizedBox(
                      width: MediaQuery.textScalerOf(context).scale(16) * 5.5,
                      child: Row(
                        children: [
                          Expanded(child: Text(_controller.type)),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('dns-query'),
                onPressed: enabled ? _query : null,
                icon: SizedBox.square(
                  dimension: 18,
                  child: _controller.queryBusy
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : const Icon(Icons.search, size: 18),
                ),
                label: Text(strings.dnsQuery),
              ),
              IconButton(
                key: const ValueKey('dns-refresh'),
                tooltip: strings.refresh,
                onPressed: _controller.canRefresh && !_confirming
                    ? _controller.refresh
                    : null,
                color: HomePalette.of(context).syncAction,
                icon: const Icon(Icons.refresh),
              ),
              _actions(strings, bounds, enabled),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            strings.dnsResolverNotice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          ConstrainedBox(
            key: const ValueKey('dns-status'),
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      _status(strings),
                      softWrap: false,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: failed
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Visibility(
                  visible: cacheCurrent && cache.persistent != null,
                  maintainSize: true,
                  maintainState: true,
                  maintainAnimation: true,
                  child: IconButton(
                    key: const ValueKey('dns-cache-details'),
                    tooltip: strings.details,
                    onPressed: cacheCurrent
                        ? () => _details(_cacheDetails(strings, cache))
                        : null,
                    icon: const Icon(Icons.info_outline),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _records(AppLocalizations strings, DnsResponse result) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('${result.name} ${result.type}'),
          const SizedBox(height: 8),
          SelectableText(strings.dnsRcode(result.rcodeName, result.rcode)),
          Text(strings.dnsElapsed(result.elapsedMs)),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              _status(strings),
              softWrap: false,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (result.truncated) Text(strings.dnsTruncated),
        ],
      ),
    ),
    for (final section in [
      (strings.dnsAnswer, result.answer),
      (strings.dnsAuthority, result.authority),
      (strings.dnsAdditional, result.additional),
    ]) ...[
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
        child: Text(section.$1, style: Theme.of(context).textTheme.titleSmall),
      ),
      if (section.$2.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(strings.dnsNoRecords),
        ),
      for (final record in section.$2)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(record.name),
              SelectableText(
                strings.dnsRecordMeta(
                  record.type,
                  record.recordClass,
                  record.ttl,
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              SelectableText(record.data),
              const SizedBox(height: 8),
              const Divider(height: 1),
            ],
          ),
        ),
    ],
    const SizedBox(height: 16),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      _syncVisibility();
      final strings = AppLocalizations.of(context);
      final result = _controller.response;
      final rows = _results && result != null
          ? _records(strings, result)
          : <Widget>[];
      return PopScope(
        canPop: !_results,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _controller.setVisible(false);
          } else if (_results) {
            _edit();
          }
        },
        child: Dialog(
          clipBehavior: Clip.antiAlias,
          constraints: BoxConstraints(maxWidth: _results ? 840 : 560),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          child: LayoutBuilder(
            builder: (context, bounds) => ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _results
                    ? math.min(
                        bounds.maxHeight,
                        720 * MediaQuery.textScalerOf(context).scale(14) / 14,
                      )
                    : bounds.maxHeight,
              ),
              child: SizedBox(
                width: double.infinity,
                child: CustomScrollView(
                  key: const PageStorageKey('dns-tool-scroll'),
                  controller: _scroll,
                  shrinkWrap: true,
                  slivers: [
                    PinnedHeaderSliver(
                      child: Material(
                        color: HomePalette.of(context).surface,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                          child: Row(
                            children: [
                              if (_results)
                                BackButton(
                                  key: const ValueKey('dns-edit'),
                                  onPressed: _edit,
                                ),
                              Expanded(
                                child: Text(
                                  strings.dnsTools,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('dns-close'),
                                tooltip: strings.close,
                                onPressed: _close,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Offstage(
                        offstage: _results,
                        child: _form(strings, bounds),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, index) => rows[index],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    } else {
      _controller.setVisible(false);
    }
    _name.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
