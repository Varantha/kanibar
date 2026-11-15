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

  // ---------- State ----------
  // summary/user are kept on failure so stale numbers stay visible.
  property var summary: null
  property var user: null
  property string error: ""
  property bool loading: false
  property real lastUpdated: 0
  property real now: Date.now()

  readonly property bool hasToken: apiToken !== ""
  readonly property int reviews: summary ? summary.reviews : 0
  readonly property int lessons: summary ? summary.lessons : 0
  readonly property bool idle: summary !== null && reviews === 0 && lessons === 0
  readonly property var slots: summary ? Model.hourlySlots(summary.forecast, now, 24) : []
  readonly property int slotMax: slots.reduce(function(m, s) { return Math.max(m, s.count) }, 0)

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
      done()
    })
    request("/user", function(status, json) {
      if (status === 200) root.user = Model.parseUser(json)
      else if (failure === "") failure = Model.errorMessage(status)
      done()
    })
  }

  // XMLHttpRequest keeps the token out of process argv (unlike curl).
  function request(path, callback) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var json = null
      try { json = JSON.parse(xhr.responseText) } catch (e) {}
      callback(xhr.status, json)
    }
    xhr.open("GET", Model.API_BASE + path)
    xhr.setRequestHeader("Authorization", "Bearer " + root.apiToken)
    xhr.setRequestHeader("Wanikani-Revision", Model.API_REVISION)
    xhr.send()
  }

  function openUrl(url) {
    Quickshell.execDetached(["omarchy-launch-browser", url])
    root.close()
  }

  onApiTokenChanged: Qt.callLater(refresh)
  onOpenedChanged: if (opened) refresh()
  Component.onCompleted: Qt.callLater(refresh)

  ShellIpc {
    target: "io.github.erfoip.kanibar"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { root.refresh() }
  }

  // Token fallback for people who'd rather not keep it in shell.json.
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/kanibar/token"
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
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: body
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
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
          title: "WaniKani"
          meta: {
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

        // ---------- Missing token / error ----------
        Text {
          width: parent.width
          visible: !root.hasToken || root.error !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: !root.hasToken
            ? "Add a read-only API token in the widget settings, or save it to ~/.config/kanibar/token."
            : root.error
          color: root.hasToken ? Commons.Color.urgent : body.dim
          font.family: body.family
          font.pixelSize: Style.font.body
        }

        // ---------- Counts ----------
        Row {
          visible: root.summary !== null
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

        // ---------- Forecast ----------
        Column {
          visible: root.summary !== null
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

        Text {
          visible: root.lastUpdated > 0
          width: parent.width
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: (root.loading ? "Refreshing… · " : "") + "Updated " + Qt.formatTime(new Date(root.lastUpdated), "hh:mm")
          color: body.dim
          font.family: body.family
          font.pixelSize: Style.font.caption
        }
      }
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
