#!/usr/bin/env python3
"""项目工具的公共入口，支持 Python 隔离模式及任意工作目录。"""
from pathlib import Path
import sys


def main():
    # 只加入入口文件所属仓库，不使用调用目录或 PYTHONPATH 定位项目包。
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from tool.cli import main as run
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
