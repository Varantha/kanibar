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
// Older versions kept the token in $XDG_CONFIG_HOME/kanibar/token. On the
// first lookup that finds nothing in the keyring, that file is moved in
// and then deleted. If the keyring already holds a token, a leftover file
// is just deleted. If the keyring can't be reached, the file is left alone.
Item {
  id: store

  // How the entry is found in the keyring, and what Seahorse shows for it.
  readonly property var attributes: ["service", Model.PLUGIN_ID, "account", "wanikani-api-token"]
  readonly property string label: "Kanibar: WaniKani API token"
  readonly property string legacyDirectory: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/kanibar"
  readonly property string legacyPath: legacyDirectory + "/token"

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
  // ok is false when the token could not be removed and is still stored.
  signal removed(bool ok)

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

  function lookup() {
    store.secretTool(["lookup"].concat(store.attributes), null, function(result) {
      store.available = !result.unreachable
      var value = result.found ? String(result.output).trim().slice(0, Model.MAX_TOKEN_CHARS) : ""
      store.token = value
      store.loaded = true
      if (!result.unreachable) store.migrateLegacyFile(value !== "")
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
    store.secretTool(["clear"].concat(store.attributes), null, function(result) {
      // Nothing to clear fails silently, and counts as removed.
      store.available = !result.unreachable
      store.finishRemove(!result.unreachable)
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

  function finishRemove(ok) {
    // On failure the token is still stored, and so still active.
    if (ok) store.token = ""
    store.removed(ok)
  }

  // Stores a token found elsewhere (an older version's file or setting)
  // without going through the token entry flow. done(ok).
  function adopt(value, done) {
    store.secretTool(["store", "--label=" + store.label].concat(store.attributes), value, function(result) {
      store.available = !result.unreachable
      if (result.found) store.token = value
      done(result.found)
    })
  }

  // ---------- Moving an older token file into the keyring ----------
  function migrateLegacyFile(keyringHasToken) {
    legacyRead.keyringHasToken = keyringHasToken
    legacyRead.running = true
  }

  Process {
    id: legacyRead
    property bool keyringHasToken: false
    command: ["cat", store.legacyPath]
    stdout: StdioCollector {
      onStreamFinished: {
        var value = String(text || "").trim()
        if (value === "") return   // no file
        if (legacyRead.keyringHasToken || !Model.isValidToken(value)) {
          legacyDelete.running = true
          return
        }
        store.adopt(value, function(ok) {
          if (ok) legacyDelete.running = true   // otherwise keep the file for next time
        })
      }
    }
  }

  // The file only goes once the keyring has the token (or never needed it).
  Process {
    id: legacyDelete
    command: ["sh", "-c", "rm -f \"$1/token\" && rmdir \"$1\" 2>/dev/null; exit 0", "sh", store.legacyDirectory]
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
