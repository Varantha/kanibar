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

  signal saved(bool ok)
  signal removed()

  function save(newToken) {
    store.pendingToken = newToken
    saveProc.running = true
  }

  function remove() {
    removeProc.running = true
  }

  function finishSave(ok) {
    // Use it right away; the FileView watch confirms it moments later.
    if (ok) store.token = store.pendingToken
    store.pendingToken = ""
    store.saved(ok)
  }

  // Never writes into an existing token file: its mode might let other
  // accounts read it, and a reader that opened it earlier keeps access.
  // Instead the token goes into a new file created private (0600) next to
  // it, which then replaces the old one with an atomic rename. The rename
  // also replaces a symlink at that path rather than writing through it.
  // The token travels over stdin, never argv, so it doesn't show up in the
  // process list.
  readonly property string saveScript: [
    "umask 077",
    "mkdir -p \"$1\" || exit 1",
    "tmp=$(mktemp \"$1/.token.XXXXXX\") || exit 1",
    "trap 'rm -f \"$tmp\"' EXIT",
    "chmod 600 \"$tmp\" || exit 1",
    "IFS= read -r t || exit 1",
    "printf '%s\\n' \"$t\" > \"$tmp\" || exit 1",
    "mv -f \"$tmp\" \"$1/token\" || exit 1",
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
    onExited: {
      store.token = ""
      store.removed()
    }
  }

  FileView {
    path: store.path
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: store.token = String(text() || "").trim().slice(0, Model.MAX_TOKEN_CHARS)
    onLoadFailed: store.token = ""
  }
}
