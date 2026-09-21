# Remote Alarm — Google Calendar Mirror Design

> **Date:** 2026-09-21
> **Status:** Approved design — pending written-spec review, then implementation plan
> **Scope:** Backend-only change. Adds a one-way mirror from Remote Alarm to a dedicated
> Google Calendar.
> **Roadmap reference:** `docs/ROADMAP.md` §2.1 (calendar integration) — the *export* half.
> **Companion spec:** `docs/superpowers/specs/2026-09-21-clients-cli-raycast-design.md`

---

## 1. Context & Intent

Alarms currently live only in Remote Alarm: the Android app, the web dashboard, and (since the
clients work) the `alarm` CLI and Raycast extension. None of them show the *shape of the week* —
you cannot see that a "weekdays 7am Standup" alarm exists while you are planning your calendar.

**Intended outcome.** Alarms created in Remote Alarm appear in Google Calendar, so they can be
seen alongside real commitments.

**Success criterion.** Create an alarm via Raycast or `alarm 25m "Oven"`, and within seconds it
appears in a dedicated *Remote Alarms* calendar in Google, correctly positioned in local time,
without duplicating the phone's notification behaviour.

### 1.1 Why an API push rather than an ICS subscription

This was settled by research before design, and the reasoning is recorded so it is not revisited:

| Option | Verdict |
|---|---|
| **Public ICS feed + Tailscale Funnel** | ❌ Google refreshes subscribed feeds only every **~12–24h (undocumented, no SLA, no manual refresh)** — an alarm set for 25 minutes from now would never appear in time. Funnel is also **beta and unauthenticated by default**, and the free tier is `ts.net`-only on ports 443/8443/10000. |
| **API push (adopted)** | ✅ Outbound-only, so **no public endpoint at all**; near-real-time; native recurrence support. |
| **CalDAV** | ❌ Google Calendar does not support CalDAV. Also wrong for one-way data: it invites clients to write back. |
| **ICS + Apple Calendar over `tailscale serve`** | ✅ Technically clean (client-side fetch, no exposure) but rejected — the user uses **Google Calendar**. Recorded as a viable fallback if that changes. |

---

## 2. Scope

### In scope
- One-way mirror: Remote Alarm → a dedicated **"Remote Alarms"** secondary Google calendar.
- All active alarms.
- Event-driven push on every alarm mutation, plus periodic reconciliation.
- A one-off interactive auth helper.
- A status endpoint so silent failures become visible.

### Explicitly out of scope
- **Ingest** (calendar events → alarms). The user's existing calendar reminders already work
  well, so this was judged low value. It is a *separate* design if ever wanted.
- **Two-way sync.** Google-side edits are overwritten. See §9.3.
- **Any change to the existing `GET /api/calendar.ics` feed.** It stays as-is for Apple/other
  clients; only the README's stale `/ical/feed` reference is corrected.
- CalDAV. Writing into the user's **primary** calendar. Any client-side change.

---

## 3. Verified Constraints

Each was verified against primary documentation or the repository, not assumed.

### 3.1 OAuth scope — the decisive finding

**`https://www.googleapis.com/auth/calendar.app.created`** is current and documented as:
*"Make secondary Google Calendars, and see, create, change, and delete events on them."*

| Scope | Create secondary cal. | Manage its events | See other calendars | Fit |
|---|---|---|---|---|
| **`calendar.app.created`** | ✅ | ✅ | **No** | ✅ **true minimum** |
| `calendar.events` | ❌ | ✅ | **Yes** (all) | over-broad |
| `calendar.events.owned` | ❌ | ✅ | **Yes** (all owned) | over-broad |
| `calendar` | ✅ | ✅ | **Yes** (all) + permanent delete | severe over-grant |

One scope is sufficient for every call this design makes (`calendars.insert`, `events.insert`,
`events.update`, `events.delete`, `events.list`). The app can never read a calendar it did not
create.

*Unverified caveat:* Google does not publish a per-scope sensitivity table. The strongest
available evidence (a 2026 developer-forum report) is that `calendar.app.created` is classified
**non-sensitive**, meaning no "unverified app" warning. Confirm in the Cloud Console →
**Data Access** page when setting up. Either way, single-user use is unaffected.

### 3.2 Refresh-token lifetime

*"A Google Cloud Platform project with an OAuth consent screen configured for an external user
type and a publishing status of 'Testing' is issued a refresh token expiring in 7 days, unless
the only OAuth scopes requested are a subset of name, email address, and user profile."*

Any Calendar scope triggers this. **Therefore publishing status must be "In production".**
Verification is a *separate* axis and is **not required** below 100 users.

**The change is not retroactive** — tokens minted while in Testing keep their 7-day clock. After
switching, re-consent once.

### 3.3 Event IDs can be client-supplied — no migration needed

`events.insert` accepts a client `id`: base32hex (`[0-9a-v]`), 5–1024 chars, unique per calendar.
A hyphen-stripped UUID is 32 chars of `[0-9a-f]`, a strict subset of the allowed alphabet.

```
eventId = alarmUuid.toLowerCase().replace(/-/g, "")   // 32 chars, valid, deterministic
```

Consequences:
- **No `google_event_id` column and no migration.** The mapping is computed.
- Collisions are documented as *not guaranteed to be caught at creation time*. Since this is a
  single-writer mirror, on `409 duplicate` we fall back to `update` (§9.2), making the write an
  idempotent upsert.

### 3.4 Recurring events and timezone — grounded in verified client behaviour

For recurring events `start.timeZone` is **required** and *"specifies the time zone in which the
recurrence is expanded."* This determines DST behaviour.

**Verified in this repo:** the Android client does **not** hold a fixed UTC instant per
recurrence. `mobile/lib/services/alarm_service.dart:79` converts the stored UTC to local
(`.toLocal()`), `:86-94` keeps only hours/minutes, and `getNextOccurrence` (`:415`) rebuilds
candidates from *local* `year/month/day` + local `hour`/`minute`, matching on local `weekday`.
**The phone schedules at a fixed local wall-clock time.**

**Therefore `timeZone` is set to the configured IANA zone**, so the calendar agrees with the
phone — including across a DST transition.

> This verifies and **corrects** an earlier claim in the companion spec, which had asserted
> recurring alarms drift by an hour across DST. They do not. The companion spec is corrected.

### 3.5 Reminders must be suppressed

Mirrored events are *representations* of alarms that already ring at hardware level on the phone.
Without `reminders: { useDefault: false }`, Google would additionally notify, duplicating every
alarm. `useDefault: false` with no `overrides` = no reminders.

### 3.6 Other API facts that shape the implementation

- **`events.update` is a full replace (PUT)** — *"does not support patch semantics and always
  updates the entire event resource."* We therefore always send the complete constructed body;
  we never PUT a partial object. (`events.patch` costs 3 quota units vs `update`'s 1, and brings
  no benefit when we own every field.)
- **`end` is exclusive and must be after `start`.**
- **`sendUpdates: "none"`** prevents invitation emails.
- **`recurrence` must not contain `DTSTART`** — it is inferred from `start`. `FREQ` is mandatory.
- **Quota is a non-issue:** 10,000 req/min/project, 600 req/min/user, 1,000,000/day. Event-driven
  push plus a 15-minute reconcile is a rounding error.
- **Refresh-token invalidators:** user revocation; **6 months of inactivity**; password change
  (Gmail scopes only — not applicable here); **100 live refresh tokens per account per client**
  (oldest silently dropped); admin policy.
- **DPoP must be skipped.** Newer Google native-app guidance encourages DPoP, which binds the
  refresh token to a private device key. Authorising on the Mac and running the daemon on the
  homelab **requires not using DPoP**, or the key must be copied.
- **`calendars.insert` is user-owned.** Google explicitly warns not to use a service account, as
  the service account would become the data owner and ownership cannot be transferred. User OAuth
  is mandatory.

---

## 4. Architecture

```
alarm mutation (create / patch / delete / state)
        │
        ▼
  server.ts  ──►  gcal.ts  ──►  Google Calendar API
                    │              (outbound HTTPS only)
                    │
                    └── never throws; returns a result object

  gcal-reconcile.ts  ── periodic (startup + every 15 min) full-list repair
```

New files:

```
backend/src/gcal.ts             # client: auth, ensureCalendar, upsert, remove, list
backend/src/gcal-events.ts      # pure: alarm → Google event payload (no I/O — unit-testable)
backend/src/gcal-reconcile.ts   # compare active alarms against the calendar; repair
backend/scripts/gcal-auth.ts    # one-off interactive loopback + PKCE helper
backend/test/gcal.test.ts       # unit tests with a stubbed HTTP layer
backend/test/gcal-events.test.ts
```

`gcal-events.ts` is deliberately separated and pure: the payload mapping is the part most likely
to break, and it should be testable without a network or a token.

---

## 5. Auth & Credential Handling

### 5.1 Flow

Desktop OAuth client + **loopback redirect on `127.0.0.1` + PKCE** — the documented recommended
mechanism for desktop apps. OOB and custom URI schemes are **no longer supported** by Google, so
neither is an option.

Authorise **once on the Mac**; the refresh token is then usable headlessly from the homelab.
Nothing in Google's documentation binds a refresh token to an IP or a machine.

### 5.2 Storage — following existing repo convention

`fcm.ts` already establishes the pattern: a path supplied by environment variable, defaulting to
a gitignored file. Reuse it rather than inventing a mechanism.

| Value | Location |
|---|---|
| `client_id`, `client_secret` | `backend/.env` (gitignored) |
| refresh token | JSON file at `GOOGLE_OAUTH_TOKEN_PATH` (default `./google-oauth-token.json`) |
| `calendarId` | `settings` table, key `gcal_calendar_id` |

`backend/.gitignore` additions: `backend/google-oauth-token.json`.
`backend/.env.example` gains the new keys with placeholder values.

The token file gets `0600` permissions on write.

**A small repo addition is required.** `SettingsRepo` (`backend/src/db.ts:229-277`) only reads
and writes the four known `AppSettings` keys, so it currently **cannot** store an arbitrary key.
A generic raw accessor (`SettingsRepo.getRaw(key)` / `setRaw(key, value)`) is needed for
`gcal_calendar_id` and sync bookkeeping. The `settings` table already exists, so **no schema
migration is required** — but this is not a zero-code change, and the plan must include it.

### 5.3 Longevity

- **Monthly keep-alive refresh** to defeat the 6-month inactivity rule.
- On `invalid_grant`: **stop, log loudly, do not retry.** Auto-re-auth loops burn the
  100-token cap. Surface a re-auth instruction via `GET /api/calendar/status`.
- Re-consent after any change to publishing status.

---

## 6. The One-Off Auth Helper

`npm run gcal:auth` (→ `backend/scripts/gcal-auth.ts`).

1. Reads `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` from `backend/.env`.
2. Starts a loopback HTTP server on an ephemeral port.
3. Prints/opens the consent URL with `access_type=offline`, `prompt=consent`, PKCE challenge.
4. Catches the redirect, exchanges the code, writes the token file (`0600`).
5. Prints the next step: copy the token file to the homelab's data directory.

Run on the Mac, then copy. This is a deliberate one-time manual step, not automated.

---

## 7. Event Model

### 7.1 Payload

```jsonc
{
  "id": "550e8400e29b41d4a716446655440000",   // alarm UUID, hyphens stripped
  "summary": "Standup",                        // alarm label
  "description": "Managed by Remote Alarm\nAlarm ID: <uuid>\nTone: alarm · Ramp: 30s",
  "start": { "dateTime": "2026-09-22T07:00:00+10:00", "timeZone": "Australia/Brisbane" },
  "end":   { "dateTime": "2026-09-22T07:15:00+10:00", "timeZone": "Australia/Brisbane" },
  "recurrence": ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"],   // recurring alarms only
  "reminders": { "useDefault": false },
  "transparency": "transparent",
  "status": "confirmed"
}
```

Notes:
- **15-minute duration** — matching the existing ICS feed's convention (`server.ts:88`).
- **Both offset and `timeZone` are sent**, mirroring Google's own canonical recurring example,
  rather than depending on undocumented precedence when both are present.
- **`transparency: "transparent"`** — these are synthetic markers, so they must not make you
  appear busy to anyone scheduling against your calendar.
- **Never** include credentials, tokens, or FCM device data in `description`.
- Recurrence is only attached when the alarm has `repeat_days`; the timezone is resolved from
  config (§11).

### 7.2 Status → action mapping

| Alarm status | Calendar action | Rationale |
|---|---|---|
| `pending`, `ringing`, `snoozed` | **upsert** the event | currently scheduled |
| `canceled` | **delete** the event | explicitly cancelled; should not appear |
| `disabled` | **delete** the event | not going to ring |
| `dismissed` | **leave in place** | it happened; a past calendar entry is history, and deleting it would erase the record |

### 7.3 Timezone resolution — required explicitly, and precisely why

`GCAL_TIMEZONE` is the **phone/user's** IANA zone, and it is **required** whenever
`GCAL_ENABLED=true`.

**What it does NOT affect: the instant.** `target_time` is a UTC instant and is sent with an
explicit offset (§7.1), so an event always lands at the correct absolute moment regardless of
this setting. A wrong zone does **not** shift an event by hours — an earlier draft of this
section claimed it would ("ten hours wrong"), and that was incorrect. It is corrected here
rather than left as a plausible-sounding but false rationale.

**What it DOES affect: recurrence expansion.** For recurring events Google *requires*
`start.timeZone` and expands the RRULE **in that zone**. The phone schedules recurring alarms on
**local wall-clock** (§3.4). So this value must be the phone's zone or the two disagree:

| `timeZone` | Recurrence expands at | No-DST zone (Brisbane) | DST zone |
|---|---|---|---|
| the phone's zone | the local wall-clock time | matches phone | **matches phone** |
| `UTC` | a fixed UTC instant | matches phone | **drifts 1h from the phone** after a DST change |

**Why it must not be inferred from the server.** `docker-compose.yml` sets no `TZ`, so the
container resolves to **UTC**. Inferring would silently select the wrong expansion zone — a
latent bug that would only surface if this were ever run in a DST zone, which is exactly the
kind of fault that is expensive to find later.

**Failing loudly:** if `GCAL_ENABLED=true` and `GCAL_TIMEZONE` is unset or is not a valid IANA
zone, the subsystem **disables itself, logs an error**, and `GET /api/calendar/status` reports
`configured: false` with the reason. It never falls back to a guess.

---

## 8. The Dedicated Calendar

Created once via `calendars.insert` with `summary: "Remote Alarms"` and the configured timezone.
The returned `id` is persisted to the `settings` table as `gcal_calendar_id`.

**The ID must be persisted — not re-discovered.** Re-discovery would require `calendarList.list`,
which needs a broader scope and would defeat the §3.1 minimal-scope design.

There is no `appCreated` marker field on the resource; "app-created" scoping is enforced by the
OAuth grant, not by a resource property.

---

## 9. Synchronisation

### 9.1 Push on mutation

Hooked into the existing mutation paths in `server.ts`:
create (`POST /api/alarms`), patch (`PATCH /api/alarms/:id`), delete
(`DELETE /api/alarms/:id`), silence (`POST /api/alarms/:id/silence`), and state
(`POST /api/alarms/:id/state`).

Push is **awaited with a bounded timeout (3s), then swallowed.** A truly fire-and-forget call
makes failures invisible and tests non-deterministic, while an unbounded await would let a slow
Google response stall every alarm creation. On timeout the push is recorded as failed and
abandoned — the reconcile pass (§9.4) repairs it.

The mutation's **response shape and status code are unchanged**: `fcm_dispatch` is untouched and
**no `gcal` field is added to the response**. This deliberately avoids changing the API contract
and the clients' `AlarmMutationResult`. Visibility comes from `GET /api/calendar/status` (§10.1).

### 9.2 Idempotency

| Situation | Response | Action |
|---|---|---|
| `insert` on an ID that already exists | `409 duplicate` | fall back to `update` |
| `update` on an event the user deleted | `404 notFound` | fall back to `insert` |
| `403` / `429` rate limit | | exponential backoff |
| `400` | | **do not retry** — documented as permanent; log and move on |
| `invalid_grant` | | stop; flag for re-auth (§5.3) |

This makes the write a self-healing upsert and means a user deleting an event in Google is
repaired on the next alarm write or reconcile.

### 9.3 Drift policy

**Remote Alarm is the single source of truth.** Edits or deletions made in Google are
**overwritten** on the next alarm write or reconcile pass. This is deliberate and documented —
not silent. Two-way sync was explicitly rejected (§2).

### 9.4 Reconciliation

Startup plus every 15 minutes:
1. `events.list` the *Remote Alarms* calendar (a personal calendar is one cheap call).
2. Compute each active alarm's derived event ID; re-insert any missing.
3. Delete events whose ID matches no active alarm (orphans).

**Deliberately not using `syncToken`.** It would bring `410 GONE` full-resync handling and a set
of forbidden query parameters (`timeMin`, `updatedMin`, `q`, `orderBy`, …) for no benefit at this
size. Recorded as a future optimisation if the calendar ever grows enough to matter.

**Test isolation:** the scheduler runs via `setInterval` in `server.ts` **only when
`NODE_ENV !== 'test'`**, mirroring the existing `app.listen` guard (`server.ts:573`). Without
that guard the existing backend suite would spawn timers and attempt outbound HTTP calls.

---

## 10. Failure Isolation — the critical constraint

**Google must never be able to break alarm creation.**

`gcal.ts` mirrors `fcm.ts` exactly:
- Module-level `isConfigured` flag.
- Multi-path credential discovery (`env var → data/ → cwd → /app/`).
- Graceful **no-op with a warning** when unconfigured — never a throw.
- Returns a result object; the alarm path ignores it.

### 10.1 Making failure visible

Silent degradation is the risk of graceful no-op. A new endpoint:

```
GET /api/calendar/status
→ { configured: bool, ok: bool, calendar_id: string|null,
    last_sync_at: string|null, last_error: string|null,
    last_error_at: string|null }
```

No credentials or tokens are ever returned. This is what the `alarm` CLI / Raycast extension
could surface later; it is not wired into the clients by this design.

---

## 11. Configuration

`backend/.env` additions (and `.env.example`):

```
GOOGLE_OAUTH_CLIENT_ID=<desktop oauth client id>
GOOGLE_OAUTH_CLIENT_SECRET=<desktop oauth client secret>
GOOGLE_OAUTH_TOKEN_PATH=./google-oauth-token.json
GCAL_TIMEZONE=Australia/Brisbane   # REQUIRED when enabled — the PHONE's zone, not the server's (§7.3)
GCAL_ENABLED=true
```

`GCAL_ENABLED=false` (or absent credentials) makes the whole subsystem a no-op — the documented
path for anyone who does not want calendar sync.

### 11.1 Manual prerequisites (one-time, performed by the user)

1. Create a GCP project; enable the **Google Calendar API**.
2. Configure the OAuth consent screen: **External** user type; **publishing status = In
   production** (§3.2 — leaving it in Testing breaks the sync weekly). Verification is not
   required for personal use under 100 users.
3. Confirm the scope classification in **Data Access** (§3.1 caveat).
4. Create an OAuth client of type **Desktop app**; record the client ID and secret.
5. Run `npm run gcal:auth` on the Mac.
6. Copy the token file to the homelab data directory.

---

## 12. Repo Integration

| File | Change |
|---|---|
| root `.gitignore` | Ignore `backend/google-oauth-token.json` |
| `docker-compose.yml` | Optionally set `TZ` — **not** required (event times come from `GCAL_TIMEZONE`), but it improves container log timestamps |
| `backend/.env.example` | Document the new keys |
| `backend/package.json` | Add `gcal:auth` script; add `googleapis` dependency |
| `run_tests.sh` | No change — backend tests already run; new suites are picked up automatically |
| `README.md` | Fix the stale `GET /ical/feed` reference → `GET /api/calendar.ics`; document calendar sync |
| `docs/ROADMAP.md` §2.1 | Mark the export half implemented; ingest remains backlog |

**Dependency note:** this is the **first** non-trivial runtime dependency added to the backend
beyond Fastify/Firebase. Use the official `googleapis` package. It is server-side only and never
reaches the `clients/` tree, so the "zero-dependency core" constraint for Raycast is unaffected.

---

## 13. Verification

### 13.1 Unit tests (stubbed transport, no network, no token)

- `gcal-events.test.ts` — payload shape for one-time vs recurring; derived ID correctness
  (hyphen stripping, length, alphabet); `reminders.useDefault === false`; 15-minute end;
  `transparency`; recurrence omitted when no `repeat_days`; timezone from config; **no
  credentials present in any output field**.
- `gcal.test.ts` — status→action mapping for all six statuses; `409 → update`; `404 → insert`;
  `400` not retried; `403`/`429` backed off; unconfigured → no-op and **no throw**;
  `invalid_grant` → flagged.
- **The load-bearing test:** a `gcal` client that throws on every call must not prevent
  `POST /api/alarms` from returning `201`, and must not alter `fcm_dispatch`.

### 13.2 Integration — a real limitation, stated plainly

**Automated tests cannot call the real Google Calendar API.** They need live OAuth credentials
and would mutate a real calendar. The unit suite therefore uses a stubbed transport, and the
real-API path is verified **once, manually**, against a throwaway calendar.

The manual check is: create an alarm via the CLI → confirm the event appears in the correct
local time → patch it → confirm the event moves → cancel it → confirm the event disappears.
This is documented as a required manual step rather than implied to be covered by CI.

### 13.3 Regression safety

`./run_tests.sh` must stay green. Because `gcal` is disabled without credentials, the existing
backend suite runs unchanged with the subsystem inert — which is itself a test of §10.

---

## 14. Risks

### 14.1 Refresh token silently dies
The 7-day Testing-mode trap is the most likely failure. Mitigated by mandating "In production",
a monthly keep-alive, and `GET /api/calendar/status` making it visible. *Accepted residual:* a
revoked token still requires manual re-auth — auto-reauth would burn the 100-token cap.

### 14.2 Silent degradation hides breakage
Graceful no-op is correct for availability but dangerous for observability. Mitigated by
`GET /api/calendar/status` and loud logging on every failed push.

### 14.3 Broader dependency surface
`googleapis` is a large package and a new supply-chain surface in the backend. Mitigated by
server-only use, a single well-known vendor package, and the fact that its failure is isolated
by §10.

### 14.4 Google-side quota model change
New GCP projects (created on/after 2026-05-01) get the standardised quota model, with the daily
threshold planned to incur charges later in 2026. This workload is ~0.1% of a single day's
threshold, so it is a watch item rather than a real risk.

### 14.5 User edits in Google are overwritten
Deliberate (§9.3). Documented in `README.md` and surfaced in the spec, not silent.

---

## 15. Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Integration mechanism | Calendar API push | ICS subscription is 12–24h stale and needs public exposure (§1.1) |
| OAuth scope | `calendar.app.created` only | Manages only app-created calendars; cannot read the user's others |
| Calendar target | Dedicated "Remote Alarms" secondary | Togglable in the Google UI; never mixes with real events |
| Event identity | Derived from alarm UUID | Removes the need for a mapping column and a migration (§3.3) |
| Recurrence timezone | Configured IANA zone | Matches the phone's verified local wall-clock behaviour (§3.4) |
| Notifications | `reminders.useDefault = false` | Prevents duplicating the hardware alarm |
| `transparency` | `transparent` | Synthetic markers must not make the user appear busy |
| Reconcile strategy | Full list, not `syncToken` | Small personal calendar; avoids 410/filter complexity |
| Drift | Remote Alarm wins | Two-way sync rejected as scope creep with conflict risk |
| Second calendar vs primary | Secondary | Avoids cluttering real events |
| Sync status | New `GET /api/calendar/status` | Makes graceful degradation observable |

---

## 16. Open Items

None blocking. Deferred to their own cycle: calendar **ingest** (events → alarms), `syncToken`
optimisation, and surfacing `calendar/status` in the CLI and Raycast extension.
