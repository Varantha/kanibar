// Runs real curl with Model.curlCommand's arguments against local servers.
// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const http = require("node:http")
const os = require("node:os")
const path = require("node:path")
const { spawn } = require("node:child_process")
const { Model } = require("./load-model")

const TOKEN = "11111111-2222-4333-8444-555555555555"

// Two local origins: A redirects to B. B records every request it gets.
async function servers() {
  const seenByB = []
  const b = http.createServer((req, res) => {
    seenByB.push(req.headers)
    res.writeHead(200, { "Content-Type": "application/json" })
    res.end('{"stolen":true}')
  })
  await new Promise(r => b.listen(0, "127.0.0.1", r))
  const seenByA = []
  const a = http.createServer((req, res) => {
    seenByA.push(req.headers)
    res.writeHead(302, { Location: "http://127.0.0.1:" + b.address().port + "/elsewhere" })
    res.end()
  })
  await new Promise(r => a.listen(0, "127.0.0.1", r))
  return {
    urlA: "http://127.0.0.1:" + a.address().port + "/v2/user",
    seenByA, seenByB,
    close: () => { a.close(); b.close() }
  }
}

// Kanibar's arguments, except that the HTTPS-only rule is lifted where a
// test needs a plain-HTTP local server.
function run(args, env) {
  return new Promise((resolve) => {
    const child = spawn(args[0], args.slice(1), { env: { ...process.env, ...env } })
    let out = ""
    child.stdout.on("data", d => { out += d })
    child.on("close", code => resolve({ code, out }))
    child.stdin.end(Model.authorizationHeader(TOKEN))
  })
}

function withoutHttpsOnly(args) {
  const i = args.indexOf("--proto")
  return args.slice(0, i).concat(args.slice(i + 2))
}

test("a cross-origin redirect is not followed and B never sees the token", async () => {
  const s = await servers()
  try {
    const { code, out } = await run(withoutHttpsOnly(Model.curlCommand(s.urlA)))
    assert.equal(s.seenByA[0].authorization, "Bearer " + TOKEN)   // the header did arrive via stdin
    assert.equal(s.seenByB.length, 0)
    assert.equal(Model.parseCurlResult(code, out).status, 302)
  } finally { s.close() }
})

test("a ~/.curlrc that turns on redirects is ignored", async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "kanibar-curlrc-"))
  fs.writeFileSync(path.join(home, ".curlrc"), "location\nmax-redirs = 5\n")
  const s = await servers()
  try {
    const { code, out } = await run(withoutHttpsOnly(Model.curlCommand(s.urlA)), { HOME: home, CURL_HOME: home, XDG_CONFIG_HOME: home })
    assert.equal(s.seenByB.length, 0)
    assert.equal(Model.parseCurlResult(code, out).status, 302)
  } finally { s.close() }
})

test("plain HTTP is refused outright", async () => {
  const s = await servers()
  try {
    const { code, out } = await run(Model.curlCommand(s.urlA))
    assert.equal(s.seenByA.length, 0)
    assert.equal(Model.parseCurlResult(code, out).status, Model.STATUS_OFFLINE)
  } finally { s.close() }
})
