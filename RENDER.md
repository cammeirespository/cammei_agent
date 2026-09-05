# Deploying to Render

## 1. Push this folder to a new GitHub repo

```bash
cd cammei-openclaw-deploy   # this folder: Dockerfile + openclaw.json + workspace-*
git init
git add .
git commit -m "OpenClaw config for Render"
git remote add origin https://github.com/your-org/cammei-openclaw-deploy.git
git push -u origin main
```

## 2. Create the Web Service on Render

1. Render dashboard → **New** → **Web Service**
2. Connect the repo you just pushed
3. Environment: **Docker** (it should auto-detect the `Dockerfile`)
4. Instance type: **Free**

## 3. Set environment variables

In the service's **Environment** tab, add (as secrets, not in any file):

- `GROQ_API_KEY`
- `GITHUB_TOKEN`
- `GITHUB_REPO`
- `OPENCLAW_GATEWAY_TOKEN`

Render sets `PORT` automatically — don't add it yourself.

## 4. Deploy and test

Once it's live, Render gives you a URL like `https://cammei-agent.onrender.com`.

```bash
curl -X POST https://cammei-agent.onrender.com/v1/chat/completions \
  -H "Authorization: Bearer YOUR_GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"openclaw/main","messages":[{"role":"user","content":"hello"}]}'
```

## Two things to verify before this works end-to-end

I don't have full certainty on two specific details, since they depend on
your installed OpenClaw version:

1. **`--port $PORT` flag** in the Dockerfile's `CMD` — check
   `openclaw gateway --help` for the actual flag name (might be
   `--port`, might be a config key instead, e.g. `gateway.port` in
   `openclaw.json`, set dynamically at container start via a small
   startup script instead of a CLI flag).
2. **`"bind": "all"`** in `openclaw.json` — check OpenClaw's gateway docs
   for the exact accepted value for "listen on all interfaces" (could be
   `"all"`, `"0.0.0.0"`, or something else entirely).

If the container starts but the `curl` above times out or connection-refuses,
these two are the first place to look.

## The trade-off you're accepting

Free Render services spin down after inactivity — the first request after
idle takes about a minute to wake back up. Fine for a team tool that isn't
constantly in use; worth knowing so a slow first message doesn't look like
it's broken.
