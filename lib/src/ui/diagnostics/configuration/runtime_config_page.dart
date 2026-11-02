import '../../components/feedback/operation_feedback.dart';
import '../../components/feedback/operation_notice.dart';
import '../../../model/app_message.dart';
import '../../navigation/page_route.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../components/reading/original_text_view.dart';
import '../../components/input/task_shortcuts.dart';
import '../../components/reading/technical_reading_pane.dart';

import '../../theme/app_theme.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';
import '../../../l10n/app_localizations.dart';
import 'runtime_config_controller.dart';

class RuntimeConfigPage extends StatefulWidget {
  const RuntimeConfigPage({super.key, required this.app});
  final AppController app;

  @override
  State<RuntimeConfigPage> createState() => _RuntimeConfigPageState();
}

class _RuntimeConfigPageState extends State<RuntimeConfigPage> {
  late final _controller = RuntimeConfigController(widget.app);
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  String _query = '';
  Object get _authority => (
    widget.app.storageEpoch,
    widget.app.state.core.identity,
    widget.app.collection.selected?.id,
    widget.app.collection.selected?.revision,
  );
  Object? _readAuthority;
  Object? _noticeAuthority;
  Object? _noticeToken;
  bool _wasLoading = false;
  bool _readNoticed = false;
  late final _feedbackChanges = Listenable.merge([widget.app, _controller]);

  AppMessage? get _error =>
      (_readAuthority == _authority ? _controller.readError : null) ??
      widget.app.platformErrorMessage ??
      widget.app.state.core.errorMessage ??
      widget.app.commandErrorMessage;

  void _readFeedback() {
    if (!mounted) return;
    final authority = _authority;
    if (_controller.loading && !_wasLoading) _readAuthority = authority;
    _wasLoading = _controller.loading;
    if (_noticeAuthority != authority) {
      _noticeAuthority = authority;
      _noticeToken = null;
      _readNoticed = false;
    }
    final error = _error;
    if (error == null) {
      if (!_controller.loading) {
        _noticeToken = null;
        _readNoticed = false;
      }
      return;
    }
    if (_controller.loading || _readNoticed || !_pageLive) return;
    _readNoticed = true;
    final token = _noticeToken = Object();
    bool current() =>
        mounted && _authority == authority && identical(_noticeToken, token);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!current() || !_pageLive) {
        if (current()) _readNoticed = false;
        return;
      }
      final presented = await showAppNotice(
        context,
        error,
        isCurrent: () => _pageLive && current(),
        isCurrentWithPopup: (popup) => _pageWithPopup(popup) && current(),
        eligibilityChanges: _feedbackChanges,
        onRetry: _controller.refresh,
        identity: token,
      );
      if (!presented && current()) _readNoticed = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.setVisible(true);
    _readAuthority = _authority;
    _wasLoading = _controller.loading;
    _controller.addListener(_readFeedback);
    widget.app.addListener(_readFeedback);
  }

  ModalRoute<dynamic>? _route;

  bool get _pageLive =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context) &&
      (_route?.isCurrent ?? true) &&
      _route?.animation?.status != AnimationStatus.reverse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      _route?.animation?.removeListener(_syncVisibility);
      _route = route;
      route?.animation?.addListener(_syncVisibility);
    }
    _syncVisibility();
  }

  bool _pageWithPopup(ModalRoute<dynamic> popup) =>
      mounted &&
      widget.app.foreground &&
      AppTaskActivity.isActive(context, ownedPopup: popup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: popup);

  bool _visibilityScheduled = false;

  void _syncVisibility() {
    if (!mounted || _visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      _controller.setVisible(_pageLive);
      if (!_pageLive) _searchFocus.unfocus();
      _readFeedback();
    });
  }

  @override
  void dispose() {
    _route?.animation?.removeListener(_syncVisibility);
    widget.app.removeListener(_readFeedback);
    _controller.removeListener(_readFeedback);
    _controller.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _filter() {
    final query = _search.text.trim().toLowerCase();
    if (query == _query) return;
    setState(() => _query = query);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => TaskShortcuts(
    onSearch: () {
      if (_pageLive) _searchFocus.requestFocus();
    },
    onEscape: () {
      if (_pageLive) _searchFocus.unfocus();
    },
    child: _content(context),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final readError = _error;
      final authority = _authority;
      final lines = _controller.lines.indexed
          .where((line) => line.$2.toLowerCase().contains(_query))
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(strings.runtimeConfiguration),
          actions: [
            IconButton(
              tooltip: strings.resourceRawData,
              icon: const Icon(Icons.data_object),
              onPressed: _controller.data == null
                  ? null
                  : () {
                      if (!_pageLive) return;
                      final text = const JsonEncoder.withIndent('  ')
                          .convert(_controller.data);
                      Navigator.of(context).push<void>(
                        FocusedPageRoute(
                          builder: (_) => Scaffold(
                            appBar: AppBar(
                              title: Text(strings.resourceRawData),
                            ),
                            body: OriginalTextView(text: text),
                          ),
                        ),
                      );
                    },
            ),
            PopupMenuButton<String>(
              tooltip: strings.moreActions,
              style: IconButton.styleFrom(
                foregroundColor: HomePalette.of(context).syncAction,
              ),
              onSelected: (action) {
                if (!_pageLive || _authority != authority) return;
                if (action == 'refresh') {
                  if (_controller.canRefresh) _controller.refresh();
                } else if (action == 'details' && readError != null) {
                  showAppMessage(
                    context,
                    readError,
                    title: (strings) => strings.errorDetails,
                    isCurrent: () => _pageLive && _authority == authority,
                    isCurrentWithPopup: (popup) =>
                        _pageWithPopup(popup) && _authority == authority,
                    eligibilityChanges: _feedbackChanges,
                  );
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'refresh',
                  enabled: _controller.canRefresh,
                  child: Text(strings.refresh),
                ),
                PopupMenuItem(
                  value: 'details',
                  enabled: readError != null,
                  child: Text(strings.errorDetails),
                ),
              ],
              icon: AnimatedSwitcher(
                key: const ValueKey('runtime-refresh-state'),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                child: _controller.loading
                    ? const SizedBox.square(
                        key: ValueKey('runtime-refresh-pending'),
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.refresh,
                        key: ValueKey('runtime-refresh-idle'),
                      ),
              ),
            ),
          ],
        ),
        body: TechnicalReadingPane(
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        onChanged: (_) => _filter(),
                        decoration: InputDecoration(
                          labelText: strings.runtimeConfigSearch,
                          prefixIconColor: WidgetStateColor.resolveWith(
                            (states) => states.contains(WidgetState.disabled)
                                ? Theme.of(context).disabledColor
                                : HomePalette.of(context).moreAction,
                          ),
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: IconButton(
                            tooltip: strings.clearSearch,
                            onPressed: () {
                              _search.clear();
                              _filter();
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
              if (lines.isEmpty && _controller.lines.isNotEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(strings.noSearchResults),
                    ),
                  ),
                )
              else if (lines.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  sliver: SliverList.builder(
                    itemCount: lines.length,
                    itemBuilder: (context, index) {
                      final (number, text) = lines[index];
                      return Padding(
                        key: ValueKey(number),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 2,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 44,
                              child: Text(
                                '${number + 1}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                text,
                                style: TechnicalReadingPane.textStyleOf(
                                  context,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
