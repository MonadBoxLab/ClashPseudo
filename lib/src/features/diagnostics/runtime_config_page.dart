import 'package:flutter/material.dart';

import '../../app/widgets/task_shortcuts.dart';
import '../../app/widgets/technical_reading_pane.dart';

import '../../app/app_theme.dart';

import '../../app/app_controller.dart';
import '../../l10n/app_localizations.dart';
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

  @override
  void initState() {
    super.initState();
    _controller.setVisible(true);
  }

  @override
  void dispose() {
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
    onSearch: _searchFocus.requestFocus,
    onEscape: _searchFocus.unfocus,
    child: _content(context),
  );

  Widget _content(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final status = switch (_controller.status) {
        RuntimeConfigStatus.loading => strings.runtimeConfigLoading,
        RuntimeConfigStatus.live => strings.runtimeConfigLive,
        RuntimeConfigStatus.preview => strings.runtimeConfigPreview,
        RuntimeConfigStatus.stale => strings.runtimeConfigStale,
        RuntimeConfigStatus.empty => strings.runtimeConfigEmpty,
        RuntimeConfigStatus.failed => strings.runtimeConfigFailed,
      };
      final lines = _controller.lines.indexed
          .where((line) => line.$2.toLowerCase().contains(_query))
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(strings.runtimeConfiguration),
          actions: [
            IconButton(
              tooltip: strings.refresh,
              color: HomePalette.of(context).syncAction,
              onPressed: _controller.canRefresh ? _controller.refresh : null,
              icon: _controller.loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
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
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Text(
                        strings.runtimeConfigExplanation,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(
                          status,
                          softWrap: false,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color:
                                    _controller.status ==
                                        RuntimeConfigStatus.failed
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
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
