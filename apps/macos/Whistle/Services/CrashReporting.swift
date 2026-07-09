// CrashReporting.swift
// Env-gated crash-reporting seam (U11, TECH-SPEC §10: "Sentry initializes
// as a clean no-op when SENTRY_DSN is absent or empty").
//
// The Sentry SDK itself is intentionally NOT integrated in the one-shot
// build — no DSN exists (TECH-SPEC §2a), so shipping the SDK would add a
// dependency that can never activate. This seam keeps the contract in
// place: `CrashReporting.configure()` is called once at launch, reads the
// DSN from Info.plist (`SENTRY_DSN`, injected at build time via
// xcconfig/environment; expands to the empty string until provisioned),
// and no-ops with a logged reason when it's absent or empty.
//
// To ship real crash reporting later (see SECRETS.md):
//   1. Provision SENTRY_DSN (xcconfig value or CI build setting).
//   2. Add the sentry-cocoa SPM package to project.yml (pinned exact).
//   3. Replace the body of `start(dsn:)` below with `SentrySDK.start`.
// Nothing else in the app needs to change — this file is the only seam.

import Foundation

enum CrashReporting {
    /// Call once at launch. Safe to call with no DSN provisioned — that is
    /// the normal state for local/dev builds and the one-shot build.
    static func configure(bundle: Bundle = .main) {
        let dsn = (bundle.object(forInfoDictionaryKey: "SENTRY_DSN") as? String) ?? ""
        // An unexpanded `$(...)` placeholder means the build setting was
        // never defined — treat it the same as absent.
        guard !dsn.isEmpty, !dsn.hasPrefix("$(") else {
            NSLog("Whistle: crash reporting disabled — SENTRY_DSN not configured (expected until provisioned; see SECRETS.md)")
            return
        }
        start(dsn: dsn)
    }

    private static func start(dsn: String) {
        // Sentry SDK not yet integrated (see header). When a DSN is
        // provisioned, wire sentry-cocoa here; until then, log loudly so a
        // provisioned-but-unwired build is visible in the console rather
        // than silently dropping crashes.
        NSLog("Whistle: SENTRY_DSN is configured but the Sentry SDK is not yet integrated — see CrashReporting.swift / SECRETS.md")
    }
}
