FROM node:24-slim

RUN npm install -g openclaw

# Bake your agent config into OpenClaw's expected state directory
COPY openclaw.json /root/.openclaw/openclaw.json
COPY workspace-main /root/.openclaw/workspace-main
COPY workspace-architect /root/.openclaw/workspace-architect
COPY workspace-coder /root/.openclaw/workspace-coder
COPY workspace-github /root/.openclaw/workspace-github

# No .env file here on purpose — Render injects GROQ_API_KEY, GITHUB_TOKEN,
# GITHUB_REPO, OPENCLAW_GATEWAY_TOKEN, and PORT as real env vars at runtime,
# set in the Render dashboard, not baked into the image.

CMD ["sh", "-c", "openclaw gateway --port $PORT"]
