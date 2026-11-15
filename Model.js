// Pure helpers for Kanibar: WaniKani API response parsing and formatting.
// No QML or Quickshell dependencies, so `node --test test/` can load this
// file directly.

var API_BASE = "https://api.wanikani.com/v2"
var API_REVISION = "20170710"

var REVIEW_URL = "https://www.wanikani.com/subjects/review"
var LESSON_URL = "https://www.wanikani.com/subject-lessons/start"
var DASHBOARD_URL = "https://www.wanikani.com/dashboard"

function count(entry) {
  return entry && entry.subject_ids ? entry.subject_ids.length : 0
}

function timeOf(value) {
  var t = Date.parse(value || "")
  return isNaN(t) ? null : t
}

// GET /summary → counts available now plus the 24-hour review forecast.
// `reviews[0]` holds everything already available; later entries are the
// reviews unlocking at that hour (non-cumulative).
function parseSummary(json, now) {
  var data = json && json.data ? json.data : {}
  var lessons = data.lessons || []
  var reviews = data.reviews || []
  var nowMs = now === undefined ? Date.now() : now

  var lessonCount = 0
  for (var i = 0; i < lessons.length; i++) {
    var lt = timeOf(lessons[i].available_at)
    if (lt === null || lt <= nowMs) lessonCount += count(lessons[i])
  }

  var reviewCount = 0
  var forecast = []
  for (var j = 0; j < reviews.length; j++) {
    var rt = timeOf(reviews[j].available_at)
    if (rt === null || rt <= nowMs) reviewCount += count(reviews[j])
    else forecast.push({ time: rt, count: count(reviews[j]) })
  }
  forecast.sort(function(a, b) { return a.time - b.time })

  return {
    lessons: lessonCount,
    reviews: reviewCount,
    nextReviewsAt: timeOf(data.next_reviews_at),
    forecast: forecast,
    forecastTotal: forecast.reduce(function(sum, f) { return sum + f.count }, 0)
  }
}

// GET /user → the bits the panel shows.
function parseUser(json) {
  var data = json && json.data ? json.data : {}
  var sub = data.subscription || {}
  return {
    username: data.username || "",
    level: data.level || 0,
    maxLevel: sub.max_level_granted || 0,
    subscribed: sub.active === true
  }
}

// Fixed 24 hourly slots starting at the hour after `now`, so the chart keeps
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

function barLabel(state, showLessons) {
  if (!state || state.reviews === undefined) return "…"
  var text = String(state.reviews)
  if (showLessons && state.lessons > 0) text += " · " + state.lessons
  return text
}

function relativeTime(target, now) {
  if (target === null || target === undefined) return ""
  var diff = target - now
  if (diff <= 0) return "now"
  var minutes = Math.round(diff / 60000)
  if (minutes < 60) return "in " + Math.max(1, minutes) + "m"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours < 24) return "in " + hours + "h" + (rest ? " " + rest + "m" : "")
  var days = Math.floor(hours / 24)
  return "in " + days + "d" + (hours % 24 ? " " + (hours % 24) + "h" : "")
}

function hourLabel(time) {
  var h = new Date(time).getHours()
  return (h < 10 ? "0" : "") + h
}

// Milliseconds until shortly after the next full hour, when WaniKani unlocks
// the next batch of reviews.
function msUntilNextHour(now, slackMs) {
  var d = new Date(now)
  d.setMinutes(0, 0, 0)
  return d.getTime() + 3600000 + (slackMs === undefined ? 30000 : slackMs) - now
}

function errorMessage(status) {
  if (status === 0) return "Can't reach WaniKani. Check your connection."
  if (status === 401) return "WaniKani rejected the API token."
  if (status === 429) return "Rate limited by WaniKani. Retrying later."
  if (status >= 500) return "WaniKani is having trouble (" + status + ")."
  return "Request failed (" + status + ")."
}

var TOKEN_URL = "https://www.wanikani.com/settings/personal_access_tokens"

// API v2 tokens are UUIDs. Catches pasting the wrong thing (e.g. a v1 key or
// a URL) before bothering the API. Empty string means it looks fine.
function tokenProblem(token) {
  var t = String(token || "").trim()
  if (t === "") return "Paste your token first."
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(t))
    return "That doesn't look like a WaniKani API v2 token (xxxxxxxx-xxxx-…)."
  return ""
}

// ---------- SRS breakdown ----------
// Each group is fetched as /assignments?srs_stages=… and only total_count is
// read, so a 9000-item account costs five requests instead of ~18 pages.
var SRS_GROUPS = [
  { key: "apprentice",  label: "Apprentice",  short: "APPR", stages: "1,2,3,4" },
  { key: "guru",        label: "Guru",        short: "GURU", stages: "5,6" },
  { key: "master",      label: "Master",      short: "MAST", stages: "7" },
  { key: "enlightened", label: "Enlightened", short: "ENLI", stages: "8" },
  { key: "burned",      label: "Burned",      short: "BURN", stages: "9" }
]

function srsBreakdown(counts) {
  var c = counts || {}
  return SRS_GROUPS.map(function(g) {
    return { key: g.key, label: g.label, short: g.short, count: c[g.key] || 0 }
  })
}

function totalCount(json) {
  return json && typeof json.total_count === "number" ? json.total_count : 0
}

// ---------- Level progress ----------
// WaniKani levels you up once 90% of the level's (non-hidden) kanji reach
// Guru, i.e. have a passed_at timestamp.
var LEVEL_UP_RATIO = 0.9

// subjectsJson: /subjects?levels=L&types=kanji
// assignmentsJson: /assignments?levels=L&subject_types=kanji
function levelProgress(subjectsJson, assignmentsJson, level) {
  var subjects = (subjectsJson && subjectsJson.data) || []
  var assignments = (assignmentsJson && assignmentsJson.data) || []

  var bySubject = {}
  for (var i = 0; i < assignments.length; i++) {
    var a = assignments[i].data || {}
    bySubject[a.subject_id] = a
  }

  var items = []
  for (var j = 0; j < subjects.length; j++) {
    var s = subjects[j]
    var d = s.data || {}
    if (d.hidden_at) continue
    var asg = bySubject[s.id]
    var stage = asg ? (asg.srs_stage || 0) : -1   // -1 = still locked
    var primary = (d.meanings || []).filter(function(m) { return m.primary })[0]
    items.push({
      id: s.id,
      characters: d.characters || "?",
      meaning: primary ? primary.meaning : "",
      position: d.lesson_position || 0,
      stage: stage,
      passed: !!(asg && asg.passed_at)
    })
  }
  items.sort(function(x, y) { return x.position - y.position })

  var total = items.length
  var passed = items.filter(function(it) { return it.passed }).length
  var required = Math.ceil(total * LEVEL_UP_RATIO)
  return {
    level: level || 0,
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

function stageName(stage) {
  if (stage < 0) return "Locked"
  if (stage === 0) return "In lessons"
  if (stage <= 4) return "Apprentice " + stage
  if (stage <= 6) return "Guru " + (stage - 4)
  if (stage === 7) return "Master"
  if (stage === 8) return "Enlightened"
  return "Burned"
}
