import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The API token in the system keyring. On Omarchy that is gnome-keyring
// (in the base install, also used by Chromium and the Secret portal),
// reached through libsecret's secret-tool. Storing the token is the
// keyring's job; this file only stores, looks up and clears one entry. The
// token travels over stdin and stdout, never argv, so it doesn't show up in
// the process list.
//
// What the keyring adds is a well-tested place for the token outside
// Kanibar's own code and config, not protection from programs running as
// the user: the Secret Service has no per-app access control. Encryption
// at rest depends on the keyring having a password. Omarchy's default
// keyring has none, so it is always unlocked and its file in
// ~/.local/share/keyrings is unencrypted, readable only by the user.
//
// Older versions kept the token in $XDG_CONFIG_HOME/kanibar/token. This
// file only reads and deletes that file; Service.migrate() decides, once,
// which older token (if any) moves into the keyring.
Item {
  id: store

  // How the entry is found in the keyring, and what Seahorse shows for it.
  readonly property var attributes: ["service", Model.PLUGIN_ID, "account", "wanikani-api-token"]
  readonly property string label: "Kanibar: WaniKani API token"
  readonly property string legacyDirectory: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/kanibar"
  readonly property string legacyPath: legacyDirectory + "/token"
  readonly property string legacyDisplayPath: legacyPath.replace(Quickshell.env("HOME"), "~")

  // The token in the keyring ("" when there is none).
  property string token: ""
  // The first lookup has finished.
  property bool loaded: false
  // False when the last keyring call couldn't reach the keyring at all.
  property bool available: true

  property string pendingToken: ""
  // True from save() until its result is in.
  property bool saving: false
  // A removal asked for while a save was still running. It runs once the
  // save is done, so the save can't land after it and bring the token back.
  property bool removeQueued: false

  signal saved(bool ok)
  // ok is false when a token could not be removed: reason "keyring" (still
  // in the keyring, e.g. locked) or "legacyFile" (an older version's token
  // file couldn't be deleted, so a later start would import it again).
  signal removed(bool ok, string reason)

  Component.onCompleted: store.lookup()

  // ---------- Keyring calls ----------
  // Runs secret-tool and calls done(result) once, with result.found (exit 0),
  // result.unreachable (it failed and said why on stderr; "not found"
  // fails silently) and result.output.
  function secretTool(args, input, done) {
    var proc = secretToolProcess.createObject(store, { command: ["secret-tool"].concat(args) })
    var exitCode = null
    var output = null
    var errors = null
    function settle() {
      if (exitCode === null || output === null || errors === null) return
      proc.destroy()
      done({ found: exitCode === 0, unreachable: exitCode !== 0 && errors.trim() !== "", output: output })
    }
    proc.started.connect(function() {
      if (input !== null) proc.write(input)
      proc.stdinEnabled = false   // EOF: secret-tool store reads the secret to the end
    })
    proc.out.streamFinished.connect(function() { output = proc.out.text; settle() })
    proc.err.streamFinished.connect(function() { errors = proc.err.text; settle() })
    proc.exited.connect(function(code) { exitCode = code; settle() })
    proc.running = true
  }

  // done(value, unreachable) is optional; the result also updates `token`.
  function lookup(done) {
    store.secretTool(["lookup"].concat(store.attributes), null, function(result) {
      store.available = !result.unreachable
      var value = result.found ? String(result.output).trim().slice(0, Model.MAX_TOKEN_CHARS) : ""
      if (!result.unreachable) store.token = value
      store.loaded = true
      if (done) done(value, result.unreachable)
    })
  }

  function save(newToken) {
    store.saving = true
    store.pendingToken = newToken
    store.secretTool(["store", "--label=" + store.label].concat(store.attributes), newToken, function(result) {
      store.available = !result.unreachable
      store.finishSave(result.found)
    })
  }

  function remove() {
    if (store.saving) {
      store.removeQueued = true
      return
    }
    store.clearConfirmed(1, function(ok) {
      if (!ok) {
        store.removed(false, "keyring")
        return
      }
      // An older version's token file must go too, or a later start
      // would import it again.
      store.deleteLegacy(function(fileGone) { store.removed(fileGone, fileGone ? "" : "legacyFile") })
    })
  }

  // secret-tool clear exits 1 silently both when there was nothing to clear
  // and when the entry is locked (libsecret only deletes unlocked items), so
  // its exit code confirms nothing. A lookup can't confirm it either: for a
  // locked entry whose unlock prompt is dismissed it also reports "not
  // found". A search without unlocking lists matching items whether locked
  // or not (libsecret's load_items), so that is the check. If the entry is
  // still there, a lookup asks the user to unlock the keyring and the
  // removal is tried once more. When it still fails, `token` becomes what
  // the keyring hands out (nothing, if it stays locked), so the app never
  // keeps running on a different token than the one stored.
  function clearConfirmed(retries, done) {
    store.secretTool(["clear"].concat(store.attributes), null, function(cleared) {
      store.available = !cleared.unreachable
      // Unreachable: what's stored is unknown, so stop using the token
      // rather than risk running on a different one than the keyring holds.
      if (cleared.unreachable) {
        store.token = ""
        done(false)
        return
      }
      store.isStored(function(present, unreachable) {
        if (unreachable) {
          store.token = ""
          done(false)
        } else if (!present) {
          store.token = ""
          done(true)
        } else if (retries > 0) {
          store.lookup(function() { store.clearConfirmed(retries - 1, done) })
        } else {
          store.lookup(function() { done(false) })
        }
      })
    })
  }

  // done(present, unreachable): whether the keyring holds the entry at all,
  // locked or not. Never prompts.
  function isStored(done) {
    store.secretTool(["search", "--all"].concat(store.attributes), null, function(result) {
      store.available = !result.unreachable
      done(!result.unreachable && /^\[/m.test(String(result.output)), result.unreachable)
    })
  }

  function finishSave(ok) {
    store.saving = false
    var removeNext = store.removeQueued
    store.removeQueued = false
    // Unless a removal is waiting: then the new token never becomes active.
    if (ok && !removeNext) store.token = store.pendingToken
    store.pendingToken = ""
    store.saved(ok && !removeNext)
    if (removeNext) store.remove()
  }


  // Stores a token found elsewhere (an older version's file or setting)
  // without going through the token entry flow. done(ok). Used only by
  // Service.migrate().
  function adopt(value, done) {
    store.secretTool(["store", "--label=" + store.label].concat(store.attributes), value, function(result) {
      store.available = !result.unreachable
      if (result.found) store.token = value
      done(result.found)
    })
  }

  // ---------- An older version's token file ----------
  // done(value): its trimmed contents, or "" when there is no file.
  function readLegacy(done) {
    var proc = legacyReadProcess.createObject(store, {})
    var exitCode = null
    var output = null
    function settle() {
      if (exitCode === null || output === null) return
      proc.destroy()
      done(exitCode === 0 ? String(output).trim() : "")
    }
    proc.out.streamFinished.connect(function() { output = proc.out.text; settle() })
    proc.exited.connect(function(code) { exitCode = code; settle() })
    proc.running = true
  }

  // done(ok): ok once the file is confirmed gone (or was never there). The
  // then-empty directory is removed if possible; that part is optional.
  function deleteLegacy(done) {
    var proc = legacyDeleteProcess.createObject(store, {})
    proc.exited.connect(function(code) {
      proc.destroy()
      done(code === 0)
    })
    proc.running = true
  }

  property Component legacyReadProcess: Component {
    Process {
      property alias out: legacyOut
      command: ["cat", store.legacyPath]
      stdout: StdioCollector { id: legacyOut }
    }
  }

  property Component legacyDeleteProcess: Component {
    Process {
      command: ["sh", "-c", "rm -f \"$1/token\"; [ ! -e \"$1/token\" ] || exit 1; rmdir \"$1\" 2>/dev/null; exit 0", "sh", store.legacyDirectory]
    }
  }

  property Component secretToolProcess: Component {
    Process {
      property alias out: outCollector
      property alias err: errCollector
      stdinEnabled: true
      stdout: StdioCollector { id: outCollector }
      stderr: StdioCollector { id: errCollector }
    }
  }
}
