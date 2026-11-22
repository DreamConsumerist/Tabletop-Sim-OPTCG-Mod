#!/usr/bin/env python3
"""
Live link to a running Tabletop Simulator instance via its External Editor
API (the same local protocol the official VS Code/Atom extensions use).

This is NOT a persistent streaming socket in either direction -- each
message is its own one-shot TCP connection: the sender connects, writes one
JSON message, and closes; the receiver reads until EOF and treats that as
one complete message. So this tool runs a small TCP server (listening on
the port TTS pushes to) and, separately, opens one-shot connections to send
requests into the running game.

Ports (fixed by TTS, not configurable):
  39999 <- TTS listens here for requests from the editor (us)
  39998 <- we listen here for pushes from TTS (print/error/custom messages,
           "game saved" notifications, script dumps, etc.)

Commands:
  listen                      Run the listener, appending every message TTS
                               sends to tts_debug.log (and stdout). This is
                               what gives us live print()/error/chat-like
                               visibility instead of manual copy-paste.
  request-scripts             One-shot: ask TTS to push every object's
                               current Lua script (arrives via `listen`).
  exec <guid> <script...>     One-shot: execute a Lua snippet on a live
                               object (guid "-1" targets Global). Any
                               returned value comes back via `listen`.

TTS must have a save loaded and the game running for any of this to work --
there's no explicit "enable" toggle; TTS pushes to 39998 whenever something
is listening there, which is exactly what `listen` sets up.
"""
import json
import os
import socket
import sys
import threading
from datetime import datetime

EDITOR_PORT = 39998
GAME_PORT = 39999
LOG_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tts_debug.log")

MESSAGE_NAMES = {
    0: "PUSH_OBJECT",
    1: "LOADED_GAME",
    2: "PRINT",
    3: "ERROR",
    4: "CUSTOM_MESSAGE",
    5: "RETURN_VALUE",
    6: "GAME_SAVED",
    7: "OBJECT_CREATED",
}


def log(line):
    timestamp = datetime.now().strftime("%H:%M:%S")
    text = f"[{timestamp}] {line}"
    print(text, flush=True)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(text + "\n")


def describe(data):
    message_id = data.get("messageID")
    name = MESSAGE_NAMES.get(message_id, f"UNKNOWN({message_id})")

    if message_id == 2:
        return f"PRINT: {data.get('message')}"
    if message_id == 3:
        prefix = data.get("errorMessagePrefix", "")
        return f"ERROR [{data.get('guid')}]: {prefix}{data.get('error')}"
    if message_id == 4:
        return f"CUSTOM: {json.dumps(data.get('customMessage'))}"
    if message_id == 5:
        return f"RETURN VALUE: {json.dumps(data.get('returnValue'))}"
    if message_id == 6:
        return "GAME SAVED"
    if message_id == 7:
        return f"OBJECT CREATED: {data.get('guid')}"
    if message_id in (0, 1):
        states = data.get("scriptStates", [])
        names = ", ".join(s.get("name", "?") for s in states[:10])
        more = f" (+{len(states) - 10} more)" if len(states) > 10 else ""
        return f"{name}: {len(states)} script state(s): {names}{more}"
    return f"{name}: {json.dumps(data)[:500]}"


def handle_connection(conn):
    try:
        chunks = []
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        raw = b"".join(chunks).decode("utf-8", errors="replace")
        if not raw.strip():
            return
        try:
            data = json.loads(raw)
            log(describe(data))
        except json.JSONDecodeError:
            log(f"RAW (unparsed): {raw[:500]}")
    finally:
        conn.close()


def serve():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", EDITOR_PORT))
    server.listen(5)
    log(f"Listening on 127.0.0.1:{EDITOR_PORT} for messages from TTS (log: {LOG_PATH})")
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle_connection, args=(conn,), daemon=True).start()


def send_to_game(message_dict, timeout=3):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(("127.0.0.1", GAME_PORT))
    sock.sendall(json.dumps(message_dict).encode("utf-8"))
    sock.shutdown(socket.SHUT_WR)
    sock.close()


def main():
    if len(sys.argv) < 2 or sys.argv[1] == "listen":
        serve()
        return

    command = sys.argv[1]
    if command == "request-scripts":
        send_to_game({"messageID": 0})
        print("Sent 'Get Lua Scripts' request to TTS (reply arrives via `listen`).")
    elif command == "exec":
        if len(sys.argv) < 4:
            print("Usage: tts_live_console.py exec <guid> <script>", file=sys.stderr)
            sys.exit(1)
        guid = sys.argv[2]
        script = " ".join(sys.argv[3:])
        send_to_game({"messageID": 3, "guid": guid, "script": script})
        print(f"Sent execute request for GUID {guid} (any return value arrives via `listen`).")
    elif command == "save-and-play":
        # Pushes updated script source into the LIVE running game and
        # triggers TTS's own "Save & Play" (reload scripts), skipping the
        # file-based sync + manual in-game reload entirely. Deliberately
        # scoped: only the guid=path pairs given on the command line are
        # included in scriptStates, so only those objects' scripts change
        # -- never an implicit "push everything" that could blank out
        # scripts for objects not mentioned.
        if len(sys.argv) < 3:
            print("Usage: tts_live_console.py save-and-play <guid>=<path> [<guid>=<path> ...]", file=sys.stderr)
            sys.exit(1)
        script_states = []
        for pair in sys.argv[2:]:
            guid, path = pair.split("=", 1)
            with open(path, "r", encoding="utf-8") as f:
                script = f.read()
            script_states.append({"name": guid, "guid": guid, "script": script})
        send_to_game({"messageID": 1, "scriptStates": script_states})
        guids = ", ".join(s["guid"] for s in script_states)
        print(f"Sent Save & Play for GUID(s): {guids}")
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
