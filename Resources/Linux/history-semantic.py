#!/usr/bin/env python3
"""Bounded offline inference for the QQ history archive."""
import json
import pathlib
import sqlite3
import sys

BASE_MODEL = "multilingual-e5-small:int8:761b726"
MODEL = BASE_MODEL + ":turn-v1"


class Encoder:
    def __init__(self, directory):
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.np = np
        self.tokenizer = Tokenizer.from_file(str(directory / "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=256)
        self.tokenizer.enable_padding(pad_id=1, pad_token="<pad>")
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(directory / "model.onnx"), options, providers=["CPUExecutionProvider"])
        self.inputs = {item.name for item in self.session.get_inputs()}

    def encode(self, texts, prefix):
        np = self.np
        tokens = self.tokenizer.encode_batch([prefix + text for text in texts])
        mask = np.array([t.attention_mask for t in tokens], dtype=np.int64)
        values = {
            "input_ids": np.array([t.ids for t in tokens], dtype=np.int64),
            "attention_mask": mask,
            "token_type_ids": np.array([t.type_ids for t in tokens], dtype=np.int64),
        }
        (hidden, *_) = self.session.run(None, {k: v for k, v in values.items() if k in self.inputs})
        pooled = (hidden * mask[..., None]).sum(axis=1) / mask.sum(axis=1)[:, None]
        return (pooled / np.maximum(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-12)).astype("<f4")


def index(db, scope, directory):
    rows = db.execute("""
        WITH passages AS (
            SELECT archive_row,text,time,
                   lag(text,2) OVER (PARTITION BY turn ORDER BY position) AS earlier,
                   lag(text) OVER (PARTITION BY turn ORDER BY position) AS previous
            FROM history_turn_rows WHERE scope=?
        )
        SELECT p.archive_row,p.text,p.earlier,p.previous FROM passages p
        LEFT JOIN history_vectors v ON v.message=p.archive_row AND v.model=?
        WHERE v.message IS NULL ORDER BY p.time DESC,p.archive_row DESC LIMIT 48
    """, (scope, MODEL)).fetchall()
    if not rows:
        return 0
    encoder = Encoder(directory)
    for start in range(0, len(rows), 16):
        chunk = rows[start:start + 16]
        passages = ["\n".join(part[:85] for part in (earlier, previous) if part) +
                    ("\n" if previous else "") + text[:350] for _, text, earlier, previous in chunk]
        vectors = encoder.encode(passages, "passage: ")
        with db:
            db.executemany("""
                INSERT OR REPLACE INTO history_vectors(message,model,embedding)
                SELECT rowid,?,? FROM messages WHERE rowid=? AND scope=? AND text=?
            """, ((MODEL, vector.tobytes(), row, scope, text) for (row, text, _, _), vector in zip(chunk, vectors)))
    return len(rows)


def retrieve(db, scope, directory, request):
    rows = db.execute("""
        SELECT m.id, m.text, v.embedding FROM history_vectors v JOIN messages m ON m.rowid=v.message
        WHERE m.scope=? AND v.model IN (?,?) AND m.time>=? AND m.time<?
        ORDER BY m.time DESC LIMIT 20000
    """, (scope, BASE_MODEL, MODEL, request["from"], request["through"])).fetchall()
    excluded = set(request["excluded"])
    unique = {}
    for message, text, vector in rows:
        if message not in excluded and len(vector) == 384 * 4:
            unique.setdefault(text, (message, vector))
    rows = list(unique.values())
    if not rows:
        return []
    encoder = Encoder(directory)
    query = encoder.encode([request["text"]], "query: ")[0]
    np = encoder.np
    vectors = np.frombuffer(b"".join(vector for _, vector in rows), dtype="<f4").reshape(-1, 384)
    scores = vectors @ query
    order = np.argsort(-scores, kind="stable")
    # E5 similarities are concentrated near the upper end of the cosine scale.
    threshold = max(.865, float(scores[order[0]]) - .055)
    return [rows[i][0] for i in order[:6] if scores[i] >= threshold]


def main():
    mode, database, directory = sys.argv[1:]
    request = json.loads(sys.stdin.buffer.read(32769))
    scope = request["scope"]
    database = pathlib.Path(database)
    url = database.as_uri() + ("?mode=rw" if mode == "index" else "?mode=ro")
    with sqlite3.connect(url, uri=True, timeout=1) as db:
        result = index(db, scope, pathlib.Path(directory)) if mode == "index" else retrieve(db, scope, pathlib.Path(directory), request)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
