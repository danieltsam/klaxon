# Klaxon — Backend URL

Klaxon talks to your self-hosted alarm backend. This preference is that backend's address.

## Common values

- **Local backend:** `http://localhost:3000`
- **Docker backend:** `http://localhost:8001`
- **Tailnet:** `http://klaxon.tailnet:3000` (use your machine's actual name)

## Where to find it

The backend runs wherever you started it: your laptop, a homelab server, or a Docker host. The extension talks to it directly over HTTP. There is no separate sign-in step, and the API has no authentication, so keep it on a private network rather than the open internet.

If the extension says it cannot reach the backend, check that the machine running Raycast can reach that URL and that the container is up.

## Alarm actions

Select an alarm in **List Alarms** and open the action panel (⌘K) to edit, enable, disable, silence or cancel it.

A recurring alarm also offers `Skip Next Occurrence`: it skips exactly the next ring and the alarm resumes at the occurrence after that. While the skip is pending the same alarm offers `Undo Skip`, until the skipped time passes. One-time alarms do not offer either action.
