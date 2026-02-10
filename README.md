# OpenClaw Service

Self-hosted personal AI assistant.

## Quick Start

```bash
cp .env.example .env
echo "OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)" >> .env
docker compose up -d
```

## Access

- **Gateway UI**: http://localhost:18789
