import QtQuick
import Quickshell
import "Model.js" as Model

// The one place Kanibar's account lives. Omarchy builds the bar once per
// monitor, so a bar widget exists once per screen; the shell mounts exactly
// one service per plugin. Everything that must exist once lives here: the
// API client, the token store and token entry flow, the account's data, the
// refresh timers and the daily reminder. Each screen's Panel is a view onto
// this object (bar.shell.serviceFor). That keeps a Disconnect on one screen
// from being undone by a token check pending on another, and keeps several
// monitors from multiplying requests and reminders.
Item {
  id: service

  // Injected by the shell.
  property var shell: null
  // Pushed by the bar widgets: their (shared) shell.json entry without its
  // id. An entry with only defaults is {}, which is valid: a key that is
  // missing means its default, including no apiToken override.
  property var settings: ({})

  // The bar widgets currently on screen (one per monitor). The service can
  // outlive them: the shell keeps it while the plugin is enabled, even with
  // no widget on the bar. Background work (refreshes, the reminder) only
  // runs while at least one is attached.
  property var attachedWidgets: []
  readonly property bool attached: attachedWidgets.length > 0

  function attach(widget) {
    if (service.attachedWidgets.indexOf(widget) === -1) service.attachedWidgets = service.attachedWidgets.concat([widget])
  }

  function detach(widget) {
    service.attachedWidgets = service.attachedWidgets.filter(function(w) { return w !== widget })
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  Localization { id: strings }
  WaniKaniClient { id: apiClient; token: service.apiToken }

  readonly property alias tokenStore: tokenStore
  readonly property alias tokenSession: tokenSession
  readonly property alias reminder: reminder

  // ---------- Settings ----------
  readonly property string settingsToken: String(setting("apiToken", "") || "").trim()
  readonly property string apiToken: settingsToken !== "" ? settingsToken : tokenStore.token
  readonly property bool hasToken: apiToken !== ""
  // 0 turns background refresh off (popup open and middle-click still refresh).
  readonly property int refreshMinutes: Model.intSetting(setting("refreshMinutes", Model.DEFAULT_REFRESH_MINUTES),
                                                         Model.DEFAULT_REFRESH_MINUTES, 0, Model.MAX_REFRESH_MINUTES)
  readonly property bool autoRefresh: refreshMinutes > 0
  readonly property bool reminderEnabled: setting("reminderEnabled", false) === true
  readonly property string reminderTime: Model.clockText(setting("reminderTime", Model.DEFAULT_REMINDER_TIME))
  readonly property int reminderMinReviews: Model.intSetting(setting("reminderMinReviews", 1), 1, 1)

  // ---------- State ----------
  // Everything between here and "End of account state" belongs to the
  // active token's account. resetAccount() clears all of it whenever that
  // token changes or is removed (test/contracts.test.js checks it), and
  // WaniKaniClient drops results of requests made with the previous token.
  // Within one account, summary/user are kept on failure so stale numbers
  // stay visible.
  property var summary: null
  property var user: null
  property var error: null              // Model message or null
  property bool loading: false
  property real lastUpdated: 0

  // ---------- Popup details: SRS breakdown + level progress ----------
  // Fetched only while a popup is open, at most every DETAILS_MAX_AGE_MS,
  // so the background refresh stays at two requests.
  property var srsCounts: null
  property var levelInfo: null
  property bool detailsLoading: false
  property real detailsUpdated: 0
  property int detailsLevel: 0

  // ---------- Token problems ----------
  property bool tokenRejected: false   // last refresh got a 401 or the token is malformed
  property bool tokenMalformed: false  // the stored token isn't a valid API token
  // ---------- End of account state ----------

  // Timed refreshes run only while a widget is attached and has a token.
  readonly property bool backgroundRefresh: attached && hasToken && autoRefresh

  readonly property int reviews: summary ? summary.reviews : 0
  readonly property int lessons: summary ? summary.lessons : 0

  // The token file is gone: each screen's Panel returns to its main view.
  signal disconnected()

  // ---------- Data ----------
  // `withDetails`: a popup is open, so also fetch its SRS and level details.
  function refresh(withDetails) {
    if (!service.attached) return
    if (!service.hasToken) {
      service.error = null
      return
    }
    if (service.loading) return
    service.loading = true
    apiClient.getAll(["/summary", "/user"], function(results) {
      var summaryResult = results[0]
      var userResult = results[1]
      if (summaryResult.status === 200) service.summary = Model.parseSummary(summaryResult.json, Date.now())
      if (userResult.status === 200) service.user = Model.parseUser(userResult.json)
      service.tokenMalformed = summaryResult.status === Model.STATUS_BAD_TOKEN
      if (Model.tokenRejected(summaryResult.status) || Model.tokenRejected(userResult.status)) service.tokenRejected = true
      else if (userResult.status === 200) service.tokenRejected = false

      var failed = [summaryResult, userResult].filter(function(r) { return r.status !== 200 })[0]
      service.error = failed ? Model.errorInfo(failed.status) : null
      if (!failed) service.lastUpdated = Date.now()
      service.loading = false
      if (userResult.status === 200 && withDetails) service.refreshDetails(false)
    })
  }

  function refreshDetails(force) {
    var level = service.user ? service.user.level : 0
    if (!level || service.detailsLoading || !service.hasToken) return
    var fresh = Date.now() - service.detailsUpdated < Model.DETAILS_MAX_AGE_MS
    if (!force && fresh && level === service.detailsLevel) return

    service.detailsLoading = true
    var groups = Model.SRS_GROUPS
    var paths = groups.map(function(group) { return "/assignments?srs_stages=" + group.stages })
    paths.push("/subjects?types=kanji&levels=" + level)
    paths.push("/assignments?subject_types=kanji&levels=" + level)

    apiClient.getAll(paths, function(results) {
      service.detailsLoading = false
      // Keep the previous numbers visible when anything failed.
      if (results.some(function(r) { return r.status !== 200 })) return
      var counts = {}
      groups.forEach(function(group, i) { counts[group.key] = Model.totalCount(results[i].json) })
      var subjects = results[groups.length].json
      var assignments = results[groups.length + 1].json
      service.srsCounts = Model.srsBreakdown(counts)
      service.levelInfo = Model.levelProgress(subjects, assignments, level)
      service.detailsLevel = level
      service.detailsUpdated = Date.now()
    })
  }

  // A new token was saved and is active. Re-entering the active token
  // changes nothing (and resets nothing), so clear these here too.
  function tokenConnected() {
    service.tokenRejected = false
    service.tokenMalformed = false
    service.error = null
    service.refresh(true)
  }

  // Clears everything that belongs to the active token's account, including
  // in-flight flags: the client drops the results those were waiting for.
  function resetAccount() {
    service.summary = null
    service.user = null
    service.error = null
    service.loading = false
    service.lastUpdated = 0
    service.srsCounts = null
    service.levelInfo = null
    service.detailsLoading = false
    service.detailsUpdated = 0
    service.detailsLevel = 0
    service.tokenRejected = false
    service.tokenMalformed = false
  }

  function tokenDisconnected() {
    service.resetAccount()
    service.disconnected()
  }

  onApiTokenChanged: {
    service.resetAccount()
    Qt.callLater(function() { service.refresh(false) })
  }
  onAttachedChanged: if (attached) Qt.callLater(function() { service.refresh(false) })

  TokenStore {
    id: tokenStore
  }

  TokenSession {
    id: tokenSession
    client: apiClient
    store: tokenStore
    onConnected: service.tokenConnected()
    onDisconnected: service.tokenDisconnected()
  }

  Reminder {
    id: reminder
    client: apiClient
    l10n: strings
    active: service.attached && service.reminderEnabled && service.hasToken
    clockMinutes: Model.parseClock(service.reminderTime)
    minReviews: service.reminderMinReviews
    onSummaryFetched: function(summary) { service.summary = summary }
  }

  // Background refresh (disclosed in the README; refreshMinutes 0 = off).
  Timer {
    interval: Math.max(1, service.refreshMinutes) * Model.MINUTE_MS
    running: service.backgroundRefresh
    repeat: true
    onTriggered: service.refresh(false)
  }

  // New reviews unlock on the hour; refresh just after it.
  Timer {
    running: service.backgroundRefresh
    interval: Model.msUntilNextHour(Date.now())
    onTriggered: {
      service.refresh(false)
      interval = Model.msUntilNextHour(Date.now())
      restart()
    }
  }
}
