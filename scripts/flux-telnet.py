#!/usr/bin/env python3
"""Commands to the 7 Days to Die server running in this container, over its telnet console.

    flux-telnet.py [--wait SECONDS] <command> [<command>...]

Each argument is one console command (`saveworld`, `say "Restart in 5 minutes"`, `shutdown`).
Prints what the server wrote back within --wait seconds of the last command (default 1), and
exits 0 when the commands were delivered. Exits 2 when telnet is off, 3 when the password is
refused, 4 when the server cannot be reached.

WHERE THE PORT AND PASSWORD COME FROM: the serverconfig.xml the server was started with
(FLUX_SERVERCONFIG), which flux-serverconfig.py has already written the environment into. With
no TelnetPassword the game only listens on the loopback and asks for none, which is how the
image runs it unless the owner sets one.

THE CONSOLE IS A STREAM, NOT A REQUEST/REPLY PROTOCOL. The server writes its log lines to every
telnet client as they happen, and a command's answer is just more lines in that stream. So there
is no reply to wait for: a command counts as delivered once it is written after the banner.
"""
import importlib.util
import os
import socket
import sys
import time

# The config reader is shared with flux-serverconfig.py, whose name has a dash in it.
_spec = importlib.util.spec_from_file_location(
    "flux_serverconfig",
    os.path.join(os.path.dirname(os.path.realpath(__file__)), "flux-serverconfig.py"),
)
serverconfig = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(serverconfig)

CONFIG = os.environ.get("FLUX_SERVERCONFIG", "/mnt/7dtd/data/serverconfig.xml")
HOST = os.environ.get("FLUX_TELNET_HOST", "127.0.0.1")
TIMEOUT = float(os.environ.get("FLUX_TELNET_TIMEOUT", "5"))


def settings():
    """(enabled, port, password) from the server's config file."""
    try:
        with open(CONFIG, encoding="utf-8-sig") as f:
            text = f.read()
    except OSError:
        text = ""
    enabled = serverconfig.get(text, "TelnetEnabled")
    port = serverconfig.as_int(serverconfig.get(text, "TelnetPort"), 8081)
    password = serverconfig.get(text, "TelnetPassword") or ""
    return serverconfig.truthy(enabled if enabled is not None else "true"), port, password


def read_until(sock, markers, deadline):
    """Reads until one of markers shows up (returns it) or the deadline passes (returns None)."""
    buf = b""
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
        low = buf.lower()
        for marker in markers:
            if marker in low:
                return marker, buf
    return None, buf


def drain(sock, seconds):
    out = b""
    deadline = time.time() + seconds
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out


def main(argv):
    wait = 1.0
    args = argv[1:]
    if len(args) >= 2 and args[0] == "--wait":
        wait = float(args[1])
        args = args[2:]
    if not args:
        sys.stderr.write(__doc__)
        return 64
    enabled, port, password = settings()
    if not enabled:
        return 2
    try:
        sock = socket.create_connection((HOST, port), timeout=TIMEOUT)
    except OSError:
        return 4
    try:
        deadline = time.time() + TIMEOUT
        marker, _ = read_until(sock, [b"password:", b"press 'help'", b"logon successful"], deadline)
        if marker == b"password:":
            sock.sendall(password.encode("utf-8") + b"\r\n")
            marker, _ = read_until(sock, [b"logon successful", b"password incorrect", b"password:"], deadline)
            if marker != b"logon successful":
                return 3
        # No banner in time is not fatal: the console still takes commands.
        for command in args:
            sock.sendall(command.encode("utf-8") + b"\r\n")
        out = drain(sock, wait)
        try:
            sock.sendall(b"exit\r\n")
        except OSError:
            pass
        sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
        return 0
    except (OSError, ConnectionError):
        return 4
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
