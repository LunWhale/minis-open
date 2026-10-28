#!/usr/bin/env python3
"""Reference implementation of wireToolId and generator for
wire_tool_id_vectors.json. Both platforms' tests read the JSON; this script
is the independent third implementation the expected values come from.

    python3 gen_vectors.py          # rewrite the JSON
    python3 gen_vectors.py --check  # verify the JSON matches this reference
"""
import hashlib, json, os, re, sys

CAP = 40
HASH_HEX = CAP - len("call_")  # 35


def hashed(raw: str) -> str:
    return "call_" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:HASH_HEX]


def wire_tool_id(raw: str) -> str:
    head = raw.split("|", 1)[0]
    # One "-" per Unicode code point (not per UTF-16 unit, not per grapheme).
    clean = "".join(c if re.fullmatch(r"[A-Za-z0-9_-]", c) else "-" for c in head)
    if not clean or len(clean) > CAP:
        return hashed(raw)
    return clean


RESP_CALL = "call_" + "Ab3dE5fG7hI9jK1lM3nO5pQ7"          # 29 chars, Responses shape
RESP_FC = "fc_" + "0123456789abcdef" * 3                    # 51 chars
CASES = [
    ("pipe keeps the call_id half", "call_abc|fc_def"),
    ("already valid id is unchanged", "toolu_01AbC"),
    ("space, CJK, dot and colon become '-'", "call a.b:c中文"),
    ("a non-BMP code point becomes ONE '-'", "call_\U0001F600x"),
    ("exactly 40 chars is unchanged", "t" * 40),
    ("41 chars becomes the 40-char hash form", "toolu_" + "a" * 35),
    ("100 chars becomes the 40-char hash form", "x" * 100),
    ("empty string becomes the hash of the empty string", ""),
    ("nothing before the pipe becomes the hash of the whole raw id", "|fc_only"),
    ("call_id over 40 hashes the WHOLE raw id", "c" * 41 + "|fc_1"),
    ("Responses combined id keeps its 29-char call_id", RESP_CALL + "|" + RESP_FC),
    ("collision pair A: same call_id as B, different fc_id", "call_dup|fc_one"),
    ("collision pair B: same call_id as A, different fc_id", "call_dup|fc_two"),
]


def build():
    return {
        "spec": "wireToolId(raw): (1) keep the part before the first '|'; "
                "(2) replace every code point outside [A-Za-z0-9_-] with '-'; "
                "(3) if the result is empty or longer than 40, use 'call_' + the first 35 "
                "hex chars of SHA-256(UTF-8 of the ORIGINAL raw id). Deterministic; "
                "applied only when a request is encoded, never to stored history.",
        "cap": CAP,
        "generator": "src/shared/tool-id/gen_vectors.py",
        "vectors": [{"name": n, "input": i, "expected": wire_tool_id(i)} for n, i in CASES],
        "collision_pairs": [["call_dup|fc_one", "call_dup|fc_two"]],
    }


if __name__ == "__main__":
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wire_tool_id_vectors.json")
    data = build()
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if "--check" in sys.argv:
        ok = open(path, encoding="utf-8").read() == text
        print("vectors match reference" if ok else "vectors DRIFTED from reference")
        sys.exit(0 if ok else 1)
    open(path, "w", encoding="utf-8").write(text)
    print(f"wrote {len(data['vectors'])} vectors to {path}")
