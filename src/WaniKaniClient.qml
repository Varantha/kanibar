import QtQuick
import Quickshell.Io
import "Model.js" as Model

// GET requests against the fixed WaniKani API base, through curl (see
// Model.curlCommand for why not XMLHttpRequest). The token reaches curl on
// stdin, never argv. No redirects are followed, only HTTPS is allowed, and
// requests fail closed on timeout, oversized or non-JSON responses.
// Callbacks get (status, json), where status is the HTTP status or one of
// Model's pseudo-statuses.
QtObject {
  id: client

  property string token: ""

  // Account isolation: bumped whenever the active token changes or is
  // removed. A request made with the active token belongs to the generation
  // it started in, and its result is dropped (the callback never runs) once
  // the generation has moved on, so an old account's data can't come back
  // after a disconnect or token change. Owners reset their in-flight flags
  // on generationChanged.
  property int generation: 0
  onTokenChanged: generation++

  // Runs `callback` at most once, always asynchronously: exactly once,
  // unless the active token changes first. `tokenOverride` checks a token
  // that isn't saved yet; such a request belongs to no account generation
  // and always reports back.
  function get(path, callback, tokenOverride) {
    var token = tokenOverride || client.token
    var generation = client.generation
    var scoped = !tokenOverride

    function report(status, json) {
      if (scoped && generation !== client.generation) return
      callback(status, json)
    }

    if (!Model.isValidToken(token)) {
      Qt.callLater(function() { report(Model.STATUS_BAD_TOKEN, null) })
      return
    }

    var proc = curlProcess.createObject(client, { command: Model.curlCommand(Model.API_BASE + path) })
    // Backstop in case curl never starts or never exits; curl's own
    // --max-time normally ends the request first.
    var backstop = backstopTimer.createObject(client, { interval: Model.REQUEST_TIMEOUT_MS + 5 * Model.SECOND_MS })
    var output = null
    var exitCode = null
    var finished = false

    function finish(status, json) {
      if (finished) return
      finished = true
      backstop.stop()
      backstop.destroy()
      if (proc.running) proc.running = false
      proc.destroy()
      report(status, json)
    }

    // curl is done once it exited and its output is collected, in either
    // order.
    function settle() {
      if (output === null || exitCode === null) return
      var result = Model.parseCurlResult(exitCode, output)
      finish(result.status, result.json)
    }

    proc.started.connect(function() {
      proc.write(Model.authorizationHeader(token))
      proc.stdinEnabled = false   // EOF: curl reads the header file to the end
    })
    proc.collector.streamFinished.connect(function() {
      output = proc.collector.text
      settle()
    })
    proc.exited.connect(function(code) {
      exitCode = code
      settle()
    })
    backstop.triggered.connect(function() { finish(Model.STATUS_OFFLINE, null) })

    backstop.start()
    proc.running = true
  }

  // Requests every path in parallel and calls `callback` once with an array
  // of { status, json } in the same order. Dropped as a whole if the active
  // token changes before every request is back.
  function getAll(paths, callback) {
    var results = []
    var pending = paths.length
    paths.forEach(function(path, index) {
      client.get(path, function(status, json) {
        results[index] = { status: status, json: json }
        if (--pending === 0) callback(results)
      })
    })
  }

  property Component curlProcess: Component {
    Process {
      property alias collector: collector
      stdinEnabled: true
      stdout: StdioCollector { id: collector }
    }
  }

  property Component backstopTimer: Component {
    Timer { repeat: false }
  }
}
