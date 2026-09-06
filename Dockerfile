FROM node:24-slim

RUN npm install -g openclaw @openclaw/groq-provider

# Diagnostic dump — prints straight into the Render build log so we can
# read the real flags/config options instead of guessing at them
RUN openclaw gateway --help || true
RUN openclaw --help || true
RUN openclaw doctor --help || true

# Bake your agent config into OpenClaw's expected state directory
COPY openclaw.json /root/.openclaw/openclaw.json
COPY workspace-main /root/.openclaw/workspace-main
COPY workspace-architect /root/.openclaw/workspace-architect
COPY workspace-coder /root/.openclaw/workspace-coder
COPY workspace-github /root/.openclaw/workspace-github

# No .env file here on purpose — Render injects GROQ_API_KEY, GITHUB_TOKEN,
# GITHUB_REPO, OPENCLAW_GATEWAY_TOKEN, and PORT as real env vars at runtime,
# set in the Render dashboard, not baked into the image.

# Run twice: OpenClaw's first boot can self-heal remaining config/plugin
# state and then deliberately exit rather than start against stale state
# ("refusing to report the gateway ready" in the logs). The second
# invocation starts clean against the now-finalized config. If the plugin
# pre-install above already covers everything, the first call just
# succeeds and the second is a harmless no-op restart.
CMD ["sh", "-c", "openclaw gateway --port $PORT || openclaw gateway --port $PORT"]
