package io.github.monadboxlab.clashpseudo.validation;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Activity;
import android.app.Instrumentation;
import android.app.KeyguardManager;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** Public SDK witness in its own test process; never queries app internals. */
public final class SystemEntryInstrumentation extends Instrumentation {
    private static final String APP = "io.github.monadboxlab.clashpseudo";
    private Bundle arguments;

    @Override public void onCreate(Bundle value) {
        super.onCreate(value);
        arguments = value == null ? new Bundle() : value;
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            require((APP + ".test").equals(getContext().getPackageName()) &&
                (APP + ".test").equals(getTargetContext().getPackageName()), "Self-target test package required");
            String action = arguments.getString("systemEntryAction", "");
            require(Arrays.asList("keyguard-state", "snapshot", "click", "notification-inspect", "notification-open", "start", "stop")
                .contains(action), "Explicit supported SDK action required");
            KeyguardManager guard = getTargetContext().getSystemService(KeyguardManager.class);
            require(guard != null, "Public KeyguardManager required");
            result.putInt("api", Build.VERSION.SDK_INT);
            android.content.res.Configuration config = new android.content.res.Configuration(
                getTargetContext().getResources().getConfiguration());
            result.putInt("densityDpi", config.densityDpi);
            result.putFloat("fontScale", config.fontScale);
            result.putInt("screenWidthDp", config.screenWidthDp);
            result.putInt("screenHeightDp", config.screenHeightDp);
            result.putInt("orientation", config.orientation);
            result.putInt("uiMode", config.uiMode);
            result.putString("locales", config.getLocales().toLanguageTags());
            result.putString("configurationScope", "Public test-context Configuration captured when the action begins.");
            result.putBoolean("deviceSecure", guard.isDeviceSecure());
            result.putBoolean("keyguardSecure", guard.isKeyguardSecure());
            result.putBoolean("deviceLocked", guard.isDeviceLocked());
            result.putBoolean("keyguardLocked", guard.isKeyguardLocked());
            result.putBoolean("keyguardMutationPerformed", false);
            if (!"keyguard-state".equals(action)) {
                if (!"snapshot".equals(action))
                    require("true".equals(arguments.getString("allowUiAction")), "Explicit allowUiAction=true required");
                require(!guard.isKeyguardLocked(), "Do not bypass keyguard");
                UiAutomation ui = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
                AccessibilityServiceInfo info = ui.getServiceInfo();
                info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
                ui.setServiceInfo(info);
                if ("snapshot".equals(action)) {
                    snapshot(ui, result);
                } else if ("click".equals(action)) {
                    click(ui, result);
                } else if ("start".equals(action) || "stop".equals(action)) {
                    String name = arguments.getString("expectedConfigName", "");
                    require(!name.trim().isEmpty() && name.length() <= 1024, "Explicit bounded expectedConfigName required");
                    tunnel(ui, "start".equals(action), name, result);
                } else {
                    notification(ui, "notification-open".equals(action), result);
                }
            }
            result.putBoolean("configurationUnchanged",
                config.equals(getTargetContext().getResources().getConfiguration()));
            result.putString("systemEntryAction", action);
            result.putBoolean("sdkActionSucceeded", true);
            result.putString("scope", "Public SDK nodes and single-action receipts. The calling scenario verifies navigation, operation outcomes, resource release and measurement identity.");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            result.putString("failure", android.util.Log.getStackTraceString(failure));
            finish(Activity.RESULT_CANCELED, result);
        }
    }

    private String expectedPackage() {
        String expectedPackage = arguments.getString("expectedWindowPackage", "");
        require(Arrays.asList(APP, "com.android.settings", "com.android.documentsui", "com.google.android.documentsui",
            "com.android.vpndialogs", "com.android.launcher3", "com.google.android.apps.nexuslauncher")
            .contains(expectedPackage), "Explicit supported window package required; no global SystemUI dump");
        return expectedPackage;
    }

    private List<String> expectedLabels() throws Exception {
        String encodedLabels = arguments.getString("labelsJson", "[]");
        require(encodedLabels.length() <= 65536, "Expected-label JSON exceeds its input budget");
        JSONArray labels = new JSONArray(encodedLabels);
        require(labels.length() > 0 && labels.length() <= 64, "Provide 1..64 exact expected labels");
        List<String> wanted = new ArrayList<>();
        for (int i = 0; i < labels.length(); ++i) {
            require(labels.get(i) instanceof String, "Expected labels must be strings");
            String label = labels.getString(i);
            require(!label.isEmpty() && label.length() <= 1024 && !wanted.contains(label), "Unique bounded labels required");
            wanted.add(label);
        }
        return wanted;
    }

    private void snapshot(UiAutomation ui, Bundle result) throws Exception {
        String expectedPackage = expectedPackage();
        List<String> wanted = expectedLabels();
        long deadline = SystemClock.uptimeMillis() + 10_000;
        while (SystemClock.uptimeMillis() < deadline) {
            if (Build.VERSION.SDK_INT >= 33) require(ui.clearCache(), "Fresh observer cache required");
            AccessibilityNodeInfo root = ui.getRootInActiveWindow();
            JSONArray matches = new JSONArray();
            try {
                if (root != null && expectedPackage.contentEquals(root.getPackageName()))
                    matchingNodes(root, wanted, matches);
            } finally { if (root != null) root.recycle(); }
            if (matches.length() > 0) {
                result.putString("matchedNodes", matches.toString());
                result.putString("windowPackage", expectedPackage);
                result.putLong("snapshotElapsedMs", SystemClock.elapsedRealtime());
                result.putBoolean("uiMutationPerformed", false);
                return;
            }
            SystemClock.sleep(100);
        }
        throw new IllegalStateException("No exact expected label in the requested current window; no action performed");
    }

    private void click(UiAutomation ui, Bundle result) throws Exception {
        String expectedPackage = expectedPackage();
        require(Arrays.asList(APP, "com.android.documentsui", "com.google.android.documentsui")
            .contains(expectedPackage), "Clicks are limited to own app and DocumentsUI; no system settings action");
        List<String> wanted = expectedLabels();
        require(wanted.size() == 1, "One exact click label required");
        String label = wanted.get(0);
        require(!Arrays.asList("Start tunnel", "启动接管", "Stop tunnel", "停止接管").contains(label),
            "Use the dedicated tunnel action with its expected configuration identity");
        long deadline = SystemClock.uptimeMillis() + 10_000;
        while (SystemClock.uptimeMillis() < deadline) {
            if (Build.VERSION.SDK_INT >= 33) require(ui.clearCache(), "Fresh observer cache required");
            AccessibilityNodeInfo root = ui.getRootInActiveWindow();
            List<AccessibilityNodeInfo> matches = new ArrayList<>();
            try {
                if (root != null && root.getPackageName() != null && expectedPackage.contentEquals(root.getPackageName()))
                    buttons(root, label, label, matches);
                require(matches.size() <= 1, "Never choose among multiple actionable exact labels");
                if (matches.size() == 1) {
                    result.putString("clickedNode", metadata(matches.get(0)).put("label", label).toString());
                    result.putLong("clickElapsedMs", SystemClock.elapsedRealtime());
                    require(matches.get(0).performAction(AccessibilityNodeInfo.ACTION_CLICK), "Click once; never resend");
                    result.putBoolean("clickAccepted", true);
                    result.putString("clickScope", "SDK action accepted only. Independently verify navigation, save, cancellation and resource exit.");
                    return;
                }
            } finally {
                recycle(matches);
                if (root != null) root.recycle();
            }
            SystemClock.sleep(100);
        }
        throw new IllegalStateException("No unique actionable exact label in the current requested window; no click sent");
    }

    private static JSONObject metadata(AccessibilityNodeInfo node) throws Exception {
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        return new JSONObject().put("id", node.getViewIdResourceName())
            .put("class", String.valueOf(node.getClassName())).put("bounds", bounds.toShortString())
            .put("clickable", node.isClickable()).put("enabled", node.isEnabled())
            .put("visible", node.isVisibleToUser()).put("scrollable", node.isScrollable());
    }

    private static void matchingNodes(AccessibilityNodeInfo node, List<String> wanted, JSONArray output) throws Exception {
        if (node.isVisibleToUser() && !node.isPassword()) {
            for (String label : wanted) if (label.contentEquals(node.getText() == null ? "" : node.getText()) ||
                    label.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription())) {
                require(output.length() < 256, "Too many exact-label matches; refusing ambiguous snapshot");
                JSONObject match = metadata(node).put("label", label);
                JSONArray ancestors = new JSONArray();
                AccessibilityNodeInfo parent = node.getParent();
                try {
                    for (int level = 0; level < 3 && parent != null; ++level) {
                        ancestors.put(metadata(parent));
                        AccessibilityNodeInfo next = parent.getParent();
                        parent.recycle();
                        parent = next;
                    }
                } finally { if (parent != null) parent.recycle(); }
                output.put(match.put("ancestors", ancestors));
            }
        }
        for (int i = 0; i < node.getChildCount(); ++i) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { matchingNodes(child, wanted, output); } finally { child.recycle(); }
        }
    }

    private static void tunnel(UiAutomation ui, boolean start, String expectedName, Bundle result) {
        boolean issued = false;
        boolean observed = false;
        long deadline = SystemClock.uptimeMillis() + 40_000;
        while (!observed && SystemClock.uptimeMillis() < deadline) {
            if (Build.VERSION.SDK_INT >= 33) require(ui.clearCache(), "Fresh observer cache required");
            AccessibilityNodeInfo root = ui.getRootInActiveWindow();
            List<AccessibilityNodeInfo> starts = new ArrayList<>();
            List<AccessibilityNodeInfo> stops = new ArrayList<>();
            try {
                if (root != null && APP.contentEquals(root.getPackageName()) && text(root, expectedName)) {
                    buttons(root, "Start tunnel", "启动接管", starts);
                    buttons(root, "Stop tunnel", "停止接管", stops);
                    require(starts.size() <= 1 && stops.size() <= 1, "Unique explicit own tunnel action required");
                    boolean stopped = (text(root, "Tunnel stopped") || text(root, "接管已关闭")) &&
                        starts.size() == 1 && stops.isEmpty();
                    if (!start && stopped) {
                        observed = true;
                    } else if (start && issued && stops.size() == 1 && starts.isEmpty()) {
                        observed = true;
                    } else if (!issued && ((start && stopped) || (!start && stops.size() == 1))) {
                        issued = true;
                        result.putLong(start ? "startClickElapsedMs" : "stopClickElapsedMs", SystemClock.elapsedRealtime());
                        AccessibilityNodeInfo button = start ? starts.get(0) : stops.get(0);
                        require(button.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Click one explicit own action, never toggle or resend");
                    }
                }
            } finally {
                recycle(starts);
                recycle(stops);
                if (root != null) root.recycle();
            }
            if (!observed) SystemClock.sleep(100);
        }
        require(observed && (!start || issued), "Actual requested UI transition required; no automatic retry");
        result.putBoolean(start ? "startClicked" : "stopClicked", issued);
        result.putBoolean(start ? "subsequentStopActionVisible" : "stoppedAndStartEnabled", true);
    }

    private static void notification(UiAutomation ui, boolean open, Bundle result) throws Exception {
        require(ui.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS),
            "Open notifications once");
        long deadline = SystemClock.uptimeMillis() + 10_000;
        boolean observed = false;
        JSONArray paths = new JSONArray();
        while (!observed && SystemClock.uptimeMillis() < deadline) {
            if (Build.VERSION.SDK_INT >= 33) require(ui.clearCache(), "Fresh observer cache required");
            AccessibilityNodeInfo root = ui.getRootInActiveWindow();
            List<AccessibilityNodeInfo> rows = new ArrayList<>();
            try {
                if (root != null && "com.android.systemui".contentEquals(root.getPackageName())) {
                    if (open) ownRows(root, rows);
                    else ownTitlePaths(root, paths);
                }
                if (open) {
                    require(rows.size() <= 1, "Never choose among multiple own running notifications");
                    if (rows.size() == 1) {
                        AccessibilityNodeInfo row = rows.get(0);
                        if (row.isVisibleToUser() && row.isEnabled() && row.isClickable()) {
                            result.putLong("notificationClickElapsedMs", SystemClock.elapsedRealtime());
                            require(row.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Click only the own running notification");
                            observed = true;
                        }
                    }
                } else observed = paths.length() > 0;
            } finally {
                recycle(rows);
                if (root != null) root.recycle();
            }
            if (!observed) SystemClock.sleep(100);
        }
        require(observed, "Actual own notification required; never inspect another notification body");
        result.putBoolean("otherNotificationTextRecorded", false);
        if (open) {
            result.putBoolean("ownNotificationClicked", true);
            result.putString("postClickWindowScope", "Independently verify actual WindowManager MainActivity focus, PID/startTicks and native generation; a cached pre-click root is not post-click proof.");
        } else {
            result.putString("ownTitleAncestorMetadata", paths.toString());
            result.putBoolean("notificationClicked", false);
        }
    }

    private static void ownTitlePaths(AccessibilityNodeInfo node, JSONArray paths) throws Exception {
        if ("Clash Pseudo".contentEquals(node.getText() == null ? "" : node.getText()) ||
            "Clash Pseudo".contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription())) {
            JSONArray path = new JSONArray();
            AccessibilityNodeInfo cursor = AccessibilityNodeInfo.obtain(node);
            try {
                for (int level = 0; level < 7 && cursor != null; ++level) {
                    path.put(metadata(cursor));
                    AccessibilityNodeInfo parent = cursor.getParent();
                    cursor.recycle();
                    cursor = parent;
                }
            } finally { if (cursor != null) cursor.recycle(); }
            paths.put(path);
        }
        for (int i = 0; i < node.getChildCount(); ++i) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { ownTitlePaths(child, paths); } finally { child.recycle(); }
        }
    }

    private static void buttons(AccessibilityNodeInfo node, String english, String chinese,
                                List<AccessibilityNodeInfo> found) {
        String label = node.getText() == null ? "" : node.getText().toString();
        String description = node.getContentDescription() == null ? "" : node.getContentDescription().toString();
        if (node.isVisibleToUser() && node.isEnabled() && node.isClickable() &&
            (english.equals(label) || chinese.equals(label) || english.equals(description) || chinese.equals(description)))
            found.add(AccessibilityNodeInfo.obtain(node));
        for (int i = 0; i < node.getChildCount(); ++i) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { buttons(child, english, chinese, found); } finally { child.recycle(); }
        }
    }

    private static boolean text(AccessibilityNodeInfo node, String expected) {
        if (expected.contentEquals(node.getText() == null ? "" : node.getText()) ||
            expected.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription())) return true;
        for (int i = 0; i < node.getChildCount(); ++i) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { if (text(child, expected)) return true; } finally { child.recycle(); }
        }
        return false;
    }

    private static void ownRows(AccessibilityNodeInfo node, List<AccessibilityNodeInfo> rows) {
        int before = rows.size();
        for (int i = 0; i < node.getChildCount(); ++i) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { ownRows(child, rows); } finally { child.recycle(); }
        }
        boolean modern = "com.android.systemui:id/expandableNotificationRow".equals(node.getViewIdResourceName());
        boolean legacy = Build.VERSION.SDK_INT == 24 && "com.android.systemui:id/expanded".equals(node.getViewIdResourceName());
        if (rows.size() != before || (!modern && !legacy) || !text(node, "Clash Pseudo") ||
            !(text(node, "Native takeover running") || text(node, "原生接管运行中"))) return;
        if (modern) rows.add(AccessibilityNodeInfo.obtain(node));
        else {
            AccessibilityNodeInfo parent = node.getParent();
            try {
                Rect content = new Rect();
                Rect action = new Rect();
                node.getBoundsInScreen(content);
                if (parent != null) parent.getBoundsInScreen(action);
                if (parent != null && parent.isVisibleToUser() && parent.isEnabled() && parent.isClickable() &&
                    "android.widget.FrameLayout".contentEquals(parent.getClassName()) && content.equals(action))
                    rows.add(AccessibilityNodeInfo.obtain(parent));
            } finally { if (parent != null) parent.recycle(); }
        }
    }

    private static void recycle(List<AccessibilityNodeInfo> nodes) {
        for (AccessibilityNodeInfo node : nodes) node.recycle();
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }
}
