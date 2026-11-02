import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../navigation/task_activity.dart';
import '../../../components/feedback/operation_notice.dart';
import 'form_interaction.dart';

part 'form_layout.dart';

class DefinitionFormChapter {
  const DefinitionFormChapter({
    required this.id,
    required this.title,
    required this.children,
    this.secondary = false,
    this.fullWidth = false,
    this.visible = true,
    this.initiallyExpanded = true,
  });

  final String id;
  final String title;
  final List<Widget> children;
  final bool secondary;
  final bool fullWidth;
  final bool visible;
  final bool initiallyExpanded;
}

class DefinitionFormBody extends StatefulWidget {
  static double _scale(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(14) / 14;

  static double widthOf(BuildContext context, {bool wide = true}) =>
      (wide ? 1600.0 : 840.0) * _scale(context);

  static bool validate(GlobalKey<FormState> key) {
    final form = key.currentState;
    if (form == null) return false;
    final body = form.context
        .findAncestorStateOfType<_DefinitionFormBodyState>();
    final version = body == null ? 0 : ++body._validation;
    if (body != null) body._validationReading = null;
    final errors = form.validateGranularly();
    if (errors.isEmpty) return true;
    Element? target;
    if (body != null) {
      for (final chapter in body.widget.chapters) {
        final context = body._chapters[chapter.id]?.currentContext;
        if (context is Element) target = _firstInvalid(context, errors);
        if (target != null) break;
      }
    }
    target ??= _firstInvalid(form.context as Element, errors);
    if (target != null) {
      unawaited(
        _revealError(
          target,
          form,
          () => body == null || body.mounted && body._validation == version,
        ),
      );
    }
    return false;
  }

  static Element? _firstInvalid(Element element, Set<FormFieldState> errors) {
    if (element is StatefulElement && errors.contains(element.state)) {
      return element;
    }
    Element? found;
    element.visitChildElements((child) {
      found ??= _firstInvalid(child, errors);
    });
    return found;
  }

  static Element? _editable(Element element) {
    final widget = element.widget;
    if (widget is EditableText &&
        !widget.readOnly &&
        widget.focusNode.canRequestFocus) {
      return element;
    }
    Element? found;
    element.visitChildElements((child) => found ??= _editable(child));
    return found;
  }

  static Element? _inputFor(BuildContext context) {
    if (context.widget is TextField) return context as Element;
    Element? found;
    context.visitAncestorElements((element) {
      if (element.widget is TextField) {
        found = element;
        return false;
      }
      return true;
    });
    return found;
  }

  static Future<void> _keepVisible(
    Element target,
    bool Function() current,
  ) async {
    if (!target.mounted || !current()) return;
    await Scrollable.ensureVisible(
      target,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    if (!target.mounted || !current()) return;
    await Scrollable.ensureVisible(
      target,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
  }

  static Future<void> _keepErrorVisible(
    Element reading,
    Element input,
    bool Function() current,
  ) async {
    if (!reading.mounted || !input.mounted || !current()) return;
    await Scrollable.ensureVisible(
      reading,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    await _keepVisible(input, current);
  }

  static void unfocusWithin(BuildContext owner) {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return;
    context.visitAncestorElements((element) {
      if (identical(element, owner)) {
        focus!.unfocus();
        return false;
      }
      return true;
    });
  }

  static Future<void> _revealError(
    Element target,
    FormState form,
    bool Function() owns,
  ) async {
    final body = form.context
        .findAncestorStateOfType<_DefinitionFormBodyState>();
    final route = ModalRoute.of(target);
    bool current() =>
        owns() &&
        form.mounted &&
        target.mounted &&
        AppTaskActivity.isActive(target) &&
        AppTaskActivity.routeIsActive(route);
    if (!current()) return;
    final sections = <ExpansibleController>{};
    void include(BuildContext context) {
      final controller = ExpansibleController.maybeOf(context);
      if (controller != null) sections.add(controller);
    }

    include(target);
    void includeBody(Element element) {
      final widget = element.widget;
      if (widget is Expansible) {
        sections.add(widget.controller);
      } else {
        element.visitChildElements(includeBody);
      }
    }

    includeBody(target);
    target.visitAncestorElements((element) {
      if (element == form.context) return false;
      include(element);
      return true;
    });
    final expanding = sections.any((controller) => !controller.isExpanded);
    final reduced =
        MediaQuery.disableAnimationsOf(target) ||
        MediaQuery.accessibleNavigationOf(target);
    Future<Duration> nextLayoutFrame() {
      final completed = Completer<Duration>();
      final binding = WidgetsBinding.instance;
      binding.addPostFrameCallback(completed.complete);
      binding.scheduleFrame();
      return completed.future;
    }

    for (final controller in sections.toList().reversed) {
      controller.expand();
    }
    var frameTime = await nextLayoutFrame();
    final animationStart = frameTime;
    // A tap/shortcut and an async continuation may both run outside a frame.
    // Use callback timestamps, after layout, rather than a frame-only getter.
    while (expanding &&
        !reduced &&
        current() &&
        frameTime - animationStart < const Duration(milliseconds: 180)) {
      frameTime = await nextLayoutFrame();
    }
    if (!current()) return;
    var reading = target;
    final nested = target
        .findAncestorWidgetOfExactType<DefinitionValidationTarget>();
    if (nested != null) {
      final context = await nested.reveal();
      if (context is! Element || !current() || !context.mounted) return;
      reading = context;
    }
    final editing = _editable(reading);
    final input = editing == null ? reading : _inputFor(editing) ?? editing;
    if (!DefinitionFormInteraction.canAct(input)) return;
    await _keepErrorVisible(reading, input, current);
    if (!current() || editing?.mounted == false) return;
    if (editing?.widget case final EditableText widget) {
      body?._validationReading = (target: reading, focus: widget.focusNode);
      widget.focusNode.requestFocus();
    }
    final field = (target as StatefulElement).state as FormFieldState;
    final message = field.errorText;
    if (message != null) {
      await showLocalizedOperationNotice(
        target,
        (_) => message,
        identity: (form, body?._validation),
        isCurrent: () =>
            current() && field.mounted && field.errorText == message,
      );
    }
  }

  static Future<BuildContext?> revealListRow({
    required BuildContext context,
    required ScrollController controller,
    required int index,
    required int count,
    required Key rowKey,
  }) async {
    if (!context.mounted ||
        !controller.hasClients ||
        index < 0 ||
        index >= count) {
      return null;
    }
    Element? find(Element element) {
      if (element.widget.key == rowKey) return element;
      Element? found;
      element.visitChildElements((child) => found ??= find(child));
      return found;
    }

    final owner = context as Element;
    var row = find(owner);
    if (row == null) {
      final position = controller.position;
      final extent =
          (position.maxScrollExtent + position.viewportDimension) / count;
      position.jumpTo(
        (index * extent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!owner.mounted) return null;
      row = find(owner);
    }
    Element? invalid;
    if (row != null) {
      void validate(Element element) {
        if (element is StatefulElement && element.state is FormFieldState) {
          final field = element.state as FormFieldState;
          if (!field.validate()) invalid ??= element;
        }
        element.visitChildElements(validate);
      }

      validate(row);
    }
    return invalid ?? row;
  }

  const DefinitionFormBody({
    super.key,
    required this.form,
    required this.controller,
    this.chapters = const [],
    this.children,
    this.header,
    this.scrollKey,
    this.onChanged,
  });

  final GlobalKey<FormState> form;
  final ScrollController controller;
  final List<DefinitionFormChapter> chapters;
  final List<Widget>? children;
  final Widget? header;
  final Key? scrollKey;
  final VoidCallback? onChanged;

  static double collectionHeightOf(BuildContext context) {
    final viewport = context
        .dependOnInheritedWidgetOfExactType<_DefinitionFormViewport>()!;
    final height = viewport.height;
    return (height / 2).clamp(math.min(144.0, height), math.min(480.0, height));
  }

  @override
  State<DefinitionFormBody> createState() => _DefinitionFormBodyState();
}

class DefinitionValidationTarget extends InheritedWidget {
  const DefinitionValidationTarget({
    super.key,
    required this.reveal,
    required super.child,
  });

  final Future<BuildContext?> Function() reveal;

  @override
  bool updateShouldNotify(DefinitionValidationTarget oldWidget) => false;
}

class _DefinitionFormBodyState extends State<DefinitionFormBody> {
  var _validation = 0;
  ({Element target, FocusNode focus})? _validationReading;
  final _chapters = <String, GlobalKey>{};
  Object? _layout;
  var _layoutVersion = 0;

  void _trackLayout(BoxConstraints bounds) {
    final next = (
      bounds.biggest,
      MediaQuery.textScalerOf(context),
      Localizations.localeOf(context),
    );
    if (_layout == next) return;
    _layout = next;
    unawaited(_restoreFocus(++_layoutVersion));
  }

  Future<void> _restoreFocus(int version) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    bool current() =>
        mounted &&
        version == _layoutVersion &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (!current()) return;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null ||
        !focus.mounted ||
        focus.findAncestorStateOfType<_DefinitionFormBodyState>() != this) {
      return;
    }
    final input = DefinitionFormBody._inputFor(focus);
    if (input == null) return;
    final reading = _validationReading;
    if (reading != null && reading.target.mounted && reading.focus.hasFocus) {
      await DefinitionFormBody._keepErrorVisible(
        reading.target,
        input,
        current,
      );
    } else {
      _validationReading = null;
      await DefinitionFormBody._keepVisible(input, current);
    }
  }

  static const _padding = EdgeInsets.fromLTRB(20, 8, 20, 16);
  static const _gap = 24.0;

  Widget _chapter(DefinitionFormChapter chapter) => KeyedSubtree(
    key: _chapters.putIfAbsent(chapter.id, GlobalKey.new),
    child: FocusTraversalGroup(
      child: Card.filled(
        margin: EdgeInsets.zero,
        child: DefinitionFormExpansion(
          key: ValueKey('definition-chapter:${chapter.id}'),
          maintainState: true,
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: chapter.initiallyExpanded,
          onExpansionChanged: (expanded) {
            final owner = _chapters[chapter.id]?.currentContext;
            if (!expanded && owner != null) {
              DefinitionFormBody.unfocusWithin(owner);
            }
          },
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Semantics(
            header: true,
            child: Text(
              chapter.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          children: chapter.children,
        ),
      ),
    ),
  );

  Widget _section(DefinitionFormChapter chapter) => DefinitionFormVisibility(
    key: ValueKey('definition-section:${chapter.id}'),
    visible: chapter.visible,
    child: Padding(
      padding: const EdgeInsets.only(bottom: _gap),
      child: _chapter(chapter),
    ),
  );

  Widget _column(Iterable<DefinitionFormChapter> chapters) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [for (final chapter in chapters) _section(chapter)],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildViewport);

  Widget _buildViewport(BuildContext context, BoxConstraints viewport) {
    _trackLayout(viewport);
    return _DefinitionFormViewport(
      height: math.max(0, viewport.maxHeight - _padding.vertical),
      child: SingleChildScrollView(
        key: widget.scrollKey,
        controller: widget.controller,
        padding: _padding,
        child: Form(
          key: widget.form,
          onChanged: () {
            _validationReading = null;
            widget.onChanged?.call();
          },
          child: LayoutBuilder(
            builder: (context, bounds) {
              final scale = DefinitionFormBody._scale(context);
              final primaryMinimum = 320 * scale;
              final secondaryMinimum = 480 * scale;
              final maximumWidth = DefinitionFormBody.widthOf(context);
              final columnWidth = math.min(bounds.maxWidth, maximumWidth);
              final capacity = _definitionColumnsCapacity(
                columnWidth,
                primaryMinimum,
                secondaryMinimum,
                _gap,
              );
              final regular = widget.chapters.where((item) => !item.fullWidth);
              final secondary = regular.where((item) => item.secondary);
              final wide =
                  secondary.any((item) => item.visible) &&
                  regular.any((item) => !item.secondary && item.visible) &&
                  columnWidth >= primaryMinimum + secondaryMinimum + _gap;
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maximumWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.header case final header?) ...[
                        header,
                        const SizedBox(height: 16),
                      ],
                      ...?widget.children,
                      _DefinitionColumnsMotion(
                        target: wide ? capacity : 0.0,
                        capacity: capacity,
                        reduced:
                            MediaQuery.disableAnimationsOf(context) ||
                            MediaQuery.accessibleNavigationOf(context),
                        onEnd: () => unawaited(_restoreFocus(++_layoutVersion)),
                        builder: (context, progress, _) => _DefinitionColumns(
                          progress: progress,
                          primaryMinimum: primaryMinimum,
                          capacity: capacity,
                          gap: _gap,
                          direction: Directionality.of(context),
                          secondary: [
                            for (final chapter in regular) chapter.secondary,
                          ],
                          children: [
                            for (final chapter in regular) _section(chapter),
                          ],
                        ),
                      ),
                      _column(widget.chapters.where((item) => item.fullWidth)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
