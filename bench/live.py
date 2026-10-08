"""ทดสอบ Gemini Live (WebSocket) แบบ streaming: ส่งเสียงทีละ 100ms ตามเวลาจริง แล้ววัดเวลาหลัง "ปล่อยปุ่ม" (activityEnd)
uv run --with websockets python3 bench/live.py <model> [modality TEXT|AUDIO] [ids...]"""
import asyncio, base64, json, os, sys, time, wave
from pathlib import Path
import websockets
sys.path.insert(0, str(Path(__file__).parent)); import run

URL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=" + os.environ["GEMINI_API_KEY"]

async def one(model, modality, sid, system, verbose=False):
    pcm = wave.open(str(Path(__file__).parent / "samples" / f"{sid}.wav")).readframes(10**9)
    gen = {"responseModalities": [modality]}
    if modality == "TEXT": gen["temperature"] = 0
    setup = {"model": f"models/{model}", "generationConfig": gen,
             "realtimeInputConfig": {"automaticActivityDetection": {"disabled": True}},
             "inputAudioTranscription": {}}
    if system: setup["systemInstruction"] = {"parts": [{"text": system}]}
    if modality == "AUDIO": setup["outputAudioTranscription"] = {}
    t0 = time.time()
    async with websockets.connect(URL, max_size=None) as ws:
        await ws.send(json.dumps({"setup": setup}))
        msg = json.loads(await ws.recv())
        if "setupComplete" not in msg: return f"SETUP FAIL {str(msg)[:300]}"
        t_setup = time.time() - t0
        await ws.send(json.dumps({"realtimeInput": {"activityStart": {}}}))
        chunk = 3200  # 100ms
        for i in range(0, len(pcm), chunk):
            await ws.send(json.dumps({"realtimeInput": {"audio": {"data": base64.b64encode(pcm[i:i+chunk]).decode(), "mimeType": "audio/pcm;rate=16000"}}}))
            await asyncio.sleep(0.1)
        t_end = time.time()
        await ws.send(json.dumps({"realtimeInput": {"activityEnd": {}}}))
        text, itx, otx, first = "", "", "", None
        while True:
            try: m = json.loads(await asyncio.wait_for(ws.recv(), 20))
            except Exception as e: text += f" [recv {type(e).__name__}]"; break
            sc = m.get("serverContent", {})
            if verbose: print("   msg", str(m)[:200])
            if "inputTranscription" in sc: itx += sc["inputTranscription"].get("text", "")
            if "outputTranscription" in sc: otx += sc["outputTranscription"].get("text", "")
            for p in sc.get("modelTurn", {}).get("parts", []):
                if "text" in p and not p.get("thought"):
                    first = first or time.time(); text += p["text"]
            if sc.get("turnComplete") or sc.get("generationComplete") and modality=="TEXT": 
                if sc.get("turnComplete"): break
            if "error" in m: text += str(m); break
        return f"setup {t_setup:.2f}s · after-release {time.time()-t_end:.2f}s (first {((first or time.time())-t_end):.2f}s)\n   text={text.strip()!r}\n   inputTx={itx.strip()!r}" + (f"\n   outTx={otx.strip()!r}" if otx else "")

async def main():
    model = sys.argv[1]; modality = sys.argv[2] if len(sys.argv) > 2 else "TEXT"
    ids = sys.argv[3:] or [s["id"] for s in run.SAMPLES]
    system = None if "transcribe" in model and os.environ.get("NOSYS") else run.build_prompt()
    for sid in ids:
        try: r = await one(model, modality, sid, system, os.environ.get("V"))
        except Exception as e: r = f"ERROR {type(e).__name__}: {str(e)[:300]}"
        print(f"[{sid}] {r}")

asyncio.run(main())
