import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';

import 'package:file_selector/file_selector.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/choice_menu_button.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../app/widgets/reading_list.dart';
import 'config_entry.dart';
import 'config_file.dart';
import 'config_text.dart';
import '../settings/auto_update_dialog.dart';
import 'config_text_page.dart';
import 'widgets/confirm_action.dart';
import 'widgets/config_field_dialog.dart';
import 'widgets/import_dialog.dart';

import '../../app/app_task.dart';

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

class _ConfigsPageState extends State<ConfigsPage> {
  AppController get controller => widget.controller;
  final _scroll = ScrollController();
  final _feedbackOwner = ValueNotifier<bool>(true);
  final _keys = <String, GlobalKey>{};
  bool _adding = false;

  Widget _cards(BuildContext context) => Padding(
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
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: columns * 760 + (columns - 1) * 16,
            ),
            child: ReadingList(
              controller: _scroll,
              identity: controller.storageEpoch,
              header: entries.isEmpty && controller.configsCurrent
                  ? _empty(context)
                  : const SizedBox.shrink(),
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
                                : KeyedSubtree(
                                    key: _keys.putIfAbsent(
                                      entries[start + column].id,
                                      GlobalKey.new,
                                    ),
                                    child: IndexedSemantics(
                                      index: start + column,
                                      child: _tile(
                                        context,
                                        entries[start + column],
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
        );
      },
    ),
  );

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
    _feedbackOwner.value = false;
    _feedbackOwner.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final strings = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(
          title: Text(
            controller.configsCurrent
                ? strings.configTitle
                : controller.configError == null
                ? strings.configReading
                : strings.configStale,
            maxLines: 1,
          ),
          actions: [
            if (controller.configError != null)
              IconButton(
                tooltip: strings.configReadFailed,
                onPressed: () => showAppMessage(
                  context,
                  controller.configErrorMessage!,
                  title: (strings) => strings.configReadFailed,
                ),
                icon: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            _addMenu(),
          ],
        ),
        body: SafeArea(child: _cards(context)),
      );
    },
  );

  Widget _addMenu({bool labeled = false}) {
    final palette = HomePalette.of(context);
    final enabled = widget.active && controller.canEdit && !_adding;
    final epoch = controller.storageEpoch;
    final strings = AppLocalizations.of(context);
    return ChoiceMenuButton<String>(
      enabled: enabled,
      identity: epoch,
      tooltip: strings.addConfig,
      iconColor: Theme.of(context).colorScheme.primary,
      icon: Icons.add,
      options: {
        'url': strings.importFromUrl,
        'file': strings.importFromFile,
        'new': strings.newLocalConfig,
      },
      leadingIcon: (kind) => Icon(switch (kind) {
        'url' => Icons.link,
        'file' => Icons.file_open_outlined,
        _ => Icons.note_add_outlined,
      }, color: kind == 'url' ? palette.remoteSource : palette.localSource),
      onSelected: (kind) => _add(kind, epoch),
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
    if (storageEpoch == null || _adding || !controller.canEdit) return;
    final strings = AppLocalizations.of(context);
    setState(() => _adding = true);
    try {
      if (kind == 'url') {
        await openImport(context, controller, storageEpoch: storageEpoch);
      } else if (kind == 'new') {
        final name = await showDialog<String>(
          context: context,
          builder: (_) => ConfigFieldDialog(
            initial: strings.localConfig,
            title: (strings) => strings.newLocalConfig,
            confirmLabel: (strings) => strings.continueLabel,
          ),
        );
        if (!mounted || name == null) return;
        if (name.isEmpty || configNameBytes(name) > maxConfigNameBytes) {
          await showLocalizedOperationMessage(
            context,
            (strings) => strings.nameInvalid,
          );
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
        if (file == null || !mounted) return;
        final body = await readConfigFile(file);
        if (!mounted) return;
        if (!controller.canEdit) {
          await showLocalizedOperationMessage(
            context,
            (strings) => strings.operationBusyFile,
          );
          return;
        }
        final result = await controller.saveLocal({
          'storageEpoch': storageEpoch,
          'name': configFileName(file.name),
          'body': body,
        }, feedbackOwner: _feedbackOwner);
        try {
          if (!mounted) return;
          if (result?.configStatus != 'saved') {
            await showAppMessage(
              context,
              result?.resultMessageDescription ??
                  controller.commandErrorMessage ??
                  messages.importResultUnconfirmed,
            );
          }
        } finally {
          controller.acknowledgeLocalFeedback(_feedbackOwner, result: result);
        }
      }
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          error is ConfigFailure ? error.message : messages.fileUnreadable,
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _openText(ConfigEntry entry, int storageEpoch) {
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
    await showDialog<String>(
      context: context,
      builder: (_) => ConfigFieldDialog(
        initial: source ? entry.source! : entry.name,
        source: source,
        onSubmit: (value) async {
          if (!mounted || !controller.canEdit) return false;
          if (source) return _update(entry, storageEpoch, source: value);
          final accepted = await controller.submit({
            'action': 'renameConfig',
            'id': entry.id,
            'name': value,
            'storageEpoch': storageEpoch,
          });
          return accepted != null;
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
    if (!controller.canEdit) return false;
    final accepted = await controller.submit({
      'action': 'updateConfig',
      'id': entry.id,
      'source': url,
      'storageEpoch': storageEpoch,
    });
    return accepted != null;
  }

  Widget _tile(BuildContext context, ConfigEntry entry) {
    final entryEpoch = controller.storageEpoch;
    final selected = entry.id == controller.collection.selectedId;
    final running =
        controller.configsCurrent &&
        controller.state.running &&
        entry.id == controller.state.configId;
    final canSelect = controller.canEdit && !selected;
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = HomePalette.of(context);
    final titleStyle = theme.textTheme.titleMedium!.copyWith(
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
        : entry.error != null
        ? strings.operationNotCompleted
        : null;
    final menuOptions = <String, String>{
      if (entry.error != null) 'error': strings.viewConfigError,
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
        if ((action != 'error' && !controller.canEdit) ||
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
          onPressed: controller.canEdit
              ? () {
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
          enabled: controller.canEdit || entry.error != null,
          onSelected: (action) {
            final epoch = entryEpoch;
            switch (action) {
              case 'error':
                showLocalizedOperationMessage(
                  context,
                  (strings) =>
                      entry.errorMessage?.resolve(strings) ??
                      strings.operationNotCompleted,
                  title: (strings) => strings.configActionFailed,
                  subject: entry.name,
                );
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
    return Semantics(
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
              ? () => controller.submit({
                  'action': 'select',
                  'id': entry.id,
                  'storageEpoch': entryEpoch,
                })
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
                      // Select layout from viewport and font constraints.
                      final compact =
                          constraints.maxWidth <
                          280 * MediaQuery.textScalerOf(context).scale(14) / 14;
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
                                child: status == null
                                    ? null
                                    : Tooltip(
                                        message: status,
                                        child: Icon(
                                          running
                                              ? oldBody
                                                    ? Icons.history
                                                    : Icons.play_arrow
                                              : Icons.error_outline,
                                          size: 18,
                                          semanticLabel: status,
                                          color: running
                                              ? oldBody
                                                    ? palette.warning
                                                    : palette.success
                                              : palette.error,
                                        ),
                                      ),
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
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
    final selected = entry.id == controller.collection.selectedId;
    final remaining = controller.collection.entries
        .where((e) => e.id != entry.id)
        .toList();
    final accepted = await confirmAction(
      context,
      title: (strings) => strings.deleteConfigTitle,
      subject: entry.name,
      message: (strings) {
        final outcome = !selected
            ? strings.deleteKeepsSelection
            : remaining.isEmpty
            ? strings.deleteNoSelection
            : strings.deleteSelects(remaining.first.name);
        return '${entry.remote ? strings.deleteRemoteBody : strings.deleteLocalBody}\n\n$outcome';
      },
      confirmLabel: (strings) => strings.delete,
    );
    if (accepted && context.mounted) {
      await controller.submit({
        'action': 'delete',
        'id': entry.id,
        'storageEpoch': storageEpoch,
      });
    }
  }
}
