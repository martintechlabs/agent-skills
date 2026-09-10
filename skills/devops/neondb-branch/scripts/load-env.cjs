// scripts/load-env.cjs
//
// Preloaded via NODE_OPTIONS='--require ./scripts/load-env.cjs' (see the dev/build/start scripts in
// your package.json) so the process runs against THIS workspace's Neon branch.
//
// It does two things, and both are load-bearing:
//
//  1. STARTUP GUARD. It refuses to let the process start unless .neondb/state.json says the
//     workspace database is `ready`. A branch in `creating`/`pending` still holds production rows or
//     an unfinished schema — only the provisioning migrator may touch it — and one in `deleting` is
//     on its way out. There is deliberately NO fallback to an ambient DATABASE_URL: falling back
//     silently points the app at the SHARED database, which is the exact failure this skill exists
//     to prevent.
//
//  2. ISOLATED URL LOADING. It assigns the managed DB vars from .env.neondb with OVERRIDE, so a
//     DATABASE_URL already exported by the shell, by a shared .env, or by an orchestrator's
//     environment tab cannot win. Values are read literally — no ${…} expansion — because a
//     connection-string password may legitimately contain a `$`.
//
// Only the listed vars are touched; every other line in .env.neondb is left to whatever else loads
// it. Nothing else in the file is read, and this file never writes.

const { readFileSync } = require('node:fs')
const { join } = require('node:path')

// KEEP IN SYNC with DB_ENV_VARS in scripts/neondb-branch.ts.
const DB_ENV_VARS = ['DATABASE_URL']
const ENV_FILE = '.env.neondb'
const STATE_FILE = join('.neondb', 'state.json')

function fail(message) {
  throw new Error(`[neondb-branch] ${message}`)
}

function readWorkspaceStatus() {
  let raw
  try {
    raw = readFileSync(STATE_FILE, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') {
      fail(`this workspace has no database (${STATE_FILE} is missing). Run \`db:provision\` (or \`worktree:setup\`) first.`)
    }
    throw error
  }
  let state
  try {
    state = JSON.parse(raw)
  } catch {
    fail(`${STATE_FILE} is not valid JSON. Re-run \`db:provision\`.`)
  }
  if (!state || typeof state !== 'object' || typeof state.status !== 'string') {
    fail(`${STATE_FILE} is malformed. Re-run \`db:provision\`.`)
  }
  return state.status
}

/** Minimal literal parser for the KEY='value' lines this skill writes. No expansion, by design. */
function readManagedVars() {
  let raw
  try {
    raw = readFileSync(ENV_FILE, 'utf8')
  } catch (error) {
    if (error.code === 'ENOENT') return {}
    throw error
  }
  const wanted = new Set(DB_ENV_VARS)
  const found = {}
  for (const line of raw.split('\n')) {
    const eq = line.indexOf('=')
    if (eq === -1) continue
    const key = line.slice(0, eq).trim()
    if (!wanted.has(key)) continue
    let value = line.slice(eq + 1).trim()
    if ((value.startsWith("'") && value.endsWith("'")) || (value.startsWith('"') && value.endsWith('"'))) {
      value = value.slice(1, -1)
    }
    found[key] = value
  }
  return found
}

const status = readWorkspaceStatus()
if (status !== 'ready') {
  fail(
    `this workspace's database is in state "${status}", not "ready" — refusing to start against it. ` +
      (status === 'creating' || status === 'pending'
        ? 'Provisioning did not finish; the branch may still hold production rows. Re-run `db:provision`.'
        : 'Re-run `db:provision` to rebuild it.'),
  )
}

const managed = readManagedVars()
const missing = DB_ENV_VARS.filter((name) => !managed[name])
if (missing.length > 0) {
  fail(`${ENV_FILE} does not define ${missing.join(', ')} for this workspace. Re-run \`db:provision\`.`)
}
for (const name of DB_ENV_VARS) {
  process.env[name] = managed[name] // override, always — an ambient value is the shared database
}
