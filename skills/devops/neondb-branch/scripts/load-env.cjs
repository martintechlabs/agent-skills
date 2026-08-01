// scripts/load-env.cjs
//
// Preloaded via NODE_OPTIONS='--require ./scripts/load-env.cjs' (see the dev/build/start scripts
// in your package.json) so the dev server picks up DATABASE_URL from .env.neondb — the
// per-workspace Neon branch file scripts/neondb-branch.ts writes.
//
// SAFETY: this silently falls back to whatever the dev server's own .env loading provides when
// .env.neondb doesn't exist. That's only safe because `sync`'s hard gates run BEFORE this in the
// same `&&` chain (see the "dev" script) — never remove one without the other, or an unprovisioned
// workspace boots straight against the ambient/shared DATABASE_URL with no warning.
try {
  process.loadEnvFile('.env.neondb')
} catch (error) {
  if (error.code !== 'ENOENT') throw error
}
