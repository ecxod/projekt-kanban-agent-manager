# Projekt Kanban Agent Manager

This folder contains the standalone Windows/WSL agent manager and bridge.
The Firefox add-on is maintained separately in:

```text
C:\Users\Christian\projekt-kanban-agent-addon
```

## Start the manager

Double-click:

```text
C:\Users\Christian\projekt-kanban-agent-manager\start-agent-manager.cmd
```

The manager can:

- install or update the Windows-to-WSL Native Messaging bridge;
- select the WSL distribution;
- configure the Codex executable and workspace;
- test the agent connection;
- activate or deactivate the configured agent; and
- cancel active runs when the agent is deactivated.

The agent is started on demand for a confirmed task from Firefox. The manager
does not keep a permanent Codex process running.

## Recommended first configuration

Use these values for debugging the cloned project:

```text
Agent ID:                    local-codex
Agent executable (WSL):      /mnt/c/Users/Christian/.codex/bin/wsl/codex
Access mode:                 Read-only (Dry Run)
Workspace (WSL):             /mnt/c/Users/Christian/projekt-kanban-agent-addon
```

After the bridge self-test and connection test pass, use
`Workspace write` only when the agent should modify files.

## Contents

- `native-host/` contains the Python Native Messaging host and Linux scripts.
- `native-host-windows-wsl/` contains the Windows manager, installer,
  uninstaller, relay source, and relay executable.
- `start-agent-manager.cmd` is the convenient top-level launcher.

The Firefox add-on and its page protocol remain in the separate add-on folder.
