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


if __name__ == "__main__":
    unittest.main()
