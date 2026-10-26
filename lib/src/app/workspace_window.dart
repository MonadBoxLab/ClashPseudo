import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'app_controller.dart';
import 'app_task.dart';

class WorkspaceScope extends InheritedWidget {
  const WorkspaceScope({
    super.key,
    required this.controller,
    required this.supported,
    required super.child,
  });

  final AppController controller;
  final bool supported;

  static WorkspaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();

  @override
  bool updateShouldNotify(WorkspaceScope oldWidget) =>
      supported != oldWidget.supported ||
      !identical(controller, oldWidget.controller);
}

class WorkspaceWindow extends StatefulWidget {
  const WorkspaceWindow({
    super.key,
    required this.controller,
    required this.child,
  });

  final AppController controller;
  final Widget child;

  @override
  State<WorkspaceWindow> createState() => _WorkspaceWindowState();
}

class _WorkspaceWindowState extends State<WorkspaceWindow> {
  Size _lastSize = const Size(320, 900);
  MediaQueryData? _lastMedia;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final supported = WorkspaceLayout.of(
        context,
        constraints.biggest,
      ).supported;
      final app = widget.controller;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(widget.controller, app)) {
          app.setWindowSupported(supported);
        }
      });
      if (supported) {
        _lastSize = constraints.biggest;
        _lastMedia = media;
      }
      return WorkspaceScope(
        controller: app,
        supported: supported,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: !supported,
              child: OverflowBox(
                minWidth: _lastSize.width,
                maxWidth: _lastSize.width,
                minHeight: _lastSize.height,
                maxHeight: _lastSize.height,
                child: MediaQuery(
                  data: supported
                      ? media
                      : (_lastMedia ?? media.copyWith(size: _lastSize)),
                  child: widget.child,
                ),
              ),
            ),
            if (!supported)
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Text(AppLocalizations.of(context).enlargeWindow),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
