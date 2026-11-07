import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/app_localizations.dart';
import '../../../model/app_message.dart';
import '../../app/app_controller.dart';
import '../../locale/message_text.dart';
import '../../navigation/route_observer.dart';
import '../../navigation/task_activity.dart';
import '../../navigation/workspace_window.dart';
import 'operation_feedback.dart';

final _fallbackNotices = Expando<_Notice>();

Future<bool> showAppNotice(
  BuildContext context,
  AppMessage message, {
  String Function(AppLocalizations)? title,
  String? subject,
  bool error = true,
  bool? persist,
  bool Function()? isCurrent,
  bool Function()? canPresent,
  bool Function(ModalRoute<dynamic>)? isCurrentWithPopup,
  Listenable? eligibilityChanges,
  Future<void> Function()? onDetails,
  Future<void> Function()? onRetry,
  Object? identity,
  VoidCallback? onPresented,
  ValueChanged<SnackBarClosedReason>? onClosed,
}) => showLocalizedOperationNotice(
  context,
  message.summary,
  technicalDetail: message.technicalDetail,
  title: title,
  subject: subject,
  error: error,
  persist: persist,
  isCurrent: isCurrent,
  canPresent: canPresent,
  isCurrentWithPopup: isCurrentWithPopup,
  eligibilityChanges: eligibilityChanges,
  onDetails: onDetails,
  onRetry: onRetry,
  identity: identity,
  onPresented: onPresented,
  onClosed: onClosed,
);

/// [isCurrent] tracks source validity; [canPresent] only pauses presentation.
Future<bool> showLocalizedOperationNotice(
  BuildContext context,
  String Function(AppLocalizations) summary, {
  String? Function(AppLocalizations)? technicalDetail,
  String Function(AppLocalizations)? title,
  String? subject,
  bool error = true,
  bool? persist,
  bool Function()? isCurrent,
  bool Function()? canPresent,
  bool Function(ModalRoute<dynamic>)? isCurrentWithPopup,
  Listenable? eligibilityChanges,
  Future<void> Function()? onDetails,
  Future<void> Function()? onRetry,
  Object? identity,
  VoidCallback? onPresented,
  ValueChanged<SnackBarClosedReason>? onClosed,
}) async {
  if (!context.mounted) return false;
  final route = ModalRoute.of(context);
  final taskCurrent = AppTaskActivity.capture(context);
  final sourceCurrent = AppTaskActivity.captureSource(context);
  final owner =
      AppTaskScope.maybeOf(context)?.owner ??
      WorkspaceScope.maybeOf(context)?.controller;
  bool sourceValid() {
    if (!context.mounted ||
        !sourceCurrent() ||
        (route != null &&
            (!route.isActive ||
                route.animation?.status == AnimationStatus.reverse))) {
      return false;
    }
    if (isCurrent?.call() ?? true) return true;
    final popup = route == null
        ? null
        : AppTaskNavigatorObserver.coveringPopup(route);
    return popup != null && isCurrentWithPopup?.call(popup) == true;
  }

  bool current() =>
      sourceValid() &&
      AppTaskActivity.routeIsActive(route) &&
      taskCurrent() &&
      (owner is! AppController || owner.interactive) &&
      (canPresent?.call() ?? true) &&
      (isCurrent?.call() ?? true);
  if (!sourceValid()) return false;
  final notice = _Notice(
    context: context,
    route: route,
    summary: summary,
    technicalDetail: technicalDetail,
    title: title,
    subject: subject,
    error: error,
    persist: persist ?? error,
    sourceValid: sourceValid,
    eligible: current,
    isCurrentWithPopup: (popup) =>
        context.mounted &&
        AppTaskActivity.routeIsActive(route, ownedPopup: popup) &&
        taskCurrent(ownedPopup: popup) &&
        (owner is! AppController || owner.interactive) &&
        (isCurrentWithPopup?.call(popup) ?? isCurrent?.call() ?? true),
    changes: Listenable.merge([
      if (owner is AppController) owner,
      if (eligibilityChanges != null && !identical(eligibilityChanges, owner))
        eligibilityChanges,
      AppTaskNavigatorObserver.changesFor(route),
      ?route?.animation,
    ]),
    onDetails: onDetails,
    onRetry: onRetry,
    identity: identity,
    onPresented: onPresented,
    onClosed: onClosed,
  );
  final host = context.findAncestorStateOfType<_OperationNoticeHostState>();
  if (host != null) return host.show(notice);
  if (owner is AppController && !await owner.waitUntilInteractive()) {
    return false;
  }
  if (!context.mounted || !current()) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return false;
  final media = MediaQuery.of(context);
  if (!notice.fits(
    context,
    media.size.width - 32,
    media.size.height - media.viewInsets.bottom - media.padding.vertical,
  )) {
    return false;
  }
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? handle;
  var closed = false;
  var closing = false;
  void changed() {
    if (notice.current() || closing || closed) return;
    closing = true;
    notice.finish();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!closed &&
          messenger.mounted &&
          identical(_fallbackNotices[messenger], notice)) {
        handle?.close();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  notice.changes.addListener(changed);
  _fallbackNotices[messenger]?.finish();
  _fallbackNotices[messenger] = notice;
  messenger.removeCurrentSnackBar();
  handle = messenger.showSnackBar(notice.snackBar(changed));
  unawaited(
    handle.closed.then((reason) {
      closed = true;
      if (identical(_fallbackNotices[messenger], notice)) {
        _fallbackNotices[messenger] = null;
      }
      notice.changes.removeListener(changed);
      notice.finish();
      if (!notice.viewingDetails) notice.notifyClosed(reason);
    }),
  );
  return notice.presented.future;
}

class OperationNoticeHost extends StatefulWidget {
  const OperationNoticeHost({
    super.key,
    required this.child,
    this.onDismiss,
    this.shrinkWrap = false,
  }) : assert(!shrinkWrap || onDismiss == null);

  final Widget child;
  final VoidCallback? onDismiss;
  final bool shrinkWrap;

  @override
  State<OperationNoticeHost> createState() => _OperationNoticeHostState();
}

class _OperationNoticeHostState extends State<OperationNoticeHost> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _pending = <_Notice>[];
  _Notice? _notice;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _handle;
  Size _available = Size.zero;
  bool _scheduled = false;

  Future<bool> show(_Notice notice) {
    if (notice.identity != null) {
      for (final previous in [?_notice, ..._pending]) {
        if (previous.identity == notice.identity &&
            (previous.viewingDetails || previous.current())) {
          return previous.presented.future;
        }
      }
    }
    _pending.add(notice);
    notice.changes.addListener(_schedule);
    _schedule();
    return notice.presented.future;
  }

  void _retire() {
    final notice = _notice;
    final handle = _handle;
    _notice = null;
    _handle = null;
    if (notice != null) {
      notice.changes.removeListener(_schedule);
      notice.finish();
      if (handle != null) _messenger.currentState?.removeCurrentSnackBar();
    }
  }

  void _schedule() {
    for (final notice in List<_Notice>.of(_pending)) {
      if (!notice.current()) {
        _pending.remove(notice);
        notice.changes.removeListener(_schedule);
        notice.finish();
      }
    }
    if (_notice?.viewingDetails != true) _notice?.current();
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (_notice == null && _pending.isNotEmpty) {
        _notice = _pending.removeAt(0);
      }
      final notice = _notice;
      if (notice == null || notice.viewingDetails) return;
      if (!notice.current()) {
        _retire();
        _schedule();
        return;
      }
      final fits = notice.fits(context, _available.width, _available.height);
      if (!fits || !notice.eligible()) {
        if (_handle != null) {
          _handle = null;
          _messenger.currentState?.removeCurrentSnackBar();
        }
        return;
      }
      if (_handle != null) return;
      final messenger = _messenger.currentState;
      if (messenger == null) return;
      final handle = messenger.showSnackBar(
        notice.snackBar(_schedule, key: widget.shrinkWrap ? notice._key : null),
      );
      _handle = handle;
      unawaited(
        handle.closed.then((reason) {
          if (!mounted || !identical(_handle, handle)) return;
          _handle = null;
          if (notice.viewingDetails) return;
          notice.notifyClosed(reason);
          if (identical(_notice, notice)) {
            _retire();
            _schedule();
          }
        }),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.shrinkWrap) {
      return Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: _NoticeHitRegion(
              snackBarKey: () => _notice?._key,
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _surface(context, constraints, overlay: true),
              ),
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(builder: _surface);
  }

  Widget _surface(
    BuildContext context,
    BoxConstraints constraints, {
    bool overlay = false,
  }) {
    final media = MediaQuery.of(context);
    final width = math.max(
      0.0,
      math.min(560.0, constraints.maxWidth - media.padding.horizontal - 32),
    );
    _available = Size(
      width,
      math.max(
        0.0,
        constraints.maxHeight -
            media.viewInsets.bottom -
            media.padding.vertical,
      ),
    );
    final fits = _notice?.fits(context, width, _available.height) ?? true;
    if (_notice != null) _schedule();
    final horizontal = math.max(
      0.0,
      (constraints.maxWidth - width - media.padding.horizontal) / 2,
    );
    return MediaQuery(
      data: media.copyWith(size: constraints.biggest),
      child: Theme(
        data: Theme.of(context).copyWith(
          snackBarTheme: Theme.of(context).snackBarTheme.copyWith(
            behavior: SnackBarBehavior.floating,
            insetPadding: fits
                ? EdgeInsets.fromLTRB(horizontal, 0, horizontal, 12)
                : EdgeInsets.zero,
          ),
        ),
        child: ScaffoldMessenger(
          key: _messenger,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: overlay
                ? const SizedBox.shrink()
                : Theme(
                    data: Theme.of(context),
                    child: widget.onDismiss == null
                        ? widget.child
                        : Actions(
                            actions: {
                              DismissIntent: CallbackAction<DismissIntent>(
                                onInvoke: (_) {
                                  widget.onDismiss?.call();
                                  return null;
                                },
                              ),
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ModalBarrier(onDismiss: widget.onDismiss),
                                widget.child,
                              ],
                            ),
                          ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final notice in [?_notice, ..._pending]) {
      notice.changes.removeListener(_schedule);
      notice.finish();
    }
    super.dispose();
  }
}

class _NoticeHitRegion extends SingleChildRenderObjectWidget {
  const _NoticeHitRegion({required this.snackBarKey, required super.child});

  final GlobalKey? Function() snackBarKey;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNoticeHitRegion(snackBarKey);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNoticeHitRegion renderObject,
  ) => renderObject.snackBarKey = snackBarKey;
}

class _RenderNoticeHitRegion extends RenderProxyBox {
  _RenderNoticeHitRegion(this.snackBarKey);

  GlobalKey? Function() snackBarKey;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final box = snackBarKey()?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final local = box.globalToLocal(localToGlobal(position));
    if (!(Offset.zero & box.size).contains(local)) return false;
    return super.hitTest(result, position: position);
  }
}

class _Notice {
  _Notice({
    required this.context,
    required this.route,
    required this.summary,
    required this.technicalDetail,
    required this.title,
    required this.subject,
    required this.error,
    required this.persist,
    required this.sourceValid,
    required this.eligible,
    required this.isCurrentWithPopup,
    required this.changes,
    required this.onDetails,
    required this.onRetry,
    required this.identity,
    required this.onPresented,
    required this.onClosed,
  });

  final BuildContext context;
  final ModalRoute<dynamic>? route;
  final String Function(AppLocalizations) summary;
  final String? Function(AppLocalizations)? technicalDetail;
  final String Function(AppLocalizations)? title;
  final String? subject;
  final bool error;
  final bool persist;
  final bool Function() sourceValid;
  final bool Function() eligible;
  bool _retired = false;
  bool viewingDetails = false;

  bool current() {
    if (!_retired && !sourceValid()) _retired = true;
    return !_retired;
  }

  final bool Function(ModalRoute<dynamic>)? isCurrentWithPopup;
  final Listenable changes;
  final Future<void> Function()? onDetails;
  final Future<void> Function()? onRetry;
  final Object? identity;
  final VoidCallback? onPresented;
  final ValueChanged<SnackBarClosedReason>? onClosed;
  final _key = GlobalKey();
  final presented = Completer<bool>();
  bool _closed = false;

  void notifyClosed(SnackBarClosedReason reason) {
    if (_closed) return;
    _closed = true;
    onClosed?.call(reason);
  }

  String text(AppLocalizations strings) =>
      subject == null ? summary(strings) : '$subject\n${summary(strings)}';

  bool hasDetails(AppLocalizations strings) =>
      error ||
      onDetails != null ||
      (technicalDetail?.call(strings)?.isNotEmpty ?? false);

  bool fits(BuildContext context, double width, double height) {
    if (width < 80 || height <= 0) return false;
    final strings = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    final painter = TextPainter(
      text: TextSpan(text: text(strings), style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1, width - 32));
    final textHeight = painter.height;
    painter.dispose();
    final actionStyle = Theme.of(context).textTheme.labelLarge!;
    var actionHeight = 48.0;
    var actionWidth = 48.0;
    for (final label in [
      if (hasDetails(strings)) strings.errorDetails,
      if (onRetry != null) strings.retry,
    ]) {
      final action = TextPainter(
        text: TextSpan(text: label, style: actionStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: math.max(1, width - 64));
      final buttonWidth = math.max(48.0, action.width + 32);
      final buttonHeight = math.max(48.0, action.height + 16);
      if (actionWidth + buttonWidth > width - 32) {
        actionHeight += buttonHeight;
        actionWidth = buttonWidth;
      } else {
        actionHeight = math.max(actionHeight, buttonHeight);
        actionWidth += buttonWidth;
      }
      action.dispose();
    }
    return height >= textHeight + actionHeight + 56;
  }

  void finish() {
    _retired = true;
    if (!presented.isCompleted) presented.complete(false);
  }

  void _acknowledgePaintedFrame(BuildContext noticeContext) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!noticeContext.mounted ||
          !current() ||
          !eligible() ||
          presented.isCompleted) {
        return;
      }
      final render = noticeContext.findRenderObject();
      if (render is! RenderBox ||
          !render.attached ||
          !render.hasSize ||
          render.size.isEmpty) {
        return;
      }
      var opacity = 1.0;
      var visible = true;
      for (RenderObject? node = render; node != null; node = node.parent) {
        if (node is RenderOffstage && node.offstage) visible = false;
        if (node is RenderOpacity) opacity *= node.opacity;
        if (node is RenderAnimatedOpacity) opacity *= node.opacity.value;
      }
      if (!visible || (opacity * 255).round() == 0) {
        _acknowledgePaintedFrame(noticeContext);
        return;
      }
      presented.complete(true);
      onPresented?.call();
    });
  }

  SnackBar snackBar(VoidCallback changed, {Key? key}) => SnackBar(
    key: key,
    persist: persist,
    behavior: SnackBarBehavior.floating,
    padding: EdgeInsets.zero,
    content: Builder(
      builder: (noticeContext) => LayoutBuilder(
        builder: (noticeContext, constraints) {
          final media = MediaQuery.of(noticeContext);
          if (!current() ||
              !eligible() ||
              !fits(
                noticeContext,
                constraints.maxWidth,
                media.size.height -
                    media.viewInsets.bottom -
                    media.padding.vertical,
              )) {
            changed();
            return const SizedBox.shrink();
          }
          if (!presented.isCompleted) _acknowledgePaintedFrame(noticeContext);
          final strings = AppLocalizations.of(noticeContext);
          final colors = Theme.of(noticeContext).colorScheme;
          void close() {
            if (!current() || !eligible()) {
              changed();
              return;
            }
            ScaffoldMessenger.of(noticeContext)
                .hideCurrentSnackBar(reason: SnackBarClosedReason.action);
          }

          Future<void> details() async {
            if (!current() || !eligible()) return;
            viewingDetails = true;
            close();
            changed();
            try {
              if (onDetails case final show?) {
                await show();
              } else {
                await showLocalizedOperationMessage(
                  context,
                  summary,
                  technicalDetail: technicalDetail,
                  title: title ?? (strings) => strings.errorDetails,
                  subject: subject,
                  error: error,
                  isCurrent: eligible,
                  isCurrentWithPopup: isCurrentWithPopup,
                  eligibilityChanges: changes,
                  onRetry: onRetry,
                );
              }
            } finally {
              viewingDetails = false;
              finish();
              notifyClosed(SnackBarClosedReason.action);
              changed();
            }
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  text(strings),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(noticeContext).textTheme.bodyMedium!
                      .copyWith(color: colors.onInverseSurface),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (hasDetails(strings))
                      TextButton(
                        onPressed: () => unawaited(details()),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.inversePrimary,
                          minimumSize: const Size(48, 48),
                        ),
                        child: Text(strings.errorDetails),
                      ),
                    if (onRetry != null)
                      TextButton(
                        onPressed: () {
                          if (!current() || !eligible()) return;
                          close();
                          unawaited(onRetry!());
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: colors.inversePrimary,
                          minimumSize: const Size(48, 48),
                        ),
                        child: Text(strings.retry),
                      ),
                    IconButton(
                      onPressed: close,
                      tooltip: MaterialLocalizations.of(noticeContext)
                          .closeButtonTooltip,
                      color: colors.onInverseSurface,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
