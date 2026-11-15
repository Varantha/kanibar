// Loads Model.js the way QML does: as a plain script, not a CommonJS module.
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const root = path.join(__dirname, "..")
const src = path.join(root, "src")
const Model = {}
vm.runInNewContext(fs.readFileSync(path.join(src, "Model.js"), "utf8"), Model)

// Drops the VM realm's prototypes so deepEqual compares plain values.
const plain = (value) => JSON.parse(JSON.stringify(value))

module.exports = { Model, plain, root, src }
