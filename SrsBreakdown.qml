import QtQuick
import qs.Commons
import qs.Commons as Commons

// Item counts per SRS group (Apprentice … Burned), in equal columns.
Column {
  id: breakdown

  required property Localization l10n
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // Model.srsBreakdown: [{ key, count }]
  property var groups: []

  spacing: Style.space(6)

  SectionHeader {
    foreground: breakdown.foreground
    fontFamily: breakdown.fontFamily
    text: breakdown.l10n.t("srs.header")
  }

  Row {
    id: columns
    width: parent.width

    Repeater {
      model: breakdown.groups
      delegate: Column {
        required property var modelData
        width: columns.width / Math.max(1, breakdown.groups.length)
        spacing: Style.space(1)

        PlainText {
          anchors.horizontalCenter: parent.horizontalCenter
          text: breakdown.l10n.formatNumber(modelData.count)
          foreground: breakdown.foreground
          fontFamily: breakdown.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        CaptionText {
          anchors.horizontalCenter: parent.horizontalCenter
          text: breakdown.l10n.t("srs." + modelData.key + ".short")
          foreground: breakdown.foreground
          fontFamily: breakdown.fontFamily
          font.bold: true
          font.letterSpacing: 1.2
          font.capitalization: Font.AllUppercase
        }
      }
    }
  }
}
