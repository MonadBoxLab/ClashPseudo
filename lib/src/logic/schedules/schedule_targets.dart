import '../../model/config_entry.dart';
import '../../model/override_entry.dart';

/// The complete enabled target set; URLs and bodies stay in the logic engine.
List<Map<String, Object?>> scheduleTargets(
  Iterable<ConfigEntry> configs,
  Iterable<OverrideEntry> overrides,
) => [
  for (final entry in configs)
    if (entry.remote && entry.update.enabled)
      {'kind': 'config', 'id': entry.id, 'hours': entry.update.hours},
  for (final entry in overrides)
    if (entry.remote && entry.update.enabled)
      {'kind': 'override', 'id': entry.id, 'hours': entry.update.hours},
];
