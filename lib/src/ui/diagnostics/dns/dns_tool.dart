import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../components/input/choice_menu_button.dart';
import '../../components/feedback/operation_notice.dart';
import '../../../l10n/app_localizations.dart';
import 'dns_controller.dart';
import '../../../model/dns_snapshot.dart';

Future<void> showDnsTool(
  BuildContext context, {
  required AppController app,
  DnsController? controller,
}) => showDialog<void>(
  context: context,
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (dialogContext) => OperationNoticeHost(
    onDismiss: () => Navigator.of(dialogContext).maybePop(),
    child: DnsTool(app: app, controller: controller),
  ),
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
  'queryFailed' => strings.dnsQueryFailed,
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
    for (final field in [
      ('resolverActive', cache.resolverActive),
      ('systemResolverActive', cache.systemResolverActive),
    ])
      if (field.$2 case final active?)
        '${field.$1} · ${!active
            ? strings.dnsPoolInactive
            : cache.status == DnsCacheStatus.completed
            ? strings.dnsPoolCleared
            : strings.dnsPoolUnconfirmed}',
    if (cache.ipv4 case final pool?) 'IPv4 · ${outcome(pool)}',
    if (cache.ipv6 case final pool?) 'IPv6 · ${outcome(pool)}',
    if (cache.persistent case final enabled?)
      enabled
          ? strings.dnsPersistentPoolEnabled
          : strings.dnsPersistentPoolDisabled,
  ].join('\n');
}

class _DnsLayoutExtents {
  double header = 0;
}

class _DnsPhaseExtent extends SingleChildRenderObjectWidget {
  const _DnsPhaseExtent.header({required this.extents, required Widget sliver})
    : factor = null,
      super(child: sliver);

  const _DnsPhaseExtent.results({
    required this.extents,
    required this.factor,
    required Widget sliver,
  }) : super(child: sliver);

  final _DnsLayoutExtents extents;
  final double? factor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDnsPhaseExtent(extents, factor);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderDnsPhaseExtent renderObject,
  ) => renderObject
    ..extents = extents
    ..factor = factor;
}

class _RenderDnsPhaseExtent extends RenderProxySliver {
  _RenderDnsPhaseExtent(this._extents, this._factor);

  _DnsLayoutExtents _extents;
  double? _factor;

  set extents(_DnsLayoutExtents value) {
    if (identical(_extents, value)) return;
    _extents = value;
    markNeedsLayout();
  }

  set factor(double? value) {
    if (_factor == value) return;
    _factor = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    final current = geometry!;
    final factor = _factor;
    if (factor == null) {
      _extents.header = current.scrollExtent;
      return;
    }
    if (factor == 1 || current.scrollOffsetCorrection != null) return;
    // 先布局标题，再按剩余视口高度计算结果区的展开动画。
    // 正文尺寸、滚动范围和按需构建的范围保持不变。
    final resultsViewport = math.max(
      0.0,
      constraints.viewportMainAxisExtent - _extents.header,
    );
    geometry = current.copyWith(
      paintExtent: current.paintExtent * factor,
      layoutExtent: current.layoutExtent * factor,
      maxPaintExtent:
          math.max(
            current.paintExtent,
            math.min(current.maxPaintExtent, resultsViewport),
          ) *
          factor,
      hitTestExtent: current.hitTestExtent * factor,
      visible: current.visible && factor > 0,
    );
  }
}

class DnsTool extends StatefulWidget {
  const DnsTool({super.key, required this.app, this.controller});

  final AppController app;
  final DnsController? controller;

  @override
  State<DnsTool> createState() => _DnsToolState();
}

class _DnsToolState extends State<DnsTool> with SingleTickerProviderStateMixin {
  late final _controller = widget.controller ?? DnsController(widget.app);
  late final _name = TextEditingController(text: _controller.name);
  final _scroll = ScrollController();
  final _extents = _DnsLayoutExtents();
  final _contentKey = GlobalKey();
  final _localOverlays = <ModalRoute<dynamic>>{};
  DnsCacheResult? _cacheResult;
  Object? _cacheError;
  bool _results = false;
  bool _confirming = false;
  bool _menuOpen = false;
  bool _exiting = false;
  bool? _routeVisible;
  late final _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  @override
  void initState() {
    super.initState();
    _phase.addStatusListener((status) {
      if (mounted &&
          (status == AnimationStatus.completed ||
              status == AnimationStatus.dismissed)) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      final target = _results ? 1.0 : 0.0;
      if (_phase.value != target) _phase.value = target;
    }
    _syncVisibility();
  }

  void _showResults(bool value) {
    setState(() => _results = value);
    if (MediaQuery.disableAnimationsOf(context)) {
      _phase.value = value ? 1 : 0;
    } else if (value) {
      _phase.animateTo(1, curve: Curves.easeInOutCubic);
    } else {
      _phase.animateBack(0, curve: Curves.easeInOutCubic);
    }
  }

  void _syncVisibility() {
    final visible = _ownsPresentation;
    if (_routeVisible == visible) return;
    _routeVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 帧结束前导航状态可能再次变化，此时重新检查工具是否仍可见。
      _routeVisible = _ownsPresentation;
      _controller.setVisible(_routeVisible!);
    });
  }

  bool _localDialogCurrent(BuildContext dialogContext) {
    if (!mounted || _exiting || !widget.app.interactive) return false;
    final route = ModalRoute.of(dialogContext);
    return route != null &&
        _localOverlays.contains(route) &&
        route.isActive &&
        route.isCurrent &&
        route.animation?.status != AnimationStatus.reverse;
  }

  void _popLocalDialog<T>(BuildContext dialogContext, [T? result]) {
    if (!_localDialogCurrent(dialogContext)) return;
    Navigator.of(dialogContext).pop<T>(result);
  }

  Future<T?> _showLocalDialog<T>(WidgetBuilder builder) async {
    late final DialogRoute<T> route;
    route = DialogRoute<T>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (dialogContext) {
        ModalRoute.of(dialogContext);
        _syncVisibility();
        return PopScope<T>(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) FocusScope.of(dialogContext).unfocus();
          },
          child: ListenableBuilder(
            listenable: Listenable.merge([route.animation!, widget.app]),
            builder: (_, child) {
              final current = _localDialogCurrent(dialogContext);
              return ExcludeFocus(
                excluding: !current,
                child: IgnorePointer(
                  ignoring: !current,
                  child: ExcludeSemantics(excluding: !current, child: child!),
                ),
              );
            },
            child: builder(dialogContext),
          ),
        );
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

  bool get _ownsPresentation {
    if (!mounted || _exiting) return false;
    final route = ModalRoute.of(context);
    if (route != null &&
        (!route.isActive ||
            route.animation?.status == AnimationStatus.reverse)) {
      return false;
    }
    return (route?.isCurrent ?? true) ||
        _localOverlays.any(
          (overlay) =>
              overlay.isActive &&
              overlay.isCurrent &&
              overlay.animation?.status != AnimationStatus.reverse,
        );
  }

  bool get _canAct =>
      _ownsPresentation &&
      widget.app.interactive &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  Future<bool> _canPresent(int version) async {
    if (!await widget.app.waitUntilInteractive()) return false;
    return _ownsPresentation &&
        _controller.active &&
        version == _controller.contextVersion;
  }

  bool _responseExpired(DnsResponse response) =>
      response.stale ||
      !response.source.matchesIdentity(widget.app.state.core) ||
      response.source.networkRevision !=
          widget.app.state.core.networkRevision ||
      response.networkEpoch != widget.app.state.networkEpoch ||
      (identical(response, _controller.response) && _controller.stale);

  String _sourceLabel(AppLocalizations strings, DnsResponse response) =>
      response.source.purpose == 'RUNNING'
      ? strings.runtimeConfigLive
      : strings.runtimeConfigPreview;

  Widget _responseIdentity(AppLocalizations strings, DnsResponse response) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            strings.dnsQueryIdentity(response.name, response.type),
            scrollPhysics: const NeverScrollableScrollPhysics(),
          ),
          Text(strings.dnsResponseSource(_sourceLabel(strings, response))),
        ],
      );

  Future<void> _details(
    String message, {
    String? detail,
    String? title,
    WidgetBuilder? identity,
  }) async {
    if (!await _canPresent(_controller.contextVersion)) return;
    await _showLocalDialog<void>((dialogContext) {
      final strings = AppLocalizations.of(dialogContext);
      return AlertDialog(
        title: Text(title ?? strings.errorDetails),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (identity != null) ...[
              identity(dialogContext),
              const SizedBox(height: 12),
            ],
            SelectableText(
              message,
              scrollPhysics: const NeverScrollableScrollPhysics(),
            ),
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: 12),
              SelectableText(
                detail,
                scrollPhysics: const NeverScrollableScrollPhysics(),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _popLocalDialog<void>(dialogContext),
            child: Text(strings.close),
          ),
        ],
      );
    });
  }

  void _viewResults(DnsResponse response) {
    if (!_canAct || _results || !identical(response, _controller.response)) {
      return;
    }
    final draft = _name.value;
    FocusScope.of(context).unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _showResults(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _results && _name.text == draft.text) _name.value = draft;
    });
  }

  Future<void> _cacheDetailsDialog(DnsCacheResult result, bool fakeIp) {
    final strings = AppLocalizations.of(context);
    return _details(
      _cacheDetails(strings, result),
      title: strings.dnsCacheOperationDetails,
      detail: [
        ?result.detail,
        if (result.cancellationError != null)
          result.cancellationError.toString(),
      ].join('\n'),
      identity: (context) {
        final strings = AppLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(fakeIp ? strings.dnsClearFakeIp : strings.dnsClearCache),
            Text(
              strings.dnsResponseSource(
                result.source.purpose == 'RUNNING'
                    ? strings.runtimeConfigLive
                    : strings.runtimeConfigPreview,
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _clear(bool fakeIp, {required int version}) async {
    if (!_canAct ||
        version != _controller.contextVersion ||
        !_controller.canQuery ||
        _confirming ||
        (_results && _controller.stale)) {
      return;
    }
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
              onPressed: () => _popLocalDialog(context, false),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () => _popLocalDialog(context, true),
              child: Text(strings.dnsClearFakeIp),
            ),
          ],
        );
      });
      if (!mounted) return;
      setState(() => _confirming = false);
      if (confirmed != true ||
          !_canAct ||
          version != _controller.contextVersion ||
          !_controller.canQuery) {
        return;
      }
    }
    setState(() {
      _cacheResult = null;
      _cacheError = null;
    });
    try {
      final result = await _controller.clearCache(fakeIp: fakeIp);
      if (!mounted || result == null) return;
      setState(() => _cacheResult = result);
      if (_controller.active && version == _controller.contextVersion) {
        await showLocalizedOperationNotice(
          context,
          (strings) => _cacheStatus(strings, result),
          error:
              result.status == DnsCacheStatus.partialOrFailed ||
              result.cancellationError != null,
          identity: result,
          eligibilityChanges: _controller,
          isCurrent: () =>
              _canAct &&
              version == _controller.contextVersion &&
              identical(_cacheResult, result),
          onDetails: () => _cacheDetailsDialog(result, fakeIp),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _cacheError = error);
      if (!_controller.active || version != _controller.contextVersion) return;
      await showLocalizedOperationNotice(
        context,
        (strings) => error is DnsFailure
            ? _failure(strings, error.code)
            : strings.dnsCacheFailed,
        technicalDetail: (_) => error.toString(),
        identity: error,
        eligibilityChanges: _controller,
        isCurrent: () =>
            _canAct &&
            version == _controller.contextVersion &&
            identical(_cacheError, error),
        onDetails: () => _details(
          error is DnsFailure
              ? _failure(AppLocalizations.of(context), error.code)
              : AppLocalizations.of(context).dnsCacheFailed,
          title: AppLocalizations.of(context).dnsCacheOperationDetails,
          detail: error.toString(),
        ),
      );
    }
  }

  Future<void> _query({required int version}) async {
    if (!_canAct ||
        version != _controller.contextVersion ||
        _results ||
        !_controller.canQuery ||
        _confirming) {
      return;
    }
    setState(() {
      _cacheResult = null;
      _cacheError = null;
    });
    final pending = _controller.query();
    final requestVersion = _controller.contextVersion;
    await pending;
    if (!await _canPresent(requestVersion) || !mounted) return;
    final code = _controller.errorCode;
    if (code == null && _controller.response != null && !_controller.stale) {
      final draft = _name.value;
      FocusScope.of(context).unfocus();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _showResults(true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _results && _name.text == draft.text) {
          _name.value = draft;
        }
      });
      if (_controller.cancellationError case final detail?) {
        await showLocalizedOperationNotice(
          context,
          (strings) => strings.dnsQueryFailed,
          technicalDetail: (_) => detail,
          identity: (requestVersion, detail),
          eligibilityChanges: _controller,
          isCurrent: () =>
              _canAct &&
              requestVersion == _controller.contextVersion &&
              _controller.cancellationError == detail,
          onDetails: _queryDetails,
        );
      }
    } else if (code != null) {
      final detail = [
        _controller.errorDetail ?? code,
        ?_controller.cancellationError,
      ].join('\n');
      await showLocalizedOperationNotice(
        context,
        (strings) => _failure(strings, code),
        technicalDetail: (_) => detail,
        identity: (requestVersion, code, detail),
        eligibilityChanges: _controller,
        isCurrent: () =>
            _canAct &&
            requestVersion == _controller.contextVersion &&
            _controller.errorCode == code,
        onDetails: _queryDetails,
      );
    }
  }

  void _beginExit() {
    if (_exiting) return;
    setState(() => _exiting = true);
    _routeVisible = false;
    _controller.setVisible(false);
    FocusScope.of(context).unfocus();
  }

  void _close() {
    if (_exiting) return;
    _beginExit();
    Navigator.of(context).pop();
  }

  void _edit() {
    if (_exiting || !_results) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _showResults(false);
  }

  Future<void> _queryDetails() => _details(
    _failure(
      AppLocalizations.of(context),
      _controller.errorCode ?? 'queryFailed',
    ),
    detail: [
      ?(_controller.errorDetail ?? _controller.errorCode),
      ?_controller.cancellationError,
    ].join('\n'),
  );

  Widget _actions(AppLocalizations strings, BoxConstraints bounds) {
    final colors = Theme.of(context).colorScheme;
    final version = _controller.contextVersion;
    final response = _controller.response;
    final canClear = _controller.canQuery && (!_results || !_controller.stale);
    return ChoiceMenuButton<String>(
      key: const ValueKey('dns-actions'),
      identity: version,
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      enabled:
          !_exiting &&
          !_confirming &&
          (canClear || response != null && !_results),
      disabledOptions: {
        if (!canClear) ...['clear', 'fakeIp'],
      },
      maxHeight: bounds.maxHeight,
      options: {
        'clear': strings.dnsClearCache,
        'fakeIp': strings.dnsClearFakeIp,
        if (response != null && !_results)
          'results': _responseExpired(response)
              ? strings.dnsViewPreviousQuery
              : strings.dnsViewQueryResults,
      },
      leadingIcon: (action) => Icon(switch (action) {
        'fakeIp' => Icons.link_off,
        'clear' => Icons.cleaning_services_outlined,
        'results' => Icons.list_alt,
        _ => Icons.info_outline,
      }, color: action == 'fakeIp' ? colors.error : colors.onSurfaceVariant),
      optionBuilder: (action, label) => Text(
        label,
        style: TextStyle(
          color: action == 'fakeIp' ? colors.error : colors.onSurface,
        ),
      ),
      onSelected: (action) {
        if (!_canAct || version != _controller.contextVersion) return;
        switch (action) {
          case 'clear':
            _clear(false, version: version);
          case 'fakeIp':
            _clear(true, version: version);
          case 'results':
            if (response != null) _viewResults(response);
        }
      },
      onOpened: () => _menuOpen = true,
      onClosed: () => _menuOpen = false,
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
  }

  Widget _queryIcon() {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 180),
      switchInCurve: Curves.easeInOutCubic,
      switchOutCurve: Curves.easeInOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: reduced ? const AlwaysStoppedAnimation(1) : animation,
        child: child,
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        children: [
          if (!reduced)
            for (final child in previous) ExcludeSemantics(child: child),
          ?current,
        ],
      ),
      child: _controller.queryBusy
          ? const CircularProgressIndicator(strokeWidth: 2)
          : const Icon(Icons.search, size: 18),
    );
  }

  Size _labelSize(
    String text,
    TextStyle style, {
    double maxWidth = double.infinity,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final size = painter.size;
    painter.dispose();
    return size;
  }

  Widget _queryControls(AppLocalizations strings, BoxConstraints bounds) {
    final version = _controller.contextVersion;
    return Wrap(
      key: const ValueKey('dns-query-controls'),
      spacing: 8,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: 48, maxWidth: bounds.maxWidth),
          child: IntrinsicWidth(
            child: ChoiceMenuButton<String>(
              key: const ValueKey('dns-type'),
              identity: version,
              maxHeight: bounds.maxHeight * .5,
              tooltip: strings.dnsRecordType,
              value: _controller.type,
              enabled: !_controller.busy && !_confirming,
              onSelected: _controller.setType,
              options: {for (final type in dnsRecordTypes) type: type},
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: strings.dnsRecordType,
                  constraints: const BoxConstraints(minHeight: 48),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
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
        ),
        FilledButton.icon(
          key: const ValueKey('dns-query'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          onPressed: _controller.canQuery && !_confirming
              ? () => _query(version: version)
              : null,
          icon: SizedBox.square(dimension: 18, child: _queryIcon()),
          label: Text(strings.dnsQuery, textAlign: TextAlign.center),
        ),
      ],
    );
  }

  Widget _headerTitle(AppLocalizations strings) => LayoutBuilder(
    builder: (context, bounds) {
      final style = Theme.of(context).textTheme.titleLarge!;
      var height = 0.0;
      for (final title in [
        strings.dnsTools,
        strings.dnsQueryResults,
        strings.dnsPreviousQuery,
      ]) {
        height = math.max(
          height,
          _labelSize(title, style, maxWidth: bounds.maxWidth).height,
        );
      }
      return SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _results
                ? _controller.stale
                      ? strings.dnsPreviousQuery
                      : strings.dnsQueryResults
                : strings.dnsTools,
            style: style,
          ),
        ),
      );
    },
  );

  Widget _form(AppLocalizations strings, BoxConstraints bounds) {
    final version = _controller.contextVersion;
    final enabled = _controller.canQuery && !_confirming;
    return Padding(
      // 表单顶部为浮动标签预留绘制空间，SizeTransition 在退出动画中裁剪隐藏内容。
      padding: EdgeInsets.fromLTRB(
        24,
        math.max(12, MediaQuery.textScalerOf(context).scale(16)),
        24,
        16,
      ),
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
            decoration: InputDecoration(labelText: strings.dnsName),
            onSubmitted: (_) {
              if (enabled) _query(version: version);
            },
          ),
          const SizedBox(height: 16),
          _queryControls(strings, bounds),
          const SizedBox(height: 12),
          Text(
            strings.dnsResolverNotice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _resultSummary(AppLocalizations strings, DnsResponse result) => Column(
    key: const ValueKey('dns-result-summary'),
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      _responseIdentity(strings, result),
      const SizedBox(height: 8),
      SelectableText(
        strings.dnsRcode(result.rcodeName, result.rcode),
        scrollPhysics: const NeverScrollableScrollPhysics(),
      ),
      Text(strings.dnsElapsed(result.elapsedMs)),
      if (result.truncated) Text(strings.dnsTruncated),
    ],
  );

  List<Widget> _records(AppLocalizations strings, DnsResponse result) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: _resultSummary(strings, result),
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
              SelectableText(
                record.name,
                scrollPhysics: const NeverScrollableScrollPhysics(),
              ),
              SelectableText(
                strings.dnsRecordMeta(
                  record.type,
                  record.recordClass,
                  record.ttl,
                ),
                style: Theme.of(context).textTheme.bodySmall,
                scrollPhysics: const NeverScrollableScrollPhysics(),
              ),
              const SizedBox(height: 4),
              SelectableText(
                record.data,
                scrollPhysics: const NeverScrollableScrollPhysics(),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
            ],
          ),
        ),
    ],
    const SizedBox(height: 16),
  ];

  // _phase 负责展开和收起的高度动画；减少动态效果时直接显示当前尺寸。
  // 其余尺寸变化使用 AnimatedSize，_contentKey 保留同一棵组件子树。
  Widget _resize({required Widget child}) =>
      MediaQuery.disableAnimationsOf(context) || _phase.isAnimating
      ? child
      : AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: child,
        );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      _syncVisibility();
      final strings = AppLocalizations.of(context);
      final result = _controller.response;
      final rows = (_results || !_phase.isDismissed) && result != null
          ? _records(strings, result)
          : <Widget>[];
      return PopScope(
        canPop: !_results,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _beginExit();
          } else if (_results && !_menuOpen) {
            _edit();
          }
        },
        child: ExcludeFocus(
          excluding: _exiting,
          child: IgnorePointer(
            ignoring: _exiting,
            child: ExcludeSemantics(
              excluding: _exiting,
              child: Dialog(
                clipBehavior: Clip.antiAlias,
                constraints: const BoxConstraints(maxWidth: 560),
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                insetAnimationDuration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 100),
                child: LayoutBuilder(
                  builder: (context, bounds) => ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: _results || !_phase.isDismissed
                          ? math.min(
                              bounds.maxHeight,
                              720 *
                                  MediaQuery.textScalerOf(context).scale(14) /
                                  14,
                            )
                          : bounds.maxHeight,
                    ),
                    child: _resize(
                      child: SizedBox(
                        key: _contentKey,
                        width: double.infinity,
                        child: CustomScrollView(
                          key: const PageStorageKey('dns-tool-scroll'),
                          controller: _scroll,
                          shrinkWrap: true,
                          slivers: [
                            _DnsPhaseExtent.header(
                              extents: _extents,
                              sliver: SliverToBoxAdapter(
                                key: const ValueKey('dns-header'),
                                child: Material(
                                  color: HomePalette.of(context).surface,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      12,
                                      8,
                                      12,
                                    ),
                                    child: Row(
                                      children: [
                                        ExcludeFocus(
                                          excluding: !_results,
                                          child: IgnorePointer(
                                            ignoring: !_results,
                                            child: ExcludeSemantics(
                                              excluding: !_results,
                                              child: SizeTransition(
                                                axis: Axis.horizontal,
                                                sizeFactor: _phase,
                                                child: FadeTransition(
                                                  opacity: _phase,
                                                  child: Offstage(
                                                    offstage:
                                                        !_results &&
                                                        _phase.isDismissed,
                                                    child: BackButton(
                                                      key: const ValueKey(
                                                        'dns-edit',
                                                      ),
                                                      onPressed: _edit,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Expanded(child: _headerTitle(strings)),
                                        _actions(strings, bounds),
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
                            ),
                            SliverToBoxAdapter(
                              child: ExcludeFocus(
                                excluding: _results,
                                child: IgnorePointer(
                                  ignoring: _results,
                                  child: ExcludeSemantics(
                                    excluding: _results,
                                    child: SizeTransition(
                                      alignment: AlignmentDirectional.topStart,
                                      sizeFactor: ReverseAnimation(_phase),
                                      child: FadeTransition(
                                        opacity: ReverseAnimation(_phase),
                                        child: Offstage(
                                          offstage:
                                              _results && _phase.isCompleted,
                                          child: _form(strings, bounds),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SliverFadeTransition(
                              opacity: _phase,
                              sliver: AnimatedBuilder(
                                animation: _phase,
                                builder: (_, child) => _DnsPhaseExtent.results(
                                  extents: _extents,
                                  factor: _phase.value,
                                  sliver: child!,
                                ),
                                child: SliverIgnorePointer(
                                  ignoring: !_results,
                                  sliver: SliverList.builder(
                                    itemCount: rows.length,
                                    itemBuilder: (_, index) => ExcludeFocus(
                                      excluding: !_results,
                                      child: ExcludeSemantics(
                                        excluding: !_results,
                                        child: rows[index],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
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
    _phase.dispose();
    _name.dispose();
    _scroll.dispose();
    super.dispose();
  }
}
