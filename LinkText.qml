import QtQuick
import qs.Commons as Commons
import "Palette.js" as Palette

// A text link that turns accent-colored and underlined on hover.
CaptionText {
  id: link

  signal activated()

  color: linkMouse.containsMouse ? Commons.Color.accent : Palette.dim(foreground)
  font.underline: linkMouse.containsMouse

  MouseArea {
    id: linkMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: link.activated()
  }
}
