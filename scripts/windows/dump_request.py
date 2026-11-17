"""Write the MXC request `MXCSandbox` would send for one harmless command.

Used by `run-windows-tests.ps1` so the executor can be called directly with
the real policy, which makes host problems visible without any package logic
in between.

Usage: python dump_request.py ROOT_DIR OUTPUT_JSON
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from langchain_mxc import MXCSandbox


def main() -> int:
    root_dir, output = sys.argv[1], Path(sys.argv[2])
    backend = MXCSandbox(root_dir=root_dir)
    request = backend.build_request("echo mxc-kit-hello")
    output.write_text(json.dumps(request, indent=2), encoding="utf-8")
    print(json.dumps(request, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
