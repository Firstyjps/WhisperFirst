"""เทียบเครื่องถอดเสียงไทย: ความแม่น (เทียบ expect) + latency
ใช้: python3 bench/run.py gemini:gemini-3.5-flash elevenlabs whisper ...
ต้องมี GEMINI_API_KEY (และ ~/.config/elevenlabs/api_key ถ้าใช้ elevenlabs)"""
import base64, difflib, json, os, re, subprocess, sys, time, urllib.error, urllib.request, uuid
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent
SAMPLES = json.loads((HERE / "samples.json").read_text())


def build_prompt(name="dictate", app="Notes"):
    dic = [l.strip() for l in (ROOT / "defaults/dictionary.txt").read_text().splitlines() if l.strip() and not l.startswith("#")]
    return ((ROOT / f"prompts/{name}.md").read_text()
            .replace("{{APP}}", app).replace("{{APP_HINT}}", "")
            .replace("{{ABOUT_ME}}", (ROOT / "defaults/about-me.md").read_text().strip())
            .replace("{{DICTIONARY}}", ", ".join(dic)))


def post(url, body, headers, timeout=60):
    req = urllib.request.Request(url, data=body, headers=headers)
    for attempt in range(4):
        try:
            return json.load(urllib.request.urlopen(req, timeout=timeout))
        except urllib.error.HTTPError as e:
            msg = e.read().decode()[:300]
            if e.code in (429, 503) and attempt < 3:
                time.sleep(15); continue
            raise RuntimeError(f"HTTP {e.code}: {msg}")


def gemini(model, wav, system, text=None, thinking="minimal"):
    parts = [{"inlineData": {"mimeType": "audio/wav", "data": base64.b64encode(wav.read_bytes()).decode()}}] if wav else []
    if text: parts.append({"text": text})
    cfg = {"temperature": 0.0}
    if thinking:
        cfg["thinkingConfig"] = {"thinkingLevel": thinking} if not model.startswith("gemini-2.5") else {"thinkingBudget": 0}
    body = {"systemInstruction": {"parts": [{"text": system}]}, "contents": [{"role": "user", "parts": parts}], "generationConfig": cfg}
    d = post(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", json.dumps(body).encode(),
             {"Content-Type": "application/json", "x-goog-api-key": os.environ["GEMINI_API_KEY"]})
    return "".join(p.get("text", "") for p in d["candidates"][0]["content"].get("parts", []) if not p.get("thought")).strip()


def elevenlabs(wav, model="scribe_v2"):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\n{model}\r\n"
            f"--{b}\r\nContent-Disposition: form-data; name=\"language_code\"\r\n\r\ntha\r\n"
            f"--{b}\r\nContent-Disposition: form-data; name=\"tag_audio_events\"\r\n\r\nfalse\r\n"
            f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode() \
        + wav.read_bytes() + f"\r\n--{b}--\r\n".encode()
    key = Path("~/.config/elevenlabs/api_key").expanduser().read_text().strip()
    return post("https://api.elevenlabs.io/v1/speech-to-text", body,
                {"xi-api-key": key, "Content-Type": f"multipart/form-data; boundary={b}"})["text"].strip()


def whisper(wav, model="large-v3"):
    m = Path(f"~/.cache/hyperframes/whisper/models/ggml-{model}.bin").expanduser()
    out = subprocess.run(["whisper-cli", "-m", str(m), "-l", "th", "-nt", "-np", "-f", str(wav)], capture_output=True, text=True)
    return out.stdout.strip()


def run(engine, wav):
    kind, _, arg = engine.partition(":")
    if kind == "gemini":          # เสียง → ข้อความเกลาแล้ว ในครั้งเดียว
        return gemini(arg or "gemini-3.5-flash", wav, build_prompt())
    if kind == "geminiraw":       # ถอดดิบ
        return gemini(arg or "gemini-3.5-transcribe", wav, "ถอดเสียงภาษาไทยตามที่ได้ยินทุกคำ", thinking=None)
    if kind == "elevenlabs":
        return elevenlabs(wav)
    if kind == "el+gemini":       # ElevenLabs ถอด → Gemini เกลา (ส่งเสียงไปด้วยเพื่อช่วยตัดสินใจ)
        raw = elevenlabs(wav)
        return gemini(arg or "gemini-3.5-flash-lite", wav, build_prompt(), text=f"ข้อความถอดเสียงเบื้องต้น (อาจผิด):\n{raw}")
    if kind == "whisper":
        return whisper(wav, arg or "large-v3")
    raise SystemExit(f"unknown engine {engine}")


def norm(s):
    return re.sub(r"\s+", "", s)


if __name__ == "__main__":
    only = os.environ.get("ONLY")
    for engine in sys.argv[1:]:
        print(f"\n===== {engine}")
        lat, sim = [], []
        for s in SAMPLES:
            if only and s["id"] not in only.split(","): continue
            wav = HERE / "samples" / f"{s['id']}.wav"
            t = time.time()
            try:
                out = run(engine, wav)
            except Exception as e:
                out = f"ERROR {e}"
            dt = time.time() - t
            r = difflib.SequenceMatcher(None, norm(out), norm(s["expect"])).ratio()
            lat.append(dt); sim.append(r)
            print(f"[{s['id']}] {dt:.2f}s sim={r:.2f}\n   → {out!r}")
        if lat:
            print(f"== {engine}: avg {sum(lat)/len(lat):.2f}s · median {sorted(lat)[len(lat)//2]:.2f}s · sim {sum(sim)/len(sim):.3f}")
