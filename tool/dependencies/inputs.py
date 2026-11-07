"""Allowed dependency update inputs and transaction entry points."""
from tool.common import workspace
from tool.dependencies.resources import RESOURCE_INPUTS

GO_INPUTS = ("native/mihomo/go.mod", "native/mihomo/go.sum")


INPUTS = GO_INPUTS + (
    "pubspec.yaml", "pubspec.lock", "android/app/build.gradle.kts", "android/settings.gradle.kts",
    "android/gradle/wrapper/gradle-wrapper.properties",
    "third_party/notices/go.txt", "third_party/notices/mihomo.txt",
    "third_party/notices/android.txt", "third_party/notices/publicsuffix.txt",
    "third_party/data/publicsuffix/public_suffix_list.dat",
) + RESOURCE_INPUTS


def input_path(root, name):
    return workspace.input_path(root, name, INPUTS)

def input_bytes(root, name):
    return workspace.input_bytes(root, name, INPUTS)

def snapshot(root):
    return workspace.snapshot(root, INPUTS)

def publish_changes(root, before, after):
    return workspace.publish_changes(root, before, after, INPUTS)


def publish_resources(root, before, prepared, *, application_delivery=False, delivery_version=None):
    from tool.common.io import require
    from tool.dependencies.sources import resource_changes
    require(application_delivery, "Resources are refreshed only with new application deliveries, not standalone APK preparation")
    after = dict(before)
    after.update(resource_changes(root, prepared, delivery_version=delivery_version))
    return publish_changes(root, before, after)
