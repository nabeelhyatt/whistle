// Auth0 JWT validation config for Convex.
//
// Mock-first (TECH-SPEC §2a/§9): no real Auth0 tenant exists yet for this
// one-shot build. The macOS app and all automated tests exercise the
// `MockAuthProvider` seam instead of a live Auth0 login. This file wires the
// *real* provider config from environment variables so that plugging in a
// real tenant later is a config change (`npx convex env set AUTH0_DOMAIN
// ...`), not a code change.
//
// Convex statically validates auth.config.ts at deploy time: any
// `process.env.X` referenced here must resolve to a set value on the target
// deployment, or `convex dev`/`convex deploy` refuses to push (it cannot
// tell a deliberate "unconfigured" branch from a typo). Since no real tenant
// exists for this deployment (grandiose-alpaca-243), non-secret placeholder
// values are set instead of leaving these unset:
//   AUTH0_DOMAIN   = "placeholder.us.auth0.com"
//   AUTH0_AUDIENCE = "https://whistle.app/api"
// These placeholders don't correspond to a real Auth0 tenant, so no real
// JWT will ever validate against them — functionally equivalent to "no auth
// provider configured" for anyone but a real Auth0 login attempt. Every
// automated test and the one-shot smoke run go through `MockAuthProvider`
// instead of a JWT, so this doesn't block anything. Replace both values via
// `npx convex env set` (dashboard: Settings → Environment Variables) once a
// real Auth0 tenant is provisioned — no code change needed here.
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
