# Remote Alarm — Backend URL

The extension needs the URL of your Remote Alarm backend.

## Common values

- **Local backend:** `http://localhost:3000`
- **Docker backend:** `http://localhost:8001`
- **Tailscale homelab:** `http://remotealarm.tailnet:3000` (replace with your actual machine name)

## Where to find it

The backend runs wherever you started it: your laptop, a homelab server, or a Docker host. The extension talks to it directly over HTTP — there is no separate authentication step. Make sure the machine running Raycast can reach that URL.

If you are on Tailscale, use the Tailscale machine name and the port the backend is bound to (usually `3000`).
