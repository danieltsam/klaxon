# Google Calendar re-auth visibility — report

Goal: a rejected/expired Google credential must be loud, not silent.

Branch: `master` (feature branch already merged).

## What changed

1. **`backend/src/gcal.ts`**
   - `GcalStatus` extended additively with `last_error_kind: GcalErrorKind | null`
     and `needs_reauth: boolean` (no existing field removed or renamed).
   - New private field `lastErrorKind: GcalErrorKind | null`.
   - `recordError()` now stores `classifyGcalError(err)`; `recordSuccess()`
     resets it to `null` alongside the other error state.
   - New public `noteError(err: unknown): void` — records via `recordError`
     without throwing, for callers that swallow errors (reconciler).
   - `status()` returns `last_error_kind` and `needs_reauth` (`true` iff the
     last error kind is `'auth'`).
   - No `googleapis` import in this file.

2. **`backend/src/gcal-reconcile.ts`**
   - The `mirror.listEventIds()` catch block now calls `mirror.noteError(err)`
     before returning, with a comment explaining that swallowing the error
     would leave `status()` looking healthy and hide a dead credential during
     periodic reconciliation.

3. **`backend/src/server.ts`**
   - `mirrorSafely`'s catch now branches on `classifyGcalError(err)`. Auth
     failures log an unmistakable, actionable message naming the remedy; all
     other failures keep the existing generic log. Imported
     `classifyGcalError` from `./gcal.js`.
   - Pushes still never throw into request handlers.

## Tests added

- `backend/test/gcal.test.ts`
  - auth failure (`GcalApiError('invalid_grant', 401)`) →
    `needs_reauth === true`, `last_error_kind === 'auth'`.
  - non-auth failure (500) → `needs_reauth === false`, kind `'transient'`.
  - `needs_reauth` is `false` before any failure; `noteError` sets it; a later
    successful sync (`recordSuccess`) resets both to `false`/`null`.
- `backend/test/gcal-reconcile.test.ts`
  - a `listEventIds` auth failure now yields `status().needs_reauth === true`
    with `last_error_kind === 'auth'`, and still returns `failed: 1`.

## Verification

`cd backend && npx tsc --noEmit` → clean (no output).

`cd backend && npm test` → `tests 103 / pass 103 / fail 0` (99 previously
passing + 4 new). Key excerpt:

```
▶ reconcile
  ✔ surfaces an auth failure while listing as needs_reauth (6.269166ms)
▶ GcalMirror
  ✔ flags needs_reauth when the failure is an auth failure (2.160875ms)
  ✔ does not flag needs_reauth for a non-auth failure (1.687792ms)
  ✔ clears needs_reauth after a later successful sync (1.053875ms)
ℹ tests 103
ℹ suites 27
ℹ pass 103
ℹ fail 0
```

Focused flip demonstration (inline `tsx`, temp file removed after run):

```
before failure: needs_reauth = false | kind = null
after 401    : needs_reauth = true | kind = auth
after success: needs_reauth = false | kind = null
```

## Notes

- No dependencies added; `backend/src/gcal.ts` remains free of `googleapis`.
- `POST /api/alarms` still returns 201 with an unchanged `fcm_dispatch` when
  Google is unreachable (isolation and degraded suites still pass).
- `mobile/` and `backend/public/index.html` untouched.
