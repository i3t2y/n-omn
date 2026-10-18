#!/usr/bin/env python3
"""Assemble entrypoint.sh from ep_part_*.b64 next to this file."""
from pathlib import Path
import base64

def main() -> None:
    here = Path(__file__).resolve().parent
    parts = sorted(here.glob("ep_part_*.b64"), key=lambda p: int(p.stem.split("_")[-1]))
    if not parts:
        raise SystemExit("no ep_part_*.b64")
    raw = "".join(p.read_text().strip() for p in parts)
    data = base64.b64decode(raw)
    out = here / "entrypoint.sh"
    out.write_bytes(data)
    print(f"[assemble] {out} bytes={len(data)} from {len(parts)} parts")

if __name__ == "__main__":
    main()
