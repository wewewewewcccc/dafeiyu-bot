#!/usr/bin/env python3
"""Read and group one local QQ conversation without changing the archive."""
import argparse
import itertools
import json
from pathlib import Path
import re
import sqlite3


def main():
    parser = argparse.ArgumentParser(description="查看当前机器人在一个会话中的同人对话分组")
    parser.add_argument("conversation", help="private:好友QQ号 或 group:群号")
    parser.add_argument("--limit", type=int, default=20, help="显示最近多少组，默认 20")
    parser.add_argument("--data-dir", type=Path, default=Path.home() / ".local/share/dafeiyu")
    args = parser.parse_args()
    if not re.fullmatch(r"(private|group):[0-9]+", args.conversation) or not 1 <= args.limit <= 200:
        parser.error("请提供会话类型和数字账号，limit 范围为 1–200")
    directory = args.data_dir.resolve()
    try:
        account = json.loads((directory / "qq-state.json").read_text())["config"]["expectedSelfID"]
        scope = account + ":" + args.conversation
        with sqlite3.connect((directory / "qq-history.sqlite3").as_uri() + "?mode=ro", uri=True) as db:
            rows = db.execute("""
                WITH scoped AS MATERIALIZED (
                    SELECT * FROM history_turn_rows WHERE scope=? AND time >= strftime('%s','now') - 365*86400
                ), latest AS (
                    SELECT turn FROM scoped GROUP BY turn ORDER BY max(position) DESC LIMIT ?
                )
                SELECT turn,speaker,time,id,text FROM scoped WHERE turn IN (SELECT turn FROM latest)
                ORDER BY turn,position
            """, (scope, args.limit))
            for _, entries in itertools.groupby(rows, lambda row: row[0]):
                entries = list(entries)
                print(json.dumps({"speaker": entries[0][1], "start": entries[0][2], "end": entries[-1][2],
                                  "messages": [{"time": time, "id": id, "text": text} for _, _, time, id, text in entries]},
                                 ensure_ascii=False))
    except (OSError, ValueError, KeyError, sqlite3.Error):
        parser.exit(1, "无法读取分组历史库，请先运行新版大肥鱼并连接 QQ。\n")


if __name__ == "__main__":
    main()
