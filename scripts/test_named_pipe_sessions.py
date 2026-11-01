#!/usr/bin/env python3
"""Test borrowed and owned named-pipe lifecycles against real HAPI servers.

Requires rebuilt HEGo, licensed Houdini and its Python hapi module. Example:
  /opt/hfs22.0/bin/hython scripts/test_named_pipe_sessions.py --godot /path/to/godot

Creates unique, disposable servers. Never connects to the user's Session Sync.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

import hapi


def initialized(session):
    try:
        return hapi.isInitialized(session)
    except hapi.NotInitializedError:
        return False


def wait_state(directory, name, client):
    path = directory / (name + ".json")
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except json.JSONDecodeError:
                pass  # The client may still be finishing its write.
        if client.poll() is not None:
            raise RuntimeError(f"Godot exited ({client.returncode}) waiting for {name}")
        time.sleep(0.02)
    raise TimeoutError(f"Timed out waiting for {name}")


def run_case(godot, project, borrowed):
    label = "borrowed" if borrowed else "owned"
    pipe = "hego_ownership_" + uuid.uuid4().hex
    observer = None
    server_pid = None
    client = None
    with tempfile.TemporaryDirectory(prefix="hego-session-test-") as directory:
        directory = Path(directory)
        log_path = directory / "godot.log"
        try:
            if borrowed:
                options = hapi.ThriftServerOptions()
                options.autoClose = True
                options.timeoutMs = 10000
                server_pid = hapi.startThriftNamedPipeServer(options, pipe, str(directory / "server.log"))
                observer = hapi.createThriftNamedPipeSession(pipe, hapi.SessionInfo())
                hapi.initialize(observer, hapi.CookOptions())
                sentinel = hapi.createNode(observer, -1, "Sop/box", "external_sentinel", False)
                sentinel_unique_id = hapi.getNodeInfo(observer, sentinel).uniqueHoudiniNodeId
            with log_path.open("w") as log:
                client = subprocess.Popen(
                    [godot, "--headless", "--path", str(project), "--script",
                     "tests/hego_named_pipe_session_test.gd", "--", pipe, str(directory)],
                    stdout=log, stderr=subprocess.STDOUT,
                )
                first = wait_state(directory, "connected", client)
                assert first.get("connected") and first.get("geometry"), first
                if observer is None:
                    # Keep HEGo's server alive so we can verify that its cleanup
                    # still runs, rather than merely observing autoClose exit.
                    observer = hapi.createThriftNamedPipeSession(pipe, hapi.SessionInfo())
                node_id = first["node_id"]
                node_unique_id = hapi.getNodeInfo(observer, node_id).uniqueHoudiniNodeId
                (directory / "disconnect").touch()
                assert not wait_state(directory, "disconnected", client)["active"]
                assert initialized(observer) == borrowed, f"{label}: wrong cleanup policy"
                if borrowed:
                    assert hapi.isNodeValid(observer, sentinel, sentinel_unique_id)
                    assert hapi.isNodeValid(observer, node_id, node_unique_id)
                (directory / "reconnect").touch()
                second = wait_state(directory, "reconnected", client)
                assert second.get("connected") and second.get("geometry"), second
                if borrowed:
                    assert hapi.isNodeValid(observer, sentinel, sentinel_unique_id)
                # Reconnecting to a still-live server is an attachment, even
                # when a previous HEGo connection originally started it.
                (directory / "finish").touch()
                assert client.wait(timeout=15) == 0
                assert initialized(observer), "reconnected borrowed server was cleaned up"
                assert "SCRIPT ERROR" not in log_path.read_text()
                assert "HAPI failed" not in log_path.read_text(), log_path.read_text()
            print(f"PASS {label}: connect, cook, disconnect policy and reconnect", flush=True)
        except Exception:
            if log_path.exists():
                print(log_path.read_text(), flush=True)
            raise
        finally:
            if client is not None and client.poll() is None:
                client.terminate()
                client.wait(timeout=10)
            if observer is not None:
                hapi.closeSession(observer)
            # autoClose handles servers when their last client leaves. Only this
            # test's explicitly started PID is eligible for fallback termination.
            if server_pid is not None:
                try:
                    os.kill(server_pid, 15)
                except ProcessLookupError:
                    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Godot executable (not a terminal wrapper)")
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1] / "demo")
    args = parser.parse_args()
    for borrowed in [True, False]:
        run_case(args.godot, args.project, borrowed)


if __name__ == "__main__":
    main()
