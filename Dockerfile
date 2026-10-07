FROM node:24-slim

RUN npm install -g openclaw @openclaw/groq-provider

# Bake your agent config into OpenClaw's expected state directory
COPY openclaw.json /root/.openclaw/openclaw.json
COPY workspace-main /root/.openclaw/workspace-main
COPY workspace-architect /root/.openclaw/workspace-architect
COPY workspace-coder /root/.openclaw/workspace-coder
COPY workspace-github /root/.openclaw/workspace-github

# No .env file here on purpose — Render injects GROQ_API_KEY, GITHUB_TOKEN,
# OPENCLAW_GATEWAY_TOKEN, and PORT as real env vars at runtime, set in the
# Render dashboard, not baked into the image.

# Official fix per OpenClaw docs: run doctor --fix once to settle any
# plugin/config migrations, THEN start the gateway clean. This is the
# documented pattern for container image startup, not a guess.
CMD ["sh", "-c", "\
  openclaw doctor --fix --non-interactive || true; \
  exec openclaw gateway --port ${PORT:-8080} --bind lan --allow-unconfigured \
"]
