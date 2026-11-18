// Behavioral tests for the token entry flow: runs the real TokenSession and
// TokenStore in Quickshell, with a scratch XDG_CONFIG_HOME and a fake API
// client whose answer the scenario releases at a chosen moment. That makes
// orderings like "check succeeds, save starts, then Cancel" reproducible.
// Skipped where Quickshell (qs) isn't installed. Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")
const { src } = require("./load-model")

const OLD = "aaaaaaaa-1111-4111-8111-111111111111"
const NEW = "bbbbbbbb-2222-4222-8222-222222222222"
const hasQs = spawnSync("sh", ["-c", "command -v qs"]).status === 0

// `steps` is QML/JS run in order, each after the previous one settled
// (STEP_MS apart, enough for the store's processes). Steps can use:
// session, store, client.answer(status), log(name, value).
const STEP_MS = 600

function run(steps, { tokenDirMode } = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "kanibar-session-"))
  const config = path.join(base, "config")
  const tokenDir = path.join(config, "kanibar")
  fs.mkdirSync(tokenDir, { recursive: true, mode: 0o700 })
  fs.writeFileSync(path.join(tokenDir, "token"), OLD + "\n", { mode: 0o600 })
  if (tokenDirMode !== undefined) fs.chmodSync(tokenDir, tokenDirMode)

  const harness = path.join(base, "harness")
  fs.mkdirSync(harness)
  fs.writeFileSync(path.join(harness, "shell.qml"), `
import QtQuick
import Quickshell
import "${"file://" + src}" as K
ShellRoot {
  id: root
  property int connectedCount: 0
  property int disconnectedCount: 0
  function log(name, value) { console.log("RESULT " + JSON.stringify({ name: name, value: value })) }

  QtObject {
    id: client
    property var pending: null
    function get(path, callback, tokenOverride) { pending = callback }
    function answer(status) {
      var callback = pending
      pending = null
      callback(status, status === 200 ? { data: { username: "new", level: 1 } } : null)
    }
  }
  K.TokenStore { id: store }
  K.TokenSession {
    id: session
    client: client
    store: store
    onConnected: root.connectedCount++
    onDisconnected: root.disconnectedCount++
  }

  property var steps: [
    ${steps.map(s => "function() { " + s + " }").join(",\n    ")},
    function() {
      log("final", {
        phase: session.phase, editing: session.editing,
        error: session.error ? session.error.key : null,
        accountError: session.accountError ? session.accountError.key : null,
        storeToken: store.token === "${OLD}" ? "old" : store.token === "${NEW}" ? "new" : store.token,
        connected: root.connectedCount, disconnected: root.disconnectedCount,
        clearCount: session.clearCount
      })
      Qt.quit()
    }
  ]
  property int stepIndex: 0
  Timer {
    interval: ${STEP_MS}; repeat: true; running: true
    onTriggered: { root.steps[root.stepIndex](); root.stepIndex++ }
  }
}
`)
  const result = spawnSync("qs", ["-p", harness], {
    env: { ...process.env, XDG_CONFIG_HOME: config },
    encoding: "utf8",
    timeout: (steps.length + 4) * STEP_MS + 8000
  })
  if (tokenDirMode !== undefined) fs.chmodSync(tokenDir, 0o700)
  const results = {}
  for (const line of (result.stdout + result.stderr).split("\n")) {
    const m = /RESULT (\{.*\})\s*$/.exec(line)
    if (m) { const r = JSON.parse(m[1]); results[r.name] = r.value }
  }
  assert.ok(results.final, "harness produced no result:\n" + result.stdout + result.stderr)
  const file = path.join(tokenDir, "token")
  results.file = fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim() : null
  return results
}

const skip = hasQs ? false : "Quickshell (qs) is not installed"

test("a pasted token is checked, saved and connected", { skip }, () => {
  const r = run([
    `session.startEditing(); session.submit("${NEW}")`,
    `log("phase", session.phase); client.answer(200)`,
  ])
  assert.equal(r.phase, "checking")
  assert.equal(r.file, NEW)
  assert.deepEqual(r.final, { phase: "idle", editing: false, error: null, accountError: null, storeToken: "new", connected: 1, disconnected: 0, clearCount: 1 })
})

test("Cancel while checking: nothing is saved and the old token stays", { skip }, () => {
  const r = run([
    `session.startEditing(); session.submit("${NEW}")`,
    `log("cancelled", session.cancel()); client.answer(200)`,
  ])
  assert.equal(r.cancelled, true)
  assert.equal(r.file, OLD)
  assert.deepEqual(r.final, { phase: "idle", editing: false, error: null, accountError: null, storeToken: "old", connected: 0, disconnected: 0, clearCount: 1 })
})

// The ordering from the audit: the check succeeds and the save starts, then
// Cancel. The save can't be undone, so Cancel must refuse, not pretend.
test("Cancel once saving has begun is refused", { skip }, () => {
  const r = run([
    `session.startEditing(); session.submit("${NEW}")`,
    `client.answer(200); log("during", { phase: session.phase, canCancel: session.canCancel, cancelled: session.cancel(), editing: session.editing })`,
  ])
  assert.deepEqual(r.during, { phase: "saving", canCancel: false, cancelled: false, editing: true })
  assert.equal(r.file, NEW)
  assert.deepEqual(r.final, { phase: "idle", editing: false, error: null, accountError: null, storeToken: "new", connected: 1, disconnected: 0, clearCount: 1 })
})

test("Disconnect while checking: the checked token is never saved", { skip }, () => {
  const r = run([
    `session.startEditing(); session.submit("${NEW}")`,
    `session.disconnect(); client.answer(200)`,
  ])
  assert.equal(r.file, null)
  assert.equal(r.final.storeToken, "")
  assert.equal(r.final.connected, 0)
  assert.equal(r.final.disconnected, 1)
  assert.equal(r.final.clearCount, 1)          // the pasted token leaves the field
})

test("Disconnect while saving: the save finishes, then the token is removed", { skip }, () => {
  const r = run([
    `session.startEditing(); session.submit("${NEW}")`,
    `client.answer(200); session.disconnect()`,
  ])
  assert.equal(r.file, null)
  assert.equal(r.final.storeToken, "")
  assert.equal(r.final.connected, 0)
  assert.equal(r.final.disconnected, 1)
  assert.equal(r.final.phase, "idle")
})

test("A failed delete keeps the account connected and says so", { skip }, () => {
  const r = run([`session.disconnect()`], { tokenDirMode: 0o500 })
  assert.equal(r.file, OLD)
  assert.equal(r.final.storeToken, "old")
  assert.equal(r.final.accountError, "settings.disconnectFailed")
  assert.equal(r.final.disconnected, 0)
})

test("A token WaniKani rejects is not saved", { skip }, () => {
  const r = run([
    `session.startEditing(); session.submit("${NEW}")`,
    `client.answer(401)`,
  ])
  assert.equal(r.file, OLD)
  // The rejected token stays in the field so it can be corrected.
  assert.deepEqual(r.final, { phase: "idle", editing: true, error: "token.unknown", accountError: null, storeToken: "old", connected: 0, disconnected: 0, clearCount: 0 })
})

test("Closing the popup clears a pasted token", { skip }, () => {
  const r = run([`session.startEditing(); session.reset()`])
  assert.equal(r.final.clearCount, 1)
  assert.equal(r.final.editing, false)
})
