import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Token entry: shown on first run, after WaniKani rejects the saved token,
// or after "Change token". It reads state and emits intent.
Column {
  id: entry

  required property Localization l10n
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  property bool busy: false
  property bool rejected: false        // the saved token got a 401
  property bool malformed: false       // the saved token isn't a valid API token
  property bool editing: false         // "Change token" was clicked
  property bool canCancel: true        // false once the accepted token is being saved
  property var error: null             // Model message or null
  property bool tokenFromSettings: false
  property string savedPath: ""

  readonly property alias input: tokenField

  signal submitted(string token)
  signal cancelRequested()
  signal getTokenRequested()
  // Escape outside of editing: close the popup.
  signal dismissRequested()
  signal edited()

  spacing: Style.space(8)

  PlainText {
    width: parent.width
    wrapMode: Text.WordWrap
    text: entry.editing || !entry.rejected ? entry.l10n.t("token.prompt")
      : entry.malformed ? entry.l10n.t("token.malformed")
      : entry.l10n.t("token.rejected")
    foreground: entry.foreground
    fontFamily: entry.fontFamily
  }

  Row {
    width: parent.width
    spacing: Style.space(6)

    TextField {
      id: tokenField
      width: parent.width - connectButton.width - parent.spacing
      password: true
      maximumLength: Model.MAX_TOKEN_CHARS
      enabled: !entry.busy
      placeholderText: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
      foreground: entry.foreground
      font.family: entry.fontFamily
      onTextChanged: entry.edited()
      onAccepted: entry.submitted(text)
      Keys.onEscapePressed: function(event) {
        if (entry.editing) entry.cancelRequested()
        else entry.dismissRequested()
        event.accepted = true
      }
    }

    Button {
      id: connectButton
      text: entry.busy ? entry.l10n.t("token.checking") : entry.l10n.t("token.connect")
      bordered: true
      enabled: !entry.busy && tokenField.text.trim() !== ""
      foreground: entry.foreground
      fontFamily: entry.fontFamily
      anchors.verticalCenter: tokenField.verticalCenter
      onClicked: entry.submitted(tokenField.text)
    }
  }

  PlainText {
    width: parent.width
    visible: entry.error !== null
    wrapMode: Text.WordWrap
    text: entry.l10n.message(entry.error)
    foreground: Commons.Color.urgent
    fontFamily: entry.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  CaptionText {
    width: parent.width
    visible: entry.tokenFromSettings
    wrapMode: Text.WordWrap
    text: entry.l10n.t("token.settingsOverride")
    foreground: entry.foreground
    fontFamily: entry.fontFamily
  }

  Row {
    spacing: Style.space(12)

    LinkText {
      text: entry.l10n.t("token.get")
      foreground: entry.foreground
      fontFamily: entry.fontFamily
      onActivated: entry.getTokenRequested()
    }
    LinkText {
      // Hidden once saving has begun: the replacement can't be undone then.
      visible: entry.editing && entry.canCancel
      text: entry.l10n.t("token.cancel")
      foreground: entry.foreground
      fontFamily: entry.fontFamily
      onActivated: entry.cancelRequested()
    }
  }

  CaptionText {
    width: parent.width
    wrapMode: Text.WordWrap
    text: Model.fill(entry.l10n.t("token.savedTo"), entry.savedPath)
    foreground: entry.foreground
    fontFamily: entry.fontFamily
  }
}
