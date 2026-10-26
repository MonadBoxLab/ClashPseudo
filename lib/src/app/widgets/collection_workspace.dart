import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class CollectionWorkspace extends StatefulWidget {
  const CollectionWorkspace({
    super.key,
    required this.master,
    required this.detail,
    required this.onClose,
    this.active = true,
    this.detailStatus = '',
    this.onMasterVisibilityChanged,
  });

  final Widget master;
  final Widget? detail;
  final VoidCallback onClose;
  final bool active;
  final String detailStatus;
  final ValueChanged<bool>? onMasterVisibilityChanged;

  @override
  State<CollectionWorkspace> createState() => CollectionWorkspaceState();
}

class CollectionWorkspaceState extends State<CollectionWorkspace> {
  final _master = GlobalKey();
  final _detail = GlobalKey();
  final _masterFocus = FocusScopeNode(debugLabel: 'collection-master');
  LocalHistoryEntry? _history;
  late bool _showDetail;
  bool _historyWanted = false;
  bool? _masterVisible;

  @override
  void initState() {
    super.initState();
    _showDetail = widget.detail != null;
    _masterFocus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (mounted && _masterFocus.hasFocus && _showDetail) {
      setState(() => _showDetail = false);
    }
  }

  @override
  void didUpdateWidget(CollectionWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detail == null) {
      _showDetail = false;
    } else if (oldWidget.detail == null ||
        oldWidget.detail?.key != widget.detail?.key) {
      _showDetail = true;
    }
  }

  bool get showingDetail => _showDetail && widget.detail != null;

  void showMaster() {
    if (widget.active) setState(() => _showDetail = false);
  }

  void _showDetails() {
    if (!widget.active || widget.detail == null) return;
    _masterFocus.unfocus();
    setState(() => _showDetail = true);
  }

  void _syncHistory() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.active || !_historyWanted || widget.detail == null) {
        _removeHistory();
        return;
      }
      if (_history != null) return;
      final route = ModalRoute.of(context);
      if (route == null) return;
      late final LocalHistoryEntry entry;
      entry = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          if (!identical(_history, entry)) return;
          _history = null;
          widget.onClose();
        },
      );
      _history = entry;
      route.addLocalHistoryEntry(entry);
    });
  }

  void _removeHistory() {
    final entry = _history;
    _history = null;
    entry?.remove();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final masterMinimum = (320 * scale).clamp(320.0, 480.0);
      final detailMinimum = (480 * scale).clamp(480.0, 840.0);
      final wide =
          constraints.maxWidth >= masterMinimum + detailMinimum + 1 &&
          constraints.maxHeight >= 280;
      final showDetail = widget.detail != null && _showDetail;
      final masterVisible = widget.active && (wide || !showDetail);
      if (_masterVisible != masterVisible) {
        _masterVisible = masterVisible;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _masterVisible == masterVisible) {
            widget.onMasterVisibilityChanged?.call(masterVisible);
          }
        });
      }
      _historyWanted = wide || showDetail;
      _syncHistory();
      final master = KeyedSubtree(
        key: _master,
        child: ExcludeFocus(
          excluding: !wide && showDetail,
          child: FocusScope(node: _masterFocus, child: widget.master),
        ),
      );
      final detail = KeyedSubtree(
        key: _detail,
        child: widget.detail == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(AppLocalizations.of(context).selectDetails),
                ),
              )
            : Column(
                children: [
                  Expanded(child: widget.detail!),
                  SafeArea(
                    top: false,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          widget.detailStatus,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      );
      final content = wide
          ? Row(
              children: [
                SizedBox(
                  width: (constraints.maxWidth * .38).clamp(
                    masterMinimum,
                    560.0,
                  ),
                  child: master,
                ),
                const VerticalDivider(width: 1),
                Expanded(child: detail),
              ],
            )
          : IndexedStack(
              index: showDetail ? 1 : 0,
              children: [
                master,
                ExcludeFocus(excluding: !showDetail, child: detail),
              ],
            );
      return _CollectionScope(
        detailAvailable:
            widget.active && !wide && !showDetail && widget.detail != null,
        showDetails: _showDetails,
        child: content,
      );
    },
  );

  @override
  void dispose() {
    _removeHistory();
    _masterFocus.removeListener(_focusChanged);
    _masterFocus.dispose();
    super.dispose();
  }
}

class _CollectionScope extends InheritedWidget {
  const _CollectionScope({
    required this.detailAvailable,
    required this.showDetails,
    required super.child,
  });

  final bool detailAvailable;
  final VoidCallback showDetails;

  @override
  bool updateShouldNotify(_CollectionScope oldWidget) =>
      detailAvailable != oldWidget.detailAvailable;
}

class CollectionDetailsAction extends StatelessWidget {
  const CollectionDetailsAction({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_CollectionScope>();
    if (scope?.detailAvailable != true) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('collection-show-details'),
      onPressed: scope!.showDetails,
      tooltip: AppLocalizations.of(context).details,
      icon: const Icon(Icons.article_outlined),
    );
  }
}
