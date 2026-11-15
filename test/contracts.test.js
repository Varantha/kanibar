// Contracts between the QML, Model.js and the catalog: every string exists
// and is used, every text renders PlainText, and animations follow Omarchy's
// motion rules. Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const { Model, root, src } = require("./load-model")

const qmlFiles = fs.readdirSync(src).filter(f => f.endsWith(".qml")).sort()
const qmlSources = Object.fromEntries(qmlFiles.map(f => [f, fs.readFileSync(path.join(src, f), "utf8")]))
const qml = Object.values(qmlSources).join("\n")
const en = JSON.parse(fs.readFileSync(path.join(root, "i18n", "en.json"), "utf8"))

test("every key the QML and Model.js use exists in en.json", () => {
  const used = new Set()
  for (const m of qml.matchAll(/\.tn?\("([a-zA-Z.]+)"\s*[,)]/g)) used.add(m[1])
  assert.ok(used.size > 50, "found only " + used.size + " keys; did the call style change?")
  for (const g of Model.SRS_GROUPS) used.add("srs." + g.key + ".short")
  for (const s of [-1, 0, 3, 6, 7, 8, 9]) used.add(Model.stageInfo(s).key)
  for (const st of [0, -1, 401, 429, 500, 404]) used.add(Model.errorInfo(st).key)
  for (const k of ["token.empty", "token.format"]) used.add(k)
  for (const k of ["now", "minutes", "hours", "hoursMinutes", "days", "daysHours"]) used.add("time." + k)
  const missing = [...used].filter(k => !(k in en))
  assert.deepEqual(missing, [])
})

test("plural entries have the forms English needs", () => {
  for (const [key, value] of Object.entries(en)) {
    if (typeof value === "object") {
      assert.ok(value.one && value.other, key + " needs one and other")
    }
  }
})

test("every catalog key is used", () => {
  const dynamic = new Set(Model.SRS_GROUPS.map(g => "srs." + g.key + ".short"))
  for (const s of [-1, 0, 3, 6, 7, 8, 9]) dynamic.add(Model.stageInfo(s).key)
  for (const st of [0, -1, 401, 429, 500, 404]) dynamic.add(Model.errorInfo(st).key)
  for (const k of ["now", "minutes", "hours", "hoursMinutes", "days", "daysHours"]) dynamic.add("time." + k)
  const model = fs.readFileSync(path.join(src, "Model.js"), "utf8")
  const unused = Object.keys(en).filter(k => !dynamic.has(k) && !qml.includes('"' + k + '"') && !model.includes('"' + k + '"'))
  assert.deepEqual(unused, [])
})

// Text renders AutoText by default, so the only bare Text allowed is the
// PlainText base itself; everything else builds on it.
test("every text renders PlainText", () => {
  const offenders = []
  for (const [file, source] of Object.entries(qmlSources)) {
    source.split("\n").forEach((line, i) => {
      if (/(^|[\s:])Text \{/.test(line) && file !== "PlainText.qml") offenders.push(file + ":" + (i + 1))
    })
  }
  assert.deepEqual(offenders, [])
  assert.match(qmlSources["PlainText.qml"], /textFormat: Text\.PlainText/)
})

test("animations go through Style.duration and stay within 300ms", () => {
  const durations = [...qml.matchAll(/duration: ([^;\n}]+)/g)].map(m => m[1].trim())
  assert.ok(durations.length > 0)
  for (const d of durations) {
    const m = /^Style\.duration\((\d+)\)$/.exec(d)
    assert.ok(m, "bare duration: " + d)
    assert.ok(Number(m[1]) <= 300, "too long: " + d)
  }
  assert.doesNotMatch(qml, /OutBack|OutBounce|OutElastic|Easing\.In[A-Z]/)
})
