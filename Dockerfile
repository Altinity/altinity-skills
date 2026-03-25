FROM ghcr.io/altinity/altinity-mcp:latest AS mcp

FROM docker.io/oven/bun:debian
ARG CODEX_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG TOOLCHAIN_REFRESH=static

RUN bash -xec "apt-get update && apt-get install --no-install-recommends -y curl ca-certificates unzip git git-lfs ripgrep && \
    update-ca-certificates && \
    curl 'https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip' -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip && \
    rm -rf /var/lib/apt/lists/* && rm -rf /var/cache/apt/*"

RUN mkdir -p /home/bun /opt/bun

ENV HOME=/home/bun
ENV BUN_INSTALL=/opt/bun
ENV PATH="/opt/bun/bin:${PATH}"

RUN bun install -g @openai/codex@${CODEX_VERSION} \
  && bun install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
  && echo "toolchain_refresh=${TOOLCHAIN_REFRESH}" >/tmp/toolchain-refresh.txt \
  && rm -f /usr/local/bin/codex \
  && rm -f /usr/local/bin/claude \
  && printf '%s\n' '#!/usr/bin/env bash' 'exec bun /opt/bun/install/global/node_modules/@openai/codex/bin/codex.js "$@"' > /usr/local/bin/codex \
  && chmod +x /usr/local/bin/codex \
  && printf '%s\n' '#!/usr/bin/env bash' 'exec bun /opt/bun/install/global/node_modules/@anthropic-ai/claude-code/cli.js "$@"' > /usr/local/bin/claude \
  && chmod +x /usr/local/bin/claude \
  && bunx skills add --global --agent claude-code --yes Altinity/Skills \
  && bunx skills add --global --agent codex --yes Altinity/Skills \
  && codex --version \
  && claude --version \
  && chown -R bun:bun /home/bun /opt/bun

COPY --from=mcp /bin/altinity-mcp /bin/altinity-mcp

RUN mkdir -p /etc/claude-code \
  && cat <<'EOF' > /etc/claude-code/managed-mcp.json
{
  "mcpServers": {
    "clickhouse": {
      "command": "/bin/altinity-mcp",
      "args": ["--config", "/opt/expert-mcp/mcp-config.json", "--read-only", "1"]
    }
  }
}
EOF
  && chmod 755 /etc/claude-code \
  && chmod 644 /etc/claude-code/managed-mcp.json

USER bun

RUN mkdir -p /home/bun/.codex \
  && cat <<'EOF' > /home/bun/.codex/config.toml
model = "gpt-5.4"
model_reasoning_effort = "medium"
web_search = "live"

[mcp_servers.clickhouse]
command = "/bin/altinity-mcp"
args = ["--config","/opt/expert-mcp/config.yaml","--read-only", "1"]
EOF
