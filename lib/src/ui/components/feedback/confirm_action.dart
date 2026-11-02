import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../l10n/app_localizations.dart';
import '../../navigation/task_activity.dart';
import '../../navigation/route_observer.dart';

Future<bool> confirmAction(
  BuildContext context, {
  required String Function(AppLocalizations) title,
  required String Function(AppLocalizations) message,
  required String Function(AppLocalizations) confirmLabel,
  String Function(AppLocalizations)? cancelLabel,
  String? subject,
  Widget Function(BuildContext, StateSetter)? contentBuilder,
  bool Function()? canConfirm,
  Listenable? eligibilityChanges,
  ValueChanged<ModalRoute<dynamic>?>? onRoute,
  bool Function()? isCurrent,
}) async {
  final origin = context;
  final originRoute = ModalRoute.of(origin);
  final taskCurrent = AppTaskActivity.capture(origin);
  ModalRoute<dynamic>? ownedPopup;
  bool structuralOwnerCurrent() =>
      origin.mounted &&
      AppTaskActivity.routeIsActive(originRoute, ownedPopup: ownedPopup) &&
      taskCurrent(ownedPopup: ownedPopup);
  bool ownerCurrent() =>
      structuralOwnerCurrent() && (isCurrent?.call() ?? true);
  if (!ownerCurrent() || originRoute?.isCurrent == false) return false;
  final navigator = Navigator.of(context, rootNavigator: true);
  var retired = false;
  var retirementScheduled = false;
  VoidCallback? checkCurrent;
  final dialogRoute = DialogRoute<bool>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: Theme.of(context).dialogTheme.barrierColor ?? Colors.black54,
    animationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    builder: (context) {
      final route = ModalRoute.of(context)!;
      final animation = route.animation!;
      void retire() {
        if (!retired ||
            retirementScheduled ||
            !route.isActive ||
            animation.status == AnimationStatus.reverse) {
          return;
        }
        final navigator = route.navigator;
        if (navigator == null) return;
        retirementScheduled = true;
        void dismiss() {
          if (!navigator.mounted ||
              !route.isActive ||
              !identical(route.navigator, navigator) ||
              animation.status == AnimationStatus.reverse) {
            return;
          }
          if (route.isCurrent) {
            navigator.pop(false);
          } else {
            navigator.removeRoute(route);
          }
        }

        if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
          dismiss();
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
          WidgetsBinding.instance.ensureVisualUpdate();
        }
      }

      bool eligible() {
        final cover = AppTaskNavigatorObserver.coveringPopup(route);
        final paused =
            !retired &&
            context.mounted &&
            origin.mounted &&
            identical(route, ownedPopup) &&
            animation.status != AnimationStatus.reverse &&
            cover != null &&
            AppTaskActivity.routeIsActive(originRoute, ownedPopup: cover) &&
            taskCurrent(ownedPopup: cover);
        if (paused) return false;
        final sourceExpired =
            !retired && structuralOwnerCurrent() && isCurrent?.call() == false;
        if (!retired &&
            !(context.mounted &&
                ownerCurrent() &&
                identical(route, ownedPopup) &&
                route.isActive &&
                route.isCurrent &&
                animation.status != AnimationStatus.reverse)) {
          retired = true;
        }
        if (retired && (eligibilityChanges != null || sourceExpired)) {
          retire();
        }
        return !retired;
      }

      checkCurrent = () => eligible();
      ModalRoute.isCurrentOf(context);
      return StatefulBuilder(
        builder: (context, change) => AnimatedBuilder(
          animation: Listenable.merge([animation, eligibilityChanges]),
          builder: (context, _) {
            final active = eligible();
            void close(bool accepted) {
              if (!eligible() || accepted && !(canConfirm?.call() ?? true)) {
                return;
              }
              Navigator.pop(context, accepted);
              retired = true;
            }

            final strings = AppLocalizations.of(context);
            return IgnorePointer(
              ignoring: !active,
              child: ExcludeFocus(
                excluding: !active,
                child: ExcludeSemantics(
                  excluding: !active,
                  child: AlertDialog(
                    scrollable: true,
                    titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                    contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    title: Text(title(strings)),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (subject != null) ...[
                          SelectableText(
                            subject,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                        ],
                        SelectableText(message(strings)),
                        if (contentBuilder != null)
                          contentBuilder(context, (update) {
                            if (eligible()) change(update);
                          }),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: active ? () => close(false) : null,
                        child: Text(
                          cancelLabel?.call(strings) ?? strings.cancel,
                        ),
                      ),
                      FilledButton(
                        onPressed: active && (canConfirm?.call() ?? true)
                            ? () => close(true)
                            : null,
                        child: Text(confirmLabel(strings)),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
  void eligibilityChanged() {
    final check = checkCurrent;
    if (check != null) {
      check();
    } else if (!ownerCurrent()) {
      retired = true;
    }
  }

  eligibilityChanges?.addListener(eligibilityChanged);
  ownedPopup = dialogRoute;
  final bool? accepted;
  try {
    onRoute?.call(dialogRoute);
    accepted = await navigator.push(dialogRoute);
  } finally {
    eligibilityChanges?.removeListener(eligibilityChanged);
    ownedPopup = null;
    onRoute?.call(null);
  }
  return accepted == true && ownerCurrent() && (originRoute?.isCurrent ?? true);
}
