import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The API token on disk at $XDG_CONFIG_HOME/kanibar/token (mode 600). The
// popup saves here; hand-written files work too.
Item {
  id: store

  readonly property string directory: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/kanibar"
  readonly property string path: directory + "/token"
  // The path with $HOME shown as ~, for display.
  readonly property string displayPath: path.replace(Quickshell.env("HOME"), "~")
  // What the file holds right now ("" when missing).
  property string token: ""

  property string pendingToken: ""
  // True from save() until its result is in. Process.running isn't enough:
  // it only turns true once the process has actually started.
  property bool saving: false
  // A removal asked for while a save was still writing. It runs once the
  // save is done, so the save can't land after it and bring the token back.
  property bool removeQueued: false

  signal saved(bool ok)
  // ok is false when the token file could not be deleted and is still there.
  signal removed(bool ok)

  function save(newToken) {
    store.saving = true
    store.pendingToken = newToken
    saveProc.running = true
  }

  function remove() {
    if (store.saving) {
      store.removeQueued = true
      return
    }
    removeProc.running = true
  }

  function finishSave(ok) {
    store.saving = false
    var removeNext = store.removeQueued
    store.removeQueued = false
    // Use it right away (the FileView watch confirms it moments later),
    // unless a removal is waiting: then the new token never becomes active.
    if (ok && !removeNext) store.token = store.pendingToken
    store.pendingToken = ""
    store.saved(ok && !removeNext)
    if (removeNext) removeProc.running = true
  }

  function finishRemove(ok) {
    // On failure the file is still there, and so is the token.
    if (ok) {
      store.discardPendingRead()
      store.token = ""
    }
    store.removed(ok)
  }

  // A read of the token file can still be in flight when it is deleted, and
  // FileView.reload() joins a running read instead of starting a new one, so
  // that read could deliver the deleted token afterwards. Changing the path
  // cancels it (FileView drops results of a disowned read), and setting it
  // back starts a fresh read that finds the file gone.
  function discardPendingRead() {
    tokenFile.path = ""
    tokenFile.path = store.path
  }

  // First makes sure the token directory is ours and private: it must be a
  // real directory (not a symlink) owned by us, and is set to 0700. The
  // temp file below is reopened by name, so another account that could add
  // or remove entries in the directory could otherwise swap in its own file
  // and receive the token. mkdir -p leaves an existing directory's mode as
  // it was, so this can't rely on umask.
  //
  // Never writes into an existing token file either: its mode might let
  // other accounts read it, and a reader that opened it earlier keeps
  // access. Instead the token goes into a new file created private (0600)
  // next to it, which then replaces the old one with an atomic rename. The
  // rename also replaces a symlink at that path rather than writing through
  // it. The token travels over stdin, never argv, so it doesn't show up in
  // the process list.
  readonly property string saveScript: [
    "umask 077",
    "mkdir -p \"$1\" || exit 1",
    "[ -d \"$1\" ] && [ ! -L \"$1\" ] && [ -O \"$1\" ] || exit 1",
    "chmod 700 \"$1\" || exit 1",
    "tmp=$(mktemp \"$1/.token.XXXXXX\") || exit 1",
    "trap 'rm -f \"$tmp\"' EXIT",
    "chmod 600 \"$tmp\" || exit 1",
    "IFS= read -r t || exit 1",
    "printf '%s\\n' \"$t\" > \"$tmp\" || exit 1",
    "mv -fT \"$tmp\" \"$1/token\" || exit 1",
    "trap - EXIT"
  ].join("\n")

  Process {
    id: saveProc
    stdinEnabled: true
    command: ["sh", "-c", store.saveScript, "sh", store.directory]
    onStarted: write(store.pendingToken + "\n")
    onExited: function(exitCode) { store.finishSave(exitCode === 0) }
  }

  Process {
    id: removeProc
    command: ["rm", "-f", store.path]
    onExited: function(exitCode) { store.finishRemove(exitCode === 0) }
  }

  FileView {
    id: tokenFile
    path: store.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: store.token = String(text() || "").trim().slice(0, Model.MAX_TOKEN_CHARS)
    onLoadFailed: store.token = ""
  }
}
