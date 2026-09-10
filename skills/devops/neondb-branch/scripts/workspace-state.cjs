// Shared, credential-free state validation for the CLI and the startup preload.
const { execFileSync } = require('node:child_process')
const { readFileSync } = require('node:fs')
const { join } = require('node:path')

function parseState(raw, file = '.neondb/state.json') {
  let state
  try { state = JSON.parse(raw) } catch { throw new Error(`${file} is not valid JSON. Inspect the recorded branch in Neon before manual recovery.`) }
  if (!state || typeof state !== 'object' || Array.isArray(state)) throw new Error(`${file} must contain a JSON object.`)
  const keys = ['branchId', 'branchName', 'projectId', 'status']
  const extra = Object.keys(state).filter((key) => !keys.includes(key))
  if (extra.length) throw new Error(`${file} has unrecognized key(s): ${extra.join(', ')}.`)
  for (const key of keys) if (!(key in state)) throw new Error(`${file} is incomplete: missing "${key}".`)
  if (!['creating', 'pending', 'ready', 'deleting'].includes(state.status)) throw new Error(`${file} has an unknown status ${JSON.stringify(state.status)}.`)
  for (const key of ['branchName', 'projectId']) {
    if (typeof state[key] !== 'string' || !state[key].trim()) throw new Error(`${file} has a missing or empty "${key}".`)
  }
  if (state.status === 'creating') {
    if (state.branchId !== null) throw new Error(`${file}: creation intent is unresolved and cannot carry an id.`)
  } else if (typeof state.branchId !== 'string' || !/^br-[a-z0-9-]+$/.test(state.branchId)) {
    throw new Error(`${file}: "branchId" is not a Neon branch id.`)
  }
  return state
}

function ownershipFilePath() {
  // Test-only override. Real workspaces use their OWN Git directory, never --git-common-dir.
  if (process.env.NEONDB_OWNERSHIP_FILE) return process.env.NEONDB_OWNERSHIP_FILE
  let gitDir
  try { gitDir = execFileSync('git', ['rev-parse', '--absolute-git-dir'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim() }
  catch { throw new Error('Cannot locate per-worktree Git metadata. Run this command inside the owning Git checkout.') }
  return join(gitDir, 'neondb-workspace.json')
}

function readOwnership(state) {
  const file = ownershipFilePath()
  const fail = () => { throw new Error(`Workspace ownership receipt ${file} is missing, malformed, or belongs to a different branch. Refusing to use copied state. Inspect Neon and clean up the recorded branch manually before removing state and provisioning again.`) }
  let receipt
  try { receipt = JSON.parse(readFileSync(file, 'utf8')) } catch { fail() }
  const keys = ['branchId', 'projectId', 'parentId', 'parentLsn', 'databaseTarget']
  if (!receipt || typeof receipt !== 'object' || Array.isArray(receipt) ||
      Object.keys(receipt).length !== keys.length || keys.some((key) => !(key in receipt)) ||
      receipt.branchId !== state.branchId || receipt.projectId !== state.projectId ||
      typeof receipt.parentId !== 'string' || !/^br-[a-z0-9-]+$/.test(receipt.parentId) ||
      typeof receipt.parentLsn !== 'string' || !/^[0-9A-Fa-f]+\/[0-9A-Fa-f]+$/.test(receipt.parentLsn) ||
      !(receipt.databaseTarget === null || (typeof receipt.databaseTarget === 'string' && receipt.databaseTarget))) fail()
  return receipt
}

function databaseTarget(uri) {
  let parsed
  try { parsed = new URL(uri) } catch { throw new Error('Invalid managed database URL. Re-run provision for this workspace.') }
  if (!['postgres:', 'postgresql:'].includes(parsed.protocol) || !parsed.hostname || parsed.pathname.length < 2) {
    throw new Error('Invalid managed database URL. Re-run provision for this workspace.')
  }
  return `${parsed.hostname.toLowerCase()}:${parsed.port || '5432'}/${decodeURIComponent(parsed.pathname.slice(1))}`
}

function assertDatabaseTarget(receipt, uri) {
  if (!receipt.databaseTarget || receipt.databaseTarget !== databaseTarget(uri)) {
    throw new Error('Managed database target does not match this workspace ownership receipt. Refusing a copied or stale URL; re-run provision.')
  }
}

module.exports = { parseState, ownershipFilePath, readOwnership, databaseTarget, assertDatabaseTarget }
