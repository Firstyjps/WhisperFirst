"""สร้างไฟล์เสียงไทยทดสอบด้วย Gemini TTS (เสียงพูดธรรมชาติ มีเอ่อ/อ่า/พูดผิดแล้วแก้)
ใช้: GEMINI_API_KEY=... python3 bench/make_samples.py"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

HERE = Path(__file__).parent
KEY = os.environ["GEMINI_API_KEY"]
MODEL = os.environ.get("TTS_MODEL", "gemini-3.8-flash-tts")
VOICES = ["Puck", "Kore", "Charon", "Leda"]

for i, s in enumerate(json.loads((HERE / "samples.json").read_text())):
    out = HERE / "samples" / f"{s['id']}.wav"
    if out.exists():
        continue
    if os.environ.get("TTS") == "elevenlabs":   # สำรองเมื่อ Gemini TTS ติด quota
        key = Path("~/.config/elevenlabs/api_key").expanduser().read_text().strip()
        req = urllib.request.Request("https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb?output_format=mp3_44100_128",
                                     data=json.dumps({"text": s["say"], "model_id": "eleven_v3", "language_code": "th"}).encode(),
                                     headers={"xi-api-key": key, "Content-Type": "application/json"})
        mp3 = urllib.request.urlopen(req, timeout=120).read()
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "-", "-ar", "16000", "-ac", "1", str(out)], input=mp3, check=True)
        print("✓ (elevenlabs)", out.name); continue
    body = {
        "contents": [{"parts": [{"text": s["say"]}]}],
        "generationConfig": {"responseModalities": ["AUDIO"],
                             "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": VOICES[i % len(VOICES)]}}}},
    }
    req = urllib.request.Request(f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent",
                                 data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "x-goog-api-key": KEY})
    for attempt in range(6):
        try:
            data = json.load(urllib.request.urlopen(req, timeout=120)); break
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 5: raise
            print("  429 → รอ 30s"); time.sleep(30)
    pcm = base64.b64decode(data["candidates"][0]["content"]["parts"][0]["inlineData"]["data"])
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", "-",
                    "-ar", "16000", str(out)], input=pcm, check=True)
    print("✓", out.name, f"{len(pcm) / 48000:.1f}s")
