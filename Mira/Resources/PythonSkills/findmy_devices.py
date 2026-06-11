#!/usr/bin/env python3
"""
List devices registered in FindMy by reading Apple's Biome database.
The Biome DB stores device identity (names, owners) but NOT real-time locations —
those require Apple's private FindMy framework (restricted entitlement).

No external deps — stdlib only.

Args JSON (stdin):
  {}          → list all devices

Output JSON:
  {success: true, devices: [{name, owner_first, owner_last}], total: N}
  {success: false, error: "..."}
"""
import sys, json, os, sqlite3

BIOME_DB = os.path.expanduser(
    "~/Library/Biome/sets/Default/FindMy.Device/Database/Set.db"
)


def decode_varint(data: bytes, pos: int):
    result, shift = 0, 0
    while pos < len(data):
        b = data[pos]; pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, pos


def decode_len_delimited(data: bytes, pos: int):
    length, pos = decode_varint(data, pos)
    return data[pos:pos + length], pos + length


def parse_device_proto(blob: bytes) -> dict:
    """Minimal protobuf decoder for the FindMy device blob."""
    device_name, owner_first, owner_last = "", "", ""
    pos = 0
    while pos < len(blob):
        if pos >= len(blob):
            break
        tag_byte, pos = decode_varint(blob, pos)
        field = tag_byte >> 3
        wire = tag_byte & 0x07

        if wire == 2:  # length-delimited
            value, pos = decode_len_delimited(blob, pos)
            if field == 1:
                try:
                    device_name = value.decode("utf-8")
                except Exception:
                    pass
            elif field == 2:
                # Nested owner message: field 1 = first name, field 2 = last name
                inner_pos = 0
                while inner_pos < len(value):
                    try:
                        inner_tag, inner_pos = decode_varint(value, inner_pos)
                        inner_field = inner_tag >> 3
                        inner_wire = inner_tag & 0x07
                        if inner_wire == 2:
                            inner_val, inner_pos = decode_len_delimited(value, inner_pos)
                            if inner_field == 1:
                                owner_first = inner_val.decode("utf-8", errors="replace")
                            elif inner_field == 2:
                                owner_last = inner_val.decode("utf-8", errors="replace")
                        elif inner_wire == 0:
                            _, inner_pos = decode_varint(value, inner_pos)
                        else:
                            break
                    except Exception:
                        break
        elif wire == 0:
            _, pos = decode_varint(blob, pos)
        elif wire == 5:
            pos += 4
        elif wire == 1:
            pos += 8
        else:
            break

    return {"name": device_name, "owner_first": owner_first, "owner_last": owner_last}


def main():
    try:
        json.load(sys.stdin)
    except Exception:
        pass

    if not os.path.exists(BIOME_DB):
        print(json.dumps({
            "success": False,
            "error": (
                "FindMy Biome database not found. "
                "Ensure FindMy has been used on this Mac at least once."
            )
        }))
        return

    try:
        db = sqlite3.connect(f"file:{BIOME_DB}?mode=ro", uri=True)
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))
        return

    try:
        rows = db.execute("SELECT content FROM content").fetchall()
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))
        return
    finally:
        db.close()

    devices = []
    seen = set()
    for (blob,) in rows:
        if not blob:
            continue
        info = parse_device_proto(bytes(blob))
        name = info["name"].strip()
        if not name or name in ("single", "left", "right"):
            continue
        if name in seen:
            continue
        seen.add(name)
        devices.append(info)

    print(json.dumps({
        "success": True,
        "devices": devices,
        "total": len(devices),
        "note": (
            "Device list only — real-time location data is protected by Apple "
            "and cannot be read by third-party apps. To see locations, open "
            "FindMy.app directly or ask Mira to screenshot it."
        )
    }))


main()
