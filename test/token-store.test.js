// Runs the token save script from TokenStore.qml in a scratch directory.
// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")
const { src } = require("./load-model")

// The script as TokenStore.qml builds it: the saveScript string array,
// joined with newlines.
function saveScript() {
  const qml = fs.readFileSync(path.join(src, "TokenStore.qml"), "utf8")
  const block = qml.slice(qml.indexOf("saveScript: ["), qml.indexOf("].join"))
  const lines = [...block.matchAll(/^\s*("(?:[^"\\]|\\.)*"),?$/gm)].map(m => JSON.parse(m[1]))
  assert.ok(lines.length > 0, "saveScript not found in TokenStore.qml")
  return lines.join("\n")
}

function save(dir, token) {
  execFileSync("sh", ["-c", saveScript(), "sh", dir], { input: token + "\n" })
}

const TOKEN = "11111111-2222-4333-8444-555555555555"
const mode = (file) => fs.statSync(file).mode & 0o777

function scratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "kanibar-token-"))
}

test("a new token file is private from the start", () => {
  const dir = path.join(scratch(), "kanibar")
  save(dir, TOKEN)
  assert.equal(mode(dir), 0o700)
  assert.equal(mode(path.join(dir, "token")), 0o600)
  assert.equal(fs.readFileSync(path.join(dir, "token"), "utf8"), TOKEN + "\n")
  assert.deepEqual(fs.readdirSync(dir), ["token"])
})

// A token file others can read must never receive the new token: it is
// replaced by a new private file instead, so even a reader that opened the
// old file beforehand only sees the old contents.
test("an existing readable token file is replaced, not written into", () => {
  const dir = scratch()
  const file = path.join(dir, "token")
  fs.writeFileSync(file, "OLD\n", { mode: 0o644 })
  fs.chmodSync(file, 0o644)
  const before = fs.statSync(file).ino
  const earlyReader = fs.openSync(file, "r")

  save(dir, TOKEN)

  assert.notEqual(fs.statSync(file).ino, before)
  assert.equal(mode(file), 0o600)
  assert.equal(fs.readFileSync(file, "utf8"), TOKEN + "\n")
  assert.equal(fs.readFileSync(earlyReader, "utf8"), "OLD\n")
  fs.closeSync(earlyReader)
  assert.deepEqual(fs.readdirSync(dir), ["token"])
})

test("a symlink at the token path is replaced, its target untouched", () => {
  const dir = scratch()
  const target = path.join(dir, "elsewhere")
  fs.writeFileSync(target, "KEEP\n")
  fs.symlinkSync(target, path.join(dir, "token"))

  save(dir, TOKEN)

  assert.equal(fs.lstatSync(path.join(dir, "token")).isSymbolicLink(), false)
  assert.equal(mode(path.join(dir, "token")), 0o600)
  assert.equal(fs.readFileSync(target, "utf8"), "KEEP\n")
})

// The temp file is reopened by name, so nobody else may be able to add or
// remove entries in the directory while the token is written.
test("an existing directory others can write to is made private first", () => {
  const dir = scratch()
  fs.chmodSync(dir, 0o777)

  save(dir, TOKEN)

  assert.equal(mode(dir), 0o700)
  assert.equal(mode(path.join(dir, "token")), 0o600)
  assert.equal(fs.readFileSync(path.join(dir, "token"), "utf8"), TOKEN + "\n")
})

test("a symlinked token directory is refused and its target untouched", () => {
  const base = scratch()
  const real = path.join(base, "real")
  fs.mkdirSync(real)
  fs.chmodSync(real, 0o777)
  const link = path.join(base, "kanibar")
  fs.symlinkSync(real, link)

  assert.throws(() => save(link, TOKEN))
  assert.equal(mode(real), 0o777)
  assert.deepEqual(fs.readdirSync(real), [])
})

// A directory at the token path makes the rename fail (mv -T) instead of
// moving the token inside it.
test("a failed save leaves no temp file and nothing inside a token directory", () => {
  const dir = scratch()
  const tokenDir = path.join(dir, "token")
  fs.mkdirSync(tokenDir)
  fs.writeFileSync(path.join(tokenDir, "keep"), "KEEP\n")

  assert.throws(() => save(dir, TOKEN))
  assert.deepEqual(fs.readdirSync(dir), ["token"])
  assert.deepEqual(fs.readdirSync(tokenDir), ["keep"])
})
