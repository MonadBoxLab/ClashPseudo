import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../../model/messages.dart';
import '../../navigation/task_activity.dart';
import '../feedback/operation_notice.dart';
import 'technical_reading_pane.dart';

/// Displays text in chunks without changing content or line breaks, or splitting UTF-16
/// surrogate pairs.
List<int> originalTextChunkEnds(String text) {
  final ends = <int>[];
  var start = 0;
  while (start < text.length) {
    var end = min(start + 8192, text.length);
    if (end < text.length) {
      final newline = text.lastIndexOf('\n', end - 1);
      if (newline >= start) {
        end = newline + 1;
      } else {
        final before = text.codeUnitAt(end - 1);
        final after = text.codeUnitAt(end);
        if (before >= 0xd800 &&
                before <= 0xdbff &&
                after >= 0xdc00 &&
                after <= 0xdfff ||
            before == 13 && after == 10) {
          end--;
        }
      }
    }
    ends.add(end);
    start = end;
  }
  return ends;
}

class OriginalTextView extends StatefulWidget {
  const OriginalTextView({
    super.key,
    required this.text,
    this.displayText,
    this.scrollController,
    this.header,
    this.identity,
    this.isCurrent,
    this.isCurrentWithPopup,
  });

  final String text;
  final String? displayText;
  final ScrollController? scrollController;
  final Widget? header;
  final Object? identity;

  /// Checks the viewed object's eligibility before copying and before showing an
  /// asynchronous copy failure.
  final bool Function()? isCurrent;

  /// After a copy-failure popup opens, checks the viewed object's eligibility with its
  /// actual Route.
  final bool Function(ModalRoute<dynamic> ownedPopup)? isCurrentWithPopup;

  @override
  State<OriginalTextView> createState() => _OriginalTextViewState();
}

class _OriginalTextViewState extends State<OriginalTextView> {
  String get _displayText => widget.displayText ?? widget.text;
  late List<int> _ends = originalTextChunkEnds(_displayText);
  ModalRoute<dynamic>? _route;
  late bool Function({Route<dynamic>? ownedPopup}) _taskActive;
  bool _attached = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _taskActive = AppTaskActivity.capture(context);
  }

  @override
  void activate() {
    super.activate();
    _attached = true;
  }

  @override
  void deactivate() {
    _attached = false;
    super.deactivate();
  }

  @override
  void didUpdateWidget(OriginalTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.displayText ?? oldWidget.text) != _displayText) {
      _ends = originalTextChunkEnds(_displayText);
    }
  }

  bool get _current =>
      _attached &&
      mounted &&
      AppTaskActivity.routeIsActive(_route) &&
      _taskActive() &&
      (widget.isCurrent?.call() ?? true);

  Future<void> _copy(
    BuildContext feedbackContext,
    String text,
    Object? identity,
  ) async {
    if (!_current || widget.identity != identity || widget.text != text) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (failure) {
      if (feedbackContext.mounted &&
          _current &&
          widget.identity == identity &&
          widget.text == text) {
        await showAppNotice(
          feedbackContext,
          messages.operationFailed.withDetail(failure),
          isCurrent: () =>
              _current && widget.identity == identity && widget.text == text,
          isCurrentWithPopup: (popup) =>
              _attached &&
              mounted &&
              widget.identity == identity &&
              widget.text == text &&
              AppTaskActivity.routeIsActive(_route, ownedPopup: popup) &&
              _taskActive(ownedPopup: popup) &&
              (widget.isCurrentWithPopup?.call(popup) ??
                  widget.isCurrent?.call() ??
                  true),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final identity = widget.identity;
    return OperationNoticeHost(
      child: Builder(
        builder: (context) => Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                key: const ValueKey('original-text-copy'),
                tooltip: AppLocalizations.of(context).copyOriginalText,
                onPressed: () => _copy(context, text, identity),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(Icons.copy_rounded),
              ),
            ),
            Expanded(
              child: TechnicalReadingPane(
                child: ListView.builder(
                  key: const ValueKey('original-text-blocks'),
                  controller: widget.scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _ends.length + (widget.header == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (widget.header != null) {
                      if (index == 0) return widget.header!;
                      index--;
                    }
                    return SelectableText(
                      _displayText.substring(
                        index == 0 ? 0 : _ends[index - 1],
                        _ends[index],
                      ),
                      style: TechnicalReadingPane.textStyleOf(context),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
