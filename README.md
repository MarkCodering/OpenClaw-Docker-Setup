# OpenClaw Docker Setup

This repo provides a single setup script for running OpenClaw in Docker with the gateway exposed on the host and the Control UI configured for local access.

The script is intended to reduce the common friction points:

- creating a persistent data directory
- starting the container with the required port mappings
- configuring OpenClaw to listen on LAN inside the container
- allowing local Control UI origins
- extracting the gateway token for a direct Control UI URL
- auto-approving the first pending device request by default

## Files

- [openclaw_setup.sh](/Users/mark/Documents/Dev/OpenClaw-Docker-Setup/openclaw_setup.sh)

## Prerequisites

- Docker installed and running
- access to the image referenced by `IMAGE`
- optionally `npm` if you want the script to install the Codex CLI for you

## Quick Start

Run the script:

```bash
bash openclaw_setup.sh
```

By default it will:

- start `alpine/openclaw:latest`
- publish the OpenClaw gateway on `localhost:18789`
- publish the browser control port on `localhost:18791`
- persist OpenClaw data in `~/openclaw-data`
- auto-approve the first pending device request

If token extraction succeeds, the script prints a URL in this form:

```text
http://localhost:18789/#token=...
```

Open that exact URL in a fresh private or incognito window.

## Why Device Binding Works More Reliably Here

The setup script does a few things specifically to make Control UI access easier in Docker:

- maps the gateway port from the container to the host
- sets `gateway.bind` to `lan` so OpenClaw listens on `0.0.0.0` inside the container
- configures the Control UI allowed origins to match the host gateway URL
- uses token auth for the gateway
- waits for a pending device request and auto-approves it by default

That last step matters for first-time use: once the browser opens the Control UI and creates a pending request, the script approves it automatically when `AUTO_APPROVE_DEVICE=true`.

## Configuration

You can override the defaults with environment variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONTAINER_NAME` | `openclaw` | Docker container name |
| `IMAGE` | `alpine/openclaw:latest` | OpenClaw image to run |
| `HOST_PORT_GATEWAY` | `18789` | Host port mapped to container port `18789` |
| `HOST_PORT_BROWSER` | `18791` | Host port mapped to container port `18791` |
| `DATA_DIR` | `$HOME/openclaw-data` | Persistent OpenClaw data directory |
| `AUTO_APPROVE_DEVICE` | `true` | `true`, `false`, or `ask` for first pending device approval |
| `SETUP_CODEX_AUTH` | `ask` | `ask`, `yes`, `no`, or `skip` style control for Codex auth setup |
| `CODEX_AUTH_METHOD` | `ask` | `login`, `api-key`, `skip`, or the numeric equivalents `1`, `2`, `3` |
| `CODEX_API_KEY` | inherits `OPENAI_API_KEY` | API key passed to `codex login --with-api-key` |
| `WAIT_TIMEOUT_SECONDS` | `120` | Shared timeout for readiness and token/device waits |

Example with custom ports and data path:

```bash
HOST_PORT_GATEWAY=28889 \
HOST_PORT_BROWSER=28891 \
DATA_DIR="$HOME/.local/share/openclaw" \
bash openclaw_setup.sh
```

Example non-interactive run:

```bash
SETUP_CODEX_AUTH=no \
AUTO_APPROVE_DEVICE=true \
bash openclaw_setup.sh
```

Example with API-key auth:

```bash
SETUP_CODEX_AUTH=yes \
CODEX_AUTH_METHOD=api-key \
CODEX_API_KEY=your_key_here \
bash openclaw_setup.sh
```

Example with Codex auth skipped entirely:

```bash
SETUP_CODEX_AUTH=skip bash openclaw_setup.sh
```

## Codex Auth Options

Codex authentication is optional for this repo. The Docker setup works without it.

You can:

- skip Codex auth entirely
- use browser-based `codex login`
- provide an API key through `CODEX_API_KEY` or `OPENAI_API_KEY`

Examples:

```bash
SETUP_CODEX_AUTH=skip bash openclaw_setup.sh
```

```bash
SETUP_CODEX_AUTH=yes CODEX_AUTH_METHOD=login bash openclaw_setup.sh
```

```bash
SETUP_CODEX_AUTH=yes CODEX_AUTH_METHOD=api-key CODEX_API_KEY=your_key_here bash openclaw_setup.sh
```

If you use another provider, the practical requirement is that the Codex CLI accepts the credentials you supply. This README does not assume direct GitHub Copilot support. If you have a compatible key or proxy setup that works with the Codex CLI, pass the key through `CODEX_API_KEY` and keep any provider-specific endpoint configuration in your shell environment.

## Expected Flow

1. The script removes any existing container with the same name.
2. It starts a new container with persistent storage.
3. It waits for the OpenClaw CLI to become ready.
4. It configures gateway and Control UI settings inside the container.
5. It restarts the container and waits for it to come back.
6. It extracts the gateway token and prints a direct URL.
7. It waits for a pending device request and approves it automatically when enabled.

## Useful Commands

Tail container logs:

```bash
docker logs -f openclaw
```

Open a shell in the container:

```bash
docker exec -it openclaw sh
```

Show a dashboard URL from inside the container:

```bash
docker exec openclaw sh -lc 'openclaw dashboard --no-open'
```

List device requests:

```bash
docker exec openclaw sh -lc 'openclaw devices list'
```

Approve a device request manually:

```bash
docker exec openclaw sh -lc 'openclaw devices approve <REQUEST_ID>'
```

## Troubleshooting

If the Control UI does not load:

- make sure Docker is running
- make sure `HOST_PORT_GATEWAY` is free on the host
- use the exact host consistently, preferably `localhost`
- check container logs for a line showing the gateway listening on `0.0.0.0`

If the UI says pairing is required:

- keep the Control UI page open for a few seconds so the pending device request appears
- run `docker exec openclaw sh -lc 'openclaw devices list'`
- approve the request manually if auto-approval was disabled

If the script cannot print a tokenized URL:

- run `docker exec openclaw sh -lc 'openclaw dashboard --no-open'`
- open the printed URL manually

## Notes

- The script is designed for local Docker-based use.
- It does not currently pull the image for you.
- It has been syntax-checked locally, but full runtime validation depends on having the OpenClaw image available.
