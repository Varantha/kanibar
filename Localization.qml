import QtQuick
import qs.Commons as Commons
import "Model.js" as Model

// The plugin's strings and number/date formatting in one place. One instance
// lives in Panel.qml and is handed to every view. Call these from bindings,
// so a language switch re-renders them.
QtObject {
  id: root

  readonly property var formatLocale: Qt.locale(Commons.I18n.formatLocale)

  property Commons.Translations catalog: Commons.Translations {
    directory: Qt.resolvedUrl("i18n")
  }

  function t(key) { return catalog.t(key) }
  function tn(key, n) { return catalog.tn(key, n) }
  function formatNumber(n) { return Commons.I18n.formatNumber(n) }

  // A Model message ({ key, arg }) as text.
  function message(info) { return info ? Model.fill(t(info.key), info.arg) : "" }

  function timeText(ms) { return new Date(ms).toLocaleTimeString(formatLocale, Locale.ShortFormat) }
  function hourText(ms) { return formatLocale.toString(new Date(ms), "HH") }

  function durationText(target, now) {
    var d = Model.duration(target, now)
    switch (d.kind) {
    case "now": return t("time.now")
    case "minutes": return Model.fill(t("time.minutes"), formatNumber(d.minutes))
    case "hours": return Model.fill(t("time.hours"), formatNumber(d.hours))
    case "hoursMinutes": return Model.fill(t("time.hoursMinutes"), formatNumber(d.hours), formatNumber(d.minutes))
    case "days": return Model.fill(t("time.days"), formatNumber(d.days))
    case "daysHours": return Model.fill(t("time.daysHours"), formatNumber(d.days), formatNumber(d.hours))
    }
    return ""
  }

  function stageText(stage) {
    var info = Model.stageInfo(stage)
    return Model.fill(t(info.key), info.arg !== "" ? formatNumber(Number(info.arg)) : "")
  }
}
