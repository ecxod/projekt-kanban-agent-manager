# Projekt Kanban Agent Manager

Manager version: `0.1.8.3`

Native Host version: `0.1.8.3`

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
- cancel active runs when the agent is deactivated; and
- run a real read-only connection test and show the agent's response; and
- view GitHub releases and install the selected Windows-WSL bridge release.

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

The Windows relay writes diagnostic information to:

```text
C:\Users\Christian\AppData\Local\ProjektKanbanAgent\relay.log
```

For invalid Base64 output the log includes the line length, failure position,
offending byte, a bounded hexadecimal preview, and a UTF-16 preview when WSL
has returned a Windows error message instead of the protocol response.

`VERSION` is the single source of truth for the Manager and Native Host
version. Tagged Manager releases are built by GitHub Actions and publish a
Windows-WSL archive containing the manager, installer, Native Host, and relay.
The Manager's update button downloads that archive from the Manager GitHub
release before running its installer; it does not reinstall a local copy.
