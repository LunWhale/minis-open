#!/usr/bin/env python3
"""Cloud ASR wire vectors shared by iOS, Android and Windows (FIX-261022-06,
OpenMinis#468 / #469). This script is an independent reference of the rules
in CloudASRProtocols.swift / CloudAsrProtocols.kt / speech/cloud_asr.rs;
run it to regenerate cloud_asr_vectors.json.

    python3 src/shared/voice-asr/gen_vectors.py
"""
import base64, json, os, struct

RATE = 16000
CHUNK = 2 * 1280

def b64(b): return base64.b64encode(b).decode()

def wav(samples_bytes, fmt, channels, rate, bits):
    fmt_chunk = struct.pack('<HHIIHH', fmt, channels, rate, rate * channels * bits // 8, channels * bits // 8, bits)
    body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt_chunk)) + fmt_chunk
    # A LIST chunk before data: readers must walk chunks, not assume 44 bytes.
    body += b'LIST' + struct.pack('<I', 4) + b'INFO'
    body += b'data' + struct.pack('<I', len(samples_bytes)) + samples_bytes
    return b'RIFF' + struct.pack('<I', len(body)) + body

def pcm16k(frames, channels, rate, is_float):
    """frames: list of per-channel float values in [-1,1]."""
    mono = [sum(f) / channels for f in frames]
    n = len(mono)
    out_n = n if rate == RATE else n * RATE // rate
    step = rate / RATE
    out = b''
    for i in range(out_n):
        x = i * step
        i0 = min(int(x), n - 1); i1 = min(i0 + 1, n - 1)
        v = mono[i0] + (mono[i1] - mono[i0]) * (x - i0)
        v = max(-1.0, min(1.0, v))
        out += struct.pack('<h', int(v * 32767))
    return out

cases = []
# 16 kHz mono int16: unchanged values (scaled by 32767/32768 and truncated).
s = [0, 1024, -1024, 16384, -16384]
cases.append({"name": "16k mono int16",
              "wav": b64(wav(struct.pack('<5h', *s), 1, 1, 16000, 16)),
              "pcm": b64(pcm16k([[v / 32768] for v in s], 1, 16000, False))})
# 48 kHz stereo int16: averaged, every third frame (no interpolation).
st = [(1024 * i, -512 * i) for i in range(12)]
cases.append({"name": "48k stereo int16",
              "wav": b64(wav(b''.join(struct.pack('<hh', a, b) for a, b in st), 1, 2, 48000, 16)),
              "pcm": b64(pcm16k([[a / 32768, b / 32768] for a, b in st], 2, 48000, False))})
# 32 kHz mono float32: every other frame.
fl = [0.5, 0.25, -0.25, -0.5, 0.125, 0.0]
cases.append({"name": "32k mono float32",
              "wav": b64(wav(struct.pack('<6f', *fl), 3, 1, 32000, 32)),
              "pcm": b64(pcm16k([[v] for v in fl], 1, 32000, True))})
cases.append({"name": "not a wav", "wav": b64(b'not a wave file at all'), "pcm": None})

# iFlytek frames for 3000 bytes of PCM: 2 audio messages + the end message.
pcm = bytes(range(256)) * 11 + bytes(184)
assert len(pcm) == 3000
frames = []
for i in range(0, len(pcm), CHUNK):
    data = {"status": 0 if i == 0 else 1, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": b64(pcm[i:i + CHUNK])}
    m = {}
    if i == 0:
        m["common"] = {"app_id": "app1"}
        m["business"] = {"language": "zh_cn", "domain": "iat", "accent": "mandarin", "eos": 10000}
    m["data"] = data
    frames.append(m)
frames.append({"data": {"status": 2}})

def res(sn, words, status, **kw):
    r = {"sn": sn, "ls": status == 2, "ws": [{"bg": 0, "cw": [{"w": w, "sc": 0}]} for w in words]}
    r.update(kw)
    return json.dumps({"code": 0, "message": "success", "sid": "iat000", "data": {"status": status, "result": r}}, ensure_ascii=False)

vectors = {
    "pcm16k": cases,
    "xunfei_language": [["zh-CN", "zh_cn"], ["en-US", "en_us"], ["en", "en_us"], [None, "zh_cn"], ["ja-JP", "zh_cn"]],
    "xunfei_frames": {"app_id": "app1", "language": "zh_cn", "pcm": b64(pcm), "frames": frames},
    "xunfei_segments": {"pcm_bytes": 55 * RATE * 2 * 2 + 10, "segment_bytes": [55 * RATE * 2, 55 * RATE * 2, 10]},
    "xunfei_results": [
        {"messages": [res(1, ["今天", "天气"], 0), res(2, ["很好", "。"], 2)], "text": "今天天气很好。"},
        {"messages": [res(1, ["今天"], 0), res(2, ["天七"], 1, pgs="apd"), res(3, ["天气", "好"], 2, pgs="rpl", rg=[2, 2])],
         "text": "今天天气好"},
        {"messages": [json.dumps({"code": 10005, "message": "licc failed", "sid": "iat001"})], "error_code": 10005},
    ],
    "bailian_model": [[None, "qwen3-asr-flash"], ["paraformer-realtime-v2", "qwen3-asr-flash"],
                      ["qwen3-asr-flash", "qwen3-asr-flash"], ["qwen3-asr-flash-2026-09-08", "qwen3-asr-flash-2026-09-08"],
                      ["sensevoice-v1", "qwen3-asr-flash"]],
    "bailian_body": [
        {"model": "qwen3-asr-flash", "wav": b64(b'RIFFfakewav'), "language": "zh-CN",
         "body": {"model": "qwen3-asr-flash", "stream": False,
                  "messages": [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": "data:audio/wav;base64," + b64(b'RIFFfakewav')}}]}],
                  "asr_options": {"enable_itn": False, "language": "zh"}}},
        {"model": "qwen3-asr-flash", "wav": b64(b'RIFFfakewav'), "language": None,
         "body": {"model": "qwen3-asr-flash", "stream": False,
                  "messages": [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": "data:audio/wav;base64," + b64(b'RIFFfakewav')}}]}],
                  "asr_options": {"enable_itn": False}}},
    ],
    "bailian_response": {"body": json.dumps({"choices": [{"finish_reason": "stop", "index": 0, "message": {"role": "assistant", "content": "欢迎使用阿里云。", "annotations": [{"type": "audio_info", "language": "zh", "emotion": "neutral"}]}}], "usage": {"seconds": 1}, "model": "qwen3-asr-flash"}, ensure_ascii=False),
                         "text": "欢迎使用阿里云。", "seconds": 1.0},
    "doubao_resource": [[None, "volc.bigasr.auc_turbo"], ["bigmodel", "volc.bigasr.auc_turbo"],
                        ["volc.seedasr.auc_turbo", "volc.seedasr.auc_turbo"]],
    "doubao_body": {"wav": b64(b'RIFFfakewav'),
                    "body": {"user": {"uid": "minis_user"}, "audio": {"data": b64(b'RIFFfakewav')},
                             "request": {"model_name": "bigmodel", "enable_itn": True, "enable_punc": True}}},
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_asr_vectors.json")
with open(out, "w") as f:
    json.dump(vectors, f, ensure_ascii=False, indent=1)
    f.write("\n")
print("wrote", out)
