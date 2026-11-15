import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Kanibar: WaniKani reviews and lessons on the Omarchy bar.
// The pill shows reviews (and lessons) available now; clicking opens a popup
// with level progress, SRS stages and the 24-hour forecast. Data comes from
// the official WaniKani API v2.
//
// Safety notes (see Omarchy's plugin guide):
// - Every Text here is Text.PlainText; test/model.test.js enforces it.
//   Shared sinks used with API text (PanelHero meta, PanelToolTip) render
//   PlainText internally.
// - Requests use a fixed HTTPS base, a timeout and a response-size cap;
//   Model.js clamps and length-limits everything it parses.
// - All user-facing strings come from i18n/<language>.json.
Panel {
  id: root
  moduleName: "io.github.erfoip.kanibar"
  ipcTarget: "io.github.erfoip.kanibar"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------- Settings ----------
  readonly property string settingsToken: String(setting("apiToken", "") || "").trim()
  property string fileToken: ""
  readonly property string apiToken: settingsToken !== "" ? settingsToken : fileToken
  // 0 turns background refresh off (popup open and middle-click still refresh).
  readonly property int refreshMinutes: {
    var n = parseInt(setting("refreshMinutes", 10), 10)
    return isNaN(n) ? 10 : Math.max(0, Math.min(60, n))
  }
  readonly property bool autoRefresh: refreshMinutes > 0
  readonly property bool showLessons: setting("showLessons", true) === true
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property int highlightThreshold: Math.max(0, parseInt(setting("highlightThreshold", 0), 10) || 0)
  readonly property bool reminderEnabled: setting("reminderEnabled", false) === true
  readonly property int reminderMinutes: Model.parseClock(setting("reminderTime", "19:00"))
  readonly property int reminderMinReviews: Math.max(1, parseInt(setting("reminderMinReviews", 1), 10) || 1)

  // ---------- State ----------
  // summary/user are kept on failure so stale numbers stay visible.
  property var summary: null
  property var user: null
  property var errorInfo: null          // { key, arg } from Model.errorInfo
  property bool loading: false
  property real lastUpdated: 0
  property real now: Date.now()

  readonly property bool hasToken: apiToken !== ""
  readonly property string tokenDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/kanibar"

  // ---------- In-popup token entry ----------
  property bool tokenRejected: false   // last refresh got a 401
  property bool editingToken: false    // "Change token" clicked
  property bool tokenBusy: false
  property var tokenErrorInfo: null    // { key, arg }
  property string pendingToken: ""
  readonly property bool showTokenEntry: !hasToken || tokenRejected || editingToken

  // "main" or "settings" (gear in the popup header).
  property string view: "main"
  readonly property bool showMain: view === "main" && !showTokenEntry
  readonly property int reviews: summary ? summary.reviews : 0
  readonly property int lessons: summary ? summary.lessons : 0
  readonly property bool idle: summary !== null && reviews === 0 && lessons === 0
  readonly property var slots: summary ? Model.hourlySlots(summary.forecast, now, 24) : []
  readonly property int slotMax: slots.reduce(function(m, s) { return Math.max(m, s.count) }, 0)

  // ---------- Popup details: SRS breakdown + level progress ----------
  // Fetched only while the popup is open, at most every 2 minutes, so the
  // background refresh stays at two requests.
  property var srsCounts: null
  property var levelInfo: null
  property bool detailsLoading: false
  property real detailsUpdated: 0
  property int detailsLevel: 0

  readonly property var pillParts: {
    if (!hasToken) return { main: "—", extra: "", done: false }
    if (!summary) return { main: errorInfo !== null ? "!" : "…", extra: "", done: false }
    return Model.barParts(summary, showLessons, num)
  }
  // All reviews cleared: the pill and popup show a check in the accent color.
  readonly property bool reviewsDone: pillParts.done === true
  readonly property real doneMarkScale: 1.5

  // ---------- Localization helpers ----------
  // Called from bindings, so a language switch re-renders them.
  readonly property var formatLocale: Qt.locale(Commons.I18n.formatLocale)

  function tr(key) { return strings.t(key) }
  function num(n) { return Commons.I18n.formatNumber(n) }
  function timeText(ms) { return new Date(ms).toLocaleTimeString(root.formatLocale, Locale.ShortFormat) }
  function hourText(ms) { return root.formatLocale.toString(new Date(ms), "HH") }

  function durationText(target) {
    var d = Model.duration(target, root.now)
    switch (d.kind) {
    case "now": return tr("time.now")
    case "minutes": return Model.fill(tr("time.minutes"), num(d.minutes))
    case "hours": return Model.fill(tr("time.hours"), num(d.hours))
    case "hoursMinutes": return Model.fill(tr("time.hoursMinutes"), num(d.hours), num(d.minutes))
    case "days": return Model.fill(tr("time.days"), num(d.days))
    case "daysHours": return Model.fill(tr("time.daysHours"), num(d.days), num(d.hours))
    }
    return ""
  }

  function infoText(info) { return info ? Model.fill(tr(info.key), info.arg) : "" }

  function stageText(stage) {
    var info = Model.stageInfo(stage)
    return Model.fill(tr(info.key), info.arg !== "" ? num(Number(info.arg)) : "")
  }

  // ---------- Data ----------
  function refresh() {
    root.now = Date.now()
    if (!hasToken) {
      root.errorInfo = null
      return
    }
    if (root.loading) return
    root.loading = true
    var pending = 2
    var failure = null
    function done() {
      if (--pending > 0) return
      root.loading = false
      root.errorInfo = failure
      if (failure === null) root.lastUpdated = Date.now()
    }
    request("/summary", function(status, json) {
      if (status === 200) root.summary = Model.parseSummary(json, Date.now())
      else failure = Model.errorInfo(status)
      if (status === 401) root.tokenRejected = true
      done()
    })
    request("/user", function(status, json) {
      if (status === 200) {
        root.user = Model.parseUser(json)
        root.tokenRejected = false
        if (root.opened) root.refreshDetails(false)
      } else if (failure === null) failure = Model.errorInfo(status)
      done()
    })
  }

  function refreshDetails(force) {
    var level = root.user ? root.user.level : 0
    if (!level || root.detailsLoading || !root.hasToken) return
    var fresh = Date.now() - root.detailsUpdated < 120000
    if (!force && fresh && level === root.detailsLevel) return

    root.detailsLoading = true
    var groups = Model.SRS_GROUPS
    var pending = groups.length + 2
    var counts = {}
    var subjects = null
    var assignments = null
    var failed = false
    function done() {
      if (--pending > 0) return
      root.detailsLoading = false
      if (failed) return   // keep the previous numbers visible
      root.srsCounts = Model.srsBreakdown(counts)
      root.levelInfo = Model.levelProgress(subjects, assignments, level)
      root.detailsLevel = level
      root.detailsUpdated = Date.now()
    }
    groups.forEach(function(g) {
      request("/assignments?srs_stages=" + g.stages, function(status, json) {
        if (status === 200) counts[g.key] = Model.totalCount(json)
        else failed = true
        done()
      })
    })
    request("/subjects?types=kanji&levels=" + level, function(status, json) {
      if (status === 200) subjects = json
      else failed = true
      done()
    })
    request("/assignments?subject_types=kanji&levels=" + level, function(status, json) {
      if (status === 200) assignments = json
      else failed = true
      done()
    })
  }

  // Check a pasted token against the API, then store it. Nothing is saved
  // unless WaniKani accepts it.
  function submitToken(raw) {
    var token = String(raw || "").trim()
    if (root.tokenBusy) return
    var problem = Model.tokenProblem(token)
    if (problem !== "") {
      root.tokenErrorInfo = { key: problem, arg: "" }
      return
    }
    root.tokenBusy = true
    root.tokenErrorInfo = null
    request("/user", function(status, json) {
      if (status !== 200) {
        root.tokenBusy = false
        root.tokenErrorInfo = status === 401 ? { key: "token.unknown", arg: "" } : Model.errorInfo(status)
        return
      }
      root.user = Model.parseUser(json)
      root.pendingToken = token
      saveProc.running = true
    }, token)
  }

  function finishTokenSave(ok) {
    root.tokenBusy = false
    if (!ok) {
      root.tokenErrorInfo = { key: "token.writeFailed", arg: root.tokenDir + "/token" }
      root.pendingToken = ""
      return
    }
    // Use it right away; the FileView watch confirms it moments later.
    root.fileToken = root.pendingToken
    root.pendingToken = ""
    root.tokenRejected = false
    root.editingToken = false
    root.errorInfo = null
    root.refresh()
  }

  // GET against the fixed API base. XMLHttpRequest keeps the token out of
  // process argv (unlike curl). Fails closed on timeout, oversized or
  // non-JSON responses. The callback runs exactly once.
  function request(path, callback, tokenOverride) {
    var finished = false
    var xhr = new XMLHttpRequest()
    var timer = timeoutTimer.createObject(root, { interval: Model.REQUEST_TIMEOUT_MS })

    function finish(status, json) {
      if (finished) return
      finished = true
      if (timer) { timer.stop(); timer.destroy() }
      callback(status, json)
    }

    // finish() before abort(): abort() re-enters onreadystatechange
    // synchronously, and that pass must not report its own result.
    timer.triggered.connect(function() {
      finish(Model.STATUS_OFFLINE, null)
      xhr.abort()
    })
    xhr.onreadystatechange = function() {
      if (finished) return
      if (xhr.readyState >= XMLHttpRequest.LOADING && xhr.responseText.length > Model.MAX_RESPONSE_CHARS) {
        finish(Model.STATUS_TOO_LARGE, null)
        xhr.abort()
        return
      }
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var json = null
      try { json = JSON.parse(xhr.responseText) } catch (e) {}
      if (json === null || typeof json !== "object") json = null
      var status = xhr.status
      if (status === 200 && json === null) status = Model.STATUS_OFFLINE
      finish(status, json)
    }
    xhr.open("GET", Model.API_BASE + path)
    xhr.setRequestHeader("Authorization", "Bearer " + (tokenOverride || root.apiToken))
    xhr.setRequestHeader("Wanikani-Revision", Model.API_REVISION)
    xhr.send()
    timer.start()
  }

  Component {
    id: timeoutTimer
    Timer { repeat: false }
  }

  // ---------- Settings page ----------
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

  function disconnect() {
    disconnectProc.running = true
  }

  function finishDisconnect() {
    root.fileToken = ""
    root.summary = null
    root.user = null
    root.srsCounts = null
    root.levelInfo = null
    root.detailsUpdated = 0
    root.lastUpdated = 0
    root.errorInfo = null
    root.tokenRejected = false
    root.view = "main"
  }

  // ---------- Daily reminder ----------
  // The handled date lives on disk: the shell rebuilds plugins whenever any
  // plugin's files change, which would otherwise re-send the reminder.
  property string reminderLastDate: ""
  property bool reminderStateLoaded: false
  property bool reminderChecking: false

  function checkReminder() {
    var now = Date.now()
    if (!root.reminderEnabled || !root.hasToken || !root.reminderStateLoaded || root.reminderChecking) return
    if (!Model.reminderDue(now, root.reminderMinutes, root.reminderLastDate)) return
    root.reminderChecking = true
    // Fresh counts, so reviews done minutes ago don't trigger a stale nag.
    request("/summary", function(status, json) {
      root.reminderChecking = false
      if (status !== 200) return   // not marked: retry next minute
      var s = Model.parseSummary(json, Date.now())
      root.summary = s
      root.markReminderDone(now)
      if (s.reviews >= root.reminderMinReviews) root.sendReminder(s.reviews, s.lessons)
    })
  }

  function markReminderDone(now) {
    root.reminderLastDate = Model.dateKey(now)
    reminderFile.setText(root.reminderLastDate + "\n")
  }

  // Only numbers and the plugin's own catalog strings reach the notification.
  function sendReminder(reviews, lessons) {
    var headline = Model.fill(strings.tn("reminder.headline", reviews), num(reviews))
    var body = lessons > 0
      ? Model.fill(strings.tn("reminder.bodyLessons", lessons), num(lessons))
      : tr("reminder.body")
    // omarchy-notification-send parses leading dashes as options.
    if (headline.charAt(0) === "-" || body.charAt(0) === "-") return
    notifyProc.command = [
      "omarchy-notification-send",
      "--app-name", "Kanibar",
      "-g", "鰐",
      "-u", "normal",
      headline, body,
      "--action", tr("reminder.action"), "omarchy-launch-browser", Model.REVIEW_URL
    ]
    notifyProc.running = true
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
      tokenErrorInfo = null
      view = "main"
    }
  }
  Component.onCompleted: Qt.callLater(refresh)

  ShellIpc {
    target: "io.github.erfoip.kanibar"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
    // Sends the reminder now with the current counts (for testing the look).
    function testReminder() { root.sendReminder(root.reviews, root.lessons) }
    // Opens the popup on its settings page.
    function settings() { root.open(); root.view = "settings" }
    // Opens the popup on the token field, like "Change token".
    function changeToken() { root.open(); root.view = "main"; root.editingToken = true }
    // Same path the settings page uses, for scripts and dotfiles:
    //   omarchy-shell io.github.erfoip.kanibar setSetting reminderTime '"19:30"'
    // The value is JSON (true, 20, "19:30").
    function setSetting(key: string, value: string): void {
      var parsed
      try { parsed = JSON.parse(value) } catch (e) { parsed = value }
      root.persistSetting(key, parsed)
    }
  }

  Process { id: notifyProc }

  Process {
    id: disconnectProc
    command: ["rm", "-f", root.tokenDir + "/token"]
    onExited: root.finishDisconnect()
  }

  FileView {
    id: reminderFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/kanibar-reminder"
    printErrors: false
    onLoaded: { root.reminderLastDate = String(text() || "").trim().slice(0, 10); root.reminderStateLoaded = true }
    onLoadFailed: { root.reminderLastDate = ""; root.reminderStateLoaded = true }
  }

  Timer {
    interval: 60000
    running: root.reminderEnabled && root.hasToken
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkReminder()
  }

  // Writes the token with mode 600. It travels over stdin, never argv, so it
  // doesn't show up in the process list.
  Process {
    id: saveProc
    stdinEnabled: true
    command: ["sh", "-c", "umask 077 && mkdir -p \"$1\" && IFS= read -r t && printf '%s\\n' \"$t\" > \"$1/token\" && chmod 600 \"$1/token\"", "sh", root.tokenDir]
    onStarted: write(root.pendingToken + "\n")
    onExited: function(exitCode) { root.finishTokenSave(exitCode === 0) }
  }

  // The popup saves here; hand-written files work too.
  FileView {
    path: root.tokenDir + "/token"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.fileToken = String(text() || "").trim().slice(0, 64)
    onLoadFailed: root.fileToken = ""
  }

  // Background refresh (disclosed in the README; refreshMinutes 0 = off).
  Timer {
    interval: Math.max(1, root.refreshMinutes) * 60000
    running: root.hasToken && root.autoRefresh
    repeat: true
    onTriggered: root.refresh()
  }

  // New reviews unlock on the hour; refresh just after it.
  Timer {
    id: hourTimer
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
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now()
  }

  visible: !(hideWhenIdle && idle)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0
  readonly property real openPanelIndicatorWidth: pillContent.implicitWidth
  readonly property real openPanelIndicatorHeight: pillContent.implicitHeight

  // ---------- Bar pill ----------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.highlightThreshold > 0 && root.reviews >= root.highlightThreshold
    fixedWidth: root.bar && root.bar.vertical ? -1 : pillContent.implicitWidth + Style.space(12)
    fixedHeight: root.bar && root.bar.vertical ? pillContent.implicitHeight + Style.space(8) : -1
    tooltipText: ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.openUrl(Model.DASHBOARD_URL)
      else root.toggle()
    }

    Grid {
      id: pillContent
      anchors.centerIn: parent
      columns: root.bar && root.bar.vertical ? 1 : 3
      spacing: Style.space(4)
      verticalItemAlignment: Grid.AlignVCenter
      horizontalItemAlignment: Grid.AlignHCenter

      Text {
        text: "鰐"
        textFormat: Text.PlainText
        color: button.foreground
        font.pixelSize: Style.font.body
      }

      Text {
        id: pillMain
        text: root.pillParts.main
        textFormat: Text.PlainText
        color: root.reviewsDone ? Commons.Color.accent : button.foreground
        font.family: button.fontFamily
        // The icon glyph sits smaller in its em box than digits do, so the
        // check gets a larger size to match the digits' height.
        font.pixelSize: root.reviewsDone ? Math.round(Style.font.bodySmall * root.doneMarkScale) : Style.font.bodySmall
        font.weight: Font.DemiBold

        // A small pop confirming the last review was cleared: 160ms out,
        // 120ms back, no overshoot. Style.duration() is 0 with animations off.
        SequentialAnimation {
          id: donePop
          NumberAnimation {
            target: pillMain; property: "scale"; to: 1.15
            duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut
          }
          NumberAnimation {
            target: pillMain; property: "scale"; to: 1.0
            duration: Style.duration(120); easing.type: Easing.OutCubic
          }
        }
        Connections {
          target: root
          function onReviewsDoneChanged() { if (root.reviewsDone) donePop.restart() }
        }
      }

      Text {
        visible: text !== ""
        text: root.pillParts.extra
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.DemiBold
      }
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
      property alias tokenInput: tokenField
      anchors.fill: parent
      blocked: (root.showTokenEntry && tokenField.activeFocus) || settingsPage.typing
      implicitHeight: column.implicitHeight
      onCloseRequested: {
        if (root.view === "settings") root.view = "main"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
      readonly property color dim: Qt.darker(fg, 1.4)
      readonly property string family: root.bar ? root.bar.fontFamily : Style.font.family

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        PanelHero {
          foreground: body.fg
          fontFamily: body.family
          title: root.view === "settings" ? root.tr("hero.settingsTitle") : root.tr("hero.title")
          trailingControl: PanelActionButton {
            visible: root.hasToken || root.view === "settings"
            // Back points the reading direction's way: left, or right in RTL.
            iconText: root.view === "settings" ? (Commons.I18n.rightToLeft ? "󰁔" : "󰁍") : "󰒓"
            tooltipText: root.view === "settings" ? root.tr("action.back") : root.tr("action.settings")
            foreground: body.fg
            fontFamily: body.family
            onClicked: root.view = root.view === "settings" ? "main" : "settings"
          }
          // PanelHero renders meta as PlainText (and upper-cases it).
          meta: {
            if (root.view === "settings") return root.tr("hero.settingsMeta")
            if (!root.user) return root.hasToken ? root.tr("hero.loading") : root.tr("hero.notConnected")
            return root.user.username
              ? Model.fill(root.tr("hero.levelUser"), root.num(root.user.level), root.user.username)
              : Model.fill(root.tr("hero.level"), root.num(root.user.level))
          }
          iconComponent: Text {
            text: "鰐"
            textFormat: Text.PlainText
            color: Commons.Color.accent
            font.pixelSize: Style.font.display
          }
        }

        // ---------- Settings page ----------
        Column {
          id: settingsPage
          visible: root.view === "settings"
          width: parent.width
          spacing: Style.space(10)

          readonly property bool typing: reminderTimeField.activeFocus
            || highlightField.field.activeFocus || refreshField.field.activeFocus || minReviewsField.field.activeFocus

          SectionHeader { text: root.tr("settings.bar") }

          SettingRow {
            label: root.tr("settings.showLessons")
            ToggleSwitch {
              checked: root.showLessons
              foreground: body.fg
              onToggled: root.persistSetting("showLessons", !root.showLessons)
            }
          }
          SettingRow {
            label: root.tr("settings.hideWhenIdle")
            ToggleSwitch {
              checked: root.hideWhenIdle
              foreground: body.fg
              onToggled: root.persistSetting("hideWhenIdle", !root.hideWhenIdle)
            }
          }
          SettingRow {
            label: root.tr("settings.highlight")
            NumberField {
              id: highlightField
              value: root.highlightThreshold
              from: 0; to: 1000; stepSize: 10
              fieldWidth: Style.space(96)
              foreground: body.fg
              fontFamily: body.family
              onModified: function(v) { root.persistSetting("highlightThreshold", v) }
            }
          }
          SettingRow {
            label: root.tr("settings.refresh")
            NumberField {
              id: refreshField
              value: root.refreshMinutes
              from: 0; to: 60; stepSize: 1
              fieldWidth: Style.space(96)
              foreground: body.fg
              fontFamily: body.family
              onModified: function(v) { root.persistSetting("refreshMinutes", v) }
            }
          }

          PanelSeparator { width: parent.width }
          SectionHeader { text: root.tr("settings.reminder") }

          SettingRow {
            label: root.tr("settings.reminderEnabled")
            ToggleSwitch {
              checked: root.reminderEnabled
              foreground: body.fg
              onToggled: root.persistSetting("reminderEnabled", !root.reminderEnabled)
            }
          }
          SettingRow {
            label: root.tr("settings.reminderTime")
            opacity: root.reminderEnabled ? 1 : 0.5
            TextField {
              id: reminderTimeField
              width: Style.space(96)
              text: String(root.setting("reminderTime", "19:00")).slice(0, 5)
              placeholderText: "19:00"
              maximumLength: 5
              horizontalAlignment: TextInput.AlignHCenter
              foreground: body.fg
              font.family: body.family
              readonly property bool valid: Model.parseClock(text) >= 0
              color: valid ? body.fg : Commons.Color.urgent
              function commit() {
                if (valid) root.persistSetting("reminderTime", text.trim())
                else text = String(root.setting("reminderTime", "19:00")).slice(0, 5)
              }
              onAccepted: { commit(); body.forceActiveFocus() }
              onEditingFinished: commit()
              Keys.onEscapePressed: function(event) {
                text = String(root.setting("reminderTime", "19:00")).slice(0, 5)
                body.forceActiveFocus()
                event.accepted = true
              }
            }
          }
          SettingRow {
            label: root.tr("settings.reminderMin")
            opacity: root.reminderEnabled ? 1 : 0.5
            NumberField {
              id: minReviewsField
              value: root.reminderMinReviews
              from: 1; to: 500; stepSize: 1
              fieldWidth: Style.space(96)
              foreground: body.fg
              fontFamily: body.family
              onModified: function(v) { root.persistSetting("reminderMinReviews", v) }
            }
          }
          Row {
            spacing: Style.space(12)
            LinkText {
              text: root.tr("settings.testNotification")
              onActivated: root.sendReminder(root.reviews, root.lessons)
            }
            Text {
              visible: root.reminderEnabled && root.reminderLastDate === Model.dateKey(root.now)
              textFormat: Text.PlainText
              text: root.tr("settings.sentToday")
              color: body.dim
              font.family: body.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width }
          SectionHeader { text: root.tr("settings.account") }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.user && root.user.username
              ? Model.fill(root.tr("settings.connectedAs"), root.user.username, root.num(root.user.level))
              : (root.hasToken ? root.tr("settings.tokenSaved") : root.tr("settings.notConnected"))
            color: body.fg
            font.family: body.family
            font.pixelSize: Style.font.body
          }
          Row {
            spacing: Style.space(12)
            LinkText {
              text: root.tr("settings.changeToken")
              onActivated: { root.view = "main"; root.editingToken = true }
            }
            LinkText {
              visible: root.fileToken !== "" && root.settingsToken === ""
              text: root.tr("settings.disconnect")
              onActivated: root.disconnect()
            }
          }
          Text {
            visible: root.settingsToken !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.tr("settings.usingApiToken")
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Token entry (first run, rejected token, or "Change token") ----------
        Column {
          visible: root.view === "main" && root.showTokenEntry
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.tokenRejected && !root.editingToken ? root.tr("token.rejected") : root.tr("token.prompt")
            color: body.fg
            font.family: body.family
            font.pixelSize: Style.font.body
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: tokenField
              width: parent.width - connectButton.width - parent.spacing
              password: true
              maximumLength: 64
              enabled: !root.tokenBusy
              placeholderText: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
              foreground: body.fg
              font.family: body.family
              onTextChanged: root.tokenErrorInfo = null
              onAccepted: root.submitToken(text)
              Keys.onEscapePressed: function(event) {
                if (root.editingToken) root.editingToken = false
                else root.close()
                event.accepted = true
              }
            }

            Button {
              id: connectButton
              text: root.tokenBusy ? root.tr("token.checking") : root.tr("token.connect")
              bordered: true
              enabled: !root.tokenBusy && tokenField.text.trim() !== ""
              foreground: body.fg
              fontFamily: body.family
              anchors.verticalCenter: tokenField.verticalCenter
              onClicked: root.submitToken(tokenField.text)
            }
          }

          Text {
            width: parent.width
            visible: root.tokenErrorInfo !== null
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.infoText(root.tokenErrorInfo)
            color: Commons.Color.urgent
            font.family: body.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.settingsToken !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.tr("token.settingsOverride")
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(12)

            LinkText {
              text: root.tr("token.get")
              onActivated: root.openUrl(Model.TOKEN_URL)
            }
            LinkText {
              visible: root.editingToken
              text: root.tr("token.cancel")
              onActivated: root.editingToken = false
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: Model.fill(root.tr("token.savedTo"), root.tokenDir.replace(Quickshell.env("HOME"), "~") + "/token")
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Request error ----------
        Text {
          width: parent.width
          visible: root.showMain && root.errorInfo !== null
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.infoText(root.errorInfo)
          color: Commons.Color.urgent
          font.family: body.family
          font.pixelSize: Style.font.body
        }

        // ---------- Counts ----------
        Row {
          visible: root.summary !== null && root.showMain
          width: parent.width
          spacing: Style.space(10)

          StatTile {
            width: (parent.width - parent.spacing) / 2
            label: root.reviewsDone ? root.tr("tile.allDone") : root.tr("tile.reviews")
            value: root.reviews
            valueText: root.reviewsDone ? Model.DONE_MARK : ""
            celebrate: root.reviewsDone
            note: root.reviewsDone && root.summary && root.summary.nextReviewsAt !== null
              ? Model.fill(root.tr("tile.next"), root.durationText(root.summary.nextReviewsAt))
              : ""
            actionText: root.reviews > 0 ? root.tr("tile.startReviews") : ""
            onActivated: root.openUrl(Model.REVIEW_URL)
          }

          StatTile {
            width: (parent.width - parent.spacing) / 2
            label: root.tr("tile.lessons")
            value: root.lessons
            actionText: root.lessons > 0 ? root.tr("tile.startLessons") : ""
            onActivated: root.openUrl(Model.LESSON_URL)
          }
        }

        // ---------- Level progress ----------
        Column {
          visible: root.levelInfo !== null && root.showMain
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: levelHeader.implicitHeight

            SectionHeader {
              id: levelHeader
              anchors.left: parent.left
              text: root.levelInfo ? Model.fill(root.tr("level.header"), root.num(root.levelInfo.level)) : ""
            }

            Text {
              anchors.right: parent.right
              anchors.baseline: levelHeader.baseline
              textFormat: Text.PlainText
              text: {
                var l = root.levelInfo
                if (!l) return ""
                return l.remaining > 0
                  ? Model.fill(root.tr("level.progress"), root.num(l.passed), root.num(l.total), root.num(l.remaining))
                  : Model.fill(root.tr("level.ready"), root.num(l.passed), root.num(l.total))
              }
              color: body.dim
              font.family: body.family
              font.pixelSize: Style.font.caption
            }
          }

          // Progress bar with a tick at the 90% level-up threshold.
          Item {
            id: progressTrack
            width: parent.width
            height: Style.space(6)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(body.fg.r, body.fg.g, body.fg.b, 0.12)
            }
            Rectangle {
              // Anchored, so it fills from the right under RTL mirroring.
              anchors.left: parent.left
              height: parent.height
              radius: height / 2
              color: Commons.Color.accent
              width: root.levelInfo && root.levelInfo.total > 0
                ? Math.max(height, parent.width * root.levelInfo.passed / root.levelInfo.total)
                : 0
              Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
            }
            Rectangle {
              readonly property real offset: root.levelInfo && root.levelInfo.total > 0
                ? progressTrack.width * root.levelInfo.required / root.levelInfo.total - width / 2
                : 0
              visible: root.levelInfo && root.levelInfo.total > 0
              width: Math.max(1, Style.space(2))
              height: parent.height + Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              // Explicit x isn't mirrored automatically.
              x: LayoutMirroring.enabled ? progressTrack.width - offset - width : offset
              color: body.fg
            }
          }

          // The level's kanji, tinted by SRS state. As many columns as fit
          // at the minimum tile size, then tiles stretch so every full row
          // spans the content width exactly (same edges as the bar above).
          Grid {
            id: kanjiGrid
            width: parent.width
            spacing: Style.space(4)
            readonly property real minTile: Style.space(26)
            columns: Math.max(1, Math.floor((width + spacing) / (minTile + spacing)))
            readonly property real tile: (width - (columns - 1) * spacing) / columns

            Repeater {
              model: root.levelInfo ? root.levelInfo.items : []
              delegate: Rectangle {
                id: kanjiTile
                required property var modelData
                readonly property string tileState: Model.itemState(modelData)
                width: kanjiGrid.tile
                height: kanjiGrid.tile
                radius: Style.space(4)
                color: tileState === "passed" ? Commons.Color.accent
                  : tileState === "learning" ? Qt.rgba(body.fg.r, body.fg.g, body.fg.b, 0.14)
                  : "transparent"
                border.width: 1
                border.color: tileState === "passed" ? Commons.Color.accent
                  : Qt.rgba(body.fg.r, body.fg.g, body.fg.b, tileState === "locked" ? 0.10 : 0.25)

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: kanjiTile.modelData.characters
                  color: kanjiTile.tileState === "passed" ? Commons.Color.background
                    : kanjiTile.tileState === "locked" ? Qt.rgba(body.fg.r, body.fg.g, body.fg.b, 0.35)
                    : body.fg
                  font.pixelSize: Style.font.subtitle
                }

                MouseArea {
                  id: kanjiMouse
                  anchors.fill: parent
                  hoverEnabled: true
                }

                // PanelToolTip renders PlainText; meaning comes from the API.
                PanelToolTip {
                  visible: kanjiMouse.containsMouse
                  text: kanjiTile.modelData.meaning
                    ? Model.fill(root.tr("stage.tooltip"), kanjiTile.modelData.meaning, root.stageText(kanjiTile.modelData.stage))
                    : root.stageText(kanjiTile.modelData.stage)
                }
              }
            }
          }
        }

        // ---------- SRS breakdown ----------
        Column {
          visible: root.srsCounts !== null && root.showMain
          width: parent.width
          spacing: Style.space(6)

          SectionHeader { text: root.tr("srs.header") }

          Row {
            id: srsRow
            width: parent.width
            readonly property int n: root.srsCounts ? root.srsCounts.length : 1

            Repeater {
              model: root.srsCounts || []
              delegate: Column {
                required property var modelData
                width: srsRow.width / srsRow.n
                spacing: Style.space(1)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.num(modelData.count)
                  color: body.fg
                  font.family: body.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: root.tr("srs." + modelData.key + ".short")
                  color: body.dim
                  font.family: body.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                  font.capitalization: Font.AllUppercase
                }
              }
            }
          }
        }

        // ---------- Forecast ----------
        Column {
          visible: root.summary !== null && root.showMain
          width: parent.width
          spacing: Style.space(6)

          SectionHeader {
            text: Model.fill(root.tr("forecast.header"), root.num(root.summary ? root.summary.forecastTotal : 0))
          }

          Row {
            id: chart
            width: parent.width
            height: Style.space(56)
            spacing: Style.space(2)
            readonly property real barWidth: (width - spacing * 23) / 24

            Repeater {
              model: root.slots
              delegate: Item {
                required property var modelData
                required property int index
                width: chart.barWidth
                height: chart.height

                Rectangle {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  radius: Math.min(width / 2, Style.space(2))
                  height: modelData.count > 0 && root.slotMax > 0
                    ? Math.max(Style.space(3), parent.height * modelData.count / root.slotMax)
                    : Style.space(1)
                  color: modelData.count > 0 ? Commons.Color.accent : Qt.rgba(body.fg.r, body.fg.g, body.fg.b, 0.15)
                }

                PanelToolTip {
                  visible: barMouse.containsMouse && modelData.count > 0
                  text: Model.fill(strings.tn("forecast.tooltip", modelData.count), root.timeText(modelData.time), root.num(modelData.count))
                }

                MouseArea {
                  id: barMouse
                  anchors.fill: parent
                  hoverEnabled: true
                }
              }
            }
          }

          // Hour ticks every 6 hours.
          Item {
            width: parent.width
            height: tickRow.implicitHeight
            Row {
              id: tickRow
              anchors.left: parent.left
              Repeater {
                model: root.slots
                delegate: Text {
                  required property var modelData
                  required property int index
                  width: chart.barWidth + (index < 23 ? chart.spacing : 0)
                  textFormat: Text.PlainText
                  text: index % 6 === 0 ? root.hourText(modelData.time) : ""
                  color: body.dim
                  font.family: body.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        Item {
          visible: root.hasToken && root.showMain
          width: parent.width
          implicitHeight: updatedText.implicitHeight

          Text {
            id: updatedText
            anchors.right: parent.right
            visible: root.lastUpdated > 0
            textFormat: Text.PlainText
            text: Model.fill(root.loading ? root.tr("footer.refreshing") : root.tr("footer.updated"), root.timeText(root.lastUpdated))
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Section header in the popup's style; catalog strings stay in sentence
  // case and are upper-cased here, so translators don't have to.
  component SectionHeader: PanelSectionHeader {
    foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    font.capitalization: Font.AllUppercase
  }

  // Label on the left, one control on the right.
  component SettingRow: Item {
    id: settingRow
    property string label: ""
    default property alias control: controlSlot.data
    readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(rowLabel.implicitHeight, controlSlot.childrenRect.height)

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.right: controlSlot.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: settingRow.label
      elide: Text.ElideRight
      color: settingRow.fg
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }
    Item {
      id: controlSlot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  component LinkText: Text {
    id: link
    signal activated()
    readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
    textFormat: Text.PlainText
    color: linkMouse.containsMouse ? Commons.Color.accent : Qt.darker(fg, 1.4)
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    font.underline: linkMouse.containsMouse

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.activated()
    }
  }

  component StatTile: Rectangle {
    id: tile
    property string label: ""
    property int value: 0
    property string valueText: ""   // overrides the number (e.g. the done check)
    property bool celebrate: false  // accent-tinted tile
    property string note: ""        // plain line under the label
    property string actionText: ""
    signal activated()

    readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
    readonly property string family: root.bar ? root.bar.fontFamily : Style.font.family

    implicitHeight: tileColumn.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: tileMouse.containsMouse && actionText !== ""
      ? Qt.rgba(fg.r, fg.g, fg.b, 0.10)
      : Qt.rgba(fg.r, fg.g, fg.b, 0.04)
    border.width: 1
    border.color: celebrate ? Commons.Color.accent : Qt.rgba(fg.r, fg.g, fg.b, 0.15)

    Column {
      id: tileColumn
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: tile.valueText !== "" ? tile.valueText : root.num(tile.value)
        color: tile.value > 0 || tile.celebrate ? Commons.Color.accent : tile.fg
        font.family: tile.family
        font.pixelSize: Style.font.display
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: tile.label
        color: Qt.darker(tile.fg, 1.4)
        font.family: tile.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
        font.capitalization: Font.AllUppercase
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: tile.actionText !== ""
        textFormat: Text.PlainText
        text: tile.actionText + " ↗"
        color: tile.fg
        font.family: tile.family
        font.pixelSize: Style.font.caption
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: tile.note !== ""
        textFormat: Text.PlainText
        text: tile.note
        color: Qt.darker(tile.fg, 1.4)
        font.family: tile.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: tile.actionText !== ""
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.activated()
    }
  }
}
