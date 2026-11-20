# PhalanxAI behind nginx

PhalanxAI works behind nginx, whether nginx is a service on the machine or
a container. It does not need nginx, and it does not touch ports 80 or 443.
This page explains how PhalanxAI listens and what it expects from a proxy,
so you can write or adjust your own configuration.

- [How PhalanxAI runs](#how-phalanxai-runs)
- [What the proxy must do](#what-the-proxy-must-do)
- [nginx as a service on the machine](#nginx-as-a-service-on-the-machine)
- [nginx as a container](#nginx-as-a-container)
- [What travels over the connection](#what-travels-over-the-connection)
- [Firewall and exemptions](#firewall-and-exemptions)
- [Known limits](#known-limits)
- [Troubleshooting](#troubleshooting)

## How PhalanxAI runs

One Docker container named `phalanxai04`, from one Compose project also
named `phalanxai04`. Its settings are in `/opt/phalanxai/phalanx.env`; the
`phalanx` command writes `/opt/phalanxai/compose.yaml` from them, so edit
the `.env` file (then `phalanx up`), never the Compose file.

| | |
|---|---|
| Web page, API, and terminals | one port, **8765** by default (`PHALANX_PORT`) |
| Protocol on that port | plain HTTP, or HTTPS if installed with `--tls self-signed` |
| Second port, only when its own HTTPS is on | **8766** (the next port up), plain HTTP bound to `127.0.0.1` only, used by Claude Code and the `phalanx` command. Never proxy it. |
| Listen address | `PHALANX_BIND`: `0.0.0.0` (whole network) or `127.0.0.1` (this machine only) |
| Data | Docker volume `phalanxai04_phalanx-data` |

How the port reaches the machine depends on the host-access choice made at
install (`PHALANX_HOST_ACCESS`):

- **Restricted** (and every macOS install): the container is on its own
  Docker network, `phalanxai04_default`, and port 8765 is published to the
  machine at `PHALANX_BIND`.
- **Full** (Linux): the container shares the machine's network. There is no
  Docker network and no published port; the app itself listens on
  `PHALANX_BIND:8765` on the machine.

When nginx is the way in, install with the app listening on this machine
only and without its own HTTPS, and let nginx hold the certificate:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh \
  | bash -s -- --bind 127.0.0.1 --tls off
```

On an existing install, set `PHALANX_BIND="127.0.0.1"` and
`PHALANX_TLS="off"` in `/opt/phalanxai/phalanx.env`, then run `phalanx up`.

## What the proxy must do

Four things. The first is the one that is easy to miss.

1. **Pass the browser's `Host` header through unchanged.** Terminals are
   WebSockets, and PhalanxAI refuses a WebSocket unless the page's address
   (the `Origin` header) matches the `Host` header it receives. nginx's
   default replaces `Host` with the upstream's address, and then the page
   loads but every terminal is refused.
2. **Allow WebSocket upgrades**, and do not time them out. nginx closes an
   idle proxied connection after 60 seconds by default.
3. **Serve PhalanxAI at the root of a hostname**, such as
   `phalanx.example.com`. It cannot live under a path like
   `example.com/phalanx/`: the page requests `/api/v1/...` and `/assets/...`
   from the root.
4. **Allow request bodies of at least 20 MB.** Images attached to a chat can
   be 10 MB each; nginx's default limit is 1 MB.

## nginx as a service on the machine

Works the same for restricted and full installs: PhalanxAI is at
`127.0.0.1:8765` either way.

```nginx
server {
    listen 443 ssl;
    server_name phalanx.example.com;

    ssl_certificate     /etc/ssl/certs/phalanx.example.com.pem;
    ssl_certificate_key /etc/ssl/private/phalanx.example.com.key;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;

        # Required: terminals are refused without the original Host.
        proxy_set_header Host $http_host;

        # Required: terminals are WebSockets.
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;

        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
    }
}

server {
    listen 80;
    server_name phalanx.example.com;
    return 301 https://$host$request_uri;
}
```

## nginx as a container

Inside the nginx container, `127.0.0.1` is nginx itself, so the upstream
address is different. Everything else in the `location` block above stays
the same.

**Restricted install.** Put nginx on PhalanxAI's Docker network and use the
container's name:

```bash
docker network connect phalanxai04_default <your-nginx-container>
```

```nginx
proxy_pass http://phalanxai04:8765;
```

In a Compose file for nginx, the same thing is:

```yaml
services:
  nginx:
    networks: [default, phalanx]
networks:
  phalanx:
    name: phalanxai04_default
    external: true
```

This path does not use the published port, so `PHALANX_BIND="127.0.0.1"`
keeps PhalanxAI unreachable except through nginx. PhalanxAI must be started
before nginx, because it creates the network.

**Full install.** There is no Docker network to join; the app listens on the
machine. Give the nginx container a name for the machine and proxy to it:

```yaml
services:
  nginx:
    extra_hosts: ["host.docker.internal:host-gateway"]
```

```nginx
proxy_pass http://host.docker.internal:8765;
```

A container cannot reach the machine's `127.0.0.1`, so here `PHALANX_BIND`
must be `0.0.0.0` or the Docker bridge address (usually `172.17.0.1`).
With `0.0.0.0`, block port 8765 from outside with the firewall.

## What travels over the connection

Useful when writing rules, exemptions, or a web application firewall policy.

| Path | What it is | Notes |
|---|---|---|
| `/`, `/assets/...` | the web page | static files |
| `/api/v1/...` | the API | JSON; sign-in is a cookie, and changes also need the `X-Phalanx-CSRF` header the page sends |
| `/api/v1/sessions/<id>/attach` | a terminal | WebSocket, open for as long as the terminal is on screen; carries raw terminal bytes, including control characters |
| `/api/v1/hooks/<token>` | Claude Code reporting its status | called from inside the container, not by browsers; it does not need to be reachable through nginx |
| embed pages | a project or tool framed in another site | only if you use embedding; see below |

- **Do not rewrite or strip `Origin`, `Host`, `Cookie`, or `Set-Cookie`.**
- **Do not add your own `Content-Security-Policy` or `X-Frame-Options`.**
  PhalanxAI sets `frame-ancestors` itself: nothing may frame the app, except
  the embed pages, by the sites you listed for them. A blanket
  `X-Frame-Options: DENY` from nginx breaks embedding.
- **Do not cache.** If caching is on globally, exempt this server block.
- **Request inspection** (ModSecurity and similar) tends to object to
  terminal traffic and to prompts that look like code or shell commands.
  Exempt `/api/v1/` if terminals or chats fail with 403 from the proxy.
- **Putting your own sign-in in front** (basic auth, an SSO gateway) works
  for the page, but the `phalanx` command talks to the app from inside the
  container and is unaffected by it.

## Firewall and exemptions

| Port | Who needs it |
|---|---|
| 443 (and 80 for the redirect) | browsers, to nginx |
| 8765 | nginx only. Nothing outside the machine needs it once nginx is in front. |
| 8766 | nobody outside the machine; only exists with PhalanxAI's own HTTPS on |

The container makes outbound HTTPS connections for Claude Code (Anthropic's
API and sign-in), for `phalanx upgrade` (ghcr.io), and for whatever your
sessions do (git, package installs).

## Known limits

- **The sign-in cookie is not marked `Secure` in most proxied setups.**
  PhalanxAI believes `X-Forwarded-Proto` only from `127.0.0.1`. That is the
  case for nginx as a service with a full install; in the other
  arrangements it sees plain HTTP and omits the flag. Sign-in works either
  way. Redirect port 80 to 443, as above, so the cookie is never sent in
  the clear.
- **Sign-in logs show the proxy's address**, not the visitor's, in those
  same arrangements. Use nginx's access log for the real address.
- **No path prefix.** A hostname of its own is required.

## Troubleshooting

| What you see | Cause |
|---|---|
| Page loads; terminals show nothing or close at once. `phalanx logs` says `cross-origin terminal connections are not allowed`. | `Host` is not passed through. Add `proxy_set_header Host $http_host;`. If nginx listens on a non-standard port, `$http_host` (not `$host`) is what keeps the port. |
| Terminals work, then drop after about a minute idle | missing `proxy_read_timeout` |
| Terminals never connect; the browser console shows a failed WebSocket with status 200 or 400 | missing `Upgrade` and `Connection` headers, or `proxy_http_version 1.1` |
| Attaching an image fails with 413 | raise `client_max_body_size` |
| Blank page with 404s for `/assets/...` | served under a path prefix; move it to its own hostname |
| 502 Bad Gateway | nginx cannot reach the upstream: wrong address for your arrangement (see above), PhalanxAI stopped (`phalanx status`), or, for a container, nginx is not on `phalanxai04_default` |

To check PhalanxAI itself, bypassing nginx, on the machine:

```bash
curl http://127.0.0.1:8765/api/v1/system/version
```

---

Tested with the PhalanxAI 0.4.0 image behind an nginx container on a shared
Docker network: the page, sign-in, and a terminal WebSocket work with the
`location` block above, and the terminal is refused when `Host` is not
passed through. The other arrangements follow from the same rules but were
not each run.
