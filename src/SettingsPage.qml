import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The popup's settings page. It reads state and emits intent; Panel.qml owns
// every value and is the only writer of shell.json.
Column {
  id: page

  required property Localization l10n
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  // Current settings
  property bool showLessons: true
  property bool hideWhenIdle: false
  property int highlightThreshold: 0
  property int refreshMinutes: Model.DEFAULT_REFRESH_MINUTES
  property bool reminderEnabled: false
  property string reminderTime: Model.DEFAULT_REMINDER_TIME
  property int reminderMinReviews: 1

  // Account
  property bool reminderSentToday: false
  property string username: ""
  property int level: 0
  property bool hasToken: false
  property bool tokenFromSettings: false   // apiToken in shell.json wins over the file
  property bool tokenFromFile: false

  // True while a text field has focus, so the panel lets keys through.
  readonly property bool typing: reminderTimeField.activeFocus
    || highlightField.field.activeFocus || refreshField.field.activeFocus || minReviewsField.field.activeFocus

  signal settingChanged(string key, var value)
  signal testNotificationRequested()
  signal changeTokenRequested()
  signal disconnectRequested()
  // A text field finished editing and hands focus back to the panel.
  signal editingDone()

  readonly property real fieldWidth: Style.space(96)
  readonly property real disabledOpacity: 0.5

  spacing: Style.space(10)

  component PageRow: SettingRow {
    foreground: page.foreground
    fontFamily: page.fontFamily
  }

  component PageToggle: ToggleSwitch {
    foreground: page.foreground
  }

  component PageNumber: NumberField {
    fieldWidth: page.fieldWidth
    foreground: page.foreground
    fontFamily: page.fontFamily
  }

  component PageHeader: SectionHeader {
    foreground: page.foreground
    fontFamily: page.fontFamily
  }

  component PageSeparator: PanelSeparator {
    width: page.width
  }

  // ---------- Bar ----------
  PageHeader { text: page.l10n.t("settings.bar") }

  PageRow {
    label: page.l10n.t("settings.showLessons")
    PageToggle {
      checked: page.showLessons
      onToggled: page.settingChanged("showLessons", !page.showLessons)
    }
  }
  PageRow {
    label: page.l10n.t("settings.hideWhenIdle")
    PageToggle {
      checked: page.hideWhenIdle
      onToggled: page.settingChanged("hideWhenIdle", !page.hideWhenIdle)
    }
  }
  PageRow {
    label: page.l10n.t("settings.highlight")
    PageNumber {
      id: highlightField
      value: page.highlightThreshold
      from: 0; to: 1000; stepSize: 10
      onModified: function(v) { page.settingChanged("highlightThreshold", v) }
    }
  }
  PageRow {
    label: page.l10n.t("settings.refresh")
    PageNumber {
      id: refreshField
      value: page.refreshMinutes
      from: 0; to: Model.MAX_REFRESH_MINUTES; stepSize: 1
      onModified: function(v) { page.settingChanged("refreshMinutes", v) }
    }
  }

  // ---------- Reminder ----------
  PageSeparator {}
  PageHeader { text: page.l10n.t("settings.reminder") }

  PageRow {
    label: page.l10n.t("settings.reminderEnabled")
    PageToggle {
      checked: page.reminderEnabled
      onToggled: page.settingChanged("reminderEnabled", !page.reminderEnabled)
    }
  }
  PageRow {
    label: page.l10n.t("settings.reminderTime")
    opacity: page.reminderEnabled ? 1 : page.disabledOpacity
    TextField {
      id: reminderTimeField
      width: page.fieldWidth
      text: page.reminderTime
      placeholderText: Model.DEFAULT_REMINDER_TIME
      maximumLength: 5
      horizontalAlignment: TextInput.AlignHCenter
      foreground: page.foreground
      font.family: page.fontFamily
      readonly property bool valid: Model.parseClock(text) >= 0
      color: valid ? page.foreground : Commons.Color.urgent
      function commit() {
        if (valid) page.settingChanged("reminderTime", text.trim())
        else revert()
      }
      function revert() { text = page.reminderTime }
      onAccepted: { commit(); page.editingDone() }
      onEditingFinished: commit()
      Keys.onEscapePressed: function(event) {
        revert()
        page.editingDone()
        event.accepted = true
      }
    }
  }
  PageRow {
    label: page.l10n.t("settings.reminderMin")
    opacity: page.reminderEnabled ? 1 : page.disabledOpacity
    PageNumber {
      id: minReviewsField
      value: page.reminderMinReviews
      from: 1; to: 500; stepSize: 1
      onModified: function(v) { page.settingChanged("reminderMinReviews", v) }
    }
  }
  Row {
    spacing: Style.space(12)
    LinkText {
      text: page.l10n.t("settings.testNotification")
      foreground: page.foreground
      fontFamily: page.fontFamily
      onActivated: page.testNotificationRequested()
    }
    CaptionText {
      visible: page.reminderEnabled && page.reminderSentToday
      text: page.l10n.t("settings.sentToday")
      foreground: page.foreground
      fontFamily: page.fontFamily
    }
  }

  // ---------- Account ----------
  PageSeparator {}
  PageHeader { text: page.l10n.t("settings.account") }

  PlainText {
    width: parent.width
    wrapMode: Text.WordWrap
    text: page.username
      ? Model.fill(page.l10n.t("settings.connectedAs"), page.username, page.l10n.formatNumber(page.level))
      : (page.hasToken ? page.l10n.t("settings.tokenSaved") : page.l10n.t("settings.notConnected"))
    foreground: page.foreground
    fontFamily: page.fontFamily
  }
  Row {
    spacing: Style.space(12)
    LinkText {
      text: page.l10n.t("settings.changeToken")
      foreground: page.foreground
      fontFamily: page.fontFamily
      onActivated: page.changeTokenRequested()
    }
    LinkText {
      visible: page.tokenFromFile && !page.tokenFromSettings
      text: page.l10n.t("settings.disconnect")
      foreground: page.foreground
      fontFamily: page.fontFamily
      onActivated: page.disconnectRequested()
    }
  }
  CaptionText {
    visible: page.tokenFromSettings
    width: parent.width
    wrapMode: Text.WordWrap
    text: page.l10n.t("settings.usingApiToken")
    foreground: page.foreground
    fontFamily: page.fontFamily
  }
}
