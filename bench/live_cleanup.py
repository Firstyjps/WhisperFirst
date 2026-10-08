"""วัดแนวทาง "Live transcript → เกลาด้วยข้อความล้วน" เทียบกับ "ส่งเสียงให้ Gemini เกลา" (แบบปัจจุบัน)
uv run --with websockets python3 bench/live_cleanup.py [ids...]"""
import asyncio, base64, difflib, json, os, sys, time, urllib.request, wave
from pathlib import Path
import websockets
sys.path.insert(0, str(Path(__file__).parent)); import run

KEY = os.environ["GEMINI_API_KEY"]
WS = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=" + KEY
TEXT_MODE = (Path(__file__).parent.parent / "prompts/dictate-text.md")

async def live_final(pcm):
    async with websockets.connect(WS, max_size=None) as ws:
        await ws.send(json.dumps({"setup": {"model": "models/gemini-3.5-transcribe-live", "generationConfig": {"responseModalities": ["TEXT"]}, "inputAudioTranscription": {}}}))
        await ws.recv()
        for i in range(0, len(pcm), 3200):
            await ws.send(json.dumps({"realtimeInput": {"audio": {"data": base64.b64encode(pcm[i:i+3200]).decode(), "mimeType": "audio/pcm;rate=16000"}}}))
            await asyncio.sleep(0.1)
        t_end = time.time()
        await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), 10))
            tx = m.get("serverContent", {}).get("inputTranscription", {}).get("text")
            if tx: return tx, time.time() - t_end

def gem(model, system, parts):
    body = {"systemInstruction": {"parts": [{"text": system}]}, "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0, "thinkingConfig": {"thinkingLevel": "minimal"}}}
    req = urllib.request.Request(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "x-goog-api-key": KEY})
    t = time.time(); d = json.load(urllib.request.urlopen(req, timeout=60))
    return "".join(p.get("text", "") for p in d["candidates"][0]["content"]["parts"] if not p.get("thought")).strip(), time.time() - t

def sim(a, b): return difflib.SequenceMatcher(None, run.norm(a), run.norm(b)).ratio()

async def main():
    ids = sys.argv[1:] or [s["id"] for s in run.SAMPLES]
    system_text = run.build_prompt() + "\n\n" + TEXT_MODE.read_text()
    rows = []
    for s in [x for x in run.SAMPLES if x["id"] in ids]:
        wav = Path(__file__).parent / "samples" / f"{s['id']}.wav"
        pcm = wave.open(str(wav)).readframes(10**9)
        raw, t_live = await live_final(pcm)
        out_t = {}
        for model in ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]:
            txt, dt = gem(model, system_text, [{"text": f"<transcript>\n{raw}\n</transcript>"}])
            out_t[model] = (txt, t_live + dt)
        aud, dt_a = gem("gemini-3.1-flash-lite", run.build_prompt(), [{"inlineData": {"mimeType": "audio/wav", "data": base64.b64encode(wav.read_bytes()).decode()}}])
        print(f"[{s['id']}] raw(live +{t_live:.2f}s): {raw}")
        for m, (txt, total) in out_t.items():
            print(f"   text {m[7:]:16s} {total:.2f}s sim={sim(txt, s['expect']):.2f} → {txt!r}")
        print(f"   audio 3.1-flash-lite    {dt_a:.2f}s sim={sim(aud, s['expect']):.2f} → {aud!r}")
        rows.append((sim(out_t['gemini-3.5-flash-lite'][0], s['expect']), out_t['gemini-3.5-flash-lite'][1],
                     sim(out_t['gemini-3.1-flash-lite'][0], s['expect']), out_t['gemini-3.1-flash-lite'][1], sim(aud, s['expect']), dt_a))
        await asyncio.sleep(3)
    n = len(rows)
    avg = lambda i: sum(r[i] for r in rows) / n
    print(f"\n== text 3.5-lite: sim {avg(0):.3f} · {avg(1):.2f}s | text 3.1-lite: sim {avg(2):.3f} · {avg(3):.2f}s | audio 3.1-lite: sim {avg(4):.3f} · {avg(5):.2f}s")

asyncio.run(main())
