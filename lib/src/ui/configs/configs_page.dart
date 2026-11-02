import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';

import 'package:file_selector/file_selector.dart';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/components/collections/reading_list.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_file.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/ui/settings/auto_update_dialog.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/ui/components/feedback/confirm_action.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_field_dialog.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/import_dialog.dart';
import 'package:clash_pseudo/src/ui/components/collections/exact_size_transition.dart';

import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';

class ConfigsPage extends StatefulWidget {
  const ConfigsPage({
    super.key,
    required this.controller,
    this.selectFile = selectConfigFile,
    this.active = true,
  });
  final AppController controller;
  final bool active;
  final Future<XFile?> Function() selectFile;

  @override
  State<ConfigsPage> createState() => _ConfigsPageState();
}

class _ConfigsPageState extends State<ConfigsPage>
    with SingleTickerProviderStateMixin {
  AppController get controller => widget.controller;
  final _scroll = ScrollController();
  final _feedbackOwner = ValueNotifier<bool>(true);
  final _keys = <String, GlobalKey>{};
  late final AnimationController _layoutMotion;
  Object? _gridLayout;
  Object? _readingLayout;
  List<(String, String, String)> _readingEntries = const [];
  Map<String, Rect> _cardOrigins = const {};
  bool _adding = false;
  int _presentation = 0;
  bool _wasForeground = true;
  bool _taskActive = true;
  ModalRoute<dynamic>? _route;
  ModalRoute<dynamic>? _ownedPopup;

  bool _live(int presentation) =>
      mounted &&
      widget.active &&
      AppTaskActivity.isActive(context, ownedPopup: _ownedPopup) &&
      AppTaskActivity.routeIsActive(_route, ownedPopup: _ownedPopup) &&
      controller.foreground &&
      presentation == _presentation;

  bool _canResume(int presentation) =>
      _live(presentation) && (_route?.isCurrent ?? true);

  void _syncOwner() {
    _scheduleReadNotice();
    if (_wasForeground && !controller.foreground) {
      _presentation++;
    }
    _wasForeground = controller.foreground;
    _feedbackOwner.value =
        mounted &&
        widget.active &&
        (_taskActive || _readingFeedback) &&
        controller.foreground &&
        (_readingFeedback
            ? (_route?.isActive ?? true) &&
                  _route?.animation?.status != AnimationStatus.reverse
            : AppTaskActivity.routeIsActive(_route, ownedPopup: _ownedPopup));
  }

  @override
  void initState() {
    super.initState();
    _layoutMotion = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 180),
    );
    controller.addListener(_syncOwner);
    _syncOwner();
  }

  @override
  void didUpdateWidget(ConfigsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        !identical(oldWidget.controller, controller)) {
      _presentation++;
    }
    if (!identical(oldWidget.controller, controller)) {
      oldWidget.controller.removeListener(_syncOwner);
      controller.addListener(_syncOwner);
    }
    _syncOwner();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final active =
        AppTaskActivity.isActive(context, ownedPopup: _ownedPopup) &&
        AppTaskActivity.routeIsActive(_route, ownedPopup: _ownedPopup);
    if (_taskActive && !active) {
      _presentation++;
    }
    _taskActive = active;
    _syncOwner();
  }

  Map<String, Object?> _target(ConfigEntry entry) => {
    'id': entry.id,
    'revision': entry.revision,
    'expectedSource': entry.source,
    'expectedName': entry.name,
  };

  Future<T?> _showDialog<T>({required WidgetBuilder builder}) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      builder: (context) => OperationNoticeHost(
        onDismiss: () => Navigator.of(context).maybePop(),
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => builder(context),
        ),
      ),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
    );
    _ownedPopup = route;
    try {
      return await navigator.push(route);
    } finally {
      if (identical(_ownedPopup, route)) _ownedPopup = null;
    }
  }

  bool _readingFeedback = false;

  Future<bool> _showMessage(
    AppMessage message, {
    String Function(AppLocalizations)? title,
    String? subject,
    VoidCallback? onPresented,
  }) => _showFeedback(
    message.summary,
    technicalDetail: message.technicalDetail,
    title: title,
    subject: subject,
    onPresented: onPresented,
  );

  Future<bool> _showFeedback(
    String Function(AppLocalizations) message, {
    String? Function(AppLocalizations)? technicalDetail,
    String Function(AppLocalizations)? title,
    String? subject,
    VoidCallback? onPresented,
  }) {
    final presentation = _presentation;
    final epoch = controller.storageEpoch;
    final owner = controller;
    return showLocalizedOperationNotice(
      context,
      message,
      technicalDetail: technicalDetail,
      title: title,
      subject: subject,
      eligibilityChanges: owner,
      isCurrent: () =>
          identical(owner, controller) &&
          epoch == owner.storageEpoch &&
          _canResume(presentation),
      onPresented: onPresented,
      onDetails: () => _showDetails(
        message,
        technicalDetail: technicalDetail,
        title: title,
        subject: subject,
      ),
    );
  }

  Future<void> _showDetails(
    String Function(AppLocalizations) message, {
    String? Function(AppLocalizations)? technicalDetail,
    String Function(AppLocalizations)? title,
    String? subject,
  }) async {
    final presentation = _presentation;
    final owner = controller;
    ModalRoute<dynamic>? feedbackRoute;
    if (!_canResume(presentation)) return;
    _readingFeedback = true;
    try {
      await showLocalizedOperationMessage(
        context,
        message,
        technicalDetail: technicalDetail,
        title: title,
        subject: subject,
        eligibilityChanges: owner,
        isCurrent: () => _canResume(presentation),
        isCurrentWithPopup: (popup) =>
            mounted &&
            identical(owner, controller) &&
            presentation == _presentation &&
            widget.active &&
            owner.foreground &&
            AppTaskActivity.isActive(context, ownedPopup: popup) &&
            AppTaskActivity.routeIsActive(_route, ownedPopup: popup),
        onRoute: (route) {
          if (route != null) {
            feedbackRoute = route;
            _ownedPopup = route;
          } else if (identical(_ownedPopup, feedbackRoute)) {
            _ownedPopup = null;
          }
        },
      );
    } finally {
      _readingFeedback = false;
      if (mounted) _syncOwner();
    }
  }

  Duration _motion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  Widget _cards(
    BuildContext context, {
    required double viewportOrigin,
  }) => Padding(
    padding: const EdgeInsets.all(20),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final entries = controller.collection.entries;
        final ids = entries.map((entry) => entry.id).toSet();
        _keys.removeWhere((id, _) => !ids.contains(id));
        final fontSize = Theme.of(context).textTheme.titleMedium!.fontSize!;
        final minimum =
            360 *
            math.max(
              1,
              MediaQuery.textScalerOf(context).scale(fontSize) / fontSize,
            );
        final columns = math.max(
          1,
          ((constraints.maxWidth + 16) / (minimum + 16)).floor(),
        );
        final layout = (columns, constraints.maxWidth);
        final readingLayout = (
          controller.storageEpoch,
          constraints,
          MediaQuery.textScalerOf(context),
          Localizations.localeOf(context),
        );
        final readingEntries = [
          for (final entry in entries)
            (entry.id, entry.name, entry.displaySource),
        ];
        final readingChanged =
            _readingLayout != readingLayout ||
            !listEquals(_readingEntries, readingEntries);
        _readingLayout = readingLayout;
        _readingEntries = readingEntries;
        // Capture the currently painted cells before changing the animation,
        // children or ReadingList's scroll position. Never resolve a new
        // reading anchor from the persistent origins of an earlier motion.
        final visualRects = <String, Rect>{};
        for (final entry in _keys.entries) {
          final current = entry.value.currentContext;
          if (current == null || !current.mounted) continue;
          final box = current.findRenderObject();
          if (box is! _ConfigCardMotionRender ||
              !box.attached ||
              !box.hasSize ||
              box.child == null ||
              !box.child!.hasSize) {
            continue;
          }
          visualRects[entry.key] = box.visualGlobalRect;
        }
        if (_gridLayout != layout ||
            (readingChanged && _layoutMotion.isAnimating)) {
          final reduced = MediaQuery.disableAnimationsOf(context);
          _cardOrigins = !reduced && _gridLayout != null
              ? visualRects
              : const {};
          _gridLayout = layout;
          if (_cardOrigins.isNotEmpty) {
            _layoutMotion.forward(from: 0);
          } else {
            _layoutMotion.value = 1;
          }
        } else if (MediaQuery.disableAnimationsOf(context) &&
            _layoutMotion.isAnimating) {
          _layoutMotion.stop();
          _layoutMotion.value = 1;
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: columns * 760 + (columns - 1) * 16,
            ),
            child: _ConfigGridHitRegion(
              cards: () => _keys.values
                  .map((key) => key.currentContext?.findRenderObject())
                  .whereType<_ConfigCardMotionRender>(),
              child: ReadingList(
                controller: _scroll,
                identity: controller.storageEpoch,
                viewportOrigin: viewportOrigin,
                visualAnchorRect: (id) => visualRects[id],
                header: _ConfigSizeTransition(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (entries.isEmpty && controller.configsCurrent)
                        _empty(context),
                    ],
                  ),
                ),
                items: [
                  for (var start = 0; start < entries.length; start += columns)
                    ReadingListItem(
                      id: entries[start].id,
                      anchors: [
                        for (
                          var i = start + 1;
                          i < start + columns && i < entries.length;
                          i++
                        )
                          entries[i].id,
                      ],
                      layoutValues: [
                        for (
                          var i = start;
                          i < start + columns && i < entries.length;
                          i++
                        )
                          (entries[i].name, entries[i].displaySource),
                      ],
                      semanticChildCount: math.min(
                        columns,
                        entries.length - start,
                      ),
                      builder: (context) => Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var column = 0; column < columns; column++) ...[
                            if (column > 0) const SizedBox(width: 16),
                            Expanded(
                              child: start + column >= entries.length
                                  ? const SizedBox.shrink()
                                  : _ConfigCardMotion(
                                      key: _keys.putIfAbsent(
                                        entries[start + column].id,
                                        GlobalKey.new,
                                      ),
                                      animation: _layoutMotion,
                                      origin:
                                          _cardOrigins[entries[start + column]
                                              .id],
                                      layout: _gridLayout!,
                                      scroll: _scroll,
                                      child: IndexedSemantics(
                                        index: start + column,
                                        child: TweenAnimationBuilder<double>(
                                          key: ValueKey((
                                            controller.storageEpoch,
                                            entries[start + column].id,
                                          )),
                                          tween: Tween(begin: 0, end: 1),
                                          duration: _motion(context),
                                          curve: Curves.easeOutCubic,
                                          builder: (_, opacity, child) =>
                                              Opacity(
                                                opacity: opacity,
                                                child: child,
                                              ),
                                          child: _tile(
                                            context,
                                            entries[start + column],
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Object? _readNoticeSource;
  bool _readFault = false;
  bool _readNoticeScheduled = false;

  void _scheduleReadNotice() {
    if (_readNoticeScheduled || !mounted) return;
    _readNoticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readNoticeScheduled = false;
      if (!mounted) return;
      final source = (controller, controller.storageEpoch, _presentation);
      if (_readNoticeSource != source) {
        _readNoticeSource = source;
        _readFault = false;
      }
      final error = controller.configErrorMessage;
      if (error == null) {
        if (controller.configsCurrent) _readFault = false;
        return;
      }
      if (_readFault || !_canResume(_presentation)) return;
      _readFault = true;
      unawaited(
        showAppNotice(
          context,
          error,
          title: (strings) => strings.configReadFailed,
          eligibilityChanges: controller,
          isCurrent: () =>
              source == (controller, controller.storageEpoch, _presentation) &&
              controller.configErrorMessage != null &&
              _canResume(_presentation),
          onRetry: controller.refresh,
          onDetails: () => _showDetails(
            error.summary,
            technicalDetail: error.technicalDetail,
            title: (strings) => strings.configReadFailed,
          ),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _empty(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.description_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(strings.noSavedConfigs),
          const SizedBox(height: 8),
          Text(strings.importOrCreateHint),
          const SizedBox(height: 24),
          _addMenu(labeled: true),
        ],
      ),
    );
  }

  @override
  void dispose() {
    controller.removeListener(_syncOwner);
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    _scroll.dispose();
    _layoutMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final strings = AppLocalizations.of(context);
        final title = strings.configTitle;
        final titleStyle = Theme.of(context).textTheme.titleLarge!
            .copyWith(fontWeight: FontWeight.w600);
        final titleMeasure =
            TextPainter(
              text: TextSpan(text: title, style: titleStyle),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(
              maxWidth: math.max(
                1.0,
                constraints.maxWidth -
                    MediaQuery.paddingOf(context).horizontal -
                    80 -
                    (_route?.impliesAppBarDismissal == true
                        ? kToolbarHeight
                        : 0),
              ),
            );
        final toolbarHeight = math.max(
          kToolbarHeight,
          titleMeasure.height + 16,
        );
        titleMeasure.dispose();
        return ExcludeFocus(
          excluding: !widget.active,
          child: IgnorePointer(
            ignoring: !widget.active,
            child: ExcludeSemantics(
              excluding: !widget.active,
              child: Scaffold(
                appBar: AppBar(
                  toolbarHeight: toolbarHeight,
                  titleTextStyle: titleStyle,
                  title: DefaultTextStyle(
                    style: titleStyle,
                    child: Text(title, softWrap: true),
                  ),
                  actions: [_addMenu()],
                ),
                body: SafeArea(
                  child: _cards(
                    context,
                    viewportOrigin:
                        toolbarHeight + MediaQuery.paddingOf(context).top + 20,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _addMenu({bool labeled = false}) {
    final palette = HomePalette.of(context);
    final presentation = _presentation;
    final enabled = _live(presentation) && !_adding;
    final epoch = controller.storageEpoch;
    final strings = AppLocalizations.of(context);
    return ChoiceMenuButton<String>(
      enabled: enabled,
      identity: (epoch, presentation),
      tooltip: strings.addConfig,
      iconColor: Theme.of(context).colorScheme.primary,
      icon: Icons.add,
      options: {
        'url': strings.importFromUrl,
        'file': strings.importFromFile,
        'new': strings.newLocalConfig,
        'retry': strings.refresh,
        if (controller.configErrorMessage != null)
          'error': strings.errorDetails,
      },
      disabledOptions: {
        if (!controller.canEdit) ...['url', 'file', 'new'],
      },
      leadingIcon: (kind) => Icon(switch (kind) {
        'error' => Icons.error_outline,
        'retry' => Icons.refresh,
        'url' => Icons.link,
        'file' => Icons.file_open_outlined,
        _ => Icons.note_add_outlined,
      }, color: kind == 'url' ? palette.remoteSource : palette.localSource),
      onSelected: (kind) {
        if (!_live(presentation)) return;
        switch (kind) {
          case 'retry':
            unawaited(controller.refresh());
          case 'error':
            final error = controller.configErrorMessage;
            if (error != null) {
              unawaited(
                _showDetails(
                  error.summary,
                  technicalDetail: error.technicalDetail,
                  title: (strings) => strings.configReadFailed,
                ),
              );
            }
          default:
            _add(kind, epoch);
        }
      },
      buttonBuilder: labeled
          ? (context, onPressed, focus) => FilledButton.icon(
              focusNode: focus,
              onPressed: onPressed,
              icon: const Icon(Icons.add),
              label: Text(strings.addConfig),
            )
          : null,
    );
  }

  Future<void> _add(String kind, int? storageEpoch) async {
    final presentation = _presentation;
    if (storageEpoch == null ||
        !_canResume(presentation) ||
        _adding ||
        !controller.canEdit) {
      return;
    }
    final strings = AppLocalizations.of(context);
    setState(() => _adding = true);
    try {
      if (kind == 'url') {
        await _showDialog<Map<String, Object?>>(
          builder: (dialogContext) => ImportDialog(
            isCurrent: () => _live(presentation),
            storageEpoch: storageEpoch,
            onSubmit: (input) async {
              if (!dialogContext.mounted ||
                  !AppTaskActivity.routeIsActive(
                    ModalRoute.of(dialogContext),
                  )) {
                return false;
              }
              if (!_live(presentation) || !controller.canEdit) {
                return false;
              }
              final receipt = await controller.submit({
                'action': 'import',
                ...input,
                'storageEpoch': storageEpoch,
              });
              return receipt != null;
            },
          ),
        );
      } else if (kind == 'new') {
        final name = await _showDialog<String>(
          builder: (dialogContext) => ConfigFieldDialog(
            isCurrent: () => _live(presentation),
            initial: strings.localConfig,
            title: (strings) => strings.newLocalConfig,
            confirmLabel: (strings) => strings.continueLabel,
          ),
        );
        if (!mounted || !_canResume(presentation) || name == null) {
          return;
        }
        if (name.isEmpty || configNameBytes(name) > maxConfigNameBytes) {
          await _showFeedback((strings) => strings.nameInvalid);
          return;
        }
        await Navigator.push<void>(
          context,
          FocusedPageRoute(
            builder: (_) => ConfigTextPage(
              app: controller,
              initialName: name,
              storageEpoch: storageEpoch,
            ),
          ),
        );
      } else {
        final file = await widget.selectFile();
        if (!mounted ||
            file == null ||
            !_canResume(presentation) ||
            storageEpoch != controller.storageEpoch ||
            storageEpoch != controller.state.storageEpoch) {
          return;
        }
        final body = await readConfigFile(file);
        if (!mounted ||
            !_canResume(presentation) ||
            storageEpoch != controller.storageEpoch ||
            storageEpoch != controller.state.storageEpoch) {
          return;
        }
        if (!controller.canEdit) {
          await _showFeedback((strings) => strings.operationBusyFile);
          return;
        }
        final result = await controller.saveLocal({
          'storageEpoch': storageEpoch,
          'name': configFileName(file.name),
          'body': body,
        }, feedbackOwner: _feedbackOwner);
        try {
          if (!mounted ||
              !_canResume(presentation) ||
              storageEpoch != controller.storageEpoch ||
              storageEpoch != controller.state.storageEpoch) {
            return;
          }
          if (result?.resultSuccess != true ||
              !const ['saved', 'applied'].contains(result?.configStatus)) {
            await _showMessage(
              result?.resultMessageDescription ??
                  controller.commandErrorMessage ??
                  messages.importResultUnconfirmed,
              onPresented: () => controller.acknowledgeLocalFeedback(
                _feedbackOwner,
                result: result,
              ),
            );
          }
        } finally {
          if (result?.resultSuccess == true &&
              const ['saved', 'applied'].contains(result?.configStatus)) {
            controller.acknowledgeLocalFeedback(_feedbackOwner, result: result);
          }
        }
      }
    } catch (error) {
      if (mounted &&
          _canResume(presentation) &&
          storageEpoch == controller.storageEpoch) {
        await _showMessage(
          error is ConfigFailure
              ? error.message
              : messages.fileUnreadable.withDetail(error),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _openText(ConfigEntry entry, int storageEpoch) {
    if (!_canResume(_presentation)) {
      return;
    }
    Navigator.push<void>(
      context,
      FocusedPageRoute(
        builder: (_) => ConfigTextPage(
          app: controller,
          entry: entry,
          storageEpoch: storageEpoch,
        ),
      ),
    );
  }

  Future<void> _changeText(
    ConfigEntry entry,
    int storageEpoch, {
    bool source = false,
  }) async {
    final presentation = _presentation;
    if (!_canResume(presentation)) {
      return;
    }
    final owner = controller;
    final pageRoute = _route;
    final taskCurrent = AppTaskActivity.capture(context);
    await _showDialog<String>(
      builder: (dialogContext) => ConfigFieldDialog(
        isCurrent: () => _live(presentation),
        initial: source ? entry.source! : entry.name,
        source: source,
        onSubmit: (value) async {
          if (!dialogContext.mounted ||
              !AppTaskActivity.routeIsActive(ModalRoute.of(dialogContext))) {
            return false;
          }
          if (!_live(presentation) || !controller.canEdit) {
            return false;
          }
          final editRoute = ModalRoute.of(dialogContext)!;
          bool readerCurrent({ModalRoute<dynamic>? popup}) =>
              mounted &&
              dialogContext.mounted &&
              identical(owner, controller) &&
              widget.active &&
              owner.foreground &&
              presentation == _presentation &&
              taskCurrent(ownedPopup: popup ?? editRoute) &&
              AppTaskActivity.routeIsActive(
                pageRoute,
                ownedPopup: popup ?? editRoute,
              ) &&
              AppTaskActivity.routeIsActive(editRoute, ownedPopup: popup);
          final previousCommand = owner.lastCommand;
          final pending = owner.submitAndWait({
            'action': source ? 'updateConfig' : 'renameConfig',
            ..._target(entry),
            if (source) 'source': value else 'name': value,
            'storageEpoch': storageEpoch,
          }, feedbackOwner: _feedbackOwner);
          final submitted = owner.lastCommand;
          var acknowledged = false;
          try {
            final result = await pending;
            if (submitted == null ||
                identical(previousCommand, submitted) ||
                !identical(owner.lastCommand, submitted) ||
                !readerCurrent()) {
              return false;
            }
            if (result?.resultSuccess == true &&
                const ['saved', 'applied'].contains(result?.configStatus) &&
                result?.targetId == entry.id &&
                result?.savedRevision != null) {
              owner.acknowledgeLocalFeedback(_feedbackOwner, result: result);
              acknowledged = owner.feedbackHandledLocally(
                submitted,
                submissionFailed: false,
                resultId: result?.resultId,
              );
              return true;
            }
            final message = result == null
                ? owner.commandErrorMessage
                : result.resultMessageDescription ??
                      messages.operationNotCompletedRetry;
            if (message == null) return false;

            if (!dialogContext.mounted) return false;
            await showAppNotice(
              dialogContext,
              message,
              isCurrent: () =>
                  identical(owner.lastCommand, submitted) && readerCurrent(),
              eligibilityChanges: owner,
              onPresented: () {
                owner.acknowledgeLocalFeedback(_feedbackOwner, result: result);
                acknowledged = owner.feedbackHandledLocally(
                  submitted,
                  submissionFailed: result == null,
                  resultId: result?.resultId,
                );
              },
              onDetails: () async {
                _readingFeedback = true;
                try {
                  await showAppMessage(
                    dialogContext,
                    message,
                    isCurrent: readerCurrent,
                    isCurrentWithPopup: (popup) =>
                        identical(owner.lastCommand, submitted) &&
                        readerCurrent(popup: popup),
                    eligibilityChanges: owner,
                    onRoute: (route) => _ownedPopup = route ?? editRoute,
                  );
                } finally {
                  _readingFeedback = false;
                  if (mounted) _syncOwner();
                }
              },
            );
            return false;
          } finally {
            if (mounted) {
              if (!acknowledged &&
                  !identical(previousCommand, submitted) &&
                  identical(owner.lastCommand, submitted)) {
                _feedbackOwner.value = false;
              }
            }
          }
        },
      ),
    );
  }

  Future<bool> _update(
    ConfigEntry entry,
    int storageEpoch, {
    String? source,
  }) async {
    final url = source ?? entry.source!;
    if (!_live(_presentation) || !controller.canEdit) {
      return false;
    }
    final accepted = await controller.submit({
      'action': 'updateConfig',
      ..._target(entry),
      'source': url,
      'storageEpoch': storageEpoch,
    });
    return accepted != null;
  }

  Future<void> _showEntryError(ConfigEntry entry) {
    final message = entry.errorMessage ?? messages.operationNotCompletedRetry;
    return _showDetails(
      message.summary,
      technicalDetail: message.technicalDetail,
      title: (strings) => strings.configActionFailed,
      subject: entry.name,
    );
  }

  Widget _tile(BuildContext context, ConfigEntry entry) {
    final entryEpoch = controller.storageEpoch;
    final presentation = _presentation;
    final eligible = _canResume(presentation);
    final selected = entry.id == controller.collection.selectedId;
    final running =
        controller.configsCurrent &&
        controller.state.running &&
        entry.id == controller.state.configId;
    final canSelect = eligible && controller.canEdit && !selected;
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = HomePalette.of(context);
    final titleStyle = theme.textTheme.titleMedium!.copyWith(
      fontWeight: FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final titleLineHeight =
        (MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
                (titleStyle.height ?? 1))
            .clamp(24.0, double.infinity);
    final oldBody = running && controller.state.revision != entry.revision;
    final status = running
        ? oldBody
              ? strings.runningOldBody
              : strings.runningConfig
        : null;
    final menuOptions = <String, String>{
      if (entry.errorMessage != null) 'error': strings.viewConfigError,
      'rename': strings.rename,
      if (entry.remote) ...{
        'source': strings.changeSourceUpdate,
        'auto': entry.update.enabled
            ? strings.autoUpdateHours(entry.update.hours)
            : strings.autoUpdateClosed,
        'view': strings.viewBody,
      },
      'delete': strings.delete,
    };
    final menuIcons = {
      'error': (Icons.error_outline, palette.error),
      'rename': (Icons.drive_file_rename_outline, palette.editAction),
      'source': (Icons.link, palette.syncAction),
      'auto': (Icons.update, palette.syncAction),
      'view': (Icons.description_outlined, palette.moreAction),
      'delete': (Icons.delete_outline, palette.error),
    };
    final disabledOptions = {
      for (final action in menuOptions.keys)
        if (!eligible ||
            (action != 'error' && !controller.canEdit) ||
            (action == 'delete' && running))
          action,
    };
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: entry.remote ? strings.updateConfig : strings.editConfig,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(48),
            foregroundColor: entry.remote
                ? palette.syncAction
                : palette.editAction,
          ),
          onPressed: eligible && controller.canEdit
              ? () {
                  if (!_canResume(presentation)) {
                    return;
                  }
                  if (entry.remote) {
                    _update(entry, entryEpoch);
                  } else {
                    _openText(entry, entryEpoch);
                  }
                }
              : null,
          icon: Icon(entry.remote ? Icons.refresh : Icons.edit_outlined),
        ),
        ChoiceMenuButton<String>(
          identity: (
            entryEpoch,
            entry.id,
            entry.revision,
            entry.source,
            entry.name,
          ),
          tooltip: strings.moreActions,
          options: menuOptions,
          disabledOptions: disabledOptions,
          leadingIcon: (action) {
            final (icon, color) = menuIcons[action]!;
            return Icon(
              icon,
              color: disabledOptions.contains(action) ? null : color,
            );
          },
          buttonBuilder: (context, onPressed, focus) => IconButton(
            tooltip: strings.moreActions,
            focusNode: focus,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(48),
              foregroundColor: palette.moreAction,
            ),
            onPressed: onPressed,
            icon: const Icon(Icons.more_vert),
          ),
          enabled:
              eligible && (controller.canEdit || entry.errorMessage != null),
          onSelected: (action) {
            if (!_canResume(presentation)) {
              return;
            }
            final epoch = entryEpoch;
            switch (action) {
              case 'error':
                _showEntryError(entry);
              case 'rename':
                _changeText(entry, epoch);
              case 'source':
                _changeText(entry, epoch, source: true);
              case 'auto':
                showAutoUpdateDialog(
                  context,
                  controller,
                  config: entry,
                  override: null,
                  storageEpoch: epoch,
                  isCurrent: () => _live(presentation),
                  onRoute: (route) => _ownedPopup = route,
                );
              case 'view':
                _openText(entry, epoch);
              case 'delete':
                _delete(context, entry, epoch);
            }
          },
        ),
      ],
    );
    final savedTime = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        _savedTime(context, entry),
        softWrap: false,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    return _ConfigSizeTransition(
      layoutMotion: _layoutMotion,
      child: Semantics(
        label: strings.selectConfig,
        selected: selected,
        child: Card(
          key: ValueKey('config-${entry.id}'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: InkWell(
            onTap: canSelect
                ? () {
                    if (!_canResume(presentation)) {
                      return;
                    }
                    controller.submit({
                      'action': 'select',
                      ..._target(entry),
                      'storageEpoch': entryEpoch,
                    });
                  }
                : null,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    height: titleLineHeight,
                    child: Tooltip(
                      message: status ?? entry.displaySource,
                      child: Icon(
                        running
                            ? (oldBody ? Icons.history : Icons.play_arrow)
                            : entry.remote
                            ? Icons.cloud_outlined
                            : Icons.description_outlined,
                        semanticLabel: status,
                        color: running
                            ? (oldBody ? palette.warning : palette.success)
                            : entry.remote
                            ? palette.remoteSource
                            : palette.localSource,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // Select layout from viewport and font constraints.
                        final compact =
                            constraints.maxWidth <
                            280 *
                                MediaQuery.textScalerOf(context).scale(14) /
                                14;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(entry.name, style: titleStyle),
                                ),
                                SizedBox(
                                  width: 48,
                                  height: titleLineHeight,
                                  child: selected
                                      ? Icon(Icons.check, color: colors.primary)
                                      : null,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Tooltip(
                              message: entry.displaySource,
                              child: Text(
                                entry.displaySource,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (compact) ...[
                              SizedBox(
                                width: double.infinity,
                                child: savedTime,
                              ),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: actions,
                              ),
                            ] else
                              Row(
                                children: [
                                  Expanded(child: savedTime),
                                  const SizedBox(width: 8),
                                  actions,
                                ],
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _savedTime(BuildContext context, ConfigEntry entry) {
    final strings = AppLocalizations.of(context);
    final time = entry.updatedAt?.toLocal();
    if (time == null) {
      return entry.remote ? strings.updateTimeUnknown : strings.saveTimeUnknown;
    }
    final locale = MaterialLocalizations.of(context);
    final date = locale.formatCompactDate(time);
    final clock = locale.formatTimeOfDay(TimeOfDay.fromDateTime(time));
    return entry.remote
        ? strings.updatedAt(date, clock)
        : strings.savedAt(date, clock);
  }

  Future<void> _delete(
    BuildContext context,
    ConfigEntry entry,
    int storageEpoch,
  ) async {
    final presentation = _presentation;
    if (!_canResume(presentation)) {
      return;
    }
    final selected = entry.id == controller.collection.selectedId;
    final accepted = await confirmAction(
      context,
      title: (strings) => strings.deleteConfigTitle,
      subject: entry.name,
      message: (strings) {
        final outcome = selected
            ? strings.deleteNoSelection
            : strings.deleteKeepsSelection;
        return '${entry.remote ? strings.deleteRemoteBody : strings.deleteLocalBody}\n\n$outcome';
      },
      confirmLabel: (strings) => strings.delete,
      isCurrent: () => _live(presentation),
      onRoute: (route) => _ownedPopup = route,
    );
    if (accepted && _canResume(presentation)) {
      await controller.submit({
        'action': 'delete',
        ..._target(entry),
        'storageEpoch': storageEpoch,
      });
    }
  }
}

// Reparent only the existing content when size animation is bypassed. A zero
// duration AnimatedSize can dirty its own layout while settling a changed child.
class _ConfigSizeTransition extends StatefulWidget {
  const _ConfigSizeTransition({required this.child, this.layoutMotion});
  final Widget child;
  final Animation<double>? layoutMotion;

  @override
  State<_ConfigSizeTransition> createState() => _ConfigSizeTransitionState();
}

class _ConfigSizeTransitionState extends State<_ConfigSizeTransition> {
  final _content = GlobalKey();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.layoutMotion ?? const AlwaysStoppedAnimation<double>(1),
    child: KeyedSubtree(key: _content, child: widget.child),
    builder: (context, child) {
      final status = widget.layoutMotion?.status;
      if (MediaQuery.disableAnimationsOf(context) ||
          status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        return child!;
      }
      return ExactSizeTransition(child: child!);
    },
  );
}

// ReadingList rows keep their final layout bounds during a card's paint motion.
// Route hits from the viewport to the visible card, retaining the intervening
// box targets so the existing Scrollable still receives the same pointer path.
class _ConfigGridHitRegion extends SingleChildRenderObjectWidget {
  const _ConfigGridHitRegion({required this.cards, required super.child});
  final Iterable<_ConfigCardMotionRender> Function() cards;

  @override
  _ConfigGridHitRender createRenderObject(BuildContext context) =>
      _ConfigGridHitRender(cards);

  @override
  void updateRenderObject(
    BuildContext context,
    _ConfigGridHitRender renderObject,
  ) {
    renderObject.cards = cards;
  }
}

class _ConfigGridHitRender extends RenderProxyBox {
  _ConfigGridHitRender(this.cards);
  Iterable<_ConfigCardMotionRender> Function() cards;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final global = localToGlobal(position);
    for (final card in cards().toList().reversed) {
      if (!card.attached ||
          !card.hasSize ||
          !card.moving ||
          !card.visualGlobalRect.contains(global)) {
        continue;
      }
      final ancestors = <RenderBox>[];
      RenderObject? ancestor = card.parent;
      var blocked = false;
      while (ancestor != null && !identical(ancestor, this)) {
        if ((ancestor is RenderIgnorePointer && ancestor.ignoring) ||
            (ancestor is RenderAbsorbPointer && ancestor.absorbing) ||
            (ancestor is RenderOffstage && ancestor.offstage)) {
          blocked = true;
          break;
        }
        if (ancestor is RenderBox) ancestors.add(ancestor);
        ancestor = ancestor.parent;
      }
      if (blocked || !identical(ancestor, this)) {
        continue;
      }
      final hit = result.addWithPaintTransform(
        transform: card.getTransformTo(this),
        position: position,
        hitTest: (result, position) => card.hitTestVisual(result, position),
      );
      if (!hit) {
        continue;
      }
      for (final box in ancestors) {
        result.addWithPaintTransform(
          transform: box.getTransformTo(this),
          position: position,
          hitTest: (result, position) {
            result.add(BoxHitTestEntry(box, position));
            return true;
          },
        );
      }
      return true;
    }
    return super.hitTestChildren(result, position: position);
  }
}

// A card keeps one render subtree when ReadingList regroups its keyed rows.
// Only its painted geometry interpolates; scroll and task authority stay live.
class _ConfigCardMotion extends SingleChildRenderObjectWidget {
  const _ConfigCardMotion({
    super.key,
    required this.animation,
    required this.origin,
    required this.layout,
    required this.scroll,
    required super.child,
  });
  final Animation<double> animation;
  final Rect? origin;
  final Object layout;
  final ScrollController scroll;

  @override
  _ConfigCardMotionRender createRenderObject(BuildContext context) =>
      _ConfigCardMotionRender(animation, origin, layout, scroll);

  @override
  void updateRenderObject(
    BuildContext context,
    _ConfigCardMotionRender renderObject,
  ) => renderObject.update(animation, origin, layout, scroll);
}

class _ConfigCardMotionRender extends RenderProxyBox {
  _ConfigCardMotionRender(
    this._animation,
    this._origin,
    this._layout,
    this._scroll,
  );
  Animation<double> _animation;
  Rect? _origin;
  Object _layout;
  ScrollController _scroll;
  double? _scrollAtLayout;
  Matrix4 _matrix = Matrix4.identity();

  bool get moving => _origin != null && _animation.value < 1;

  bool hitTestVisual(BoxHitTestResult result, Offset position) {
    if (!hitTestChildren(result, position: position)) {
      return false;
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  Rect get paintBounds => super.paintBounds.expandToInclude(
    MatrixUtils.transformRect(_matrix, super.paintBounds),
  );

  Rect get visualGlobalRect => child == null || !hasSize
      ? Rect.zero
      : MatrixUtils.transformRect(
          child!.getTransformTo(null),
          Offset.zero & child!.size,
        );

  void update(
    Animation<double> animation,
    Rect? origin,
    Object layout,
    ScrollController scroll,
  ) {
    if (!identical(animation, _animation)) {
      if (attached) _animation.removeListener(_tick);
      _animation = animation;
      if (attached) _animation.addListener(_tick);
    }
    if (_layout != layout || !identical(_origin, origin)) {
      _scrollAtLayout = null;
    }
    _origin = origin;
    _layout = layout;
    _scroll = scroll;
    _tick();
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _animation.addListener(_tick);
  }

  @override
  void detach() {
    _animation.removeListener(_tick);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!moving) {
      _matrix = Matrix4.identity();
      super.paint(context, offset);
      return;
    }
    final target = localToGlobal(Offset.zero) & size;
    final scroll = _scroll.hasClients ? _scroll.offset : 0.0;
    _scrollAtLayout ??= scroll;
    final origin = _origin?.shift(Offset(0, _scrollAtLayout! - scroll));
    final visual = origin == null
        ? target
        : Rect.lerp(
            origin,
            target,
            Curves.easeInOutCubic.transform(_animation.value),
          )!;
    _matrix =
        Matrix4.translationValues(
          visual.left - target.left,
          visual.top - target.top,
          0,
        )..multiply(
          Matrix4.diagonal3Values(
            size.width == 0 ? 1 : visual.width / size.width,
            size.height == 0 ? 1 : visual.height / size.height,
            1,
          ),
        );
    context.pushTransform(
      needsCompositing,
      offset,
      _matrix,
      (context, offset) => super.paint(context, offset),
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _matrix,
        position: position,
        hitTest: (result, position) =>
            child?.hitTest(result, position: position) ?? false,
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.multiply(_matrix);
}
