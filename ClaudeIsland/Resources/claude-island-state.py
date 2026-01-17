#!/usr/bin/env python3
"""Claude Island Hook - Session state bridge to ClaudeIsland.app.

Sends session state to ClaudeIsland.app via Unix socket.
For PermissionRequest events, waits for user decision from the app.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SOCKET_PATH = Path("/tmp/claude-island.sock")
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


@dataclass(slots=True)
class SessionState:
    """Represents the state of a Claude Code session."""

    session_id: str
    cwd: str
    event: str
    pid: int
    tty: str | None
    tty_valid: bool = False
    session_active: bool = True
    status: str = "unknown"
    tool: str | None = None
    tool_input: dict[str, Any] = field(default_factory=dict)
    tool_use_id: str | None = None
    notification_type: str | None = None
    message: str | None = None

    def to_dict(self, /) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        result: dict[str, Any] = {
            "session_id": self.session_id,
            "cwd": self.cwd,
            "event": self.event,
            "pid": self.pid,
            "tty": self.tty,
            "tty_valid": self.tty_valid,
            "session_active": self.session_active,
            "status": self.status,
        }

        if self.tool is not None:
            result["tool"] = self.tool
        if self.tool_input:
            result["tool_input"] = self.tool_input
        if self.tool_use_id is not None:
            result["tool_use_id"] = self.tool_use_id
        if self.notification_type is not None:
            result["notification_type"] = self.notification_type
        if self.message is not None:
            result["message"] = self.message

        return result


def validate_tty(tty: str | None, /) -> bool:
    """Validate that a TTY is still active and writable.

    Args:
        tty: The TTY path to validate (e.g., "/dev/ttys001")

    Returns:
        True if the TTY exists and is writable, False otherwise
    """
    if not tty:
        return False

    tty_path = Path(tty)
    if not tty_path.exists():
        return False

    # Check if TTY is writable (indicates active session)
    try:
        return os.access(tty_path, os.W_OK)
    except OSError:
        return False


def is_session_active(pid: int, tty: str | None, /) -> bool:
    """Check if the Claude Code session is still active.

    Combines PID existence check with TTY validation for robust detection.

    Args:
        pid: The process ID to check
        tty: The TTY path associated with the session

    Returns:
        True if the session appears active, False otherwise
    """
    # Check if process exists
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # Process exists but we lack permission to signal it

    # Validate TTY if available
    if tty and not validate_tty(tty):
        return False

    return True


def get_tty(ppid: int, /) -> str | None:
    """Get the TTY of the Claude process.

    Args:
        ppid: Parent process ID (Claude process)

    Returns:
        The TTY path (e.g., "/dev/ttys001") or None if unavailable
    """
    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if tty := result.stdout.strip():
            if tty not in ("??", "-"):
                # ps returns just "ttys001", we need "/dev/ttys001"
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
    except (subprocess.TimeoutExpired, OSError):
        pass

    # Fallback: try current process stdin/stdout
    for fd in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(fd.fileno())
        except (OSError, AttributeError):
            continue

    return None


def send_event(state: SessionState, /) -> dict[str, Any] | None:
    """Send event to app, return response if any.

    Args:
        state: The session state to send

    Returns:
        Response dictionary for permission requests, None otherwise
    """
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(str(SOCKET_PATH))
        sock.sendall(json.dumps(state.to_dict()).encode())

        # For permission requests, wait for response
        if state.status == "waiting_for_approval":
            if response := sock.recv(4096):
                sock.close()
                return json.loads(response.decode())
        sock.close()
        return None
    except (OSError, json.JSONDecodeError):
        return None


def determine_status(
    event: str,
    data: dict[str, Any],
    /,
) -> tuple[str, dict[str, Any]]:
    """Determine session status and extra fields from hook event.

    Uses pattern matching to dispatch on event type.

    Args:
        event: The hook event name
        data: The full event data dictionary

    Returns:
        Tuple of (status, extra_fields_dict)
    """
    match event:
        case "UserPromptSubmit":
            # User just sent a message - Claude is now processing
            return "processing", {}

        case "PreToolUse":
            extras: dict[str, Any] = {
                "tool": data.get("tool_name"),
                "tool_input": data.get("tool_input", {}),
            }
            if tool_use_id := data.get("tool_use_id"):
                extras["tool_use_id"] = tool_use_id
            return "running_tool", extras

        case "PostToolUse":
            extras = {
                "tool": data.get("tool_name"),
                "tool_input": data.get("tool_input", {}),
            }
            if tool_use_id := data.get("tool_use_id"):
                extras["tool_use_id"] = tool_use_id
            return "processing", extras

        case "PermissionRequest":
            return "waiting_for_approval", {
                "tool": data.get("tool_name"),
                "tool_input": data.get("tool_input", {}),
            }

        case "Notification":
            notification_type = data.get("notification_type")
            match notification_type:
                case "permission_prompt":
                    # Handled by PermissionRequest hook with better info
                    return "skip", {}
                case "idle_prompt":
                    return "waiting_for_input", {"notification_type": notification_type}
                case _:
                    return "notification", {
                        "notification_type": notification_type,
                        "message": data.get("message"),
                    }

        case "Stop":
            return "waiting_for_input", {}

        case "SubagentStop":
            # SubagentStop fires when a subagent completes - main session continues
            return "processing", {}

        case "SessionStart":
            # New session starts waiting for user input
            return "waiting_for_input", {}

        case "SessionEnd":
            return "ended", {}

        case "PreCompact":
            # Context is being compacted (manual or auto)
            return "compacting", {}

        case _:
            return "unknown", {}


def handle_permission_response(response: dict[str, Any] | None, /) -> None:
    """Handle the permission response from ClaudeIsland.app.

    Args:
        response: The response dictionary from the app, or None
    """
    if not response:
        # No response or "ask" - let Claude Code show its normal UI
        return

    decision = response.get("decision", "ask")
    reason = response.get("reason", "")

    match decision:
        case "allow":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case "deny":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": reason or "Denied by user via ClaudeIsland",
                    },
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case _:
            # "ask" or unknown - let Claude Code show its normal UI
            pass


def main() -> None:
    """Main entry point for the hook."""
    try:
        data: dict[str, Any] = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")

    # Get process info
    claude_pid = os.getppid()
    tty = get_tty(claude_pid)

    # Validate session state
    tty_valid = validate_tty(tty)
    session_active = is_session_active(claude_pid, tty)

    # Determine status and extra fields
    status, extras = determine_status(event, data)

    # Skip certain events
    if status == "skip":
        sys.exit(0)

    # Build state object
    state = SessionState(
        session_id=session_id,
        cwd=cwd,
        event=event,
        pid=claude_pid,
        tty=tty,
        tty_valid=tty_valid,
        session_active=session_active,
        status=status,
        tool=extras.get("tool"),
        tool_input=extras.get("tool_input", {}),
        tool_use_id=extras.get("tool_use_id"),
        notification_type=extras.get("notification_type"),
        message=extras.get("message"),
    )

    # Handle permission requests specially
    if status == "waiting_for_approval":
        response = send_event(state)
        handle_permission_response(response)
        sys.exit(0)

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()
