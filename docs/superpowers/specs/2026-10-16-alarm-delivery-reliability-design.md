# Remote Alarm — Alarm Delivery Reliability & Run-Anywhere Deployment

> **Date:** 2026-10-16
> **Status:** Draft design — builder check done (§12); owner questions resolved (§13); **ready for owner approval**, then plan
> **Note:** "public exposure" here means the *management* path (laptop/phone → backend). Alarm delivery to the phone is outbound (FCM) and needs no inbound exposure.
> **Scope:** Backend, mobile, clients, README, deployment. Touches the delivery path and the auth surface.
> **Guiding principle:** an alarm must not fail **silently**, and once armed it must ring **without any network**.
> **Related:** `docs/superpowers/specs/2026-09-23-missed-alarms-design.md` (the `missed` status and the reason set),
> `docs/PROJECT-STATE.md` (deploy and verification conventions).

---

## 1. Context & Intent

Alarms are delivered over FCM, which the phone turns into a locally armed alarm. A real outage already
happened: the FCM token died (`NotRegistered`), dispatch stopped, and nothing told the owner — an alarm
was missed (see the missed-alarms design §1).

Two things now need to hold, and they are separable:

1. **Delivery must be reliable, and any failure must be loud.** Today a total delivery outage is
   indistinguishable from success in the data (§2).
2. **The system must not depend on Tailscale, and must be runnable by anyone from one image.**
   The owner wants it to keep working if Tailscale is off or broken at a bad moment, and wants other
   people to use it without running a Tailscale network. "Run one image and it works" is the bar.
   A hosted, zero-setup service is **not** wanted (it is not simple, and the owner does not want to run a
   free service).

The owner's own framing of the risk is correct and is load-bearing: without Tailscale or some tunnel, a
self-hosted backend needs a **public endpoint** for the phone and the clients to reach it. This design
therefore makes the backend **addressable from anywhere over plain HTTPS** and treats the tunnel/network
as a deployment choice, not a code dependency.

---

## 2. What Exists Today (verified)

Measured by reading the tree, not assumed.

| Fact | Where |
|---|---|
| FCM data-only message, `android.priority: 'high'`, **no TTL, no collapse key, no retry, no backoff** | `backend/src/fcm.ts:117-142` |
| Dispatch is a single best-effort attempt per token; callers persist the outcome | `fcm.ts:126-142`, `server.ts:473,498,525,684,819` |
| A token is pruned on `registration-token-not-registered` **or `invalid-argument`** | `fcm.ts:134-140` |
| With **zero tokens registered**, dispatch returns `{ sent: 0, failed: 0 }` and does nothing | `fcm.ts:76-79` |
| Mock mode (Firebase uninitialised) returns `{ sent: deviceCount }` while sending nothing | `fcm.ts:109-112` |
| FCM is **not** on the ring path; the phone arms a native alarm via the `alarm` package | `alarm_service.dart:247-261`, `main.dart:881-895` |
| Remote `CANCEL`/`DISABLE`/`DISMISS` depend **entirely** on the FCM message arriving | `server.ts:497,524,774`, `alarm_service.dart:265-283` |
| The phone's backend URL is a stored setting (`getBaseUrl()`) — already swappable | `backend_client.dart:24-36` |
| The backend API has **no authentication of any kind** | `server.ts` (no `Authorization`/token check on `/api/*`) |
| The dashboard is served same-origin at `/` and calls `/api/*` with plain `fetch()` | `backend/public/index.html` |
| `/api/calendar.ics` is a subscribable feed; calendar clients cannot send headers | `server.ts`, `index.html:1304` |
| No `onTokenRefresh`; the token is fetched once at cold start | `main.dart:2156` |
| Reconcile runs on launch and resume, not on FCM receipt | `main.dart:267-270,324-331` |
| Manifest declares both `SCHEDULE_EXACT_ALARM` and `USE_EXACT_ALARM` | `mobile/android/app/src/main/AndroidManifest.xml` |

**The root cause is not the transport.** It is that a zero-token (or dead-token) state is a **silent
no-op**. No transport swap fixes a failure the system does not notice.

---

## 3. Goals / Non-Goals / Anti-Goals

### Goals
- An alarm that is already armed on the phone **rings with no network at all** (Tailscale, Wi-Fi, or
  cellular down).
- A total delivery outage is **detected and surfaced to the owner**, not silent.
- The backend is reachable over **plain HTTPS at any address**; Tailscale becomes optional.
- The whole system runs from **one Docker image**, documented, for anyone.
- Delivery losses degrade to **a delay, not a wrong schedule** (any later trigger converges state).

### Non-Goals
- A hosted, multi-tenant, zero-setup SaaS. Explicitly deferred (§6).
- iOS. The project is Android-only.
- Removing FCM. It is the battery-cheap, Doze-aware wake channel and is kept (§5.5).
- Persistent sockets / MQTT / foreground services. Rejected on the battery goal (§5.6).

### Anti-Goals (a failure even if it works)
- A "reliable" system that still goes quiet on the failure that started this.
- Requiring the user to run Tailscale, or to open a port with no authentication.
- Ring moments made to depend on a network round-trip.

---

## 4. Constraints

- **Battery.** No persistent connection. FCM's shared, Doze-aware channel is the wake path.
- **Local-first.** The ring is the OS's job (`AlarmManager`); the network only keeps the schedule fresh.
- **Honest audit.** `sent > 0` is not proof of delivery (missed-alarms §7). Copy must not overclaim.
- **Repo conventions.** Specs in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.
  `README.md` follows ASD-STE100. The dashboard has no test harness (a known gap).
- **Exact alarms.** Android 14+ denies `SCHEDULE_EXACT_ALARM` by default; `USE_EXACT_ALARM` is the
  install-granted permission for clock/alarm apps and is already declared.
- **A host is required.** This is self-hosted: someone must run the container on a machine that is on when
  alarms are set — practically an always-on box (NAS, Pi, spare PC, always-on desktop) or a VPS. The tier
  table (§5.7) chooses how that host is *reached*, not whether one exists. A user with no such machine and
  no willingness to rent one has no version of this today; the only path for them is the hosted SaaS (§6).
  The honest audience is stated in `README.md`: comfortable running a Docker container on a machine that
  stays on.

---

## 5. Design

Five changes. (A) and (D) make the ring and the failure visible; (B) makes the deployment portable;
(C) fixes the transport's hygiene; (E) hardens the public surface.

### 5.1 Local-first arming (the ring guarantee)

The phone must hold the *next* occurrence of every enabled alarm as a native alarm, independent of the
network. On launch, on boot, on timezone/clock change, and on resume, the phone re-arms enabled alarms
and prunes removed ones. This already exists in outline (`alarm_service.dart` reconcile, `main.dart:267`).

- **Verify** which AlarmManager primitive the `alarm` package uses. If it is not `setAlarmClock()`
  (the strongest wake, exempt from Doze throttling), raise it as a builder decision — a real alarm app
  should use `setAlarmClock`.
- Confirm `USE_EXACT_ALARM` (install-granted) is the operative permission so no runtime prompt blocks arming.
- **Consequence the design relies on:** once armed, an alarm rings even if Tailscale, FCM, and the
  backend are all down. The network's only job is to *change* the schedule.

### 5.2 Anywhere-addressable backend with a shared secret (Tailscale optional)

The backend gains **one** thing it lacks: authentication. `/api/*` requires a **bearer token**
(a shared secret, set by env, e.g. `API_TOKEN`). The phone, CLI, and Raycast all send it.

- The phone already resolves a configurable base URL (`getBaseUrl()`); add the token alongside it.
- No public endpoint may run without a token. This is a hard requirement, not a nicety.
- TLS is assumed to terminate in front of the container (reverse proxy / tunnel / platform TLS).
- **Effect:** Tailscale is now just one way to reach the URL. A VPS with a public IP, a Cloudflare
  Tunnel, or a homelab DNS record all work with the same image and no code change.

**Auth model for the tricky surfaces (settled in §12).** The dashboard is served same-origin and cannot
embed a secret in HTML, the ICS feed cannot send headers, and health is polled by infrastructure — so
the model is: token entered once in the dashboard UI (kept client-side), a query-string token for
`/api/calendar.ics`, and a small unauthenticated allowlist for `/api/health` and `/api/calendar/status`.

**Exposure model (settled in §13, detailed in §5.7).** The backend is reached at any HTTPS base URL.
Three postures: **private** (LAN/Tailscale — no token needed); **public via a tunnel** (recommended —
no inbound port, TLS + provider DDoS protection, a **strong bearer token** required); and **public via a
tunnel + an optional edge identity wall** (Cloudflare Access service token, two headers). **mTLS is not
used.** A token is required **only** when the bind is public; a private deploy need not set one
(this corrects the earlier "token on every deploy" call).

### 5.3 Pokes plus authoritative state

FCM messages carry the change (`id` + delta) **and remain directly applicable** in the background handler,
so a terminated app still arms without needing to fetch. The phone *additionally* **pulls**
`GET /api/alarms?view=all` and reconciles, which is what makes a dropped or stale poke harmless.

- Extend the existing reconcile (launch/resume) to also run **on FCM receipt** and on **network regained**.
- Add a lightweight **schedule version** (e.g. `updated_at` max, or a monotonic counter) so the phone can
  skip a no-op pull and so out-of-order pokes are harmless.
- **Effect:** a dropped poke costs a delay, never a wrong schedule. Any later trigger converges.

### 5.4 Delivery-health monitor (no silent failure)

The backend watches for the failure that started this and **screams**:

- Alert when **zero device tokens** are registered.
- Alert when the **most recent dispatch failed**.
- Alert when an alarm reaches `missed` (reuses the missed-alarms status; the dashboard already shows it).
- Alert when an enabled one-time alarm is **due soon and the phone has reported nothing for it** — a
  *due-aware* check, not a blind heartbeat, so quiet days with no alarms never false-positive.

The "ack" is the phone's **existing** state reports (`ringing`/`dismissed`/`snoozed`/`missed`); **no new
ack endpoint is built**.

**Alert delivery (owner's call, §13).** Always to the **dashboard** (always-on, no setup), plus a
**best-effort phone push** over FCM. Because the failure being monitored is often *"the phone is silent,"*
the phone cannot be the only channel — so an optional **webhook** (`ALERT_WEBHOOK_URL`), which does not
depend on the phone, covers the phone-unreachable case.

**The webhook is not one universal payload.** A plain "POST JSON to a URL" works directly for **Discord**
(`{"content": …}`) and **Slack** (`{"text": …}`); **Telegram** needs a bot token + `chat_id` (fixed API
URL); **Healthchecks.io** is a **heartbeat** (ping a URL on a schedule; alert when pings *stop*), not a
message. So the feature is a **generic webhook plus a small provider adapter** (message-shaped vs
heartbeat). The README recommends a **dead-man's switch** (Healthchecks) for backend liveness — the one
thing a push-from-the-backend can never report about itself. The webhook URL is treated as a secret and
rate-limited (an attacker who could set it would turn the backend into a spam relay). **The point is that
a quiet system is provably quiet, not assumed healthy.**

### 5.5 FCM hygiene (fix the transport's leaky edges)

- **`onTokenRefresh`**: subscribe and re-register the token; also re-register on resume. This closes the
  cold-start-only hole that caused the original outage.
- **TTL is freshness, not safety.** Set a moderate `ttl` and a `collapse_key` so a superseded schedule is
  replaced and a stale one cannot land long after its time. Safety comes from local-first arming and the
  reconcile, **not** from a short TTL (a short TTL with no background pull would *cause* missed alarms).
- **Retry/backoff** on transient send errors (a few attempts), distinct from permanent errors.
- **Prune only on `registration-token-not-registered`** — remove `invalid-argument` from the prune set so
  a healthy token is not deleted on a payload error.
- **Payload guard**: validate `label`/`description` length before send; fail loudly, not at FCM's 4 KB wall.
- **Never treat `sent > 0` as delivery** in any user-facing or audit string (already documented; keep it).

### 5.6 Rejected: sockets, MQTT, ntfy, foreground services

A persistent connection (WebSocket/MQTT) or a self-hosted `ntfy`/UnifiedPush distributor over a
foreground service would remove the Play-Services and token dependencies, but costs a permanent
notification, a battery-optimisation exemption, and real, device-dependent battery drain. The owner's
explicit constraint is battery. FCM stays the wake channel. Recorded here as a considered rejection.

### 5.7 Deployment: one image, any endpoint

One Docker image runs the backend (API + dashboard + store + FCM + calendar). It already exists
(`docker-compose.yml`); this design adds the auth env and docs. The backend only needs a **reachable
HTTPS base URL**; how it is reached is a deployment choice. **The code is identical in every tier** — the
tunnel is documentation, not architecture.

**There is no zero-setup path to reachability.** Being reachable from anywhere always costs one of: a VPN
on the client, a tunnel + (often) an account, or a public IP / VPS. The design lets the operator pick the
cost. **Cloudflare is not required.**

Tiers, cheapest first:

| Tier | Client VPN? | New account / domain? | Works away? |
|---|---|---|---|
| **LAN only** | — | no | no |
| **Tailscale** (today) | yes, on clients | no | yes, with the VPN on |
| **Tailscale Funnel + bearer token** | no | **no** (uses existing Tailscale) | yes — labelled beta |
| **Cloudflare Tunnel + bearer token** | no | **yes** (account + domain) | yes — most robust |
| **Direct public IP / own reverse tunnel** | no | **yes** (VPS + domain) | yes — most control, most work |

- **Tailscale Funnel** exposes `https://<node>.<tailnet>.ts.net` as **plain public HTTPS** — the client
  needs no VPN. One command, no domain, no new account. Trade-off: beta, no uptime SLA, undisclosed
  bandwidth limits, and it depends on Tailscale's control plane.
- **Cloudflare Tunnel** (`cloudflared` dials **outbound** only) gives no inbound port, no public IP, TLS,
  DDoS/WAF, and origin hiding — the most robust tier, at the cost of an account and a domain. Cloudflare
  **Access** (two headers, no browser) is an optional extra wall on top.
- **Direct public IP / your own reverse tunnel** — the backend on a VPS with a public IP, or at home behind a
  **self-hosted reverse tunnel** (`frp` / `rathole` / `Pangolin`) to a VPS. No third party, but *you* run the
  VPS, the TLS (Caddy needs a **domain**), and all the hardening; a home port-forward additionally exposes
  your home IP and is blocked by CGNAT on many ISPs. Most control, most work.
- **Raw public port** — **not supported.** Exposing the container directly means no CDN protection and a
  directly targetable origin.

**Hardening (proportional).** TLS (from the tunnel), a strong rotatable token, app-level rate limiting,
strict input validation, no verbose errors, auth-failure logging. **Skip** fail2ban (the origin only sees
CDN IPs) and IP allowlisting (mobile IPs rotate). **Threat model:** the blast radius is "someone messes
with your alarms"; the one genuinely bad state is running publicly **without** a token, and the subtle
risk is abuse of the **outbound webhook** — so its URL is a secret and it is rate-limited.

`README.md` documents the token, the base-URL setting, the tiers, and a suggested path per situation
(already use Tailscale → Funnel; want robustness → Cloudflare) (ASD-STE100).

---

## 6. Deferred: hosted, zero-setup service

A version where the user runs nothing — the owner (or someone) hosts a multi-tenant API with accounts,
auth, a shared published app, privacy handling, ops, and ongoing cost. **Not in scope.** This design is
shaped so it can grow from here: the phone already talks to a configurable HTTPS endpoint with a token,
so a hosted endpoint is a swap of *where* the URL points, not a rewrite.

---

## 7. Repo Integration

| File | Change |
|---|---|
| `backend/src/server.ts` | Bearer-token middleware + allowlist; alert checks in the sweep; schedule version in alarm reads |
| `backend/src/fcm.ts` | `ttl`, `collapse_key`, retry/backoff, prune only on not-registered, payload guard |
| `backend/src/db.ts` | Store `updated_at`/version for the schedule; no status-model change |
| `backend/src/alerts.ts` (new) | Zero-token / failed-dispatch / missed / due-without-report detection and delivery |
| `backend/public/index.html` | One-time token entry, stored client-side; send `Authorization` on fetch |
| `mobile/lib/main.dart` | `onTokenRefresh`; pull-on-FCM-receipt; send the API token; re-arm on boot/tz |
| `mobile/lib/services/backend_client.dart` | Attach the bearer token to every request |
| `mobile/lib/services/alarm_service.dart` | Confirm/prefer `setAlarmClock`; re-arm path |
| `clients/core/src/*`, `clients/cli/src/config.ts`, `clients/raycast` | Send the bearer token (precedence in §12) |
| `README.md` | Token, base URL, the three deployment paths, the run-anywhere image (ASD-STE100) |
| `docker-compose.yml` | `API_TOKEN`, `ALERT_WEBHOOK_URL` env; optional `cloudflared` service |

---

## 8. Risks

- **Local-first assumption.** If the `alarm` package does not use `setAlarmClock`, the "rings with no
  network" guarantee is weaker than stated. Mitigation: verify first (§5.1), fix if needed.
- **Auth rollout.** Adding a token breaks any client that does not send it; the phone, CLI, and Raycast
  must ship together. Mitigation: auth is off only when `ALLOW_UNAUTHENTICATED=true` is set explicitly
  (with a startup warning); otherwise a missing `API_TOKEN` is a hard refusal to serve `/api/*`.
- **Alert fatigue / dead channel.** A webhook the owner does not watch is a silent failure in disguise.
  Mitigation: the dashboard banner is always-on and needs no setup; the due-aware trigger avoids
  false positives on quiet days.
- **Public exposure.** A misconfigured deploy without a token would expose alarm control. Mitigation:
  the explicit opt-out in §5.2/§12, and TLS termination required in front.
- **Exact-alarm permission drift.** OEMs restrict exact alarms; the boot/tz re-arm must be resilient.

---

## 9. Verification

- **Unit:** auth accepts a valid token and rejects a missing/wrong one; the allowlist paths stay open;
  prune no longer fires on `invalid-argument`; TTL/collapse set; zero-token, failed-dispatch, and
  due-without-report each produce an alert.
- **Mobile:** `onTokenRefresh` re-registers; FCM receipt triggers a pull; token attached to requests.
- **Live (manual, device):** with Wi-Fi and Tailscale **off**, an already-armed one-time alarm still
  rings; a new alarm set from the CLI over a public endpoint arrives and arms; killing the only token makes
  the dashboard/alert fire; re-enabling the phone converges state; the dashboard token entry works once.
- **Deploy:** `docker run` with `API_TOKEN` alone serves the API; a request without the token is rejected;
  an ICS subscription with the query token works; container healthcheck on `/api/health` succeeds.

---

## 10. Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Transport | Keep FCM; fix its hygiene | Battery-cheap, Doze-aware; owner's battery constraint rules out sockets |
| Ring guarantee | Local-first `AlarmManager` | The only network-independent ring; makes Tailscale outages a non-event |
| Pokes vs truth | FCM carries the change **and** the phone pulls authoritative state | A dropped poke becomes a delay, not a wrong schedule |
| Tailscale | Optional, not required | Reachability over plain HTTPS; tunnel is a deployment choice |
| Public endpoint | Required for true no-tunnel use | Owner's own reasoning: without it, a tunnel is the exposure |
| Auth | Bearer token; off only via explicit `ALLOW_UNAUTHENTICATED` | Safe public deploy without silently breaking the local one |
| Hosted SaaS | Deferred, seam designed | Not simple; owner does not want to run a free service |
| Alerting | Dashboard banner (+ optional webhook) | Always-on, zero-setup; webhook is a bonus, not the only signal |
| TTL | Moderate + `collapse_key`; freshness, not safety | A short TTL without a background pull would cause missed alarms |

---

## 11. Open Items for the Builder

Resolved or deferred during the reliability-core implementation (2026-10-17):

1. **AlarmManager primitive — resolved, no code.** The `alarm` package (5.13.1) uses
   `AlarmManager.setExactAndAllowWhileIdle`, **not** `setAlarmClock`, and it ships a
   native `BootReceiver`. The ring is therefore already local-first and reboot-safe,
   so **§5.1 needs no code**. `setExactAndAllowWhileIdle` is Doze-aware and is the
   right call here; a future switch to `setAlarmClock` is an optional stronger wake,
   not a requirement.
2. **Exact-alarm permission — needs on-device confirmation.** The manifest declares
   both `USE_EXACT_ALARM` (install-granted) and `SCHEDULE_EXACT_ALARM`. Confirm on the
   target devices that arming never blocks on a runtime prompt. No code change is
   indicated.
3. **Schedule version — deferred (YAGNI).** The phone now pulls authoritative state on
   every FCM receipt (in the foreground) plus on launch/resume, so state converges
   without a version guard. Add a version only if a no-op pull proves costly or
   out-of-order pokes are observed in practice.

---

## 12. Resolutions from the Builder Check

Answers to the reviewer's questions, marked as calls the builder made.

| # | Question | Resolution | Pile |
|---|---|---|---|
| 1 | How does the dashboard authenticate? | The dashboard keeps the token **client-side**: entered once in the UI, stored in `localStorage`, sent as `Authorization: Bearer`. Served HTML contains **no** secret. `GET /` stays public (it is just the shell). | My call |
| 2 | Is `/api/calendar.ics` exempt? | No — it accepts the token as a **query parameter** (`?token=…`), because calendar clients cannot send headers. Documented as the one place a token appears in a URL. | My call |
| 3 | Which endpoints are exempt from auth? | A small **allowlist**: `GET /api/health` and `GET /api/calendar/status`. They expose no alarm data and are used by container healthchecks and the phone's reachability probe. | My call |
| 4 | What resets the stale-dispatch timer; is there an ack? | **No new ack endpoint.** The ack is the phone's existing state reports. The monitor is **due-aware** (an alarm is due soon and nothing was reported), not a 24h heartbeat — so quiet days never alert. | My call |
| 5 | Does the pull have to work in the background isolate? | **No.** Payloads stay **directly applicable** in the background handler, so a terminated app arms without any fetch. The pull is an *additional* foreground convergence step. A background pull can be added later if wanted. | My call |
| 6 | What if a poke expires while the app is closed? | TTL is **not** the safety net. Correctness comes from local-first arming + reconcile on launch/resume/boot. TTL is moderate, paired with `collapse_key`. | My call |
| 7 | What does "refuse to start when public" mean for the Tailscale deploy? | "Public" = a non-loopback bind. Auth is required unless `ALLOW_UNAUTHENTICATED=true` is set explicitly (startup warning). **Resolved (§13): the owner sets a token on every deploy, so there is no special case; the opt-out exists but stays unused.** | Resolved |
| 8 | How are tokens configured for CLI and Raycast? | Mirror the existing URL precedence. CLI: `--token` / `REMOTEALARM_TOKEN` / config file. Raycast: a new `backendToken` preference (Raycast cannot read shell env reliably). README documents both. | My call |
| 9 | Bearer token, identity wall, or mTLS for public exposure? | **Bearer token** (app-enforced) is the default; **Cloudflare Access** service token is an *optional* edge layer; **mTLS is not used** (major per-platform work, single user). Reached via a **tunnel**, so the origin is never directly exposed. | My call (§5.2, §5.7) |
| 10 | Is a "generic webhook" actually generic? | No — Discord/Slack take a message JSON, Telegram needs token + `chat_id`, Healthchecks is a heartbeat. Ship a **generic webhook + small provider adapter**; recommend a **dead-man's switch** separately. | My call (§5.4) |

---

## 13. Owner Answers (resolved)

1. **Alert delivery.** Dashboard always; best-effort phone push over FCM; an optional **webhook** (with a
   small provider adapter) for the phone-unreachable case; a **dead-man's switch** (Healthchecks)
   recommended for backend liveness. See §5.4.
   *Correction: the owner is right that a webhook is how third parties self-integrate — we ship the URL,
   they choose Discord/Slack/Telegram/etc. It is not literally one universal payload shape (§5.4).*
2. **Is the token always needed?** No. The token is required **only when the backend is publicly exposed**.
   A private LAN/Tailscale deploy needs none. *Correction to the earlier call: not "token on every deploy".*
3. **Exposure direction — doing both.** Build the **reliability core** *and* the **public-capable** path.
   The public path is **tiered** so the operator picks the cost (§5.7): **Tailscale Funnel** (no new
   account or domain) or **Cloudflare Tunnel** (more robust, needs a domain). **Cloudflare is not
   required.** Forcing scenario: setting an alarm from a laptop at work / abroad with the VPN off, where
   the *laptop → backend* hop would otherwise fail and the alarm would never be created. Delivery to the
   phone (FCM) needs none of this.
