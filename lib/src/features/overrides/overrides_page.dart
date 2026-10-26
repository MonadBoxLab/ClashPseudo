import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';

import '../../app/app_task.dart';

import 'package:file_selector/file_selector.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/reading_list.dart';
import '../../l10n/app_localizations.dart';
import '../configs/config_text_page.dart';
import '../configs/config_entry.dart';
import '../configs/config_file.dart';
import '../../l10n/messages.dart';
import '../configs/widgets/import_dialog.dart';
import '../settings/auto_update_dialog.dart';
import '../configs/widgets/confirm_action.dart';
import '../configs/widgets/config_field_dialog.dart';
import 'override_entry.dart';

class OverridesPage extends StatefulWidget {
  const OverridesPage({
    super.key,
    required this.app,
    this.selectFile = selectConfigFile,
  });
  final AppController app;
  final Future<XFile?> Function() selectFile;
  @override
  State<OverridesPage> createState() => _OverridesPageState();
}

class _OverridesPageState extends State<OverridesPage> {
  AppController get app => widget.app;
  bool _importing = false;
  final _feedbackOwner = ValueNotifier(true);

  final _scroll = ScrollController();

  @override
  void dispose() {
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _list(BuildContext context) {
    final entries = app.overrides;
    final order = entries.map((entry) => entry.id).toList(growable: false);
    final strings = AppLocalizations.of(context);
    final canEdit =
        app.canEdit &&
        app.overridesLoaded &&
        app.overrideErrorMessage == null &&
        !_importing;
    final epoch = app.storageEpoch;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: ReadingList(
            controller: _scroll,
            identity: epoch,
            header: _header(context),
            items: [
              for (final (index, entry) in entries.indexed)
                ReadingListItem(
                  id: entry.id,
                  layoutValues: [entry.name, _summary(strings, entry)],
                  builder: (context) => _row(
                    context,
                    strings,
                    entry,
                    index,
                    canEdit: canEdit,
                    storageEpoch: epoch,
                    order: order,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final entries = app.overrides;
    final readError = app.overrideErrorMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            strings.overrideNotice,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Row(
          key: const ValueKey('override-read-state'),
          children: [
            SizedBox.square(
              dimension: 48,
              child: readError != null
                  ? IconButton(
                      tooltip: strings.overridesUnreadable,
                      onPressed: () => showAppMessage(context, readError),
                      icon: Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    )
                  : !app.overridesLoaded
                  ? const Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            const Spacer(),
            Visibility(
              visible: readError != null,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: TextButton(
                onPressed: readError == null ? null : app.refresh,
                child: Text(strings.retry),
              ),
            ),
          ],
        ),
        if (entries.isEmpty &&
            app.overridesLoaded &&
            app.overrideErrorMessage == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(child: Text(strings.overrideEmpty)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      final storageEpoch = app.storageEpoch;
      final readError = app.overrideErrorMessage;
      final canEdit =
          app.canEdit &&
          app.overridesLoaded &&
          readError == null &&
          !_importing;
      return Scaffold(
        appBar: AppBar(
          title: Text(strings.overridePlugins),
          actions: [
            _addMenu(context, strings, canEdit, storageEpoch: storageEpoch),
          ],
        ),
        body: SafeArea(child: _list(context)),
      );
    },
  );

  String _summary(AppLocalizations strings, OverrideEntry entry) {
    final uri = entry.remote ? Uri.parse(entry.source!) : null;
    final source = uri == null
        ? strings.overrideLocal
        : '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}/…';
    return [
      source,
      entry.mode == OverrideMode.prepend
          ? strings.overridePrepend
          : strings.overrideReplace,
    ].join(' · ');
  }

  Widget _row(
    BuildContext context,
    AppLocalizations strings,
    OverrideEntry entry,
    int index, {
    required bool canEdit,
    required int storageEpoch,
    required List<String> order,
  }) {
    final theme = Theme.of(context);
    final palette = HomePalette.of(context);
    final titleStyle = theme.textTheme.titleMedium!;
    final firstLine =
        (MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
                (titleStyle.height ?? 1))
            .clamp(24.0, double.infinity);
    final menuOptions = <String, String>{
      'rename': strings.rename,
      if (entry.errorMessage != null) 'error': strings.operationFailed,
      'mode': entry.mode == OverrideMode.prepend
          ? strings.overrideReplace
          : strings.overridePrepend,
      'up': strings.overrideMoveUp,
      'down': strings.overrideMoveDown,
      if (entry.remote) ...{
        'source': strings.changeSource,
        'auto': entry.update.enabled
            ? strings.autoUpdateEvery(entry.update.hours)
            : strings.autoUpdate,
      },
      'delete': strings.overrideDelete,
    };
    final menuIcons = {
      'rename': (Icons.drive_file_rename_outline, palette.editAction),
      'error': (Icons.error_outline, palette.error),
      'mode': (Icons.layers_outlined, palette.moreAction),
      'up': (Icons.arrow_upward, palette.moreAction),
      'down': (Icons.arrow_downward, palette.moreAction),
      'source': (Icons.link, palette.syncAction),
      'auto': (Icons.update, palette.syncAction),
      'delete': (Icons.delete_outline, palette.error),
    };
    final disabledOptions = {
      for (final action in menuOptions.keys)
        if ((action != 'error' && !canEdit) ||
            (action == 'up' && index == 0) ||
            (action == 'down' && index == order.length - 1))
          action,
    };
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${entry.name} · ${strings.overrideEnabled}',
          child: Switch(
            value: entry.enabled,
            onChanged: canEdit
                ? (value) => _change(entry, {
                    'enabled': value,
                  }, storageEpoch: storageEpoch)
                : null,
          ),
        ),
        IconButton(
          tooltip: entry.remote ? strings.overrideUpdate : strings.editConfig,
          style: IconButton.styleFrom(
            foregroundColor: entry.remote
                ? palette.syncAction
                : palette.editAction,
          ),
          onPressed: canEdit
              ? () {
                  if (entry.remote) {
                    _menu(
                      context,
                      entry,
                      'update',
                      storageEpoch: storageEpoch,
                      order: order,
                    );
                  } else {
                    _edit(context, entry, storageEpoch: storageEpoch);
                  }
                }
              : null,
          icon: Icon(entry.remote ? Icons.refresh : Icons.edit_outlined),
        ),
        ChoiceMenuButton<String>(
          identity: (
            storageEpoch,
            entry.id,
            entry.revision,
            entry.name,
            entry.source,
            entry.mode,
            entry.enabled,
            index,
            order.length,
          ),
          tooltip: strings.moreLabel,
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
            tooltip: strings.moreLabel,
            focusNode: focus,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(48),
              foregroundColor: palette.moreAction,
            ),
            onPressed: onPressed,
            icon: const Icon(Icons.more_vert),
          ),
          enabled: canEdit || entry.errorMessage != null,
          onSelected: (action) => _menu(
            context,
            entry,
            action,
            storageEpoch: storageEpoch,
            order: order,
          ),
        ),
      ],
    );
    final time = entry.updatedAt?.toLocal();
    final locale = MaterialLocalizations.of(context);
    final stamp = time == null
        ? entry.remote
              ? strings.updateTimeUnknown
              : strings.saveTimeUnknown
        : entry.remote
        ? strings.updatedAt(
            locale.formatCompactDate(time),
            locale.formatTimeOfDay(TimeOfDay.fromDateTime(time)),
          )
        : strings.savedAt(
            locale.formatCompactDate(time),
            locale.formatTimeOfDay(TimeOfDay.fromDateTime(time)),
          );
    final savedTime = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        stamp,
        softWrap: false,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return Card(
      key: ValueKey('override-${entry.id}'),
      child: InkWell(
        onTap: canEdit
            ? () => _edit(context, entry, storageEpoch: storageEpoch)
            : null,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                height: firstLine,
                child: Icon(
                  entry.remote
                      ? Icons.cloud_outlined
                      : Icons.description_outlined,
                  color: entry.remote
                      ? palette.remoteSource
                      : palette.localSource,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact =
                        constraints.maxWidth <
                        340 * MediaQuery.textScalerOf(context).scale(14) / 14;
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
                              width: 24,
                              height: firstLine,
                              child: entry.errorMessage == null
                                  ? null
                                  : Tooltip(
                                      message: entry.errorMessage!.resolve(
                                        strings,
                                      ),
                                      child: Icon(
                                        Icons.error_outline,
                                        size: 18,
                                        color: palette.error,
                                        semanticLabel: strings.operationFailed,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Tooltip(
                          message: _summary(strings, entry),
                          child: Text(
                            _summary(strings, entry),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (compact) ...[
                          SizedBox(width: double.infinity, child: savedTime),
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
    );
  }

  Future<void> _menu(
    BuildContext context,
    OverrideEntry entry,
    String action, {
    required int storageEpoch,
    required List<String> order,
  }) async {
    switch (action) {
      case 'rename':
        await _changeText(entry, storageEpoch: storageEpoch);
      case 'source':
        await _changeText(entry, source: true, storageEpoch: storageEpoch);
      case 'error':
        if (entry.errorMessage case final error?) {
          await showAppMessage(context, error);
        }
      case 'mode':
        _change(entry, {
          'mode': entry.mode == OverrideMode.prepend
              ? OverrideMode.replace.name
              : OverrideMode.prepend.name,
        }, storageEpoch: storageEpoch);
      case 'up':
        _reorder(entry.id, -1, storageEpoch: storageEpoch, order: order);
      case 'down':
        _reorder(entry.id, 1, storageEpoch: storageEpoch, order: order);
      case 'update':
        await app.submit({
          'action': 'updateOverride',
          'id': entry.id,
          'storageEpoch': storageEpoch,
        });
      case 'auto':
        if (!context.mounted) return;
        await showAutoUpdateDialog(
          context,
          app,
          config: null,
          override: entry,
          storageEpoch: storageEpoch,
        );
      case 'delete':
        if (!context.mounted) return;
        final accepted = await confirmAction(
          context,
          title: (strings) => strings.overrideDeleteTitle,
          subject: entry.name,
          message: (strings) => strings.overrideDeleteMessage,
          confirmLabel: (strings) => strings.overrideDelete,
        );
        if (accepted) {
          await app.submit({
            'action': 'deleteOverride',
            'id': entry.id,
            'storageEpoch': storageEpoch,
          });
        }
    }
  }

  Future<void> _changeText(
    OverrideEntry entry, {
    bool source = false,
    required int storageEpoch,
  }) async {
    if (source) {
      await showDialog<Map<String, Object?>>(
        context: context,
        builder: (_) => ImportDialog(
          fragment: true,
          editingSource: true,
          source: entry.source,
          proxyName: entry.proxyName,
          addNoResolve: entry.addNoResolve,
          storageEpoch: storageEpoch,
          onSubmit: (input) async {
            if (!mounted) return false;
            final receipt = await app.submit({
              'action': 'changeOverrideSource',
              'id': entry.id,
              'revision': entry.revision,
              'expectedSource': entry.source,
              'expectedProxyName': entry.proxyName,
              'expectedAddNoResolve': entry.addNoResolve,
              ...input,
              'storageEpoch': storageEpoch,
            });
            return receipt != null;
          },
        ),
      );
      return;
    }
    await showDialog<String>(
      context: context,
      builder: (_) => ConfigFieldDialog(
        initial: entry.name,
        title: (strings) => strings.rename,
        onSubmit: (value) async {
          if (!mounted) return false;
          final receipt = await app.submit({
            'action': 'changeOverride',
            'id': entry.id,
            'name': value,
            'storageEpoch': storageEpoch,
          });
          return receipt != null;
        },
      ),
    );
  }

  void _reorder(
    String id,
    int delta, {
    required int storageEpoch,
    required List<String> order,
  }) {
    final ids = List<String>.of(order);
    final from = ids.indexOf(id);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= ids.length) return;
    final moved = ids.removeAt(from);
    ids.insert(to, moved);
    app.submit({
      'action': 'reorderOverrides',
      'ids': ids,
      'storageEpoch': storageEpoch,
    });
  }

  void _change(
    OverrideEntry entry,
    Map<String, Object?> values, {
    required int storageEpoch,
  }) {
    app.submit({
      'action': 'changeOverride',
      'id': entry.id,
      ...values,
      'storageEpoch': storageEpoch,
    });
  }

  Future<void> _edit(
    BuildContext context,
    OverrideEntry entry, {
    required int storageEpoch,
  }) async {
    await Navigator.of(context).push<void>(
      FocusedPageRoute(
        builder: (_) => ConfigTextPage(
          app: app,
          storageEpoch: storageEpoch,
          entry: null,
          initialName: entry.name,
          initialText: entry.body,
          readOnly: entry.remote,
          saveLabel: (strings) => strings.save,
          onSave: (command, owner) => app.saveOverride({
            ...command,
            'id': command['id'] ?? entry.id,
            'revision': command['revision'] ?? entry.revision,
            'storageEpoch': storageEpoch,
          }, feedbackOwner: owner),
        ),
      ),
    );
  }

  Widget _addMenu(
    BuildContext context,
    AppLocalizations strings,
    bool enabled, {
    required int storageEpoch,
  }) {
    final palette = HomePalette.of(context);
    return ChoiceMenuButton<String>(
      enabled: enabled,
      identity: storageEpoch,
      tooltip: strings.addOverride,
      iconColor: Theme.of(context).colorScheme.primary,
      icon: Icons.add,
      options: {
        'new': strings.newOverride,
        'file': strings.importFromFile,
        'url': strings.remoteOverride,
      },
      leadingIcon: (kind) => Icon(switch (kind) {
        'url' => Icons.link,
        'file' => Icons.file_open_outlined,
        _ => Icons.note_add_outlined,
      }, color: kind == 'url' ? palette.remoteSource : palette.localSource),
      onSelected: (kind) {
        switch (kind) {
          case 'new':
            _newLocal(context, storageEpoch: storageEpoch);
          case 'file':
            _importFile(storageEpoch: storageEpoch);
          case 'url':
            _newRemote(context, storageEpoch: storageEpoch);
        }
      },
    );
  }

  Future<void> _importFile({required int storageEpoch}) async {
    if (_importing || !app.canEdit) return;
    setState(() => _importing = true);
    AppSnapshot? result;
    try {
      final file = await widget.selectFile();
      if (file == null || !mounted) return;
      final body = await readConfigFile(file);
      if (!mounted) return;
      if (!app.canEdit) {
        await showLocalizedOperationMessage(
          context,
          (strings) => strings.operationBusyFile,
        );
        return;
      }
      result = await app.saveOverride({
        'name': file.name.trim().isEmpty
            ? AppLocalizations.of(context).newOverride
            : configFileName(file.name),
        'body': body,
        'storageEpoch': storageEpoch,
      }, feedbackOwner: _feedbackOwner);
      if (!mounted) return;
      if (result?.resultSuccess != true ||
          !const ['saved', 'applied'].contains(result?.overrideStatus)) {
        await showAppMessage(
          context,
          result?.resultMessageDescription ??
              app.commandErrorMessage ??
              messages.importResultUnconfirmed,
        );
      }
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          error is ConfigFailure ? error.message : messages.fileUnreadable,
        );
      }
    } finally {
      app.acknowledgeLocalFeedback(_feedbackOwner, result: result);
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _newLocal(
    BuildContext context, {
    required int storageEpoch,
  }) async {
    final strings = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => ConfigFieldDialog(
        initial: strings.newOverride,
        title: (strings) => strings.overrideName,
        confirmLabel: (strings) => strings.continueLabel,
      ),
    );
    if (name == null || !context.mounted) return;
    await Navigator.of(context).push<void>(
      FocusedPageRoute(
        builder: (_) => ConfigTextPage(
          app: app,
          storageEpoch: storageEpoch,
          initialName: name,
          initialText: '{}',
          onSave: (command, owner) => app.saveOverride({
            ...command,
            'storageEpoch': storageEpoch,
          }, feedbackOwner: owner),
        ),
      ),
    );
    app.refresh();
  }

  Future<void> _newRemote(
    BuildContext context, {
    required int storageEpoch,
  }) async {
    await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => ImportDialog(
        fragment: true,
        storageEpoch: storageEpoch,
        onSubmit: (input) async {
          if (!context.mounted) return false;
          final receipt = await app.submit({
            'action': 'importOverride',
            ...input,
            'storageEpoch': storageEpoch,
          });
          return receipt != null;
        },
      ),
    );
  }
}
