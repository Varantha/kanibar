import QtQuick
import "Model.js" as Model

// GET requests against the fixed WaniKani API base. XMLHttpRequest keeps the
// token out of process argv (unlike curl). Fails closed on timeout,
// oversized or non-JSON responses. Callbacks get (status, json), where
// status is the HTTP status or one of Model's pseudo-statuses.
QtObject {
  id: client

  property string token: ""

  // Runs `callback` exactly once. `tokenOverride` checks a token that isn't
  // saved yet.
  function get(path, callback, tokenOverride) {
    var finished = false
    var xhr = new XMLHttpRequest()
    var timer = timeoutTimer.createObject(client, { interval: Model.REQUEST_TIMEOUT_MS })

    function finish(status, json) {
      if (finished) return
      finished = true
      if (timer) { timer.stop(); timer.destroy() }
      callback(status, json)
    }

    // finish() before abort(): abort() re-enters onreadystatechange
    // synchronously, and that pass must not report its own result.
    function failWith(status) {
      finish(status, null)
      xhr.abort()
    }

    timer.triggered.connect(function() { failWith(Model.STATUS_OFFLINE) })
    xhr.onreadystatechange = function() {
      if (finished) return
      if (xhr.readyState >= XMLHttpRequest.LOADING && xhr.responseText.length > Model.MAX_RESPONSE_CHARS) {
        failWith(Model.STATUS_TOO_LARGE)
        return
      }
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var json = parseJsonObject(xhr.responseText)
      var status = xhr.status === 200 && json === null ? Model.STATUS_OFFLINE : xhr.status
      finish(status, json)
    }
    xhr.open("GET", Model.API_BASE + path)
    xhr.setRequestHeader("Authorization", "Bearer " + (tokenOverride || client.token))
    xhr.setRequestHeader("Wanikani-Revision", Model.API_REVISION)
    xhr.send()
    timer.start()
  }

  // Requests every path in parallel and calls `callback` once with an array
  // of { status, json } in the same order.
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

  function parseJsonObject(text) {
    try {
      var json = JSON.parse(text)
      return json !== null && typeof json === "object" ? json : null
    } catch (e) {
      return null
    }
  }

  property Component timeoutTimer: Component {
    Timer { repeat: false }
  }
}
