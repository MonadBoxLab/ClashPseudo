#!/usr/bin/env python3
"""Public entry point for project tools, supporting Python isolated mode and any working directory."""
from pathlib import Path
import sys


def main():
    # Resolve project packages from this repository, not the working directory or PYTHONPATH.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tool.cli import main as run
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
