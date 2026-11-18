// Behavioral tests for Service.qml, the one instance every screen's widget
// shares: runs it in Quickshell with a fake keyring, a scratch
// XDG_CONFIG_HOME and a fake
// curl on PATH that answers slowly and logs each call. Two "screens" act on
// the same service, as two monitors' widgets do. Skipped where Quickshell
// (qs) isn't installed. Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { spawnSync } = require("node:child_process")
const { src } = require("./load-model")
const { fakeKeyring } = require("./fake-keyring")

const OLD = "aaaaaaaa-1111-4111-8111-111111111111"
const NEW = "bbbbbbbb-2222-4222-8222-222222222222"
const omarchyShell = path.join(process.env.OMARCHY_PATH || "/usr/share/omarchy", "shell")
const hasQs = spawnSync("sh", ["-c", "command -v qs"]).status === 0
const hasOmarchy = fs.existsSync(path.join(omarchyShell, "Commons"))
const skip = !hasQs ? "Quickshell (qs) is not installed" : !hasOmarchy ? "Omarchy's shell is not installed" : false

// `script` runs at start with `service`, `screenA`, `screenB` and
// `log(name, value)`; the final state is logged after `waitMs`.
// Options: settings (the widget entry the screens hand over, default
// refresh off and reminder off), tokenFile (whether the keyring holds a
// token), legacyFile (a token file from an older version).
// reminderHandled: today's reminder already marked done (the default, so an
// enabled reminder isn't due and tests never notify by accident).
function run(script, waitMs, startMs = 800, { settings = { refreshMinutes: 0, reminderEnabled: false }, tokenFile = true, reminderHandled = true, legacyFile = null, keyringDown = null } = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "kanibar-service-"))
  const config = path.join(base, "config")
  const tokenDir = path.join(config, "kanibar")
  fs.mkdirSync(config, { recursive: true })
  if (legacyFile !== null) {
    fs.mkdirSync(tokenDir, { mode: 0o700 })
    fs.writeFileSync(path.join(tokenDir, "token"), legacyFile + "\n", { mode: 0o600 })
  }
  // The real directory for the reminder state, kept inside the scratch HOME.
  const home = path.join(base, "home")
  // Today's reminder already handled, so an enabled reminder isn't due:
  // no extra request and never a real notification from a test.
  const stateDir = path.join(home, ".local", "state", "omarchy")
  fs.mkdirSync(stateDir, { recursive: true })
  const stateFile = path.join(stateDir, "kanibar-reminder")
  const d = new Date()
  const today = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
  if (reminderHandled) fs.writeFileSync(stateFile, today + "\n")

  const keyring = fakeKeyring(base, { secret: tokenFile ? OLD : null, down: keyringDown })
  const bin = keyring.bin
  const calls = path.join(base, "curl-calls")
  // One body for every endpoint: a user, and three reviews due since 2020.
  fs.writeFileSync(path.join(bin, "curl"), `#!/bin/sh
cat > /dev/null
echo "$*" >> "${calls}"
sleep 1.5
printf '%s\\n%s' '{"data":{"username":"old-account","level":5,"lessons":[],"reviews":[{"available_at":"2020-01-01T00:00:00Z","subject_ids":[1,2,3]}]}}' 200
`, { mode: 0o755 })
  // Logs instead of notifying.
  const notifications = path.join(base, "notifications")
  fs.writeFileSync(path.join(bin, "omarchy-notification-send"), `#!/bin/sh
echo "$*" >> "${notifications}"
`, { mode: 0o755 })

  const harness = path.join(base, "harness")
  fs.mkdirSync(harness)
  // Service uses Omarchy's Commons (translations, number formatting). In
  // Quickshell "qs.Commons" resolves against the config root, so link the
  // installed one in.
  fs.symlinkSync(path.join(omarchyShell, "Commons"), path.join(harness, "Commons"))
  fs.writeFileSync(path.join(harness, "shell.qml"), `
import QtQuick
import Quickshell
import "${"file://" + src}" as K
ShellRoot {
  id: root
  function log(name, value) { console.log("RESULT " + JSON.stringify({ name: name, value: value })) }
  property int retiredCount: 0
  K.Service {
    id: service
    settings: (${JSON.stringify(settings)})
    onApiTokenSettingRetired: root.retiredCount++
  }
  // Two monitors' widgets: each holds the shared service and attaches to
  // it, as Panel does.
  QtObject { id: screenA; property var service: service }
  QtObject { id: screenB; property var service: service }
  Component.onCompleted: { service.attach(screenA); service.attach(screenB) }
  Timer {
    interval: ${startMs}; running: true
    onTriggered: { ${script} }
  }
  Timer {
    interval: ${startMs + waitMs}; running: true
    onTriggered: {
      log("final", {
        hasToken: service.hasToken, storeToken: service.tokenStore.token,
        user: service.user ? service.user.username : null,
        summary: service.summary !== null,
        sessionPhase: service.tokenSession.phase
      })
      log("background", { attached: service.attached, backgroundRefresh: service.backgroundRefresh, reminderActive: service.reminder.active })
      log("keyringAvailable", service.keyringAvailable)
      Qt.quit()
    }
  }
}
`)
  const result = spawnSync("qs", ["-p", harness], {
    env: { ...process.env, ...keyring.env, XDG_CONFIG_HOME: config, HOME: home, PATH: bin + ":" + process.env.PATH },
    encoding: "utf8",
    timeout: startMs + waitMs + 12000
  })
  const results = { log: result.stdout + result.stderr }
  for (const line of (result.stdout + result.stderr).split("\n")) {
    const m = /RESULT (\{.*\})\s*$/.exec(line)
    if (m) { const r = JSON.parse(m[1]); results[r.name] = r.value }
  }
  assert.ok(results.final, "harness produced no result:\n" + result.stdout + result.stderr)
  results.file = keyring.secret()   // what the keyring holds afterwards
  results.legacyFileLeft = fs.existsSync(path.join(tokenDir, "token"))
  results.keyringCalls = keyring.calls()
  results.notifications = fs.existsSync(notifications) ? fs.readFileSync(notifications, "utf8").trim().split("\n").filter(Boolean) : []
  results.reminderMarked = fs.existsSync(stateFile) && fs.readFileSync(stateFile, "utf8").trim() === today
  results.curlCalls = fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n").filter(Boolean) : []
  return results
}

// The audited case: a token check pending on one screen must not undo a
// Disconnect made on another. With one shared service there is one session,
// so the Disconnect abandons the check; and the old account's refresh,
// still answering slowly, must not repopulate anything.
test("Disconnect on one screen wins over a token check on another", { skip }, () => {
  const r = run(`
    screenA.service.tokenSession.startEditing()
    screenA.service.tokenSession.submit("${NEW}")
    screenB.service.tokenSession.disconnect()
  `, 3500)
  assert.equal(r.file, null)
  assert.deepEqual(r.final, { hasToken: false, storeToken: "", user: null, summary: false, sessionPhase: "idle" })
})

// Two screens refreshing at once share one request batch instead of each
// sending its own. The service refreshes once on its own when settings
// arrive; the screens ask after that batch has finished (fake curl: 1.5s).
test("Two screens refreshing at once send one batch of requests", { skip }, () => {
  const r = run(`
    screenA.service.refresh(false)
    screenB.service.refresh(false)
  `, 2500, 2800)
  const summaries = r.curlCalls.filter(c => c.includes("/v2/summary")).length
  const users = r.curlCalls.filter(c => c.includes("/v2/user")).length
  assert.equal(summaries, 2, "startup + one shared refresh:\n" + r.curlCalls.join("\n"))
  assert.equal(users, 2, r.curlCalls.join("\n"))
})

// ---------- Moving older storage into the keyring ----------

test("A plaintext apiToken setting is moved into an empty keyring and retired", { skip }, () => {
  const r = run(`log("retired", retiredCount)`, 2500, 800, { settings: { apiToken: NEW }, tokenFile: false })
  assert.equal(r.file, NEW)
  assert.equal(r.final.hasToken, true)
  assert.equal(r.final.storeToken, NEW)
  assert.equal(r.retired, 1)
  assert.ok(!r.keyringCalls.some(c => c.includes(NEW)), "token on a command line")
})

test("A plaintext apiToken setting is dropped when the keyring already has a token", { skip }, () => {
  const r = run(`log("retired", retiredCount)`, 2500, 800, { settings: { apiToken: NEW } })
  assert.equal(r.file, OLD)                // the keyring's token wins and is kept
  assert.equal(r.retired, 1)
})

test("A token file from an older version is moved into the keyring and deleted", { skip }, () => {
  const r = run(``, 2500, 800, { tokenFile: false, legacyFile: NEW })
  assert.equal(r.file, NEW)
  assert.equal(r.legacyFileLeft, false)
  assert.equal(r.final.storeToken, NEW)
})

test("A leftover token file is deleted when the keyring already has a token", { skip }, () => {
  const r = run(``, 2500, 800, { legacyFile: NEW })
  assert.equal(r.file, OLD)
  assert.equal(r.legacyFileLeft, false)
})

// The dangerous case: the keyring answers but refuses to store. Deleting
// the file then would lose the token.
test("If the keyring refuses to store, the token file is kept", { skip }, () => {
  const r = run(``, 2500, 800, { tokenFile: false, legacyFile: NEW, keyringDown: "store" })
  assert.equal(r.legacyFileLeft, true)
  assert.equal(r.file, null)
  assert.equal(r.final.hasToken, false)
})

test("With the keyring unreachable, the token file and setting stay put", { skip }, () => {
  const r = run(`log("retired", retiredCount)`, 2500, 800, { settings: { apiToken: NEW }, tokenFile: false, legacyFile: NEW, keyringDown: "all" })
  assert.equal(r.legacyFileLeft, true)
  assert.equal(r.retired, 0)
  assert.equal(r.final.hasToken, false)
  assert.equal(r.keyringAvailable, false)
})

// The regression a "wait for non-empty settings" guard caused: a widget
// with only defaults must still load.
test("A widget with only default settings loads its data", { skip }, () => {
  const r = run(``, 2500, 800, { settings: {} })
  assert.equal(r.final.hasToken, true)
  assert.equal(r.final.user, "old-account")
  assert.ok(r.curlCalls.some(c => c.includes("/v2/summary")), "no request was made")
})

// The shell keeps the service while the plugin is enabled, even with no
// widget on the bar. With the last widget gone, nothing may run.
test("Removing the last widget stops background work", { skip }, () => {
  const r = run(`
    service.detach(screenA)
    log("oneLeft", { attached: service.attached, backgroundRefresh: service.backgroundRefresh })
    service.detach(screenB)
    service.refresh(false)
  `, 2000, 2800, { settings: { refreshMinutes: 10, reminderEnabled: true } })
  assert.deepEqual(r.oneLeft, { attached: true, backgroundRefresh: true })
  assert.deepEqual(r.background, { attached: false, backgroundRefresh: false, reminderActive: false })
  // Only the startup refresh; the refresh after detaching sent nothing.
  assert.equal(r.curlCalls.filter(c => c.includes("/v2/summary")).length, 1, r.curlCalls.join("\n"))
})

// ---------- Pending work after deactivation ----------
// Each case starts a request, deactivates, then lets the (slow) response
// arrive. A positive control with the same setup shows the side effect does
// happen when nothing is deactivated, so the harness can see it.

const dueReminder = { refreshMinutes: 0, reminderEnabled: true, reminderTime: "00:00", reminderMinReviews: 1 }

test("control: a due reminder notifies and marks the day", { skip }, () => {
  const r = run(``, 2500, 800, { settings: dueReminder, reminderHandled: false })
  assert.equal(r.notifications.length, 1, r.log)
  assert.equal(r.reminderMarked, true)
})

test("Turning reminders off before the response arrives sends nothing", { skip }, () => {
  // The check starts as soon as the screens attach; turn it off mid-flight.
  const r = run(`
    service.settings = (${JSON.stringify({ ...dueReminder, reminderEnabled: false })})
  `, 2500, 400, { settings: dueReminder, reminderHandled: false })
  assert.equal(r.notifications.length, 0)
  assert.equal(r.reminderMarked, false)
})

test("Removing the last widget before the reminder response arrives sends nothing", { skip }, () => {
  const r = run(`
    service.detach(screenA)
    service.detach(screenB)
  `, 2500, 400, { settings: dueReminder, reminderHandled: false })
  assert.equal(r.notifications.length, 0)
  assert.equal(r.reminderMarked, false)
})

const details = (r) => r.curlCalls.filter(c => c.includes("/v2/assignments") || c.includes("/v2/subjects")).length

test("control: a popup refresh fetches the detail batch", { skip }, () => {
  const r = run(`screenA.service.refresh(true)`, 4000, 2800)
  assert.equal(details(r), 7, r.curlCalls.join("\n"))
})

test("Removing the last widget during a popup refresh starts no detail requests", { skip }, () => {
  const r = run(`
    screenA.service.refresh(true)
    service.detach(screenA)
    service.detach(screenB)
  `, 4000, 2800)
  assert.equal(details(r), 0, r.curlCalls.join("\n"))
  assert.equal(r.final.user, "old-account")   // from the startup refresh, before detaching
})
