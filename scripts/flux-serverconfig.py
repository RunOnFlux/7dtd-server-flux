#!/usr/bin/env python3
"""Reads and writes the 7 Days to Die serverconfig.xml the server is started with.

    flux-serverconfig.py apply <file>        apply the environment to the file, print what changed
    flux-serverconfig.py get <file> <name>   print one property's value (exit 1 if not set)

WHAT `apply` DOES, in this order, every start:

  1. SDTD_<Property>=<value> environment variables. SDTD_ServerMaxPlayerCount=16 sets
     <property name="ServerMaxPlayerCount" value="16" />. This is how a marketplace tier sets its
     own values: a config's `commands` never reach the container on Flux, its environment does.
     A property the file does not have yet is added. The environment wins over an edit in the
     file, for the properties it names; every other property stays as the owner left it.
  2. What the image itself needs: UserDataFolder on the data volume (saves and generated worlds
     live there, not in the install), and telnet on, which the supervisor uses to save on stop
     and to warn players before a restart. Telnet with no TelnetPassword only listens on the
     loopback, and the image never publishes its port.
  3. FLUX_CROSSPLAY=true: the rules The Fun Pimps set for PS5 and Xbox players to see and join a
     dedicated server (V3): crossplay on, EAC on, EOS sanctions honoured, public, at most 8
     players, a generated world of at most 8192. They are applied last so that nothing above,
     not even an SDTD_ variable, can make a crossplay server invisible to consoles. Past 8
     players the game gives no error at all: the server just stops being listed on consoles.

THE FILE IS EDITED, NOT REGENERATED. Only the value="" of the properties above is replaced, in
place, so comments, order and every other edit survive. Commented-out properties
(<!-- <property name="UserDataFolder" ... /> -->, as the game ships them) are never matched.
"""
import os
import re
import sys

PROPERTY = re.compile(r'<property\s+name="([^"]*)"\s+value="([^"]*)"\s*/>')
COMMENT = re.compile(r"<!--.*?-->", re.S)
NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
ENV_PREFIX = "SDTD_"

CROSSPLAY_MAX_PLAYERS = 8
CROSSPLAY_MAX_WORLD = 8192


def truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def escape(value):
    return (
        value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    )


def unescape(value):
    return (
        value.replace("&quot;", '"').replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
    )


def active(text):
    """{name: match} for every property outside a comment. The last one wins, as in the game."""
    comments = [m.span() for m in COMMENT.finditer(text)]
    found = {}
    for m in PROPERTY.finditer(text):
        if not any(a <= m.start() < b for a, b in comments):
            found[m.group(1)] = m
    return found


def get(text, name):
    m = active(text).get(name)
    return None if m is None else unescape(m.group(2))


def put(text, name, value):
    m = active(text).get(name)
    if m is not None:
        return text[: m.start(2)] + escape(value) + text[m.end(2) :]
    # The game ships the file with CRLF line ends; an added line follows whatever the file uses.
    eol = "\r\n" if "\r\n" in text else "\n"
    line = '\t<property name="%s" value="%s" />%s' % (name, escape(value), eol)
    end = text.rfind("</ServerSettings>")
    if end == -1:
        raise ValueError("no </ServerSettings> in the file")
    # At the start of the closing tag's line, so the new property gets a line of its own.
    start = text.rfind("\n", 0, end) + 1
    if text[start:end].strip():
        start = end
        line = eol + line
    return text[:start] + line + text[start:]


def as_int(value, default):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def plan(text, env, data_dir):
    """The (name, value, why) the environment asks for, in the order they are applied."""
    wanted = []
    for key in sorted(env):
        if not key.startswith(ENV_PREFIX):
            continue
        name, value = key[len(ENV_PREFIX) :], env[key]
        if not NAME.match(name):
            wanted.append((name, None, "skipped: %s is not a property name" % key))
        elif "\n" in value or "\r" in value:
            wanted.append((name, None, "skipped: %s has a line break" % key))
        else:
            wanted.append((name, value, key))

    wanted.append(("UserDataFolder", data_dir, "the image keeps saves on the data volume"))
    wanted.append(("TelnetEnabled", "true", "the image saves on stop over telnet"))

    if truthy(env.get("FLUX_CROSSPLAY")):
        why = "FLUX_CROSSPLAY"
        wanted.append(("ServerAllowCrossplay", "true", why))
        wanted.append(("EACEnabled", "true", why))
        wanted.append(("IgnoreEOSSanctions", "false", why))
        wanted.append(("ServerVisibility", "2", why))
        # What the steps above leave, not what the file had: an SDTD_ value is clamped too.
        current = dict((n, v) for n, v, _ in wanted if v is not None)
        players = as_int(current.get("ServerMaxPlayerCount", get(text, "ServerMaxPlayerCount")), 8)
        if players > CROSSPLAY_MAX_PLAYERS or players < 1:
            wanted.append(("ServerMaxPlayerCount", str(CROSSPLAY_MAX_PLAYERS), why + ", 8 players at most"))
        size = as_int(current.get("WorldGenSize", get(text, "WorldGenSize")), 0)
        if size > CROSSPLAY_MAX_WORLD:
            wanted.append(("WorldGenSize", str(CROSSPLAY_MAX_WORLD), why + ", a world of 8192 at most"))
    return wanted


def shown(name, value):
    return "(hidden)" if "password" in name.lower() else value


def apply(path, env, data_dir):
    with open(path, encoding="utf-8-sig") as f:
        raw = f.read()
    with open(path, "rb") as f:
        bom = f.read(3) == b"\xef\xbb\xbf"
    # Later steps override earlier ones, so only each property's final value is written and
    # reported: a crossplay tier with SDTD_ServerMaxPlayerCount=16 logs 8, never 16 then 8.
    final = {}
    for name, value, why in plan(raw, env, data_dir):
        if value is None:
            print("WARN %s" % why)
        else:
            final.pop(name, None)
            final[name] = (value, why)
    text = raw
    for name, (value, why) in final.items():
        if get(text, name) == value:
            continue
        text = put(text, name, value)
        print("%s=%s (%s)" % (name, shown(name, value), why))
    if text != raw:
        tmp = path + ".flux-tmp"
        with open(tmp, "w", encoding="utf-8-sig" if bom else "utf-8") as f:
            f.write(text)
        os.replace(tmp, path)


def main(argv):
    if len(argv) >= 3 and argv[1] == "apply":
        apply(argv[2], os.environ, os.environ.get("FLUX_DATA_DIR", "/mnt/7dtd/data"))
        return 0
    if len(argv) == 4 and argv[1] == "get":
        with open(argv[2], encoding="utf-8-sig") as f:
            value = get(f.read(), argv[3])
        if value is None:
            return 1
        print(value)
        return 0
    sys.stderr.write(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
