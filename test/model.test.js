// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const Model = {}
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8"), Model)

const NOW = Date.parse("2026-11-15T13:20:00Z")

const summary = {
  object: "report",
  data: {
    lessons: [{ available_at: "2026-11-15T13:00:00Z", subject_ids: [1, 2, 3, 4, 5] }],
    next_reviews_at: "2026-11-15T13:00:00Z",
    reviews: [
      { available_at: "2026-11-15T13:00:00Z", subject_ids: [10, 11, 12] },
      { available_at: "2026-11-15T14:00:00Z", subject_ids: [] },
      { available_at: "2026-11-15T15:00:00Z", subject_ids: [20, 21] },
      { available_at: "2026-11-16T12:00:00Z", subject_ids: [30] }
    ]
  }
}

test("parseSummary counts what is available now", () => {
  const s = Model.parseSummary(summary, NOW)
  assert.equal(s.reviews, 3)
  assert.equal(s.lessons, 5)
  assert.equal(s.forecastTotal, 3)
  assert.equal(s.forecast.length, 3)
})

test("parseSummary tolerates empty or broken input", () => {
  const s = Model.parseSummary(null, NOW)
  assert.equal(s.reviews, 0)
  assert.equal(s.lessons, 0)
  assert.equal(s.nextReviewsAt, null)
})

test("hourlySlots buckets the forecast into 24 fixed hours", () => {
  const s = Model.parseSummary(summary, NOW)
  const slots = Model.hourlySlots(s.forecast, NOW, 24)
  assert.equal(slots.length, 24)
  assert.equal(slots[0].time, Date.parse("2026-11-15T14:00:00Z"))
  assert.equal(slots[1].count, 2)
  assert.equal(slots[22].count, 1)
})

test("parseUser", () => {
  const u = Model.parseUser({ data: { username: "koichi", level: 12, subscription: { active: true, max_level_granted: 60 } } })
  assert.deepEqual({ ...u }, { username: "koichi", level: 12, maxLevel: 60, subscribed: true })
})

test("barLabel", () => {
  assert.equal(Model.barLabel(null, true), "…")
  assert.equal(Model.barLabel({ reviews: 42, lessons: 5 }, true), "42 · 5")
  assert.equal(Model.barLabel({ reviews: 42, lessons: 5 }, false), "42")
  assert.equal(Model.barLabel({ reviews: 0, lessons: 0 }, true), "0")
})

test("relativeTime", () => {
  assert.equal(Model.relativeTime(NOW - 1, NOW), "now")
  assert.equal(Model.relativeTime(NOW + 20 * 60000, NOW), "in 20m")
  assert.equal(Model.relativeTime(NOW + 135 * 60000, NOW), "in 2h 15m")
  assert.equal(Model.relativeTime(NOW + 26 * 3600000, NOW), "in 1d 2h")
  assert.equal(Model.relativeTime(null, NOW), "")
})

test("msUntilNextHour lands just after the hour", () => {
  assert.equal(Model.msUntilNextHour(NOW, 30000), 40 * 60000 + 30000)
})

test("errorMessage", () => {
  assert.match(Model.errorMessage(401), /token/)
  assert.match(Model.errorMessage(0), /reach/)
})
