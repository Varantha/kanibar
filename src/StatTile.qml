import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Palette.js" as Palette

// A big number with a label, optionally clickable ("Start reviews ↗").
Rectangle {
  id: tile

  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property string label: ""
  property string valueText: ""
  property bool highlighted: false  // value in the accent color
  property bool celebrate: false    // accent-colored border
  property string note: ""          // plain line under the label
  property string actionText: ""    // makes the tile clickable

  signal activated()

  readonly property bool clickable: actionText !== ""

  implicitHeight: tileColumn.implicitHeight + Style.space(20)
  radius: Style.cornerRadius
  color: Palette.tint(foreground, tileMouse.containsMouse && clickable ? 0.10 : 0.04)
  border.width: 1
  border.color: celebrate ? Commons.Color.accent : Palette.tint(foreground, 0.15)

  Column {
    id: tileColumn
    anchors.centerIn: parent
    spacing: Style.space(2)

    PlainText {
      anchors.horizontalCenter: parent.horizontalCenter
      text: tile.valueText
      foreground: tile.highlighted || tile.celebrate ? Commons.Color.accent : tile.foreground
      fontFamily: tile.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
    }
    CaptionText {
      anchors.horizontalCenter: parent.horizontalCenter
      text: tile.label
      foreground: tile.foreground
      fontFamily: tile.fontFamily
      font.bold: true
      font.letterSpacing: 1.2
      font.capitalization: Font.AllUppercase
    }
    PlainText {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: tile.clickable
      text: tile.actionText + " ↗"
      foreground: tile.foreground
      fontFamily: tile.fontFamily
      font.pixelSize: Style.font.caption
    }
    CaptionText {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: tile.note !== ""
      text: tile.note
      foreground: tile.foreground
      fontFamily: tile.fontFamily
    }
  }

  MouseArea {
    id: tileMouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: tile.clickable
    cursorShape: Qt.PointingHandCursor
    onClicked: tile.activated()
  }
}
