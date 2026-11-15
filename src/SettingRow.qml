import QtQuick
import qs.Commons
import qs.Commons as Commons

// Label on the left, one control on the right.
Item {
  id: row

  property string label: ""
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  default property alias control: controlSlot.data

  width: parent ? parent.width : implicitWidth
  implicitHeight: Math.max(rowLabel.implicitHeight, controlSlot.childrenRect.height)

  PlainText {
    id: rowLabel
    anchors.left: parent.left
    anchors.right: controlSlot.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: row.label
    elide: Text.ElideRight
    foreground: row.foreground
    fontFamily: row.fontFamily
  }

  Item {
    id: controlSlot
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: childrenRect.width
    height: childrenRect.height
  }
}
