// Behavioral tests for Service.qml, the one instance every screen's widget
// shares: runs it in Quickshell with a scratch XDG_CONFIG_HOME and a fake
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

const OLD = "aaaaaaaa-1111-4111-8111-111111111111"
const NEW = "bbbbbbbb-2222-4222-8222-222222222222"
const omarchyShell = path.join(process.env.OMARCHY_PATH || "/usr/share/omarchy", "shell")
const hasQs = spawnSync("sh", ["-c", "command -v qs"]).status === 0
const hasOmarchy = fs.existsSync(path.join(omarchyShell, "Commons"))
const skip = !hasQs ? "Quickshell (qs) is not installed" : !hasOmarchy ? "Omarchy's shell is not installed" : false

// `script` runs at start with `service`, `screenA`, `screenB` and
// `log(name, value)`; the final state is logged after `waitMs`.
function run(script, waitMs, startMs = 800) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "kanibar-service-"))
  const config = path.join(base, "config")
  const tokenDir = path.join(config, "kanibar")
  fs.mkdirSync(tokenDir, { recursive: true, mode: 0o700 })
  fs.writeFileSync(path.join(tokenDir, "token"), OLD + "\n", { mode: 0o600 })
  // The real directory for the reminder state, kept inside the scratch HOME.
  const home = path.join(base, "home")
  fs.mkdirSync(home)

  const bin = path.join(base, "bin")
  fs.mkdirSync(bin)
  const calls = path.join(base, "curl-calls")
  fs.writeFileSync(path.join(bin, "curl"), `#!/bin/sh
cat > /dev/null
echo "$*" >> "${calls}"
sleep 1.5
printf '%s\\n%s' '{"data":{"username":"old-account","level":5,"lessons":[],"reviews":[]}}' 200
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
  K.Service {
    id: service
    settings: ({ id: "io.github.erfoip.kanibar", refreshMinutes: 0, reminderEnabled: false })
  }
  // Two monitors' widgets: each just holds the shared service.
  QtObject { id: screenA; property var service: service }
  QtObject { id: screenB; property var service: service }
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
      Qt.quit()
    }
  }
}
`)
  const result = spawnSync("qs", ["-p", harness], {
    env: { ...process.env, XDG_CONFIG_HOME: config, HOME: home, PATH: bin + ":" + process.env.PATH },
    encoding: "utf8",
    timeout: startMs + waitMs + 12000
  })
  const results = {}
  for (const line of (result.stdout + result.stderr).split("\n")) {
    const m = /RESULT (\{.*\})\s*$/.exec(line)
    if (m) { const r = JSON.parse(m[1]); results[r.name] = r.value }
  }
  assert.ok(results.final, "harness produced no result:\n" + result.stdout + result.stderr)
  const file = path.join(tokenDir, "token")
  results.file = fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim() : null
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
