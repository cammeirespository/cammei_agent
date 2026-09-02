# Deploying this to OpenClaw

This folder mirrors the layout OpenClaw expects under `~/.openclaw/` on
your VM. Nothing here runs on its own — it's config + workspace files
that the OpenClaw Gateway process reads.

## 1. Install OpenClaw on your Oracle Cloud VM (if not already done)

Follow OpenClaw's own install instructions for your OS, then run
`openclaw onboard` once to create `~/.openclaw/` with defaults — this
gives you a base to merge into.

## 2. Copy these files into place

```bash
cp openclaw.json ~/.openclaw/openclaw.json
cp -r workspace-main ~/.openclaw/
cp -r workspace-architect ~/.openclaw/
cp -r workspace-coder ~/.openclaw/
cp -r workspace-github ~/.openclaw/
```

## 3. Set your secrets

```bash
cp .env.example ~/.openclaw/.env
nano ~/.openclaw/.env   # fill in the real values
```

Make sure OpenClaw is actually loading this `.env` — depending on your
install method you may need to `source` it before starting the gateway,
or export the variables in your systemd service file instead.

## 4. Add your real architecture docs

```bash
# replace the placeholder, or add more files alongside it
cp /path/to/cammei/ARCHITECTURE.md ~/.openclaw/workspace-architect/
```

## 5. Start the gateway

```bash
openclaw gateway --daemon
```

Check it's up:

```bash
openclaw gateway status --json
```

## 6. Test each agent directly before wiring up the frontend

```bash
openclaw agent --agent architect --message "What do we know about the storage layer?"
openclaw agent --agent github --message "List open pull requests"
openclaw agent --agent main --message "Summarize the architecture and check for open PRs"
```

That last one should trigger `main` delegating to both `architect` and
`github` and merging the results — if it does, the whole system is wired
correctly.

## 7. Point the frontend at it

`POST http://<vm-address>:18789/v1/chat/completions` with
`Authorization: Bearer <OPENCLAW_GATEWAY_TOKEN>` and
`model: "openclaw/main"`.

## A note on accuracy

Config key names in `openclaw.json` (`agents.entries.*`, `skills.entries.*`,
`models.providers.*`) reflect OpenClaw's documented schema as of this
writing, but the project moves fast — run `openclaw doctor` after copying
these in, and fix any key it flags as unrecognized for your installed
version before going further.
