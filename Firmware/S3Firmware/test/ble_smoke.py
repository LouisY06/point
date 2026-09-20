"""Physical BLE bench check. Install bleak; pass --motor to request three finite pulses."""
import argparse
import asyncio
import struct
import math
from bleak import BleakClient, BleakScanner

SERVICE = "7f510001-1b15-4f0d-9e82-8a7c4d6e5f01"
COMMAND = "7f510002-1b15-4f0d-9e82-8a7c4d6e5f01"
STATUS = "7f510003-1b15-4f0d-9e82-8a7c4d6e5f01"

async def main(motor):
    devices = await BleakScanner.discover(timeout=8, service_uuids=[SERVICE])
    matches = [d for d in devices if d.name == "Point S3"]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one Point S3, found {[(d.name, d.address) for d in devices]}")
    queue = asyncio.Queue(maxsize=32)
    async with BleakClient(matches[0]) as client:
        def notified(_, data):
            if not queue.full(): queue.put_nowait(bytes(data))
        await client.start_notify(STATUS, notified)
        async def exchange(packet, prefix):
            await client.write_gatt_char(COMMAND, packet, response=True)
            async with asyncio.timeout(2):
                while True:
                    result = await queue.get()
                    if result.startswith(prefix): return result
        probe = b"P:point-s3-test"
        assert await exchange(probe, b"ACK:") == b"ACK:" + probe
        token = 100
        async def send(op, payload=b""):
            nonlocal token
            token += 1
            header = struct.pack("<BBBI", 0xA7, 1, op, token)
            prefix = struct.pack("<BBBI", 0xA7, 1, op | 0x80, token)
            return await exchange(header + payload, prefix)
        hello = await send(1)
        assert len(hello) == 8 and hello[7] == 31, hello.hex()
        print(f"Echo and negotiation passed; capabilities=0x{hello[7]:02x}", flush=True)
        stop = await send(3, bytes(4))
        assert stop[-1] == 0, stop.hex()
        for _ in range(10):
            reply = await send(4)
            assert len(reply) == 17 and reply[14] == 1, reply.hex()
            heading, accuracy, reference, age = struct.unpack("<HHBH", reply[7:14])
            assert heading < 36000 and age < 100, reply.hex()
            print(f"BNO heading={heading/100:.2f} accuracy={accuracy/100:.2f} ref={reference} age={age}ms cal=0x{reply[15]:02x} health=0x{reply[16]:02x}", flush=True)
            orientation = await send(5)
            assert len(orientation) == 20 and orientation[17] == 1, orientation.hex()
            q = [v / 16384 for v in struct.unpack("<hhhh", orientation[7:15])]
            norm = sum(v*v for v in q)
            age5 = struct.unpack("<H", orientation[15:17])[0]
            assert .90 <= norm <= 1.10 and age5 < 100, orientation.hex()
            w,x,y,z = q
            yaw = math.degrees(math.atan2(2*(w*z+x*y), 1-2*(y*y+z*z))) % 360
            print(f"Orientation WXYZ={q} norm²={norm:.4f} yaw={yaw:.2f} age={age5}ms cal=0x{orientation[18]:02x} health=0x{orientation[19]:02x}", flush=True)
            await asyncio.sleep(.1)
        if motor:
            assert hello[7] & 2, "Motor capability unavailable"
            for _ in range(3):
                ack = await send(3, struct.pack("<BHB", 1, 180, 160))
                assert ack[-1] == 0, ack.hex()
                await asyncio.sleep(1)
            print("Three finite motor requests accepted (physical vibration still needs observation).", flush=True)
        assert (await send(3, bytes(4)))[-1] == 0
    print("Disconnected cleanly.", flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--motor", action="store_true")
    asyncio.run(main(parser.parse_args().motor))
