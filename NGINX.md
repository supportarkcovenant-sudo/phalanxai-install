# PhalanxAI behind nginx

PhalanxAI works behind nginx, whether nginx is a service on the machine or
a container. It does not need nginx, and it does not touch ports 80 or 443.
This page explains how PhalanxAI listens and what it expects from a proxy,
so you can write or adjust your own configuration.

- [How PhalanxAI runs](#how-phalanxai-runs)
- [What the proxy must do](#what-the-proxy-must-do)
- [Telling PhalanxAI to trust the proxy](#telling-phalanxai-to-trust-the-proxy)
- [Under a path of another site](#under-a-path-of-another-site)
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

Three things, plus a fourth if PhalanxAI shares a hostname. The first is
the one that is easy to miss.

1. **Pass the browser's `Host` header through unchanged.** Terminals are
   WebSockets, and PhalanxAI refuses a WebSocket unless the page's address
   (the `Origin` header) matches the `Host` header it receives. nginx's
   default replaces `Host` with the upstream's address, and then the page
   loads but every terminal is refused.
2. **Allow WebSocket upgrades**, and do not time them out. nginx closes an
   idle proxied connection after 60 seconds by default.
3. **Allow request bodies of at least 20 MB.** Images attached to a chat can
   be 10 MB each; nginx's default limit is 1 MB.
4. **Under a path, leave the path on.** PhalanxAI can live at the root of
   its own hostname (`phalanx.example.com`) with no further setup, or under
   a path of another site (`example.com/phalanx/`) once it is told the
   path. See [Under a path of another site](#under-a-path-of-another-site).

## Telling PhalanxAI to trust the proxy

nginx tells PhalanxAI that the visitor used HTTPS (`X-Forwarded-Proto`) and
what their address is (`X-Forwarded-For`). PhalanxAI believes those headers
only from proxies it trusts, because otherwise anyone who can reach the port
could claim any address. When it believes them:

- the sign-in cookies are marked `Secure`,
- embed snippets are written with `https://`,
- sign-in logs show the visitor's address instead of the proxy's.

`127.0.0.1` is always trusted. Anything else has to be named, as an address
or a network. Needs PhalanxAI 0.4.1 or later (`phalanx status` shows the
version; `phalanx upgrade` moves to the newest).

| Arrangement | PhalanxAI sees nginx as | What to do |
|---|---|---|
| nginx service, full install | `127.0.0.1` | nothing |
| nginx service, restricted install | the Docker network's gateway | trust the Docker networks |
| nginx container, either install | the nginx container's address | trust the Docker networks |

Docker hands out addresses from `172.16.0.0/12` by default, so that network
covers the last two rows. At install:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh   | bash -s -- --bind 127.0.0.1 --tls off --trusted-proxy 172.16.0.0/12
```

On an existing install, add this line to `/opt/phalanxai/phalanx.env` and
run `phalanx up`:

```bash
PHALANX_TRUSTED_PROXIES="172.16.0.0/12"
```

Several entries are separated by commas. To be exact rather than broad, use
the one network or address instead: `docker network inspect
phalanxai04_default` shows the subnet and gateway. An entry that is not an
address or a network stops PhalanxAI from starting, and `phalanx logs` says
which one.

Only trust networks where everything that can reach port 8765 is yours.
With `PHALANX_BIND="127.0.0.1"` that is this machine and its containers.

## Under a path of another site

Needs PhalanxAI 0.4.2 or later. Two halves: tell PhalanxAI the path, and
have nginx pass requests through with the path still on them.

**Tell PhalanxAI.** At install:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh   | bash -s -- --bind 127.0.0.1 --tls off --base-path /phalanx
```

On an existing install, add this line to `/opt/phalanxai/phalanx.env` and
run `phalanx up`:

```bash
PHALANX_BASE_PATH="/phalanx"
```

**Tell nginx.** Inside your site's existing `server` block:

```nginx
location = /phalanx {
    return 301 /phalanx/;
}

location /phalanx/ {
    # No path after the address. With a trailing slash here nginx would
    # remove /phalanx, and PhalanxAI needs to see it.
    proxy_pass http://127.0.0.1:8765;
    proxy_http_version 1.1;

    proxy_set_header Host $http_host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;

    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;

    client_max_body_size 20m;
}
```

For nginx as a container, change the `proxy_pass` address as described
[below](#nginx-as-a-container); the rest is the same.

How it behaves, so you know what to expect:

- PhalanxAI answers both under `/phalanx/` and at the root of its own port.
  Each is complete on its own: a request that arrives with the prefix gets
  a page, API and terminals under the prefix; one that arrives without it
  (the `phalanx` command, Claude Code inside the container, a browser going
  straight to port 8765) works as if no path were set.
- Under the prefix, the sign-in cookies are scoped to `/phalanx`, so the
  rest of the site is never sent them. A sign-in at `/phalanx/` and one made
  straight at port 8765 are separate.
- Everything in [What travels over the connection](#what-travels-over-the-connection)
  moves under the prefix: `/phalanx/api/v1/...`, `/phalanx/assets/...`.
- Embed snippets shown in the app include the prefix.
- The path may be several segments deep (`/tools/phalanx`). It may hold
  letters, digits, and `. _ ~ -`.

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

- **Until the proxy is trusted, the sign-in cookie is not marked `Secure`**
  and sign-in logs show the proxy's address rather than the visitor's. See
  [Telling PhalanxAI to trust the proxy](#telling-phalanxai-to-trust-the-proxy).
  Sign-in works either way; redirect port 80 to 443, as above, so the
  cookie is never sent in the clear.
- **Under a path, nginx must not remove the path.** A `proxy_pass` that
  ends in `/` strips it, and the page then asks for its files at the site's
  root. See [Under a path of another site](#under-a-path-of-another-site).

## Troubleshooting

| What you see | Cause |
|---|---|
| Page loads; terminals show nothing or close at once. `phalanx logs` says `cross-origin terminal connections are not allowed`. | `Host` is not passed through. Add `proxy_set_header Host $http_host;`. If nginx listens on a non-standard port, `$http_host` (not `$host`) is what keeps the port. |
| Terminals work, then drop after about a minute idle | missing `proxy_read_timeout` |
| Terminals never connect; the browser console shows a failed WebSocket with status 200 or 400 | missing `Upgrade` and `Connection` headers, or `proxy_http_version 1.1` |
| Attaching an image fails with 413 | raise `client_max_body_size` |
| Blank page with 404s for `/assets/...` | served under a path, but either `PHALANX_BASE_PATH` is not set or `proxy_pass` ends in `/` and strips the path |
| Under a path, signed in but every change fails with a CSRF error | the same cause: the page and its cookies disagree about the path |
| Sign-in cookie has no `Secure` flag; logs show a `172.x` address for every sign-in | the proxy is not trusted; see above |
| 502 Bad Gateway right after editing `phalanx.env` | a bad `PHALANX_TRUSTED_PROXIES` entry stopped the app; `phalanx logs` names it |
| 502 Bad Gateway | nginx cannot reach the upstream: wrong address for your arrangement (see above), PhalanxAI stopped (`phalanx status`), or, for a container, nginx is not on `phalanxai04_default` |

To check PhalanxAI itself, bypassing nginx, on the machine:

```bash
curl http://127.0.0.1:8765/api/v1/system/version
```

---

Tested with PhalanxAI behind an nginx container on a shared Docker network:
the page, sign-in, and a terminal WebSocket work with the `location` block
above; the terminal is refused when `Host` is not passed through; and with
`PHALANX_TRUSTED_PROXIES="172.16.0.0/12"` the cookies come back `Secure` and
the log shows the visitor's address. Under `/phalanx/` of a site serving
something else at its root: the page, its files, sign-in (cookies scoped to
`/phalanx`), a terminal WebSocket, and the `phalanx` command inside the
container all work. The other arrangements follow from the same rules but
were not each run.
