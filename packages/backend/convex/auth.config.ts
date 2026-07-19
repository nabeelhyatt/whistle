// Auth0 JWT validation config for Convex.
//
// A real Auth0 tenant (dev-jrm7z08z1lx4u3pg.us.auth0.com) is wired up and
// live in production as of the canonical-accounts investigation
// (2026-07-18 plan): `AUTH0_DOMAIN`/`AUTH0_AUDIENCE` are set for real on the
// deployment (confirmed via the plan's tenant checklist step 1, Convex
// dashboard → Settings → Environment Variables), and real Auth0 users
// authenticate against it. This file still reads both from environment
// variables rather than hardcoding them, so rotating the tenant or
// promoting to a different deployment stays a config change (`npx convex
// env set AUTH0_DOMAIN ...`), not a code change.
//
// Convex statically validates auth.config.ts at deploy time: any
// `process.env.X` referenced here must resolve to a set value on the target
// deployment, or `convex dev`/`convex deploy` refuses to push (it cannot
// tell a deliberate "unconfigured" branch from a typo). The `providers`
// array below still falls back to `[]` when either var is unset (e.g. a
// fresh local `convex dev` deployment that hasn't had env vars pushed to
// it yet) — automated tests and the one-shot smoke run don't depend on
// this at all, since they exercise `MockAuthProvider` instead of a real
// JWT.
const domain = process.env.AUTH0_DOMAIN;
const audience = process.env.AUTH0_AUDIENCE;

const providers =
  domain && audience
    ? [
        {
          domain,
          applicationID: audience,
        },
      ]
    : [];

export default {
  providers,
};
