// Pure helpers for Kanibar: WaniKani API response parsing and validation.
// No QML or Quickshell dependencies, so `node --test test/` can load this
// file directly. Nothing here produces user-facing prose: functions return
// numbers or translation keys, and Panel.qml looks the words up in i18n/.

var API_BASE = "https://api.wanikani.com/v2"
var API_REVISION = "20170710"

var REVIEW_URL = "https://www.wanikani.com/subjects/review"
var LESSON_URL = "https://www.wanikani.com/subject-lessons/start"
var DASHBOARD_URL = "https://www.wanikani.com/dashboard"
var TOKEN_URL = "https://www.wanikani.com/settings/personal_access_tokens"

// ---------- Request limits ----------
var REQUEST_TIMEOUT_MS = 15000
var MAX_RESPONSE_CHARS = 2 * 1024 * 1024
// Pseudo-statuses for failures that never got an HTTP status.
var STATUS_OFFLINE = 0        // network error or timeout
var STATUS_TOO_LARGE = -1     // response exceeded MAX_RESPONSE_CHARS

// ---------- Validation ----------
// Everything from the API is untrusted: numbers are clamped to sane ranges,
// strings are cut to a maximum length and stripped of control characters.
// Markup is left as literal text; every sink renders Text.PlainText.
var MAX_COUNT = 100000
var MAX_LEVEL = 60
var MAX_ENTRIES = 200

function clampInt(value, min, max) {
  var n = Math.floor(Number(value))
  if (!isFinite(n)) return min
  return Math.max(min, Math.min(max, n))
}

function cleanText(value, maxLength) {
  if (typeof value !== "string") return ""
  var s = value.replace(/[\u0000-\u001f\u007f]/g, "")
  return s.length > maxLength ? s.slice(0, maxLength) : s
}

function list(value, max) {
  return Array.isArray(value) ? value.slice(0, max === undefined ? MAX_ENTRIES : max) : []
}

function count(entry) {
  return entry && Array.isArray(entry.subject_ids) ? clampInt(entry.subject_ids.length, 0, MAX_COUNT) : 0
}

function timeOf(value) {
  if (typeof value !== "string" || value.length > 40) return null
  var t = Date.parse(value)
  return isNaN(t) ? null : t
}

// ---------- /summary ----------
// `reviews[0]` holds everything already available; later entries are the
// reviews unlocking at that hour (non-cumulative).
function parseSummary(json, now) {
  var data = json && typeof json.data === "object" && json.data ? json.data : {}
  var lessons = list(data.lessons, 48)
  var reviews = list(data.reviews, 48)
  var nowMs = now === undefined ? Date.now() : now

  var lessonCount = 0
  for (var i = 0; i < lessons.length; i++) {
    var lt = timeOf(lessons[i] && lessons[i].available_at)
    if (lt === null || lt <= nowMs) lessonCount += count(lessons[i])
  }

  var reviewCount = 0
  var forecast = []
  for (var j = 0; j < reviews.length; j++) {
    var rt = timeOf(reviews[j] && reviews[j].available_at)
    if (rt === null || rt <= nowMs) reviewCount += count(reviews[j])
    else forecast.push({ time: rt, count: count(reviews[j]) })
  }
  forecast.sort(function(a, b) { return a.time - b.time })

  return {
    lessons: clampInt(lessonCount, 0, MAX_COUNT),
    reviews: clampInt(reviewCount, 0, MAX_COUNT),
    nextReviewsAt: timeOf(data.next_reviews_at),
    forecast: forecast,
    forecastTotal: clampInt(forecast.reduce(function(sum, f) { return sum + f.count }, 0), 0, MAX_COUNT)
  }
}

// ---------- /user ----------
function parseUser(json) {
  var data = json && typeof json.data === "object" && json.data ? json.data : {}
  var sub = data.subscription && typeof data.subscription === "object" ? data.subscription : {}
  return {
    username: cleanText(data.username, 64),
    level: clampInt(data.level, 0, MAX_LEVEL),
    maxLevel: clampInt(sub.max_level_granted, 0, MAX_LEVEL),
    subscribed: sub.active === true
  }
}

// Fixed hourly slots starting at the hour after `now`, so the chart keeps
// its shape even when the API skips empty hours.
function hourlySlots(forecast, now, hours) {
  var n = hours || 24
  var start = new Date(now)
  start.setMinutes(0, 0, 0)
  var base = start.getTime() + 3600000
  var slots = []
  for (var i = 0; i < n; i++) slots.push({ time: base + i * 3600000, count: 0 })
  for (var j = 0; j < (forecast || []).length; j++) {
    var idx = Math.round((forecast[j].time - base) / 3600000)
    if (idx >= 0 && idx < n) slots[idx].count += forecast[j].count
  }
  return slots
}

// ---------- Bar pill ----------
// Shown instead of "0" once every review is done.
var DONE_MARK = ""   // Nerd Font check (nf-fa-check), bolder than ✓ at bar size

// The pill in two parts so the done mark can take the accent color:
// main = review count or the check, extra = "· <lessons>" or "".
// `formatNumber` localizes digits (Commons.I18n.formatNumber in the shell).
function barParts(state, showLessons, formatNumber) {
  var fmt = formatNumber || String
  if (!state || state.reviews === undefined) return { main: "…", extra: "", done: false }
  var done = state.reviews === 0
  return {
    main: done ? DONE_MARK : fmt(state.reviews),
    extra: showLessons && state.lessons > 0 ? "· " + fmt(state.lessons) : "",
    done: done
  }
}

function barLabel(state, showLessons, formatNumber) {
  var parts = barParts(state, showLessons, formatNumber)
  return parts.extra ? parts.main + " " + parts.extra : parts.main
}

// ---------- Time ----------
// Time until `target`, split for translation: kind is one of
// "none", "now", "minutes", "hours", "hoursMinutes", "days", "daysHours".
function duration(target, now) {
  if (target === null || target === undefined) return { kind: "none" }
  var diff = target - now
  if (diff <= 0) return { kind: "now" }
  var minutes = Math.round(diff / 60000)
  if (minutes < 60) return { kind: "minutes", minutes: Math.max(1, minutes) }
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours < 24) return rest ? { kind: "hoursMinutes", hours: hours, minutes: rest } : { kind: "hours", hours: hours }
  var days = Math.floor(hours / 24)
  return hours % 24 ? { kind: "daysHours", days: days, hours: hours % 24 } : { kind: "days", days: days }
}

// Milliseconds until shortly after the next full hour, when WaniKani unlocks
// the next batch of reviews.
function msUntilNextHour(now, slackMs) {
  var d = new Date(now)
  d.setMinutes(0, 0, 0)
  return d.getTime() + 3600000 + (slackMs === undefined ? 30000 : slackMs) - now
}

// ---------- Errors ----------
// → { key, arg } for i18n ("error.server" takes the status as %1).
function errorInfo(status) {
  if (status === STATUS_TOO_LARGE) return { key: "error.tooLarge", arg: "" }
  if (status === STATUS_OFFLINE) return { key: "error.offline", arg: "" }
  if (status === 401) return { key: "error.token", arg: "" }
  if (status === 429) return { key: "error.rateLimited", arg: "" }
  if (status >= 500) return { key: "error.server", arg: String(status) }
  return { key: "error.generic", arg: String(status) }
}

// API v2 tokens are UUIDs. Catches pasting the wrong thing (e.g. a v1 key or
// a URL) before bothering the API. Returns an i18n key, or "" if it looks fine.
function tokenProblem(token) {
  var t = String(token || "").trim()
  if (t === "") return "token.empty"
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(t)) return "token.format"
  return ""
}

// ---------- SRS breakdown ----------
// Each group is fetched as /assignments?srs_stages=… and only total_count is
// read, so a 9000-item account costs five requests instead of ~18 pages.
// Labels live in i18n as "srs.<key>.short".
var SRS_GROUPS = [
  { key: "apprentice",  stages: "1,2,3,4" },
  { key: "guru",        stages: "5,6" },
  { key: "master",      stages: "7" },
  { key: "enlightened", stages: "8" },
  { key: "burned",      stages: "9" }
]

function srsBreakdown(counts) {
  var c = counts || {}
  return SRS_GROUPS.map(function(g) {
    return { key: g.key, count: clampInt(c[g.key] || 0, 0, MAX_COUNT) }
  })
}

function totalCount(json) {
  return json && typeof json.total_count === "number" ? clampInt(json.total_count, 0, MAX_COUNT) : 0
}

// ---------- Level progress ----------
// WaniKani levels you up once 90% of the level's (non-hidden) kanji reach
// Guru, i.e. have a passed_at timestamp.
var LEVEL_UP_RATIO = 0.9

// subjectsJson: /subjects?levels=L&types=kanji
// assignmentsJson: /assignments?levels=L&subject_types=kanji
function levelProgress(subjectsJson, assignmentsJson, level) {
  var subjects = list(subjectsJson && subjectsJson.data)
  var assignments = list(assignmentsJson && assignmentsJson.data, 1000)

  var bySubject = {}
  for (var i = 0; i < assignments.length; i++) {
    var a = assignments[i] && assignments[i].data ? assignments[i].data : {}
    if (typeof a.subject_id === "number") bySubject[a.subject_id] = a
  }

  var items = []
  for (var j = 0; j < subjects.length; j++) {
    var s = subjects[j] || {}
    var d = s.data || {}
    if (d.hidden_at || typeof s.id !== "number") continue
    var asg = bySubject[s.id]
    var stage = asg ? clampInt(asg.srs_stage, 0, 9) : -1   // -1 = still locked
    var primary = list(d.meanings, 20).filter(function(m) { return m && m.primary })[0]
    items.push({
      id: s.id,
      characters: cleanText(d.characters, 8) || "?",
      meaning: primary ? cleanText(primary.meaning, 64) : "",
      position: clampInt(d.lesson_position, 0, 10000),
      stage: stage,
      passed: !!(asg && asg.passed_at)
    })
  }
  items.sort(function(x, y) { return x.position - y.position })

  var total = items.length
  var passed = items.filter(function(it) { return it.passed }).length
  var required = Math.ceil(total * LEVEL_UP_RATIO)
  return {
    level: clampInt(level, 0, MAX_LEVEL),
    total: total,
    passed: passed,
    required: required,
    remaining: Math.max(0, required - passed),
    items: items
  }
}

// Coarse state for coloring a kanji tile.
function itemState(item) {
  if (!item || item.stage < 0) return "locked"
  if (item.passed) return "passed"
  if (item.stage === 0) return "lesson"
  return "learning"
}

// → { key, arg } for i18n.
function stageInfo(stage) {
  if (stage < 0) return { key: "stage.locked", arg: "" }
  if (stage === 0) return { key: "stage.lesson", arg: "" }
  if (stage <= 4) return { key: "stage.apprentice", arg: String(stage) }
  if (stage <= 6) return { key: "stage.guru", arg: String(stage - 4) }
  if (stage === 7) return { key: "stage.master", arg: "" }
  if (stage === 8) return { key: "stage.enlightened", arg: "" }
  return { key: "stage.burned", arg: "" }
}

// ---------- Daily review reminder ----------

// "19:00" / "7:30" → minutes after midnight, or -1 when unparseable.
function parseClock(text) {
  var m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(String(text || ""))
  if (!m) return -1
  var h = parseInt(m[1], 10), min = parseInt(m[2], 10)
  if (h > 23 || min > 59) return -1
  return h * 60 + min
}

// Local calendar date, used to remember "already reminded today".
function dateKey(time) {
  var d = new Date(time)
  var mm = d.getMonth() + 1, dd = d.getDate()
  return d.getFullYear() + "-" + (mm < 10 ? "0" : "") + mm + "-" + (dd < 10 ? "0" : "") + dd
}

// Due once the configured time has passed today and today hasn't been
// handled yet, so a laptop asleep at 19:00 still gets reminded on wake
// (until midnight).
function reminderDue(now, clockMinutes, lastDateKey) {
  if (clockMinutes < 0) return false
  var d = new Date(now)
  if (d.getHours() * 60 + d.getMinutes() < clockMinutes) return false
  return dateKey(now) !== String(lastDateKey || "").trim()
}

// ---------- Placeholders ----------
// Fills %1…%9 in one pass. Unlike chained QString.arg(), text that was
// already inserted is never re-scanned, so a username containing "%1" stays
// literal, and JS replacement patterns like "$&" aren't interpreted.
function fill(template) {
  var args = arguments
  return String(template).replace(/%(\d)/g, function(match, index) {
    var value = args[Number(index)]
    return value === undefined ? match : String(value)
  })
}
