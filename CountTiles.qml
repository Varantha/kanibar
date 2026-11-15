import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Reviews and lessons available now, side by side. Once every review is
// done the reviews tile shows the check and when the next ones unlock.
Row {
  id: tiles

  required property Localization l10n
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property int reviews: 0
  property int lessons: 0
  property bool reviewsDone: false
  property string nextReviewsText: ""   // "in 2h", or "" when unknown

  signal reviewsActivated()
  signal lessonsActivated()

  readonly property real tileWidth: (width - spacing) / 2

  spacing: Style.space(10)

  StatTile {
    width: tiles.tileWidth
    foreground: tiles.foreground
    fontFamily: tiles.fontFamily
    label: tiles.reviewsDone ? tiles.l10n.t("tile.allDone") : tiles.l10n.t("tile.reviews")
    valueText: tiles.reviewsDone ? Model.DONE_MARK : tiles.l10n.formatNumber(tiles.reviews)
    highlighted: tiles.reviews > 0
    celebrate: tiles.reviewsDone
    note: tiles.reviewsDone && tiles.nextReviewsText !== ""
      ? Model.fill(tiles.l10n.t("tile.next"), tiles.nextReviewsText)
      : ""
    actionText: tiles.reviews > 0 ? tiles.l10n.t("tile.startReviews") : ""
    onActivated: tiles.reviewsActivated()
  }

  StatTile {
    width: tiles.tileWidth
    foreground: tiles.foreground
    fontFamily: tiles.fontFamily
    label: tiles.l10n.t("tile.lessons")
    valueText: tiles.l10n.formatNumber(tiles.lessons)
    highlighted: tiles.lessons > 0
    actionText: tiles.lessons > 0 ? tiles.l10n.t("tile.startLessons") : ""
    onActivated: tiles.lessonsActivated()
  }
}
