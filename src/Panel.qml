import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Kanibar: WaniKani reviews and lessons on the Omarchy bar.
// The pill shows reviews (and lessons) available now; clicking opens a popup
// with level progress, SRS stages and the 24-hour forecast. Data comes from
// the official WaniKani API v2.
//
// This file owns the settings and state, decides when to fetch, and lays
// out the popup. The views next to it read state and emit intent;
// WaniKaniClient, TokenStore and Reminder do the I/O.
//
// Safety notes (see Omarchy's plugin guide):
// - Every text goes through PlainText; test/contracts.test.js enforces it.
//   Shared sinks used with API text (PanelHero meta, PanelToolTip) render
//   PlainText internally.
// - Requests use a fixed HTTPS base, a timeout and a response-size cap;
//   Model.js clamps and length-limits everything it parses.
// - All user-facing strings come from i18n/<language>.json.
Panel {
  id: root
  moduleName: Model.PLUGIN_ID
  ipcTarget: Model.PLUGIN_ID
  manageIpc: false

  Localization { id: strings }
  WaniKaniClient { id: apiClient; token: root.apiToken }

  // ---------- Settings ----------
  readonly property string settingsToken: String(setting("apiToken", "") || "").trim()
  readonly property string apiToken: settingsToken !== "" ? settingsToken : tokenStore.token
  readonly property bool hasToken: apiToken !== ""
  // 0 turns background refresh off (popup open and middle-click still refresh).
  readonly property int refreshMinutes: Model.intSetting(setting("refreshMinutes", Model.DEFAULT_REFRESH_MINUTES),
                                                         Model.DEFAULT_REFRESH_MINUTES, 0, Model.MAX_REFRESH_MINUTES)
  readonly property bool autoRefresh: refreshMinutes > 0
  readonly property bool showLessons: setting("showLessons", true) === true
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property int highlightThreshold: Model.intSetting(setting("highlightThreshold", 0), 0, 0)
  readonly property bool reminderEnabled: setting("reminderEnabled", false) === true
  readonly property string reminderTime: Model.clockText(setting("reminderTime", Model.DEFAULT_REMINDER_TIME))
  readonly property int reminderMinReviews: Model.intSetting(setting("reminderMinReviews", 1), 1, 1)

  // ---------- State ----------
  // summary/user are kept on failure so stale numbers stay visible.
  property var summary: null
  property var user: null
  property var error: null              // Model message or null
  property bool loading: false
  property real lastUpdated: 0
  property real now: Date.now()

  readonly property int reviews: summary ? summary.reviews : 0
  readonly property int lessons: summary ? summary.lessons : 0
  // Nothing the bar would show besides the done check (hideWhenIdle hides it).
  readonly property bool idle: Model.idle(summary, showLessons)

  // ---------- Popup details: SRS breakdown + level progress ----------
  // Fetched only while the popup is open, at most every DETAILS_MAX_AGE_MS,
  // so the background refresh stays at two requests.
  property var srsCounts: null
  property var levelInfo: null
  property bool detailsLoading: false
  property real detailsUpdated: 0
  property int detailsLevel: 0

  // ---------- In-popup token entry ----------
  property bool tokenRejected: false   // last refresh got a 401
  property bool editingToken: false    // "Change token" clicked
  property bool tokenBusy: false
  property var tokenError: null        // Model message or null
  readonly property bool showTokenEntry: !hasToken || tokenRejected || editingToken

  // "main" or "settings" (gear in the popup header).
  property string view: "main"
  readonly property bool inSettings: view === "settings"
  readonly property bool showMain: !inSettings && !showTokenEntry

  readonly property var pillParts: {
    if (!hasToken) return { main: "—", extra: "", done: false }
    if (!summary) return { main: error !== null ? "!" : "…", extra: "", done: false }
    return Model.barParts(summary, showLessons, strings.formatNumber)
  }
  // All reviews cleared: the pill and popup show a check in the accent color.
  readonly property bool reviewsDone: pillParts.done === true

  // ---------- Data ----------
  function refresh() {
    root.now = Date.now()
    if (!hasToken) {
      root.error = null
      return
    }
    if (root.loading) return
    root.loading = true
    apiClient.getAll(["/summary", "/user"], function(results) {
      var summaryResult = results[0]
      var userResult = results[1]
      if (summaryResult.status === 200) root.summary = Model.parseSummary(summaryResult.json, Date.now())
      if (userResult.status === 200) root.user = Model.parseUser(userResult.json)
      if (summaryResult.status === 401 || userResult.status === 401) root.tokenRejected = true
      else if (userResult.status === 200) root.tokenRejected = false

      var failed = [summaryResult, userResult].filter(function(r) { return r.status !== 200 })[0]
      root.error = failed ? Model.errorInfo(failed.status) : null
      if (!failed) root.lastUpdated = Date.now()
      root.loading = false
      if (userResult.status === 200 && root.opened) root.refreshDetails(false)
    })
  }

  function refreshDetails(force) {
    var level = root.user ? root.user.level : 0
    if (!level || root.detailsLoading || !root.hasToken) return
    var fresh = Date.now() - root.detailsUpdated < Model.DETAILS_MAX_AGE_MS
    if (!force && fresh && level === root.detailsLevel) return

    root.detailsLoading = true
    var groups = Model.SRS_GROUPS
    var paths = groups.map(function(group) { return "/assignments?srs_stages=" + group.stages })
    paths.push("/subjects?types=kanji&levels=" + level)
    paths.push("/assignments?subject_types=kanji&levels=" + level)

    apiClient.getAll(paths, function(results) {
      root.detailsLoading = false
      // Keep the previous numbers visible when anything failed.
      if (results.some(function(r) { return r.status !== 200 })) return
      var counts = {}
      groups.forEach(function(group, i) { counts[group.key] = Model.totalCount(results[i].json) })
      var subjects = results[groups.length].json
      var assignments = results[groups.length + 1].json
      root.srsCounts = Model.srsBreakdown(counts)
      root.levelInfo = Model.levelProgress(subjects, assignments, level)
      root.detailsLevel = level
      root.detailsUpdated = Date.now()
    })
  }

  // Check a pasted token against the API, then store it. Nothing is saved
  // unless WaniKani accepts it.
  function submitToken(raw) {
    if (root.tokenBusy) return
    var token = String(raw || "").trim()
    var problem = Model.tokenProblem(token)
    if (problem !== "") {
      root.tokenError = Model.message(problem)
      return
    }
    root.tokenBusy = true
    root.tokenError = null
    apiClient.get("/user", function(status, json) {
      if (status !== 200) {
        root.tokenBusy = false
        root.tokenError = status === 401 ? Model.message("token.unknown") : Model.errorInfo(status)
        return
      }
      root.user = Model.parseUser(json)
      tokenStore.save(token)
    }, token)
  }

  function finishTokenSave(ok) {
    root.tokenBusy = false
    if (!ok) {
      root.tokenError = Model.message("token.writeFailed", tokenStore.path)
      return
    }
    root.tokenRejected = false
    root.editingToken = false
    root.error = null
    root.refresh()
  }

  function forgetAccount() {
    root.summary = null
    root.user = null
    root.srsCounts = null
    root.levelInfo = null
    root.detailsUpdated = 0
    root.lastUpdated = 0
    root.error = null
    root.tokenRejected = false
    root.view = "main"
  }

  // Writes one key into this widget's shell.json entry; the shell pushes the
  // merged settings back, which re-evaluates every setting() binding.
  function persistSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    var current = root.settings || {}
    for (var k in current) if (k !== "id") entry[k] = current[k]
    entry[key] = value
    root.settings = entry
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function showSettings() {
    root.open()
    root.view = "settings"
  }

  function startTokenChange() {
    root.open()
    root.view = "main"
    root.editingToken = true
  }

  function openUrl(url) {
    Quickshell.execDetached(["omarchy-launch-browser", url])
    root.close()
  }

  onApiTokenChanged: Qt.callLater(refresh)
  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      editingToken = false
      tokenError = null
      view = "main"
    }
  }
  Component.onCompleted: Qt.callLater(refresh)

  ShellIpc {
    target: Model.PLUGIN_ID

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
    // Sends the reminder now with the current counts (for testing the look).
    function testReminder() { reminder.send(root.reviews, root.lessons) }
    // Opens the popup on its settings page.
    function settings() { root.showSettings() }
    // Opens the popup on the token field, like "Change token".
    function changeToken() { root.startTokenChange() }
    // Same path the settings page uses, for scripts and dotfiles:
    //   omarchy-shell io.github.erfoip.kanibar setSetting reminderTime '"19:30"'
    // The value is JSON (true, 20, "19:30").
    function setSetting(key: string, value: string): void {
      var parsed
      try { parsed = JSON.parse(value) } catch (e) { parsed = value }
      root.persistSetting(key, parsed)
    }
  }

  TokenStore {
    id: tokenStore
    onSaved: function(ok) { root.finishTokenSave(ok) }
    onRemoved: root.forgetAccount()
  }

  Reminder {
    id: reminder
    client: apiClient
    l10n: strings
    active: root.reminderEnabled && root.hasToken
    clockMinutes: Model.parseClock(root.reminderTime)
    minReviews: root.reminderMinReviews
    onSummaryFetched: function(summary) { root.summary = summary }
  }

  // Background refresh (disclosed in the README; refreshMinutes 0 = off).
  Timer {
    interval: Math.max(1, root.refreshMinutes) * Model.MINUTE_MS
    running: root.hasToken && root.autoRefresh
    repeat: true
    onTriggered: root.refresh()
  }

  // New reviews unlock on the hour; refresh just after it.
  Timer {
    running: root.hasToken && root.autoRefresh
    interval: Model.msUntilNextHour(Date.now())
    onTriggered: {
      root.refresh()
      interval = Model.msUntilNextHour(Date.now())
      restart()
    }
  }

  // Keeps relative times in the open popup current.
  Timer {
    interval: Model.CLOCK_TICK_MS
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now()
  }

  visible: !(hideWhenIdle && idle)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0
  readonly property real openPanelIndicatorWidth: pill.implicitWidth
  readonly property real openPanelIndicatorHeight: pill.implicitHeight

  readonly property bool barVertical: root.bar ? root.bar.vertical === true : false
  readonly property color contentForeground: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---------- Bar pill ----------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.highlightThreshold > 0 && root.reviews >= root.highlightThreshold
    fixedWidth: root.barVertical ? -1 : pill.implicitWidth + Style.space(12)
    fixedHeight: root.barVertical ? pill.implicitHeight + Style.space(8) : -1
    tooltipText: ""

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.refresh()
      else if (mouseButton === Qt.RightButton) root.openUrl(Model.DASHBOARD_URL)
      else root.toggle()
    }

    BarPill {
      id: pill
      anchors.centerIn: parent
      vertical: root.barVertical
      parts: root.pillParts
      // WidgetButton's `active` only recolors its own label, which is hidden
      // here, so the pill takes the urgent color itself.
      foreground: button.active ? button.activeColor : button.foreground
      fontFamily: button.fontFamily
    }
  }

  // ---------- Popup ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // The token field takes focus whenever it's showing, so pasting works
    // straight away.
    focusTarget: panel.loadedContent && root.showTokenEntry ? panel.loadedContent.tokenInput : panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: body
      property alias tokenInput: tokenEntry.input
      anchors.fill: parent
      blocked: (root.showTokenEntry && tokenEntry.input.activeFocus) || settingsPage.typing
      implicitHeight: column.implicitHeight
      onCloseRequested: {
        if (root.inSettings) root.view = "main"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      readonly property color fg: root.contentForeground
      readonly property string family: root.contentFontFamily

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        PanelHero {
          foreground: body.fg
          fontFamily: body.family
          title: root.inSettings ? strings.t("hero.settingsTitle") : strings.t("hero.title")
          trailingControl: PanelActionButton {
            visible: root.hasToken || root.inSettings
            // Back points the reading direction's way: left, or right in RTL.
            iconText: root.inSettings ? (Commons.I18n.rightToLeft ? "󰁔" : "󰁍") : "󰒓"
            tooltipText: root.inSettings ? strings.t("action.back") : strings.t("action.settings")
            foreground: body.fg
            fontFamily: body.family
            onClicked: root.view = root.inSettings ? "main" : "settings"
          }
          // PanelHero renders meta as PlainText (and upper-cases it).
          meta: {
            if (root.inSettings) return strings.t("hero.settingsMeta")
            if (!root.user) return root.hasToken ? strings.t("hero.loading") : strings.t("hero.notConnected")
            var level = strings.formatNumber(root.user.level)
            return root.user.username
              ? Model.fill(strings.t("hero.levelUser"), level, root.user.username)
              : Model.fill(strings.t("hero.level"), level)
          }
          iconComponent: PlainText {
            text: Model.ICON_GLYPH
            foreground: Commons.Color.accent
            font.pixelSize: Style.font.display
          }
        }

        SettingsPage {
          id: settingsPage
          visible: root.inSettings
          width: parent.width
          l10n: strings
          foreground: body.fg
          fontFamily: body.family
          showLessons: root.showLessons
          hideWhenIdle: root.hideWhenIdle
          highlightThreshold: root.highlightThreshold
          refreshMinutes: root.refreshMinutes
          reminderEnabled: root.reminderEnabled
          reminderTime: root.reminderTime
          reminderMinReviews: root.reminderMinReviews
          reminderSentToday: reminder.lastDate === Model.dateKey(root.now)
          username: root.user ? root.user.username : ""
          level: root.user ? root.user.level : 0
          hasToken: root.hasToken
          tokenFromSettings: root.settingsToken !== ""
          tokenFromFile: tokenStore.token !== ""
          onSettingChanged: function(key, value) { root.persistSetting(key, value) }
          onTestNotificationRequested: reminder.send(root.reviews, root.lessons)
          onChangeTokenRequested: root.startTokenChange()
          onDisconnectRequested: tokenStore.remove()
          onEditingDone: body.forceActiveFocus()
        }

        TokenEntry {
          id: tokenEntry
          visible: !root.inSettings && root.showTokenEntry
          width: parent.width
          l10n: strings
          foreground: body.fg
          fontFamily: body.family
          busy: root.tokenBusy
          rejected: root.tokenRejected
          editing: root.editingToken
          error: root.tokenError
          tokenFromSettings: root.settingsToken !== ""
          savedPath: tokenStore.displayPath
          onSubmitted: function(token) { root.submitToken(token) }
          onEdited: root.tokenError = null
          onCancelRequested: root.editingToken = false
          onDismissRequested: root.close()
          onGetTokenRequested: root.openUrl(Model.TOKEN_URL)
        }

        // ---------- Request error ----------
        PlainText {
          width: parent.width
          visible: root.showMain && root.error !== null
          wrapMode: Text.WordWrap
          text: strings.message(root.error)
          foreground: Commons.Color.urgent
          fontFamily: body.family
        }

        CountTiles {
          visible: root.showMain && root.summary !== null
          width: parent.width
          l10n: strings
          foreground: body.fg
          fontFamily: body.family
          reviews: root.reviews
          lessons: root.lessons
          reviewsDone: root.reviewsDone
          nextReviewsText: root.summary && root.summary.nextReviewsAt !== null
            ? strings.durationText(root.summary.nextReviewsAt, root.now)
            : ""
          onReviewsActivated: root.openUrl(Model.REVIEW_URL)
          onLessonsActivated: root.openUrl(Model.LESSON_URL)
        }

        LevelProgress {
          visible: root.showMain && root.levelInfo !== null
          width: parent.width
          l10n: strings
          foreground: body.fg
          fontFamily: body.family
          info: root.levelInfo
        }

        SrsBreakdown {
          visible: root.showMain && root.srsCounts !== null
          width: parent.width
          l10n: strings
          foreground: body.fg
          fontFamily: body.family
          groups: root.srsCounts || []
        }

        ReviewForecast {
          visible: root.showMain && root.summary !== null
          width: parent.width
          l10n: strings
          foreground: body.fg
          fontFamily: body.family
          slots: root.summary ? Model.hourlySlots(root.summary.forecast, root.now, Model.FORECAST_HOURS) : []
          total: root.summary ? root.summary.forecastTotal : 0
        }

        // ---------- Footer ----------
        Item {
          visible: root.showMain && root.hasToken
          width: parent.width
          implicitHeight: updatedText.implicitHeight

          CaptionText {
            id: updatedText
            anchors.right: parent.right
            visible: root.lastUpdated > 0
            text: Model.fill(root.loading ? strings.t("footer.refreshing") : strings.t("footer.updated"), strings.timeText(root.lastUpdated))
            foreground: body.fg
            fontFamily: body.family
          }
        }
      }
    }
  }
}
