---
title: MCP & coding agents
description: How the installer wires up DeepSQL's MCP server for Claude Code, Codex, and Cursor.
---

import { Aside, Tabs, TabItem } from '@astrojs/starlight/components';

After the stack is healthy, the installer installs the DeepSQL MCP server globally:

```bash
npm install -g @deepsql/mcp@latest
```

Then it prompts you to pick which coding agents to wire up:

```
  Which coding agent(s) will you use DeepSQL with?
  1) Claude Code
  2) Codex
  3) Cursor
  a) All of the above
  s) Skip

  Enter choice(s) separated by spaces (e.g. 1 3):
```

For each agent you pick, it runs:

```bash
deepsql mcp config --install --for <agent> --force
```

That command writes the MCP server configuration into the right location for that agent. `--force` overwrites any existing DeepSQL MCP block (it leaves other servers untouched).

## Where each agent's config goes

<Tabs>
  <TabItem label="Claude Code">
    `~/.claude.json` — adds a `deepsql` entry under `mcpServers`. Claude Code picks it up on next launch.
  </TabItem>
  <TabItem label="Codex">
    `~/.codex/config.toml` — adds a `[mcp_servers.deepsql]` section.
  </TabItem>
  <TabItem label="Cursor">
    `~/.cursor/mcp.json` — adds a `deepsql` entry under `mcpServers`.
  </TabItem>
</Tabs>

<Aside type="tip" title="Add agents later">
  You can re-run any of these at any time without re-running the full installer:

  ```bash
  npm install -g @deepsql/mcp@latest
  deepsql mcp config --install --for claude-code --force
  deepsql mcp config --install --for codex --force
  deepsql mcp config --install --for cursor --force
  ```
</Aside>

## Skipping MCP install entirely

If you don't want any MCP wiring, just pick `s` (skip) at the prompt — or have `npm` missing from `PATH` (the installer skips MCP with a clear message in that case).
