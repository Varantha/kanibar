// UI regression tests for the token field: the real TokenEntry (with
// Omarchy's own TextField and Button) wired to the real TokenSession and
// TokenStore, in Quickshell, with a scratch XDG_CONFIG_HOME and a fake API
// client. A pasted token must not stay in the field, ready to reconnect with
// one click. Skipped where Quickshell or Omarchy's shell isn't installed.
// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")
const { src } = require("./load-model")

const OLD = "aaaaaaaa-1111-4111-8111-111111111111"
const NEW = "bbbbbbbb-2222-4222-8222-222222222222"
const omarchyShell = path.join(process.env.OMARCHY_PATH || "/usr/share/omarchy", "shell")
const hasQs = spawnSync("sh", ["-c", "command -v qs"]).status === 0
const hasOmarchy = fs.existsSync(path.join(omarchyShell, "Ui"))
const skip = !hasQs ? "Quickshell (qs) is not installed" : !hasOmarchy ? "Omarchy's shell is not installed" : false
const STEP_MS = 600

function run(steps) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "kanibar-entry-"))
  const tokenDir = path.join(base, "config", "kanibar")
  fs.mkdirSync(tokenDir, { recursive: true, mode: 0o700 })
  fs.writeFileSync(path.join(tokenDir, "token"), OLD + "\n", { mode: 0o600 })
  const harness = path.join(base, "harness")
  fs.mkdirSync(harness)
  // "qs.Commons" and "qs.Ui" resolve against the config root.
  for (const module of ["Commons", "Ui"]) fs.symlinkSync(path.join(omarchyShell, module), path.join(harness, module))
  fs.writeFileSync(path.join(harness, "shell.qml"), `
import QtQuick
import Quickshell
import "${"file://" + src}" as K
ShellRoot {
  id: root
  function log(name, value) { console.log("RESULT " + JSON.stringify({ name: name, value: value })) }
  function connectButton() {
    function find(item) {
      for (var i = 0; i < item.children.length; i++) {
        var c = item.children[i]
        if (c.bordered !== undefined && c.text === l10n.t("token.connect")) return c
        var r = find(c)
        if (r) return r
      }
      return null
    }
    return find(entry)
  }
  function fieldState() {
    return { text: entry.input.text, connectEnabled: connectButton().enabled }
  }

  QtObject {
    id: client
    property var pending: null
    function get(path, callback, tokenOverride) { pending = callback }
    function answer(status) { var c = pending; pending = null; c(status, null) }
  }
  K.TokenStore { id: store }
  K.TokenSession { id: session; client: client; store: store }
  K.Localization { id: l10n }

  FloatingWindow {
    visible: true; implicitWidth: 400; implicitHeight: 300
    K.TokenEntry {
      id: entry
      width: 380
      l10n: l10n
      busy: session.busy
      editing: session.editing
      canCancel: session.canCancel
      clearCount: session.clearCount
      onSubmitted: function(token) { session.submit(token) }
    }
  }

  property var steps: [
    ${steps.map(s => "function() { " + s + " }").join(",\n    ")},
    function() { log("final", fieldState()); Qt.quit() }
  ]
  property int stepIndex: 0
  Timer {
    interval: ${STEP_MS}; repeat: true; running: true
    onTriggered: { root.steps[root.stepIndex](); root.stepIndex++ }
  }
}
`)
  const result = spawnSync("qs", ["-p", harness], {
    env: { ...process.env, XDG_CONFIG_HOME: path.join(base, "config") },
    encoding: "utf8",
    timeout: (steps.length + 4) * STEP_MS + 8000
  })
  const results = {}
  for (const line of (result.stdout + result.stderr).split("\n")) {
    const m = /RESULT (\{.*\})\s*$/.exec(line)
    if (m) { const r = JSON.parse(m[1]); results[r.name] = r.value }
  }
  assert.ok(results.final, "harness produced no result:\n" + result.stdout + result.stderr)
  return results
}

test("after Disconnect the field is empty and Connect is disabled", { skip }, () => {
  const r = run([
    `session.startEditing(); entry.input.text = "${NEW}"; log("pasted", fieldState())`,
    `session.disconnect()`,
  ])
  assert.deepEqual(r.pasted, { text: NEW, connectEnabled: true })
  assert.deepEqual(r.final, { text: "", connectEnabled: false })
})

test("after a successful connect the field is empty", { skip }, () => {
  const r = run([
    `session.startEditing(); entry.input.text = "${NEW}"; session.submit(entry.input.text)`,
    `client.answer(200)`,
  ])
  assert.deepEqual(r.final, { text: "", connectEnabled: false })
})

test("after Cancel the field is empty", { skip }, () => {
  const r = run([
    `session.startEditing(); entry.input.text = "${NEW}"`,
    `session.cancel()`,
  ])
  assert.deepEqual(r.final, { text: "", connectEnabled: false })
})

test("a rejected token stays in the field to be corrected", { skip }, () => {
  const r = run([
    `session.startEditing(); entry.input.text = "${NEW}"; session.submit(entry.input.text)`,
    `client.answer(401)`,
  ])
  assert.deepEqual(r.final, { text: NEW, connectEnabled: true })
})
