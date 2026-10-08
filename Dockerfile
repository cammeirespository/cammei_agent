FROM node:24-slim

RUN npm install -g openclaw @openclaw/groq-provider

# Create state directory explicitly
RUN mkdir -p /root/.openclaw

COPY openclaw.json /root/.openclaw/openclaw.json
COPY workspace-main /root/.openclaw/workspace-main
COPY workspace-architect /root/.openclaw/workspace-architect
COPY workspace-github /root/.openclaw/workspace-github

# Limit Node memory so it fails faster instead of freezing under 512MB
ENV NODE_OPTIONS="--max-old-space-size=384"

CMD ["sh", "-c", "exec openclaw gateway --port ${PORT:-8080} --bind lan"]
