import QtQuick
import qs.Commons
import "Palette.js" as Palette

// Small, dimmed secondary text: hints, notes, axis labels.
PlainText {
  color: Palette.dim(foreground)
  font.pixelSize: Style.font.caption
}
