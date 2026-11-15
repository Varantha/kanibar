import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Kanibar: WaniKani reviews and lessons on the Omarchy bar.
// The pill shows reviews (and lessons) available now; clicking opens a popup
// with level, next-review time and the 24-hour forecast. Data comes from the
// official WaniKani API v2 (GET /summary and GET /user).
Panel {
  id: root
  moduleName: "io.github.erfoip.kanibar"
  ipcTarget: "io.github.erfoip.kanibar"
  manageIpc: false

  // ---------- Settings ----------
  readonly property string settingsToken: String(setting("apiToken", "") || "").trim()
  property string fileToken: ""
  readonly property string apiToken: settingsToken !== "" ? settingsToken : fileToken
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 10), 10) || 10)
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
  property string error: ""
  property bool loading: false
  property real lastUpdated: 0
  property real now: Date.now()

  readonly property bool hasToken: apiToken !== ""
  readonly property string tokenDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/kanibar"

  // ---------- In-popup token entry ----------
  property bool tokenRejected: false   // last refresh got a 401
  property bool editingToken: false    // "Change token" clicked
  property bool tokenBusy: false
  property string tokenError: ""
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

  readonly property string pillText: {
    if (!hasToken) return "—"
    if (!summary) return error !== "" ? "!" : "…"
    return Model.barLabel(summary, showLessons)
  }

  function refresh() {
    root.now = Date.now()
    if (!hasToken) {
      root.error = ""
      return
    }
    if (root.loading) return
    root.loading = true
    var pending = 2
    var failure = ""
    function done() {
      if (--pending > 0) return
      root.loading = false
      root.error = failure
      if (failure === "") root.lastUpdated = Date.now()
    }
    request("/summary", function(status, json) {
      if (status === 200) root.summary = Model.parseSummary(json, Date.now())
      else failure = Model.errorMessage(status)
      if (status === 401) root.tokenRejected = true
      done()
    })
    request("/user", function(status, json) {
      if (status === 200) {
        root.user = Model.parseUser(json)
        root.tokenRejected = false
        if (root.opened) root.refreshDetails(false)
      } else if (failure === "") failure = Model.errorMessage(status)
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
      root.tokenError = problem
      return
    }
    root.tokenBusy = true
    root.tokenError = ""
    request("/user", function(status, json) {
      if (status !== 200) {
        root.tokenBusy = false
        root.tokenError = status === 401 ? "WaniKani doesn't recognize this token." : Model.errorMessage(status)
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
      root.tokenError = "Couldn't write " + root.tokenDir + "/token."
      root.pendingToken = ""
      return
    }
    // Use it right away; the FileView watch confirms it moments later.
    root.fileToken = root.pendingToken
    root.pendingToken = ""
    root.tokenRejected = false
    root.editingToken = false
    root.error = ""
    root.refresh()
  }

  // XMLHttpRequest keeps the token out of process argv (unlike curl).
  function request(path, callback, tokenOverride) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var json = null
      try { json = JSON.parse(xhr.responseText) } catch (e) {}
      callback(xhr.status, json)
    }
    xhr.open("GET", Model.API_BASE + path)
    xhr.setRequestHeader("Authorization", "Bearer " + (tokenOverride || root.apiToken))
    xhr.setRequestHeader("Wanikani-Revision", Model.API_REVISION)
    xhr.send()
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
    root.error = ""
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

  function sendReminder(reviews, lessons) {
    var t = Model.reminderText(reviews, lessons)
    notifyProc.command = [
      "omarchy-notification-send",
      "--app-name", "Kanibar",
      "-g", "鰐",
      "-u", "normal",
      t.headline, t.body,
      "--action", "Start reviews", "omarchy-launch-browser", Model.REVIEW_URL
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
      tokenError = ""
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
    onLoaded: { root.reminderLastDate = String(text() || "").trim(); root.reminderStateLoaded = true }
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
    onLoaded: root.fileToken = String(text() || "").trim()
    onLoadFailed: root.fileToken = ""
  }

  Timer {
    interval: root.refreshMinutes * 60000
    running: root.hasToken
    repeat: true
    onTriggered: root.refresh()
  }

  // New reviews unlock on the hour; refresh just after it.
  Timer {
    id: hourTimer
    running: root.hasToken
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
      columns: root.bar && root.bar.vertical ? 1 : 2
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
        text: root.pillText
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
          title: root.view === "settings" ? "Settings" : "WaniKani"
          trailingControl: PanelActionButton {
            visible: root.hasToken || root.view === "settings"
            iconText: root.view === "settings" ? "󰁍" : "󰒓"
            tooltipText: root.view === "settings" ? "Back" : "Settings"
            foreground: body.fg
            fontFamily: body.family
            onClicked: root.view = root.view === "settings" ? "main" : "settings"
          }
          meta: {
            if (root.view === "settings") return "KANIBAR"
            if (!root.user) return root.hasToken ? "LOADING…" : "NOT CONNECTED"
            var parts = ["LEVEL " + root.user.level]
            if (root.user.username) parts.push(root.user.username.toUpperCase())
            return parts.join(" · ")
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

          PanelSectionHeader { foreground: body.fg; fontFamily: body.family; text: "BAR" }

          SettingRow {
            label: "Show lessons on the bar"
            ToggleSwitch {
              checked: root.showLessons
              foreground: body.fg
              onToggled: root.persistSetting("showLessons", !root.showLessons)
            }
          }
          SettingRow {
            label: "Hide when nothing is due"
            ToggleSwitch {
              checked: root.hideWhenIdle
              foreground: body.fg
              onToggled: root.persistSetting("hideWhenIdle", !root.hideWhenIdle)
            }
          }
          SettingRow {
            label: "Highlight at (0 = off)"
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
            label: "Refresh every (minutes)"
            NumberField {
              id: refreshField
              value: root.refreshMinutes
              from: 1; to: 60; stepSize: 1
              fieldWidth: Style.space(96)
              foreground: body.fg
              fontFamily: body.family
              onModified: function(v) { root.persistSetting("refreshMinutes", v) }
            }
          }

          PanelSeparator { width: parent.width }
          PanelSectionHeader { foreground: body.fg; fontFamily: body.family; text: "DAILY REMINDER" }

          SettingRow {
            label: "Remind me if reviews are waiting"
            ToggleSwitch {
              checked: root.reminderEnabled
              foreground: body.fg
              onToggled: root.persistSetting("reminderEnabled", !root.reminderEnabled)
            }
          }
          SettingRow {
            label: "At (HH:MM)"
            opacity: root.reminderEnabled ? 1 : 0.5
            TextField {
              id: reminderTimeField
              width: Style.space(96)
              text: String(root.setting("reminderTime", "19:00"))
              placeholderText: "19:00"
              horizontalAlignment: TextInput.AlignHCenter
              foreground: body.fg
              font.family: body.family
              readonly property bool valid: Model.parseClock(text) >= 0
              color: valid ? body.fg : Commons.Color.urgent
              function commit() {
                if (valid) root.persistSetting("reminderTime", text.trim())
                else text = String(root.setting("reminderTime", "19:00"))
              }
              onAccepted: { commit(); body.forceActiveFocus() }
              onEditingFinished: commit()
              Keys.onEscapePressed: function(event) {
                text = String(root.setting("reminderTime", "19:00"))
                body.forceActiveFocus()
                event.accepted = true
              }
            }
          }
          SettingRow {
            label: "Only from (reviews)"
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
              text: "Send test notification"
              onActivated: root.sendReminder(root.reviews, root.lessons)
            }
            Text {
              visible: root.reminderEnabled && root.reminderLastDate === Model.dateKey(root.now)
              textFormat: Text.PlainText
              text: "· already sent today"
              color: body.dim
              font.family: body.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width }
          PanelSectionHeader { foreground: body.fg; fontFamily: body.family; text: "ACCOUNT" }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.user && root.user.username
              ? "Connected as " + root.user.username + " (level " + root.user.level + ")."
              : (root.hasToken ? "Token saved." : "Not connected.")
            color: body.fg
            font.family: body.family
            font.pixelSize: Style.font.body
          }
          Row {
            spacing: Style.space(12)
            LinkText {
              text: "Change token"
              onActivated: { root.view = "main"; root.editingToken = true }
            }
            LinkText {
              visible: root.fileToken !== "" && root.settingsToken === ""
              text: "Disconnect"
              onActivated: root.disconnect()
            }
          }
          Text {
            visible: root.settingsToken !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Using the token from the widget's apiToken setting in shell.json."
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
            text: root.tokenRejected && !root.editingToken
              ? "WaniKani rejected the saved token. Paste a new one:"
              : "Paste a read-only WaniKani API token to connect:"
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
              enabled: !root.tokenBusy
              placeholderText: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
              foreground: body.fg
              font.family: body.family
              onTextChanged: root.tokenError = ""
              onAccepted: root.submitToken(text)
              Keys.onEscapePressed: function(event) {
                if (root.editingToken) root.editingToken = false
                else root.close()
                event.accepted = true
              }
            }

            Button {
              id: connectButton
              text: root.tokenBusy ? "Checking…" : "Connect"
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
            visible: root.tokenError !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.tokenError
            color: Commons.Color.urgent
            font.family: body.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.settingsToken !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "A token is set in the widget settings and takes precedence. Clear it there to use this one."
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(12)

            LinkText {
              text: "Get a token ↗"
              onActivated: root.openUrl(Model.TOKEN_URL)
            }
            LinkText {
              visible: root.editingToken
              text: "Cancel"
              onActivated: root.editingToken = false
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Saved to " + root.tokenDir.replace(Quickshell.env("HOME"), "~") + "/token (only readable by you)."
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Request error ----------
        Text {
          width: parent.width
          visible: root.showMain && root.error !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.error
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
            label: "REVIEWS"
            value: root.reviews
            actionText: root.reviews > 0 ? "Start reviews" : ""
            onActivated: root.openUrl(Model.REVIEW_URL)
          }

          StatTile {
            width: (parent.width - parent.spacing) / 2
            label: "LESSONS"
            value: root.lessons
            actionText: root.lessons > 0 ? "Start lessons" : ""
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

            PanelSectionHeader {
              id: levelHeader
              foreground: body.fg
              fontFamily: body.family
              text: root.levelInfo ? "LEVEL " + root.levelInfo.level + " KANJI" : ""
            }

            Text {
              anchors.right: parent.right
              anchors.baseline: levelHeader.baseline
              textFormat: Text.PlainText
              text: {
                var l = root.levelInfo
                if (!l) return ""
                return l.remaining > 0
                  ? l.passed + " / " + l.total + " Guru · " + l.remaining + " to level up"
                  : l.passed + " / " + l.total + " Guru · level-up ready"
              }
              color: body.dim
              font.family: body.family
              font.pixelSize: Style.font.caption
            }
          }

          // Progress bar with a tick at the 90% level-up threshold.
          Item {
            width: parent.width
            height: Style.space(6)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(body.fg.r, body.fg.g, body.fg.b, 0.12)
            }
            Rectangle {
              height: parent.height
              radius: height / 2
              color: Commons.Color.accent
              width: root.levelInfo && root.levelInfo.total > 0
                ? Math.max(height, parent.width * root.levelInfo.passed / root.levelInfo.total)
                : 0
              Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
            }
            Rectangle {
              visible: root.levelInfo && root.levelInfo.total > 0
              width: Math.max(1, Style.space(2))
              height: parent.height + Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              x: root.levelInfo && root.levelInfo.total > 0
                ? parent.width * root.levelInfo.required / root.levelInfo.total - width / 2
                : 0
              color: body.fg
            }
          }

          // The level's kanji, tinted by SRS state.
          Flow {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.levelInfo ? root.levelInfo.items : []
              delegate: Rectangle {
                id: kanjiTile
                required property var modelData
                readonly property string tileState: Model.itemState(modelData)
                width: Style.space(26)
                height: Style.space(26)
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

                PanelToolTip {
                  visible: kanjiMouse.containsMouse
                  text: kanjiTile.modelData.meaning + " · " + Model.stageName(kanjiTile.modelData.stage)
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

          PanelSectionHeader {
            foreground: body.fg
            fontFamily: body.family
            text: "SRS STAGES"
          }

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
                  text: String(modelData.count)
                  color: body.fg
                  font.family: body.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: modelData.short
                  color: body.dim
                  font.family: body.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
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

          PanelSectionHeader {
            text: "NEXT 24 HOURS · " + (root.summary ? root.summary.forecastTotal : 0)
          }

          Text {
            visible: root.reviews === 0 && root.summary && root.summary.nextReviewsAt !== null
            textFormat: Text.PlainText
            text: root.summary ? "Next reviews " + Model.relativeTime(root.summary.nextReviewsAt, root.now) : ""
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.bodySmall
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
                  text: Model.hourLabel(modelData.time) + ":00 · " + modelData.count
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
              Repeater {
                model: root.slots
                delegate: Text {
                  required property var modelData
                  required property int index
                  width: chart.barWidth + (index < 23 ? chart.spacing : 0)
                  textFormat: Text.PlainText
                  text: index % 6 === 0 ? Model.hourLabel(modelData.time) : ""
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
            text: (root.loading ? "Refreshing… · " : "") + "Updated " + Qt.formatTime(new Date(root.lastUpdated), "hh:mm")
            color: body.dim
            font.family: body.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
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
    border.color: Qt.rgba(fg.r, fg.g, fg.b, 0.15)

    Column {
      id: tileColumn
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: String(tile.value)
        color: tile.value > 0 ? Commons.Color.accent : tile.fg
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
