// A stand-in for libsecret's secret-tool, for tests that must not touch the
// developer's real keyring. It behaves like the real one: lookup prints the
// secret without a newline, "not found" exits 1 silently, an unreachable
// keyring exits 1 with a message on stderr, store reads the secret from
// stdin, search lists items locked or not. It keeps the secret in a file and
// logs every argv.
const fs = require("node:fs")
const path = require("node:path")

const SCRIPT = `#!/bin/sh
d="$FAKE_KEYRING_DIR"
echo "$*" >> "$d/calls"
down() { echo "secret-tool: Could not connect: No such file or directory" >&2; exit 1; }
[ -e "$d/down" ] && down
# Locked: clear deletes nothing and fails silently (libsecret only deletes
# unlocked items). lookup asks to unlock: "locked" models the user entering
# the password (it unlocks), "locked-dismiss" the prompt being dismissed
# (silent "not found"). search lists the item either way, the secret only
# when unlocked.
locked() { [ -e "$d/locked" ] || [ -e "$d/locked-dismiss" ]; }
case "$1" in
  lookup) [ -f "$d/secret" ] || exit 1
          [ -e "$d/locked-dismiss" ] && exit 1
          rm -f "$d/locked"; cat "$d/secret"; exit 0 ;;
  search) [ -f "$d/secret" ] || exit 0   # like the real one: no match is exit 0, no output
          echo "[/org/freedesktop/secrets/collection/login/1]"
          echo "label = Kanibar: WaniKani API token"
          locked || echo "secret = $(cat "$d/secret")"
          exit 0 ;;
  store)  [ -e "$d/down-store" ] && down
          locked && exit 1
          cat > "$d/secret.tmp" && mv "$d/secret.tmp" "$d/secret"; exit 0 ;;
  clear)  [ -e "$d/down-clear" ] && down
          locked && exit 1
          [ -f "$d/secret" ] && { rm -f "$d/secret"; exit 0; }; exit 1 ;;
esac
exit 2
`

// Creates the fake under `base`: bin/secret-tool and keyring/. `secret`
// seeds a stored token; `down` is "all", "store" or "clear" to make that
// part unreachable, or "locked" / "locked-dismiss" for a locked keyring
// that unlocks on lookup / whose unlock prompt is dismissed. Returns { bin, dir, env, secret(), calls() }.
function fakeKeyring(base, { secret = null, down = null } = {}) {
  const bin = path.join(base, "bin")
  const dir = path.join(base, "keyring")
  fs.mkdirSync(bin, { recursive: true })
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(bin, "secret-tool"), SCRIPT, { mode: 0o755 })
  if (secret !== null) fs.writeFileSync(path.join(dir, "secret"), secret)
  if (down) fs.writeFileSync(path.join(dir, down === "all" ? "down" : down.startsWith("locked") ? down : "down-" + down), "")
  return {
    bin, dir,
    env: { FAKE_KEYRING_DIR: dir },
    secret: () => fs.existsSync(path.join(dir, "secret")) ? fs.readFileSync(path.join(dir, "secret"), "utf8") : null,
    calls: () => fs.existsSync(path.join(dir, "calls")) ? fs.readFileSync(path.join(dir, "calls"), "utf8").trim().split("\n").filter(Boolean) : []
  }
}

module.exports = { fakeKeyring }

// Locks the fake keyring mid-test (from QML: a Process running this).
module.exports.lockCommand = (dir, how = "locked") => ["touch", require("node:path").join(dir, how)]
