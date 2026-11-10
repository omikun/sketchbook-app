import asyncio
import os
import subprocess
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from server import CanvasServer, Database
from websockets.asyncio.server import serve

async def main():
    with tempfile.TemporaryDirectory() as directory:
        database = Database(str(Path(directory) / "canvas.sqlite3"))
        token = "native-test-token-at-least-24-characters"
        app = CanvasServer(database, token)
        async with serve(app.handle, "127.0.0.1", 0) as server:
            url = "ws://127.0.0.1:" + str(server.sockets[0].getsockname()[1])
            process = await asyncio.create_subprocess_exec(sys.argv[1], url, token)
            code = await process.wait()
        database.connection.close()
        if code:
            raise SystemExit(code)

asyncio.run(main())
