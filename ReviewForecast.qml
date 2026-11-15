import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Palette.js" as Palette

// Reviews unlocking in each of the next hours, as a bar chart with an hour
// label every few bars.
Column {
  id: forecast

  required property Localization l10n
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // Model.hourlySlots: [{ time, count }]
  property var slots: []
  property int total: 0

  readonly property int slotCount: slots.length
  readonly property int maxCount: slots.reduce(function(max, slot) { return Math.max(max, slot.count) }, 0)

  spacing: Style.space(6)

  SectionHeader {
    foreground: forecast.foreground
    fontFamily: forecast.fontFamily
    text: Model.fill(forecast.l10n.t("forecast.header"), forecast.l10n.formatNumber(forecast.total))
  }

  Row {
    id: chart
    width: parent.width
    height: Style.space(56)
    spacing: Style.space(2)
    readonly property real barWidth: forecast.slotCount > 0
      ? (width - spacing * (forecast.slotCount - 1)) / forecast.slotCount
      : 0

    Repeater {
      model: forecast.slots
      delegate: Item {
        required property var modelData
        width: chart.barWidth
        height: chart.height

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          radius: Math.min(width / 2, Style.space(2))
          height: modelData.count > 0 && forecast.maxCount > 0
            ? Math.max(Style.space(3), parent.height * modelData.count / forecast.maxCount)
            : Style.space(1)
          color: modelData.count > 0 ? Commons.Color.accent : Palette.tint(forecast.foreground, 0.15)
        }

        PanelToolTip {
          visible: barMouse.containsMouse && modelData.count > 0
          text: Model.fill(forecast.l10n.tn("forecast.tooltip", modelData.count),
                           forecast.l10n.timeText(modelData.time), forecast.l10n.formatNumber(modelData.count))
        }

        MouseArea {
          id: barMouse
          anchors.fill: parent
          hoverEnabled: true
        }
      }
    }
  }

  // Hour labels, each under the first bar of its group.
  Row {
    Repeater {
      model: forecast.slots
      delegate: CaptionText {
        required property var modelData
        required property int index
        readonly property bool last: index === forecast.slotCount - 1
        width: chart.barWidth + (last ? 0 : chart.spacing)
        text: index % Model.FORECAST_TICK_EVERY === 0 ? forecast.l10n.hourText(modelData.time) : ""
        foreground: forecast.foreground
        fontFamily: forecast.fontFamily
      }
    }
  }
}
