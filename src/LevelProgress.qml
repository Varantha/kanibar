import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Palette.js" as Palette

// The current level's kanji: a header with the Guru count, a progress bar
// with a tick at the level-up threshold, and a grid of tiles tinted by SRS
// state.
Column {
  id: progress

  required property Localization l10n
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  // Model.levelProgress, or null
  property var info: null

  readonly property bool hasItems: info !== null && info.total > 0

  spacing: Style.space(6)

  Item {
    width: parent.width
    implicitHeight: levelHeader.implicitHeight

    SectionHeader {
      id: levelHeader
      anchors.left: parent.left
      foreground: progress.foreground
      fontFamily: progress.fontFamily
      text: progress.info ? Model.fill(progress.l10n.t("level.header"), progress.l10n.formatNumber(progress.info.level)) : ""
    }

    CaptionText {
      anchors.right: parent.right
      anchors.baseline: levelHeader.baseline
      foreground: progress.foreground
      fontFamily: progress.fontFamily
      text: {
        var info = progress.info
        if (!info) return ""
        var l10n = progress.l10n
        return info.remaining > 0
          ? Model.fill(l10n.t("level.progress"), l10n.formatNumber(info.passed), l10n.formatNumber(info.total), l10n.formatNumber(info.remaining))
          : Model.fill(l10n.t("level.ready"), l10n.formatNumber(info.passed), l10n.formatNumber(info.total))
      }
    }
  }

  // Progress bar with a tick at the 90% level-up threshold.
  Item {
    id: track
    width: parent.width
    height: Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Palette.tint(progress.foreground, 0.12)
    }
    Rectangle {
      // Anchored, so it fills from the right under RTL mirroring.
      anchors.left: parent.left
      height: parent.height
      radius: height / 2
      color: Commons.Color.accent
      width: progress.hasItems ? Math.max(height, parent.width * progress.info.passed / progress.info.total) : 0
      Behavior on width { NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic } }
    }
    Rectangle {
      readonly property real offset: progress.hasItems
        ? track.width * progress.info.required / progress.info.total - width / 2
        : 0
      visible: progress.hasItems
      width: Math.max(1, Style.space(2))
      height: parent.height + Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      // Explicit x isn't mirrored automatically.
      x: LayoutMirroring.enabled ? track.width - offset - width : offset
      color: progress.foreground
    }
  }

  // As many columns as fit at the minimum tile size, then tiles stretch so
  // every full row spans the content width exactly (same edges as the bar
  // above).
  Grid {
    id: kanjiGrid
    width: parent.width
    spacing: Style.space(4)
    readonly property real minTile: Style.space(26)
    columns: Math.max(1, Math.floor((width + spacing) / (minTile + spacing)))
    readonly property real tile: (width - (columns - 1) * spacing) / columns

    Repeater {
      model: progress.info ? progress.info.items : []
      delegate: Rectangle {
        id: kanjiTile
        required property var modelData
        readonly property string tileState: Model.itemState(modelData)
        readonly property bool passed: tileState === "passed"
        readonly property bool locked: tileState === "locked"
        readonly property color fg: progress.foreground

        width: kanjiGrid.tile
        height: kanjiGrid.tile
        radius: Style.space(4)
        color: passed ? Commons.Color.accent
          : tileState === "learning" ? Palette.tint(fg, 0.14)
          : "transparent"
        border.width: 1
        border.color: passed ? Commons.Color.accent : Palette.tint(fg, locked ? 0.10 : 0.25)

        PlainText {
          anchors.centerIn: parent
          text: kanjiTile.modelData.characters
          foreground: kanjiTile.passed ? Commons.Color.background
            : kanjiTile.locked ? Palette.tint(kanjiTile.fg, 0.35)
            : kanjiTile.fg
          font.pixelSize: Style.font.subtitle
        }

        MouseArea {
          id: kanjiMouse
          anchors.fill: parent
          hoverEnabled: true
        }

        // PanelToolTip renders PlainText; meaning comes from the API.
        PanelToolTip {
          visible: kanjiMouse.containsMouse
          text: kanjiTile.modelData.meaning
            ? Model.fill(progress.l10n.t("stage.tooltip"), kanjiTile.modelData.meaning, progress.l10n.stageText(kanjiTile.modelData.stage))
            : progress.l10n.stageText(kanjiTile.modelData.stage)
        }
      }
    }
  }
}
