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

Item {
  id: store

  // How the entry is found in the keyring, and what Seahorse shows for it.
  readonly property var attributes: ["service", Model.PLUGIN_ID, "account", "wanikani-api-token"]
  readonly property string label: "Kanibar: WaniKani API token"

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
  // True from remove() until its result is in. TokenSession refuses new
  // tokens meanwhile, so a removal's retry can't delete a token saved
  // after it started.
  property bool removing: false
  // Bumped by every save and removal; the startup lookup only applies its
  // answer if none started while it ran.
  property int operations: 0

  signal saved(bool ok)
  // ok is false when the removal couldn't be confirmed: the token may still
  // be in the keyring (e.g. locked, or the keyring unreachable).
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

  // done(value, unreachable) is optional; the result also updates `token`.
  // The startup lookup. Its answer is dropped if a save or removal started
  // meanwhile: that newer operation decides the token, not this older read.
  function lookup() {
    var operations = store.operations
    store.secretTool(["lookup"].concat(store.attributes), null, function(result) {
      store.available = !result.unreachable
      store.loaded = true
      if (operations !== store.operations || result.unreachable) return
      store.token = result.found ? String(result.output).trim().slice(0, Model.MAX_TOKEN_CHARS) : ""
    })
  }

  function save(newToken) {
    store.operations++
    store.saving = true
    store.pendingToken = newToken
    store.secretTool(["store", "--label=" + store.label].concat(store.attributes), newToken, function(result) {
      store.available = !result.unreachable
      store.finishSave(result.found)
    })
  }

  // Disconnect: the token stops being used immediately and stays unused
  // whatever the outcome, so a failed or partial removal can never leave
  // the app running on it (or on a different one than stored).
  //
  // A second request while one is running joins it (one removal, one
  // result), so repeated clicks can't start overlapping removals.
  function remove() {
    if (store.removing) return
    store.removing = true
    store.operations++
    store.token = ""
    if (store.saving) {
      store.removeQueued = true
      return
    }
    store.startRemoval()
  }

  function startRemoval() {
    store.clearConfirmed(1, function(ok) {
      store.removing = false
      store.removed(ok)
    })
  }

  // secret-tool clear exits 1 silently both when there was nothing to clear
  // and when the entry is locked (libsecret only deletes unlocked items), so
  // its exit code confirms nothing. A lookup can't confirm it either: for a
  // locked entry whose unlock prompt is dismissed it also reports "not
  // found". A search without unlocking lists matching items whether locked
  // or not (libsecret's load_items), so that is the check. If the entry is
  // still there, a lookup asks the user to unlock the keyring (its result
  // is discarded, never published as the active token) and the removal is
  // tried once more.
  function clearConfirmed(retries, done) {
    store.secretTool(["clear"].concat(store.attributes), null, function(cleared) {
      store.available = !cleared.unreachable
      if (cleared.unreachable) {
        done(false)
        return
      }
      store.isStored(function(present, known) {
        if (!known) done(false)
        else if (!present) done(true)
        else if (retries > 0) store.unlock(function() { store.clearConfirmed(retries - 1, done) })
        else done(false)
      })
    })
  }

  // Asks the keyring to unlock the entry (a lookup prompts for that) and
  // throws the secret away.
  function unlock(done) {
    store.secretTool(["lookup"].concat(store.attributes), null, function(result) {
      store.available = !result.unreachable
      done()
    })
  }

  // done(present, known): whether the keyring holds the entry at all,
  // locked or not. Never prompts. Only a search that succeeded is an
  // answer (the real secret-tool exits 0 with no output when nothing
  // matches); any failure, with or without a message, leaves it unknown.
  function isStored(done) {
    store.secretTool(["search", "--all"].concat(store.attributes), null, function(result) {
      store.available = !result.unreachable
      var known = result.found
      done(known && /^\[/m.test(String(result.output)), known)
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
    if (removeNext) store.startRemoval()   // `removing` is already set
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
