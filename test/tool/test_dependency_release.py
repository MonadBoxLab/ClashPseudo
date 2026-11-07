"""Test direct releases with temporary Git repositories and mocked GitHub APIs without connecting to project remotes."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import tool_test_support
from tool.artifacts import update_bundle
from tool.common.process import run
from tool.dependencies import release, validation


class GitHub:
    def __init__(self):
        self.current = None
        self.history = []
        self.files = {}
        self.calls = []
        self.fail_upload = False

    def run(self, command, cwd, env=None):
        command = list(map(str, command))
        self.calls.append(command)
        if command[0] != "gh":
            return run(command, cwd, env)
        if command[1] == "api":
            return json.dumps([self.history, [self.current] if self.current else []])
        action, tag = command[2:4]
        if action == "create":
            self.current = {"tag_name": tag, "draft": True, "prerelease": False, "assets": [],
                            "published_at": "2026-11-08T12:00:00Z"}
        elif action == "upload":
            for source in command[command.index("--clobber") + 1:]:
                path = Path(source)
                self.files[path.name] = path.read_bytes()
                self.current["assets"] = [{"name": name, "state": "uploaded"} for name in self.files]
                if self.fail_upload:
                    self.fail_upload = False
                    raise ValueError("上传失败\n原始 stdout\n原始 stderr")
        elif action == "edit":
            self.current["draft"] = False
            self.current["prerelease"] = "--prerelease=true" in command
            self.current["latest"] = "--latest=true" in command
        elif action == "download":
            destination = Path(command[command.index("--dir") + 1])
            for index, value in enumerate(command):
                if value == "--pattern":
                    name = command[index + 1]
                    if name in self.files:
                        (destination / name).write_bytes(self.files[name])
        else:
            raise AssertionError(command)
        return ""

    def mutations(self):
        return [call for call in self.calls if call[:2] == ["gh", "release"] and call[2] != "download"]


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="release-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "candidate"
        self.root.mkdir()
        environment = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            "DEFAULT_BRANCH": "main", "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "owner/project", "GITHUB_RUN_ID": "123",
            "GITHUB_EVENT_NAME": "schedule", "GITHUB_OUTPUT": "",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.git("init", "-b", "main")
        (self.root / "pubspec.yaml").write_text("name: app\nversion: 0.2.0+6\n", encoding="utf-8")
        (self.root / "unchanged.txt").write_text("baseline", encoding="utf-8")
        (self.root / "lib").mkdir()
        (self.root / "lib/main.dart").write_text("void main() {}\n", encoding="utf-8")
        resource_path = self.root / release.resources.RESOURCE_RECORD
        resource_path.parent.mkdir(parents=True)
        release.save(resource_path, {"format": "clash-pseudo-release-resources", "version": 1,
            "application": "0.2.0+6", "resources": {name: {} for name in release.resources.RESOURCE_ASSETS}})
        self.git("add", ".")
        self.git("commit", "-m", "基准")
        self.base = self.git("rev-parse", "HEAD")
        self.remote = self.directory / "remote.git"
        run(["git", "init", "--bare", "-b", "main", self.remote], self.directory)
        self.git("remote", "add", "origin", self.remote)
        self.git("push", "origin", "main")
        self.publisher = self.directory / "publisher"
        run(["git", "clone", self.remote, self.publisher], self.directory)
        self.state = self.directory / "state.json"
        self.report = self.directory / "report.json"
        self.materials = self.directory / "materials"
        self.version = "0.2.1+7"
        self.plan = {"base": self.base, "branch": "main", "repository": "owner/project", "run_id": "123",
                     "release_type": "pre-release", "promote": False, "source_changed": False,
                     "first_release": False}
        release.save(self.state, self.plan)
        self.github = GitHub()
        github = mock.patch.object(release, "run", side_effect=self.github.run)
        github.start()
        self.addCleanup(github.stop)

    def git(self, *arguments):
        return run(["git", *arguments], self.root).strip()

    def candidate(self, declaration=None):
        (self.root / "pubspec.yaml").write_text("name: app\nversion: " + (declaration or self.version) + "\n", encoding="utf-8")
        release.save(self.report, {"status": "updated", "files": ["pubspec.yaml"]})
        self.plan = release.commit(self.root, self.state, self.report, self.materials)
        return self.plan["commit"]

    def bundle(self, declaration=None):
        self.candidate(declaration)
        self.materials.mkdir()
        assets = self.materials / "assets"
        assets.mkdir()
        for name in release.names(self.version)[:-1]:
            (assets / name).write_bytes(("本轮资产 " + name).encode())
        (assets / "SHA256SUMS").write_text("".join(
            release.digest(assets / name) + "  " + name + "\n" for name in release.names(self.version)[:-1]))
        update_bundle.export_bundle(self.root, self.materials / "candidate.bundle", self.base, self.plan["commit"])
        self.plan.update(assets={name: release.digest(assets / name) for name in release.names(self.version)})
        release.save(self.materials / "release.json", self.plan)
        (self.materials / "notes.md").write_text("发布说明", encoding="utf-8")

    def published_baseline(self, *, prerelease=True):
        tag = "v0.2.0+6"
        self.git("tag", "-a", tag, self.base, "-m", "Published baseline")
        self.git("push", "origin", "refs/tags/" + tag)
        self.github.current = {"tag_name": tag, "draft": False, "prerelease": prerelease,
            "published_at": "2026-11-07T12:00:00Z",
            "assets": [{"name": name, "state": "uploaded"} for name in release.names("0.2.0+6")]}

    def source_update(self):
        (self.root / "lib/main.dart").write_text("void main() { print('updated'); }\n", encoding="utf-8")
        self.git("add", "lib/main.dart")
        self.git("commit", "-m", "fix(app): update source")
        self.base = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "main")
        run(["git", "pull", "--ff-only"], self.publisher)

    def unchanged_dependencies(self, *, requested="pre-release"):
        release.context(self.root, self.state, requested)
        release.save(self.report, {"status": "unchanged", "files": []})
        self.plan = release.commit(self.root, self.state, self.report, self.materials)
        return self.plan

    def build_candidate(self):
        def build(project, output, *, commit):
            self.assertEqual(project, self.root)
            self.assertEqual(commit, self.plan["commit"])
            self.assertEqual(release.application_version(project), self.version)
            record = release.resources.read_release_resources(project)
            self.assertEqual(record["application"], self.version)
            output.mkdir()
            for name in release.names(self.version)[:-1]:
                (output / name).write_bytes((commit + name).encode())
            (output / "SHA256SUMS").write_text("".join(
                release.digest(output / name) + "  " + name + "\n" for name in release.names(self.version)[:-1]))
            return {"status": "built", "version": self.version, "mihomo": "v1.0.0", "commit": commit,
                    "assets": list(release.names(self.version))}
        with mock.patch.object(validation, "build_release", side_effect=build) as builder:
            result = release.build(self.root, self.state, self.directory / "build", self.materials)
            builder.assert_called_once()
        return result

    def test_context_uses_pre_release_by_default_and_accepts_both_types(self):
        self.assertEqual(release.context(self.root, self.state)["release_type"], "pre-release")
        for requested in ("pre-release", "release"):
            with self.subTest(requested=requested):
                self.assertEqual(release.context(self.root, self.state, requested)["release_type"], requested)
        with self.assertRaisesRegex(ValueError, "release_type"):
            release.context(self.root, self.state, "default")

    def test_context_rejects_non_default_branch_without_query(self):
        with mock.patch.dict(os.environ, GITHUB_REF="refs/heads/feature"), self.assertRaisesRegex(ValueError, "default branch"):
            release.context(self.root, self.state)
        self.assertEqual(self.github.calls, [])

    def test_context_freezes_selected_type_and_base(self):
        plan = release.context(self.root, self.state, "release")
        self.assertEqual(plan["base"], self.base)
        self.assertEqual(plan["release_type"], "release")
        self.assertFalse(plan["promote"])

    def test_no_change_creates_no_commit_bundle_or_version_bump(self):
        self.published_baseline()
        result = self.unchanged_dependencies()
        self.assertEqual(result["operation"], "none")
        self.assertEqual(result["version"], "0.2.0+6")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        self.assertFalse(self.materials.exists())

    def test_context_outputs_first_release_until_a_public_release_exists(self):
        self.github.history.append({"tag_name": "v0.1.0+1", "draft": True})
        for published in (False, True):
            with self.subTest(published=published):
                if published:
                    self.published_baseline()
                output = self.directory / ("published-output" if published else "first-output")
                with mock.patch.dict(os.environ, GITHUB_OUTPUT=str(output)):
                    plan = release.context(self.root, self.state)
                self.assertEqual(plan["first_release"], not published)
                self.assertEqual(release.load(self.state)["first_release"], not published)
                values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(values["first_release"], str(not published).lower())
                self.assertEqual(values["base"], self.base)

    def test_first_release_builds_and_publishes_without_dependency_changes(self):
        self.version = "0.2.0+7"
        result = self.unchanged_dependencies()
        self.assertEqual(result["operation"], "publish")
        self.assertEqual(result["version"], self.version)
        self.assertEqual(self.git("rev-list", "--count", self.base + "..HEAD"), "1")
        self.assertEqual(self.git("rev-parse", "HEAD^"), self.base)
        self.build_candidate()
        release.publish(self.publisher, self.materials)
        self.assertEqual(release.remote_ref(self.publisher, "refs/tags/v" + self.version), result["commit"])
        self.assertTrue(self.github.current["prerelease"])
        self.assertEqual(self.unchanged_dependencies()["operation"], "none")
        self.assertEqual(self.git("rev-parse", "HEAD"), result["commit"])

    def test_first_resource_update_adds_both_version_files_to_the_candidate(self):
        release.context(self.root, self.state)
        record = release.resources.read_release_resources(self.root)
        record["resources"]["ca"] = {"version": "2026-11-01"}
        release.save(self.root / release.resources.RESOURCE_RECORD, record)
        release.save(self.report, {"status": "updated", "files": [release.resources.RESOURCE_RECORD]})
        result = release.commit(self.root, self.state, self.report, self.materials)
        self.assertEqual(result["version"], "0.2.0+7")
        self.assertEqual(update_bundle.changed_paths(self.root, self.base, result["commit"]),
                         {"pubspec.yaml", release.resources.RESOURCE_RECORD})
        self.assertEqual(release.resources.read_release_resources(self.root), dict(record, application="0.2.0+7"))
        self.assertEqual(self.git("rev-list", "--count", self.base + "..HEAD"), "1")

    def test_first_release_keeps_display_version_with_dependency_changes_and_retries(self):
        self.version = "0.2.0+7"
        release.context(self.root, self.state)
        declaration = "name: app\nversion: '0.2.0+6' # 应用版本\ndependencies:\n  http: ^1.6.0\n"
        (self.root / "pubspec.yaml").write_text(declaration, encoding="utf-8")
        resource_path = self.root / release.resources.RESOURCE_RECORD
        record = release.resources.read_release_resources(self.root)
        record["dependencies"] = {"pub": {"http": {"selected": "1.6.0"}}}
        release.save(resource_path, record)
        release.save(self.report, {"status": "updated", "files": ["pubspec.yaml", release.resources.RESOURCE_RECORD]})
        self.plan = release.commit(self.root, self.state, self.report, self.materials)
        candidate = self.plan["commit"]
        self.assertEqual(self.plan["operation"], "publish")
        self.assertEqual(self.plan["version"], self.version)
        self.assertEqual(self.git("rev-list", "--count", self.base + "..HEAD"), "1")
        self.assertEqual(self.git("rev-parse", "HEAD^"), self.base)
        self.assertEqual((self.root / "pubspec.yaml").read_text(), declaration.replace("0.2.0+6", self.version))
        self.assertEqual(release.resources.read_release_resources(self.root), dict(record, application=self.version))
        self.build_candidate()
        bundle = self.materials / "candidate.bundle"
        checksum = release.digest(bundle)
        with mock.patch.dict(os.environ, GITHUB_RUN_ID="124"), self.assertRaisesRegex(ValueError, "this repository run"):
            release.publish(self.publisher, self.materials)
        self.assertFalse(any(call[:2] == ["git", "push"] for call in self.github.calls))
        self.github.fail_upload = True
        with self.assertRaisesRegex(ValueError, "原始 stdout"):
            release.publish(self.publisher, self.materials)
        self.github.calls.clear()
        release.publish(self.publisher, self.materials)
        self.assertFalse(any(call[:2] == ["git", "push"] for call in self.github.calls))
        self.assertEqual(release.digest(bundle), checksum)
        self.assertEqual(release.remote_ref(self.publisher, "refs/tags/v" + self.version), candidate)
        self.github.calls.clear()
        release.publish(self.publisher, self.materials)
        self.assertEqual(self.github.mutations(), [])
        self.assertEqual(self.unchanged_dependencies()["operation"], "none")
        self.assertEqual(self.git("rev-parse", "HEAD"), candidate)
        self.assertEqual(release.application_version(self.root), self.version)

    def test_source_update_builds_publishes_and_does_not_repeat_on_next_run(self):
        self.published_baseline()
        self.source_update()
        before = release.resources.read_release_resources(self.root)
        result = self.unchanged_dependencies()
        self.assertEqual(result["operation"], "publish")
        self.assertEqual(result["version"], self.version)
        self.assertEqual(self.git("rev-parse", "HEAD^"), self.base)
        self.assertEqual(update_bundle.changed_paths(self.root, self.base, result["commit"]),
                         {"pubspec.yaml", release.resources.RESOURCE_RECORD})
        after = release.resources.read_release_resources(self.root)
        self.assertEqual(after, dict(before, application=self.version))
        self.assertEqual(self.git("show", "HEAD:lib/main.dart"), "void main() { print('updated'); }")
        self.build_candidate()
        release.publish(self.publisher, self.materials)
        self.github.calls.clear()
        release.publish(self.publisher, self.materials)
        self.assertEqual(self.github.mutations(), [])
        self.assertEqual(self.unchanged_dependencies()["operation"], "none")
        self.assertEqual(self.git("rev-parse", "HEAD"), result["commit"])
        self.assertEqual(release.application_version(self.root), self.version)

    def test_source_update_with_manual_release_publishes_new_version_instead_of_promotion(self):
        self.published_baseline()
        previous = self.github.current
        old_target = self.base
        self.source_update()
        with mock.patch.dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch"):
            result = self.unchanged_dependencies(requested="release")
        self.assertFalse(result["promote"])
        self.assertEqual(result["operation"], "publish")
        self.assertEqual(result["version"], self.version)
        self.build_candidate()
        release.publish(self.publisher, self.materials)
        self.assertFalse(self.github.current["prerelease"])
        self.assertTrue(self.github.current["latest"])
        self.assertTrue(previous["prerelease"])
        self.assertEqual(release.remote_ref(self.root, "refs/tags/v0.2.0+6"), old_target)

    def test_dependency_only_update_keeps_the_updaters_version(self):
        self.published_baseline()
        self.plan = release.context(self.root, self.state)
        self.assertFalse(self.plan["source_changed"])
        self.candidate()
        self.assertEqual(self.plan["operation"], "publish")
        self.assertEqual(self.plan["version"], self.version)
        self.assertEqual(self.git("rev-list", "--count", self.base + "..HEAD"), "1")

    def test_dependency_and_source_updates_bump_once(self):
        self.published_baseline()
        self.source_update()
        self.plan = release.context(self.root, self.state)
        self.assertTrue(self.plan["source_changed"])
        candidate = self.candidate()
        self.assertEqual(self.plan["version"], self.version)
        self.assertEqual(release.application_version(self.root), self.version)
        self.assertEqual(self.git("rev-parse", candidate + "^"), self.base)
        self.assertEqual(self.git("rev-list", "--count", self.base + "..HEAD"), "1")

    def test_latest_public_prerelease_is_used_instead_of_older_stable_release(self):
        self.published_baseline(prerelease=False)
        self.github.history.append(self.github.current)
        self.bundle()
        release.publish(self.publisher, self.materials)
        published = self.plan["commit"]
        result = self.unchanged_dependencies()
        self.assertFalse(result["source_changed"])
        self.assertEqual(result["operation"], "none")
        self.assertEqual(result["commit"], published)
        self.assertEqual(release.application_version(self.root), self.version)

    def test_empty_commit_after_public_release_does_not_release_identical_inputs(self):
        self.published_baseline()
        self.git("commit", "--allow-empty", "-m", "chore: no input changes")
        base = self.git("rev-parse", "HEAD")
        result = self.unchanged_dependencies()
        self.assertEqual(result["operation"], "none")
        self.assertEqual(result["version"], "0.2.0+6")
        self.assertEqual(self.git("rev-parse", "HEAD"), base)

    def test_unresolvable_last_public_tag_fails_instead_of_treating_it_as_first_release(self):
        self.github.current = {"tag_name": "v0.9.0+1", "draft": False, "prerelease": True,
                               "published_at": "2026-11-07T12:00:00Z", "assets": []}
        with self.assertRaisesRegex(ValueError, "Cannot determine the last published commit: remote tag is missing"):
            release.context(self.root, self.state)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)
        self.assertEqual(self.github.mutations(), [])

    def test_unavailable_last_public_commit_reports_tag_and_original_error(self):
        run(["git", "commit", "--allow-empty", "-m", "Unfetched release"], self.publisher)
        run(["git", "push", "origin", "HEAD:refs/tags/v0.9.0+1"], self.publisher)
        self.github.current = {"tag_name": "v0.9.0+1", "draft": False, "prerelease": True,
                               "published_at": "2026-11-07T12:00:00Z", "assets": []}
        with self.assertRaisesRegex(ValueError, "Cannot determine the last published commit: tag commit is unavailable locally: v0.9.0"):
            release.context(self.root, self.state)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)

    def test_ambiguous_publication_times_fail_instead_of_guessing_a_baseline(self):
        self.published_baseline()
        self.github.history.append(dict(self.github.current, tag_name="v0.9.0+1"))
        with self.assertRaisesRegex(ValueError, "Cannot determine the last published commit: multiple releases"):
            release.context(self.root, self.state)

    def test_missing_publication_time_reports_unidentifiable_baseline(self):
        self.published_baseline()
        self.github.current.pop("published_at")
        with self.assertRaisesRegex(ValueError, "Cannot determine the last published commit: missing publication time"):
            release.context(self.root, self.state)

    def test_candidate_commit_message_and_bundle_preserve_hash(self):
        self.bundle()
        candidate = self.plan["commit"]
        self.assertEqual(self.git("show", "-s", "--format=%B", candidate), update_bundle.COMMIT_MESSAGE)
        files = update_bundle.import_bundle(self.publisher, self.materials / "candidate.bundle", self.base, candidate)
        self.assertEqual(files, ["pubspec.yaml"])
        self.assertEqual(run(["git", "rev-parse", "HEAD"], self.publisher).strip(), self.base)
        self.assertEqual(run(["git", "rev-parse", "FETCH_HEAD"], self.publisher).strip(), candidate)

    def test_unexpected_file_cannot_enter_candidate(self):
        (self.root / "unchanged.txt").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "allowlist"):
            self.candidate()
        self.assertEqual(self.git("rev-parse", "HEAD"), self.base)

    def test_bundle_rejects_disallowed_committed_files(self):
        (self.root / "unchanged.txt").write_text("changed", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-m", update_bundle.COMMIT_MESSAGE)
        with self.assertRaisesRegex(ValueError, "allowlist"):
            update_bundle.export_bundle(self.root, self.directory / "bad.bundle", self.base, self.git("rev-parse", "HEAD"))

    def test_publish_pushes_candidate_and_tag_atomically_then_all_assets(self):
        self.bundle()
        self.assertEqual(release.publish(self.publisher, self.materials)["status"], "published")
        pushes = [call for call in self.github.calls if call[:2] == ["git", "push"]]
        self.assertEqual(pushes, [["git", "push", "--atomic", "origin",
            self.plan["commit"] + ":refs/heads/main", self.plan["commit"] + ":refs/tags/" + self.plan["tag"]]])
        self.assertEqual(release.remote_ref(self.publisher, "refs/heads/main"), self.plan["commit"])
        self.assertEqual(release.remote_ref(self.publisher, "refs/tags/" + self.plan["tag"]), self.plan["commit"])
        self.assertEqual(set(self.github.files), set(release.names(self.version)))
        self.assertFalse(self.github.current["draft"])
        self.assertTrue(self.github.current["prerelease"])
        self.assertFalse(self.github.current["latest"])
        self.assertEqual([call[2] for call in self.github.mutations()], ["create", "upload", "edit"])
        self.assertIn("--verify-tag", self.github.mutations()[0])

    def test_publish_reuses_application_declaration_parser_for_quotes_and_comments(self):
        self.bundle("'" + self.version + "' # 应用版本")
        self.assertEqual(release.publish(self.publisher, self.materials)["status"], "published")

    def test_explicit_release_does_not_infer_type_from_zero_major(self):
        self.version = "0.1.1+2"
        self.bundle()
        self.plan["release_type"] = "release"
        release.save(self.materials / "release.json", self.plan)
        release.publish(self.publisher, self.materials)
        self.assertFalse(self.github.current["prerelease"])
        self.assertTrue(self.github.current["latest"])

    def test_branch_race_stops_without_tag_or_release(self):
        self.bundle()
        run(["git", "commit", "--allow-empty", "-m", "并发提交"], self.publisher)
        run(["git", "push", "origin", "main"], self.publisher)
        run(["git", "checkout", "--detach", self.base], self.publisher)
        with self.assertRaisesRegex(ValueError, "Default branch has advanced"):
            release.publish(self.publisher, self.materials)
        self.assertIsNone(release.remote_ref(self.publisher, "refs/tags/" + self.plan["tag"]))
        self.assertEqual(self.github.mutations(), [])

    def test_upload_failure_keeps_draft_and_retry_skips_push_after_branch_advances(self):
        self.bundle()
        self.github.fail_upload = True
        with self.assertRaisesRegex(ValueError, "原始 stdout\n原始 stderr"):
            release.publish(self.publisher, self.materials)
        self.assertTrue(self.github.current["draft"])
        self.git("commit", "--allow-empty", "-m", "后续提交")
        advanced = self.git("rev-parse", "HEAD")
        self.git("push", "origin", "main")
        self.github.calls.clear()
        release.publish(self.publisher, self.materials)
        self.assertFalse(any(call[:2] == ["git", "push"] for call in self.github.calls))
        self.assertEqual(release.remote_ref(self.publisher, "refs/heads/main"), advanced)
        self.assertEqual([call[2] for call in self.github.mutations()], ["upload", "edit"])

    def test_same_public_assets_succeed_without_upload_or_type_change(self):
        self.bundle()
        release.publish(self.publisher, self.materials)
        self.github.current["prerelease"] = False
        self.github.calls.clear()
        release.publish(self.publisher, self.materials)
        self.assertEqual(self.github.mutations(), [])
        self.assertFalse(self.github.current["prerelease"])

    def test_conflicting_public_assets_fail_without_overwriting(self):
        self.bundle()
        release.publish(self.publisher, self.materials)
        self.github.files[release.names(self.version)[0]] = b"different bytes"
        self.github.calls.clear()
        with self.assertRaisesRegex(ValueError, "asset conflict"):
            release.publish(self.publisher, self.materials)
        self.assertEqual(self.github.mutations(), [])

    def test_bundle_symlink_is_not_imported(self):
        self.bundle()
        link = self.directory / "linked.bundle"
        link.symlink_to(self.materials / "candidate.bundle")
        with self.assertRaisesRegex(ValueError, "Git bundle"):
            update_bundle.import_bundle(self.publisher, link, self.base, self.plan["commit"])

    def test_atomic_tag_rejection_leaves_branch_unchanged(self):
        self.bundle()
        hook = self.remote / "hooks/update"
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) printf "tag 被拒绝\\n" >&2; exit 1;; esac\n', encoding="utf-8")
        hook.chmod(0o700)
        with self.assertRaisesRegex(ValueError, "tag 被拒绝"):
            release.publish(self.publisher, self.materials)
        self.assertEqual(release.remote_ref(self.publisher, "refs/heads/main"), self.base)
        self.assertIsNone(release.remote_ref(self.publisher, "refs/tags/" + self.plan["tag"]))
        self.assertEqual(self.github.mutations(), [])

    def test_existing_tag_at_another_commit_fails(self):
        self.bundle()
        self.git("push", "origin", self.base + ":refs/tags/" + self.plan["tag"])
        with self.assertRaisesRegex(ValueError, "another commit"):
            release.publish(self.publisher, self.materials)
        self.assertEqual(self.github.mutations(), [])

    def test_artifact_run_identity_and_byte_integrity_are_required_before_push(self):
        self.bundle()
        with mock.patch.dict(os.environ, GITHUB_RUN_ID="124"), self.assertRaisesRegex(ValueError, "this repository run"):
            release.publish(self.publisher, self.materials)
        (self.materials / "assets" / release.names(self.version)[0]).write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "different bytes"):
            release.publish(self.publisher, self.materials)
        self.assertFalse(any(call[:2] == ["git", "push"] for call in self.github.calls))

    def test_pending_publication_blocks_next_update_and_tells_original_job(self):
        self.git("push", "origin", self.base + ":refs/tags/v0.2.0+6")
        with self.assertRaisesRegex(ValueError, "rerun the release job in the original Actions run"):
            release.context(self.root, self.state)

    def test_only_explicit_manual_release_prepares_promotion(self):
        self.git("push", "origin", self.base + ":refs/tags/v0.2.0+6")
        self.github.current = {"tag_name": "v0.2.0+6", "draft": False, "prerelease": True,
            "published_at": "2026-11-07T12:00:00Z",
            "assets": [{"name": name, "state": "uploaded"} for name in release.names("0.2.0+6")]}
        for event, requested, expected in (("schedule", "release", False),
                ("schedule", "pre-release", False), ("workflow_dispatch", "pre-release", False),
                ("workflow_dispatch", "release", True)):
            with self.subTest(event=event, requested=requested), mock.patch.dict(os.environ, GITHUB_EVENT_NAME=event):
                plan = release.context(self.root, self.state, requested)
                self.assertEqual(plan["promote"], expected)

    def test_manual_promotion_reuses_all_assets_without_build_push_or_version_bump(self):
        self.bundle()
        release.publish(self.publisher, self.materials)
        candidate = self.plan["commit"]
        promotion = self.directory / "promotion"
        with mock.patch.dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch"):
            release.context(self.root, self.state, "release")
        release.save(self.report, {"status": "unchanged", "files": []})
        plan = release.commit(self.root, self.state, self.report, promotion)
        self.assertEqual(plan["operation"], "promote")
        self.assertEqual(plan["commit"], candidate)
        self.assertEqual(plan["version"], self.version)
        self.assertEqual([path.name for path in promotion.iterdir()], ["release.json"])
        self.github.calls.clear()
        release.publish(self.root, promotion)
        self.assertFalse(self.github.current["prerelease"])
        self.assertTrue(self.github.current["latest"])
        self.assertEqual([call[2] for call in self.github.mutations()], ["edit"])
        self.assertFalse(any(call[:2] == ["git", "push"] for call in self.github.calls))
        self.assertEqual(self.git("rev-parse", "HEAD"), candidate)
        self.assertEqual(release.application_version(self.root), self.version)

    def test_promotion_rejects_incomplete_or_corrupted_prerelease(self):
        self.bundle()
        release.publish(self.publisher, self.materials)
        self.plan.update(operation="promote", promote=True, release_type="release", base=self.plan["commit"])
        release.save(self.materials / "release.json", self.plan)
        self.github.files[release.names(self.version)[0]] = b"corrupt"
        self.github.calls.clear()
        with self.assertRaisesRegex(ValueError, "digest differs"):
            release.publish(self.root, self.materials)
        self.assertEqual(self.github.mutations(), [])

    def test_both_release_types_use_same_builder_and_exact_candidate_source(self):
        self.candidate()
        def build(project, output, *, commit):
            self.assertEqual(project, self.root)
            self.assertEqual(commit, self.plan["commit"])
            output.mkdir()
            for name in release.names(self.version):
                (output / name).write_bytes(name.encode())
            (output / "build.json").write_text("{}")
            return {"status": "built", "version": self.version, "mihomo": "v1.0.0", "commit": commit,
                    "assets": list(release.names(self.version))}
        with mock.patch.object(validation, "build_release", side_effect=build) as builder:
            for selected in ("pre-release", "release"):
                with self.subTest(selected=selected):
                    self.plan["release_type"] = selected
                    release.save(self.state, self.plan)
                    destination = self.directory / selected
                    result = release.build(self.root, self.state, self.directory / (selected + "-build"), destination)
                    self.assertEqual(result["commit"], self.plan["commit"])
                    self.assertEqual(result["release_type"], selected)
                    self.assertEqual({path.name for path in (destination / "assets").iterdir()}, set(release.names(self.version)))
                    self.assertTrue((destination / "candidate.bundle").is_file())
            self.assertEqual(builder.call_count, 2)

    def test_notes_offer_four_abis_sources_licenses_and_actual_commit(self):
        notes = release.release_notes("1.0.0-preview+1", "arbitrary-resolved-version", self.base, "owner/project")
        for name in release.names("1.0.0-preview+1"):
            self.assertIn(name.replace("+", "%2B"), notes)
        self.assertIn("Source: " + self.base, notes)
        self.assertIn("Mihomo: arbitrary-resolved-version", notes)


if __name__ == "__main__":
    unittest.main()
