import QtQuick
import qs.Commons
import qs.Commons as Commons

// Every text Kanibar draws goes through here (or a component built on it).
// PlainText keeps markup-shaped API data from being rendered as rich text;
// test/model.test.js rejects a bare `Text {` anywhere else.
Text {
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  textFormat: Text.PlainText
  color: foreground
  font.family: fontFamily
  font.pixelSize: Style.font.body
}
