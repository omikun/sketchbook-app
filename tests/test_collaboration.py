"""Exercise the actual WebSocket service with independent client connections."""
import asyncio
import copy
import hashlib
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from server import CanvasServer, Database
from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

TOKEN = "test-token-with-at-least-24-characters"


def uid():
    return str(uuid.uuid4())


class CollaborationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.temp.name) / "canvas.sqlite3")
        self.database = Database(self.path)
        self.app = CanvasServer(self.database, TOKEN)
        self.server = await serve(self.app.handle, "127.0.0.1", 0)
        self.url = "ws://127.0.0.1:" + str(self.server.sockets[0].getsockname()[1])
        self.clients = []

    async def asyncTearDown(self):
        for client in self.clients:
            await client.close()
        self.server.close(); await self.server.wait_closed()
        self.database.connection.close(); self.temp.cleanup()

    async def join(self, index, pending=None, token=TOKEN):
        client = await connect(self.url, proxy=None)
        self.clients.append(client)
        key = str(index) * 64
        author = hashlib.sha256(key.encode()).hexdigest()
        await client.send(json.dumps(dict(type="join", room="test", token=token, clientKey=key,
                                         name="Artist " + str(index), pendingIDs=pending or [])))
        snapshot = await self.read(client, "snapshot" if token == TOKEN else "error")
        return client, author, snapshot

    async def read(self, client, kind):
        async with asyncio.timeout(3):
            while True:
                message = json.loads(await client.recv())
                if message["type"] == kind:
                    return message

    async def edit(self, client, author, kind, **fields):
        op = dict(id=uid(), kind=kind, authorID=author, **fields)
        await client.send(json.dumps(dict(type="operation", operation=op)))
        return op

    async def add_stroke(self, client, author, layer):
        stroke = dict(id=uid(), layerID=layer, authorID=author, width=16,
                      color=dict(red=0.2, green=0.4, blue=0.7, alpha=1),
                      points=[dict(id=uid(), x=100, y=100, pressure=1)], ended=False,
                      visible=True, redoEligible=False, hiddenAt=0)
        await self.edit(client, author, "beginStroke", stroke=stroke)
        await self.read(client, "operation")
        await self.edit(client, author, "endStroke", strokeID=stroke["id"])
        await self.read(client, "operation")
        return stroke

    async def test_many_clients_permissions_undo_resize_and_recovery(self):
        # More than two participants, each drawing independently.
        participants = [await self.join(i) for i in range(1, 5)]
        layers = []
        for client, author, _ in participants:
            layer = dict(id=uid(), ownerID=author, ownerName="Artist", name="My layer", visible=True)
            await self.edit(client, author, "addLayer", layer=layer)
            layers.append(layer["id"])
            for recipient, _, _ in participants:
                event = await self.read(recipient, "operation")
                self.assertEqual(event["operation"]["layer"]["id"], layer["id"])
        for (client, author, _), layer in zip(participants, layers):
            await client.send(json.dumps(dict(type="presence", presence=dict(layerID=layer, drawing=True))))
        observed = set()
        while len(observed) < 4:
            observed.add((await self.read(participants[0][0], "presence"))["presence"]["authorID"])
        self.assertEqual(len(observed), 4)
        strokes = []
        for (client, author, _), layer in zip(participants, layers):
            stroke = await self.add_stroke(client, author, layer)
            strokes.append(stroke)
            for other, _, _ in participants:
                if other != client:
                    await self.read(other, "operation"); await self.read(other, "operation")
        host, host_id, _ = participants[0]
        guest, guest_id, _ = participants[1]
        await self.edit(guest, guest_id, "strokeVisibility", strokeID=strokes[0]["id"], visible=False)
        self.assertIn("own strokes", (await self.read(guest, "error"))["message"])
        await self.edit(guest, guest_id, "resize", width=64, height=64)
        self.assertIn("host", (await self.read(guest, "error"))["message"])
        await self.edit(host, host_id, "strokeVisibility", strokeID=strokes[0]["id"], visible=False)
        for client, _, _ in participants:
            await self.read(client, "operation")
        self.assertTrue(all(s["visible"] for s in self.app.documents["test"]["strokes"][1:]))
        await self.edit(host, host_id, "strokeVisibility", strokeID=strokes[0]["id"], visible=True)
        for client, _, _ in participants:
            await self.read(client, "operation")
        before = copy.deepcopy(self.app.documents["test"]["strokes"])
        resize = await self.edit(host, host_id, "resize", width=64, height=128)
        for client, _, _ in participants:
            await self.read(client, "operation")
        self.assertEqual(before, self.app.documents["test"]["strokes"])
        await host.close()
        rejoined, _, snapshot = await self.join(1, pending=[resize["id"]])
        self.assertEqual(snapshot["acceptedPendingIDs"], [resize["id"]])
        self.assertEqual(snapshot["document"]["width"], 64)
        await rejoined.send(json.dumps(dict(type="operation", operation=resize)))
        self.assertEqual((await self.read(rejoined, "ack"))["id"], resize["id"])
        revision = snapshot["document"]["revision"]
        # Recreate the service and database: accepted edits and deduplication survive restart.
        for client in self.clients:
            await client.close()
        self.server.close(); await self.server.wait_closed(); self.database.connection.close()
        self.database = Database(self.path); self.app = CanvasServer(self.database, TOKEN)
        self.server = await serve(self.app.handle, "127.0.0.1", 0)
        self.url = "ws://127.0.0.1:" + str(self.server.sockets[0].getsockname()[1])
        _, _, restored = await self.join(1, pending=[resize["id"]])
        self.assertEqual(restored["document"]["revision"], revision)
        self.assertEqual(restored["document"]["strokes"], before)
        self.assertEqual(restored["acceptedPendingIDs"], [resize["id"]])

    async def test_auth_and_invalid_samples_do_not_change_document(self):
        _, _, rejected = await self.join(1, token="wrong")
        self.assertEqual(rejected["type"], "error")
        client, author, _ = await self.join(1)
        layer = dict(id=uid(), ownerID=author, ownerName="Artist", name="Layer", visible=True)
        await self.edit(client, author, "addLayer", layer=layer); await self.read(client, "operation")
        stroke = await self.add_stroke(client, author, layer["id"])
        before = copy.deepcopy(self.app.documents["test"])
        await self.edit(client, author, "samples", strokeID=stroke["id"],
                        points=[dict(id=uid(), x=300, y=300, pressure=1)])
        self.assertIn("corrections", (await self.read(client, "error"))["message"])
        self.assertEqual(self.app.documents["test"], before)
        point = dict(stroke["points"][0], pressure=0.3)
        await self.edit(client, author, "samples", strokeID=stroke["id"], points=[point])
        await self.read(client, "operation")
        self.assertEqual(len(self.app.documents["test"]["strokes"][0]["points"]), 1)
        self.assertEqual(self.app.documents["test"]["strokes"][0]["points"][0]["pressure"], 0.3)

    async def test_pressure_dynamics_survive_broadcast_and_storage(self):
        host, author, _ = await self.join(1)
        guest, _, _ = await self.join(2)
        layer = dict(id=uid(), ownerID=author, name="Pressure", visible=True)
        await self.edit(host, author, "addLayer", layer=layer)
        await self.read(host, "operation"); await self.read(guest, "operation")
        dynamics = dict(size=dict(minimum=0.1, maximum=0.9, exponent=2),
                        opacity=dict(minimum=0, maximum=0.8, exponent=0.5))
        stroke = dict(id=uid(), layerID=layer["id"], authorID=author, width=32,
                      color=dict(red=0.2, green=0.3, blue=0.4, alpha=1),
                      points=[dict(id=uid(), x=100, y=100, pressure=0.4)], dynamics=dynamics, maxOpacity=True)
        await self.edit(host, author, "beginStroke", stroke=stroke)
        for peer in (host, guest):
            event = await self.read(peer, "operation")
            self.assertEqual(event["operation"]["stroke"]["dynamics"], dynamics)
            self.assertIs(event["operation"]["stroke"]["maxOpacity"], True)
        self.assertEqual(self.database.load("test", author)["strokes"][0]["dynamics"], dynamics)
        self.assertIs(self.database.load("test", author)["strokes"][0]["maxOpacity"], True)
        before = copy.deepcopy(self.app.documents["test"])
        for flag in ("max", 1, [], {}):
            candidate = copy.deepcopy(stroke); candidate["id"] = uid(); candidate["maxOpacity"] = flag
            await self.edit(host, author, "beginStroke", stroke=candidate)
            await self.read(host, "error")
            self.assertEqual(self.app.documents["test"], before)
        for bad in (dict(minimum=0.9, maximum=0.1, exponent=1),
                    dict(minimum=0, maximum=1, exponent=0),
                    dict(minimum=0, maximum=1, exponent=True)):
            candidate = copy.deepcopy(stroke)
            candidate["id"] = uid(); candidate["dynamics"]["size"] = bad
            await self.edit(host, author, "beginStroke", stroke=candidate)
            await self.read(host, "error")
            self.assertEqual(self.app.documents["test"], before)
        _, _, snapshot = await self.join(3)
        self.assertEqual(snapshot["document"]["strokes"][0]["dynamics"], dynamics)

    async def test_paper_color_is_shared_durable_and_host_owned(self):
        host, author, _ = await self.join(1)
        guest, guest_id, _ = await self.join(2)
        color = dict(red=0.15, green=0.2, blue=0.25, alpha=1)
        before = copy.deepcopy(self.app.documents["test"])
        await self.edit(guest, guest_id, "background", color=color)
        self.assertIn("host", (await self.read(guest, "error"))["message"])
        self.assertEqual(self.app.documents["test"], before)
        await self.edit(host, author, "background", color=color)
        for peer in (host, guest):
            self.assertEqual((await self.read(peer, "operation"))["operation"]["color"], color)
        self.assertEqual(self.database.load("test", author)["background"], color)
        before = copy.deepcopy(self.app.documents["test"])
        for invalid in (dict(color, alpha=0.5), dict(color, red=2), dict(color, blue=True)):
            await self.edit(host, author, "background", color=invalid)
            await self.read(host, "error")
            self.assertEqual(self.app.documents["test"], before)
        _, _, snapshot = await self.join(3)
        self.assertEqual(snapshot["document"]["background"], color)

    async def test_eraser_strokes_are_owned_shared_undoable_and_durable(self):
        host, author, _ = await self.join(1)
        guest, guest_id, _ = await self.join(2)
        layer = dict(id=uid(), ownerID=author, name="Eraser layer", visible=True)
        await self.edit(host, author, "addLayer", layer=layer)
        await self.read(host, "operation"); await self.read(guest, "operation")
        eraser = dict(id=uid(), layerID=layer["id"], authorID=author, tool="eraser", width=64,
                      color=dict(red=0, green=0, blue=0, alpha=0.5), maxOpacity=True,
                      points=[dict(id=uid(), x=120, y=120, pressure=0.8)])
        before = copy.deepcopy(self.app.documents["test"])
        foreign = copy.deepcopy(eraser); foreign["authorID"] = guest_id
        await self.edit(guest, guest_id, "beginStroke", stroke=foreign)
        await self.read(guest, "error")
        self.assertEqual(self.app.documents["test"], before)
        for invalid_tool in ("paint-over", 1, False, []):
            invalid = copy.deepcopy(eraser); invalid["id"] = uid(); invalid["tool"] = invalid_tool
            await self.edit(host, author, "beginStroke", stroke=invalid)
            await self.read(host, "error")
            self.assertEqual(self.app.documents["test"], before)
        await self.edit(host, author, "beginStroke", stroke=eraser)
        for peer in (host, guest):
            stroke = (await self.read(peer, "operation"))["operation"]["stroke"]
            self.assertEqual(stroke["tool"], "eraser"); self.assertEqual(stroke["color"]["alpha"], 0.5)
        await self.edit(host, author, "endStroke", strokeID=eraser["id"])
        await self.read(host, "operation"); await self.read(guest, "operation")
        for visible in (False, True):
            await self.edit(host, author, "strokeVisibility", strokeID=eraser["id"], visible=visible)
            await self.read(host, "operation"); await self.read(guest, "operation")
            self.assertEqual(self.app.documents["test"]["strokes"][0]["visible"], visible)
        self.assertEqual(self.database.load("test", author)["strokes"][0]["tool"], "eraser")
        _, _, snapshot = await self.join(3)
        self.assertEqual(snapshot["document"]["strokes"][0]["tool"], "eraser")


if __name__ == "__main__":
    unittest.main()
