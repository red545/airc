# Engine changes queued for the next engine build

Changes to `engine/` that don't justify a relink by themselves. Any commit under `engine/` reopens the Chromium
release review, so they wait here and ride with the next engine build (a Chromium update or other engine work). The
agent doing that build applies them, relinks once, and removes them from this file in the same commit. (Not
`pending-update.md`: that one is the watcher's generated, untracked dispatch brief.)

## DevTools dock at the bottom by default (devtoolsdock, 2026-11-27)

Why: Chromium's DevTools frontend starts a profile that never chose a side on the **right** (`currentDockState`
defaults to `"right"`). A user asked for them below the page, as they know it from Arc. Measured on the build Mac: a new
profile's DevTools (⌥⌘I or the page's context-menu Inspect) dock on the right.

What: when the app first wraps a regular profile, if neither `devtools.preferences` nor the two synced DevTools
dictionaries has `currentDockState`, set it to `"\"bottom\""` once. A side the person picks (⋮ › Dock side, ⌘⇧D)
stays, per profile, in Chrome's own storage. Off-the-record profiles read their original profile's. No Chromium patch.

After the relink, in the same change:
- `apps/browser/Sources/Airc/Debug/DevToolsDockCheck.swift`, `chromiumContextInspect`: turn the note "a new profile's
  first side" back into `check(l.side == "bottom", "a new profile's DevTools open at the bottom (\(l.side))")`.
- `docs/user/devmode.md`, "Developer Tools in the window": say they open at the bottom until you pick another side.

```diff
diff --git a/engine/core/airc_profile.mm b/engine/core/airc_profile.mm
index 2d47c020..3844e6cb 100644
--- a/engine/core/airc_profile.mm
+++ b/engine/core/airc_profile.mm
@@ -29,6 +29,7 @@
 #include "components/autofill/core/common/autofill_prefs.h"
 #include "components/password_manager/core/common/password_manager_pref_names.h"
 #include "components/prefs/pref_service.h"
+#include "components/prefs/scoped_user_pref_update.h"
 #include "content/public/browser/browsing_data_remover.h"
 #include "content/public/browser/spare_render_process_host_manager.h"
 #include "extensions/browser/extension_registry.h"
@@ -193,6 +194,30 @@ bool IsProfileDeleting(const Profile* profile) {
   BOOL _offTheRecord;
 }
 
+namespace {
+// Airc's default: DevTools dock at the bottom of the page. Chrome's frontend starts a profile that never
+// chose a side on the right ("currentDockState" defaults to "right"), so a regular profile with no side in either of
+// DevTools' preference dictionaries gets "bottom" once. A side the person picks (⋮ › Dock side, ⌘⇧D) is theirs and
+// stays. Off-the-record profiles read their original profile's.
+void SeedDevToolsDockSide(Profile* profile) {
+  if (profile->IsOffTheRecord()) {
+    return;
+  }
+  PrefService* prefs = profile->GetPrefs();
+  if (!prefs->FindPreference(prefs::kDevToolsPreferences)) {
+    return;
+  }
+  for (const char* name : {prefs::kDevToolsPreferences, prefs::kDevToolsSyncedPreferencesSyncEnabled,
+                           prefs::kDevToolsSyncedPreferencesSyncDisabled}) {
+    if (prefs->FindPreference(name) && prefs->GetDict(name).FindString("currentDockState")) {
+      return;  // The person's side (or one seeded before).
+    }
+  }
+  ScopedDictPrefUpdate update(prefs, prefs::kDevToolsPreferences);
+  update->Set("currentDockState", "\"bottom\"");  // DevTools keeps every value as a JSON string.
+}
+}  // namespace
+
 + (AircProfile*)wrapperFor:(Profile*)profile {
   if (!profile || airc::IsProfileDying(profile)) {
     return nil;
@@ -205,6 +230,7 @@ bool IsProfileDeleting(const Profile* profile) {
     wrapper->_name = NS(profile->GetBaseName().value());
     wrapper->_path = NS(profile->GetPath().value());
     wrapper->_observer = std::make_unique<ProfileGoneObserver>(profile, wrapper);
+    SeedDevToolsDockSide(profile);
   }
   return wrapper;
 }
```
