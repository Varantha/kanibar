import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// What sits on the bar: the crocodile, the review count (or a check once
// everything is done) and optionally "· <lessons>". Stacks on a vertical bar.
Grid {
  id: pill

  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool vertical: false
  // Model.barParts: { main, extra, done }
  property var parts: ({ main: "", extra: "", done: false })

  // The icon glyph sits smaller in its em box than digits do, so the check
  // gets a larger size to match the digits' height.
  readonly property real doneMarkScale: 1.5
  readonly property bool done: parts.done === true

  columns: vertical ? 1 : 3
  spacing: Style.space(4)
  verticalItemAlignment: Grid.AlignVCenter
  horizontalItemAlignment: Grid.AlignHCenter

  // A small pop confirming the last review was cleared.
  onDoneChanged: if (done) donePop.restart()

  PlainText {
    text: Model.ICON_GLYPH
    foreground: pill.foreground
  }

  PlainText {
    id: count
    text: pill.parts.main
    foreground: pill.done ? Commons.Color.accent : pill.foreground
    fontFamily: pill.fontFamily
    font.pixelSize: pill.done ? Math.round(Style.font.bodySmall * pill.doneMarkScale) : Style.font.bodySmall
    font.weight: Font.DemiBold

    // 160ms out, 120ms back, no overshoot. Style.duration() is 0 with
    // animations off.
    SequentialAnimation {
      id: donePop
      NumberAnimation {
        target: count; property: "scale"; to: 1.15
        duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut
      }
      NumberAnimation {
        target: count; property: "scale"; to: 1.0
        duration: Style.duration(120); easing.type: Easing.OutCubic
      }
    }
  }

  PlainText {
    visible: text !== ""
    text: pill.parts.extra
    foreground: pill.foreground
    fontFamily: pill.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.weight: Font.DemiBold
  }
}
