import QtQuick
import "Model.js" as Model

// The token entry flow: check a pasted token with WaniKani, save it, and
// disconnect. It knows nothing about the UI and only talks to the client
// and store it's given, so test/token-session.test.js can drive it with
// real event orderings.
//
// Phases:
//   idle     nothing in progress
//   checking waiting for WaniKani to accept the pasted token
//   saving   writing the accepted token to disk
//
// Cancel and Disconnect abandon a check: its result is ignored and nothing
// is saved. Once saving has begun the replacement is committed: the old
// file may already be replaced, so Cancel is refused (canCancel is false)
// rather than pretending to undo it. Disconnect during a save still wins:
// TokenStore runs the removal after the save, and the saved token never
// becomes active.
Item {
  id: session

  // WaniKaniClient-like: get(path, callback(status, json), tokenOverride)
  required property var client
  // TokenStore-like: save(token), remove(), path, displayPath,
  // signals saved(bool ok) and removed(bool ok)
  required property var store

  property string phase: "idle"
  property bool editing: false      // "Change token" was clicked
  property var error: null          // Model message for the token entry, or null
  property var accountError: null   // Model message for a failed disconnect, or null

  // Bumped by Cancel and Disconnect. A check or save from an older flow is
  // abandoned.
  property int flow: 0
  property int savingFlow: -1

  readonly property bool busy: phase !== "idle"
  readonly property bool canCancel: phase !== "saving"

  // A newly entered token is saved and active.
  signal connected()
  // The token file is gone; account data should be cleared.
  signal disconnected()

  function startEditing() {
    session.editing = true
  }

  // Check a pasted token against the API, then store it. Nothing is saved
  // unless WaniKani accepts it.
  function submit(raw) {
    if (session.busy) return
    var token = String(raw || "").trim()
    var problem = Model.tokenProblem(token)
    if (problem !== "") {
      session.error = Model.message(problem)
      return
    }
    session.phase = "checking"
    session.error = null
    var flow = session.flow
    session.client.get("/user", function(status, json) {
      if (flow !== session.flow) return   // cancelled or disconnected meanwhile
      if (status !== 200) {
        session.phase = "idle"
        session.error = status === 401 ? Model.message("token.unknown") : Model.errorInfo(status)
        return
      }
      // Only the token is saved: the account's data is fetched once it is
      // the active one.
      session.phase = "saving"
      session.savingFlow = flow
      session.store.save(token)
    }, token)
  }

  // Returns false (and changes nothing) once saving has begun.
  function cancel() {
    if (!session.canCancel) return false
    session.flow++
    session.phase = "idle"
    session.error = null
    session.editing = false
    return true
  }

  function disconnect() {
    session.flow++
    // A check in progress is abandoned. A save in progress finishes first;
    // its result is ignored and the store removes the file afterwards.
    if (session.phase === "checking") session.phase = "idle"
    session.error = null
    session.accountError = null
    session.store.remove()
  }

  // Popup closed: forget messages, keep anything already in progress.
  function reset() {
    session.editing = false
    session.error = null
    session.accountError = null
  }

  function clearError() {
    session.error = null
  }

  Connections {
    target: session.store

    function onSaved(ok) {
      var abandoned = session.savingFlow !== session.flow
      session.phase = "idle"
      if (abandoned) return   // disconnected meanwhile; the removal follows
      if (!ok) {
        session.error = Model.message("token.writeFailed", session.store.path)
        return
      }
      session.editing = false
      session.connected()
    }

    function onRemoved(ok) {
      if (!ok) {
        // The token file is still there, so the account stays connected.
        session.accountError = Model.message("settings.disconnectFailed", session.store.displayPath)
        return
      }
      session.disconnected()
    }
  }
}
