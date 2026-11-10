"""Single-process, durable shared-canvas server. Run behind TLS/Cloudflare Tunnel."""
import asyncio
import copy
import hashlib
import hmac
import json
import logging
import math
import os
import re
import sqlite3
from pathlib import Path

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

LOG = logging.getLogger("canvas")


def empty_document(host):
    return dict(width=2048, height=2736, layers=[], strokes=[], revision=0, hostID=host)


def identifier(value):
    return isinstance(value, str) and 0 < len(value) <= 128


def number(value, low, high):
    return type(value) in (int, float) and math.isfinite(value) and low <= value <= high


def points_valid(points):
    return (isinstance(points, list) and 0 < len(points) <= 256
            and len({p.get("id") for p in points if isinstance(p, dict)}) == len(points)
            and all(isinstance(p, dict) and identifier(p.get("id"))
                    and number(p.get("x"), -8192, 16384) and number(p.get("y"), -8192, 16384)
                    and number(p.get("pressure"), 0, 1) for p in points))


def apply(document, op, author, name):
    """Validate before mutation. Canonicalize authors and never accept client visibility/history."""
    if not isinstance(op, dict) or not identifier(op.get("id")):
        raise ValueError("Invalid operation ID")
    if op.get("authorID") != author:
        raise ValueError("Operation author does not match your identity")
    kind = op.get("kind")
    layer = next((x for x in document["layers"] if x["id"] == op.get("layerID")), None)
    stroke = next((x for x in document["strokes"] if x["id"] == op.get("strokeID")), None)
    if kind == "addLayer":
        candidate = op.get("layer", {})
        if (not isinstance(candidate, dict) or not identifier(candidate.get("id"))
                or candidate.get("ownerID") != author
                or not isinstance(candidate.get("name"), str) or not 0 < len(candidate["name"]) <= 100
                or any(x["id"] == candidate["id"] for x in document["layers"])
                or len(document["layers"]) >= 256):
            raise ValueError("Invalid layer or layer limit reached")
        canonical = dict(id=candidate["id"], ownerID=author, ownerName=name,
                         name=candidate["name"], visible=True)
        document["layers"].append(canonical)
        op["layer"] = copy.deepcopy(canonical)
    elif kind == "beginStroke":
        candidate = op.get("stroke", {})
        if not isinstance(candidate, dict):
            raise ValueError("Invalid stroke")
        target = next((x for x in document["layers"] if x["id"] == candidate.get("layerID")), None)
        color = candidate.get("color", {})
        if (not target or target["ownerID"] != author or not target["visible"]
                or not identifier(candidate.get("id")) or candidate.get("authorID") != author
                or any(x["id"] == candidate["id"] for x in document["strokes"])
                or not number(candidate.get("width"), 0.5, 512)
                or not isinstance(color, dict) or not all(number(color.get(c), 0, 1) for c in ("red", "green", "blue", "alpha"))
                or not points_valid(candidate.get("points")) or len(document["strokes"]) >= 10000):
            raise ValueError("Invalid stroke, hidden/foreign layer, or document limit reached")
        canonical = dict(id=candidate["id"], layerID=target["id"], authorID=author,
                         color=color, width=candidate["width"], points=candidate["points"],
                         ended=False, visible=True, redoEligible=False, hiddenAt=0)
        for old in document["strokes"]:
            if old["authorID"] == author and not old["visible"]:
                old["redoEligible"] = False
        document["strokes"].append(canonical)
        op["stroke"] = copy.deepcopy(canonical)
    elif kind in ("samples", "endStroke", "strokeVisibility"):
        if not stroke or stroke["authorID"] != author:
            raise ValueError("You can edit only your own strokes")
        if kind == "samples":
            points = op.get("points")
            if not points_valid(points):
                raise ValueError("Invalid sample batch")
            indexes = {p["id"]: i for i, p in enumerate(stroke["points"])}
            new_count = sum(p["id"] not in indexes for p in points)
            if len(stroke["points"]) + new_count > 50000:
                raise ValueError("Stroke sample limit reached; begin another stroke")
            # Completed strokes accept corrections to existing samples, never new geometry.
            if stroke["ended"] and new_count:
                raise ValueError("Completed strokes accept only sample corrections")
            for point in points:
                if point["id"] in indexes:
                    stroke["points"][indexes[point["id"]]] = point
                else:
                    stroke["points"].append(point)
        elif kind == "endStroke":
            if stroke["ended"]:
                raise ValueError("Stroke already ended")
            stroke["ended"] = True
        else:
            visible = op.get("visible")
            if not stroke["ended"] or type(visible) is not bool or visible == stroke["visible"]:
                raise ValueError("Invalid undo/redo")
            if visible and not stroke["redoEligible"]:
                raise ValueError("Redo was cleared by a new stroke")
            stroke["visible"] = visible
            stroke["redoEligible"] = not visible
            stroke["hiddenAt"] = document["revision"] + 1
    elif kind == "layerVisibility":
        if not layer or layer["ownerID"] != author or type(op.get("visible")) is not bool:
            raise ValueError("You can change only your own layers")
        layer["visible"] = op["visible"]
    elif kind == "resize":
        if document["hostID"] != author:
            raise ValueError("Only the room host can resize the canvas")
        if not number(op.get("width"), 64, 8192) or not number(op.get("height"), 64, 8192):
            raise ValueError("Canvas dimensions must be between 64 and 8192")
        document["width"] = op["width"] = math.floor(op["width"] + 0.5)
        document["height"] = op["height"] = math.floor(op["height"] + 0.5)
    else:
        raise ValueError("Unknown operation")
    document["revision"] += 1


class Database:
    def __init__(self, path):
        self.connection = sqlite3.connect(path)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("CREATE TABLE IF NOT EXISTS rooms (id TEXT PRIMARY KEY, document TEXT NOT NULL)")
        self.connection.execute("CREATE TABLE IF NOT EXISTS operations (room TEXT, id TEXT, author TEXT, PRIMARY KEY(room,id))")

    def load(self, room, host):
        row = self.connection.execute("SELECT document FROM rooms WHERE id=?", (room,)).fetchone()
        if row:
            return json.loads(row[0])
        document = empty_document(host)
        with self.connection:
            self.connection.execute("INSERT INTO rooms VALUES (?,?)", (room, json.dumps(document)))
        return document

    def accepted(self, room, op_id, author):
        row = self.connection.execute("SELECT author FROM operations WHERE room=? AND id=?", (room, op_id)).fetchone()
        if row and row[0] != author:
            raise ValueError("Operation ID belongs to another participant")
        return row is not None

    def commit(self, room, document, op):
        with self.connection:
            self.connection.execute("UPDATE rooms SET document=? WHERE id=?", (json.dumps(document, allow_nan=False), room))
            self.connection.execute("INSERT INTO operations VALUES (?,?,?)", (room, op["id"], op["authorID"]))


class Peer:
    def __init__(self, socket, author, name):
        self.socket, self.author, self.name = socket, author, name
        self.queue = asyncio.Queue(maxsize=256)
        self.writer = asyncio.create_task(self.write())

    def push(self, message):
        try:
            self.queue.put_nowait(json.dumps(message, allow_nan=False))
        except asyncio.QueueFull:
            # A lagging client rejoins from a persisted snapshot; it cannot stall the room.
            asyncio.create_task(self.socket.close(code=1013, reason="Rejoin to catch up"))

    async def write(self):
        try:
            while True:
                await self.socket.send(await self.queue.get())
        except ConnectionClosed:
            pass


class CanvasServer:
    def __init__(self, database, token):
        self.database, self.token = database, token
        self.documents = {}
        self.peers = {}

    def broadcast(self, room, message):
        for peer in self.peers.get(room, set()):
            peer.push(message)

    async def handle(self, socket):
        peer = None
        room = None
        try:
            join = json.loads(await asyncio.wait_for(socket.recv(), timeout=10))
            if (not isinstance(join, dict) or join.get("type") != "join"
                    or not isinstance(join.get("token"), str)
                    or not hmac.compare_digest(join["token"], self.token)):
                await socket.send(json.dumps(dict(type="error", message="Invalid access token")))
                return
            room, key, name = join.get("room"), join.get("clientKey"), join.get("name", "Artist")
            if (not isinstance(room, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", room)
                    or not isinstance(key, str) or not 32 <= len(key) <= 256
                    or not isinstance(name, str) or not 0 < len(name) <= 40):
                await socket.send(json.dumps(dict(type="error", message="Invalid room, name, or participant key")))
                return
            author = hashlib.sha256(key.encode()).hexdigest()
            if room not in self.documents:
                self.documents[room] = self.database.load(room, author)
            document = self.documents[room]
            peers = self.peers.setdefault(room, set())
            if len(peers) >= 64:
                await socket.send(json.dumps(dict(type="error", message="Room is full (64 connections)")))
                return
            # A reconnect supersedes an old connection for this installation.
            for old in list(peers):
                if old.author == author:
                    peers.remove(old)
                    asyncio.create_task(old.socket.close(code=1000, reason="Reconnected"))
            peer = Peer(socket, author, name)
            pending = join.get("pendingIDs", [])
            if not isinstance(pending, list) or len(pending) > 100000 or not all(identifier(x) for x in pending):
                raise ValueError("Invalid pending operation list")
            accepted = [op_id for op_id in pending if self.database.accepted(room, op_id, author)]
            # Queue the snapshot before registering for broadcasts. No await => no join gap.
            peer.push(dict(type="snapshot", document=document, acceptedPendingIDs=accepted))
            peers.add(peer)
            async for raw in socket:
                op_id = None
                try:
                    message = json.loads(raw)
                    if not isinstance(message, dict):
                        raise ValueError("Expected a message object")
                    document = self.documents[room]
                    if message.get("type") == "operation":
                        op = message.get("operation")
                        if not isinstance(op, dict) or not identifier(op.get("id")):
                            raise ValueError("Invalid operation")
                        op_id = op["id"]
                        if self.database.accepted(room, op_id, author):
                            peer.push(dict(type="ack", id=op_id))
                            continue
                        # Failed edits never mutate canonical state, even if validation changes.
                        candidate = copy.deepcopy(document)
                        apply(candidate, op, author, name)
                        if len(json.dumps(candidate)) > 16 * 1024 * 1024:
                            raise ValueError("Canvas reached the 16 MiB document limit")
                        self.database.commit(room, candidate, op)
                        document = self.documents[room] = candidate
                        self.broadcast(room, dict(type="operation", operation=op, revision=document["revision"]))
                    elif message.get("type") == "presence":
                        presence = message.get("presence", {})
                        layer_id = presence.get("layerID") if isinstance(presence, dict) else None
                        valid_layer = next((x for x in document["layers"] if x["id"] == layer_id and x["ownerID"] == author), None)
                        self.broadcast(room, dict(type="presence", presence=dict(authorID=author, name=name,
                                       layerID=layer_id if valid_layer else None,
                                       drawing=bool(presence.get("drawing")) if valid_layer else False)))
                    else:
                        raise ValueError("Unknown message type")
                except (ValueError, TypeError, KeyError) as error:
                    peer.push(dict(type="error", id=op_id, message=str(error)))
        except (ConnectionClosed, asyncio.TimeoutError):
            pass
        except (ValueError, TypeError, KeyError) as error:
            if peer:
                peer.push(dict(type="error", message=str(error)))
        finally:
            if peer:
                peers = self.peers.get(room, set())
                was_current = peer in peers
                peers.discard(peer)
                if was_current:
                    self.broadcast(room, dict(type="presence", presence=dict(authorID=peer.author, name=peer.name, layerID=None, drawing=False)))
                peer.writer.cancel()
                await asyncio.gather(peer.writer, return_exceptions=True)


async def main():
    token = os.environ.get("CANVAS_TOKEN", "")
    if len(token) < 24:
        raise SystemExit("Set CANVAS_TOKEN to a random secret of at least 24 characters")
    path = Path(os.environ.get("CANVAS_DB", "/data/canvas.sqlite3"))
    path.parent.mkdir(parents=True, exist_ok=True)
    server = CanvasServer(Database(path), token)
    async with serve(server.handle, "0.0.0.0", 8765, max_size=262144, max_queue=16,
                     ping_interval=20, ping_timeout=20, compression=None):
        LOG.info("Canvas server listening on port 8765")
        await asyncio.Future()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
