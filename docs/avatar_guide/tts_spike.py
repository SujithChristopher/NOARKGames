"""Sheep-guide voice test: the same lines in Hindi / Tamil / Telugu from Indic Parler-TTS and Piper.

Throwaway spike (2026-11-02), kept so it can be re-run — see README.md beside it.

Setup (Python 3.11; Parler wants a CUDA GPU and downloads ~3.5 GB; it is gated, so accept
the terms at https://huggingface.co/ai4bharat/indic-parler-tts and `hf auth login` first):

    uv venv --python 3.11 .venv
    uv pip install --python .venv/Scripts/python.exe torch torchaudio --index-url https://download.pytorch.org/whl/cu124
    uv pip install --python .venv/Scripts/python.exe "git+https://github.com/huggingface/parler-tts.git" soundfile piper-tts

Run (writes <out>/<lang>_<engine>_<voice>.wav and <out>/listen.html; keep <out> outside the repo):

    python tts_spike.py piper  <out>
    python tts_spike.py parler <out>
"""
import html
import io
import sys
import time
import wave
from pathlib import Path

import numpy as np
import soundfile as sf

GAP_S = 0.7          # silence between lines in the joined file
TAKES = 4            # Parler samples per line; its output varies run to run
MAX_S_PER_CHAR = 0.12  # a take longer than this per codepoint is rambling or far too slow

# Machine-written; a native speaker must check them before anything ships.
LINES = {
    "hi": [
        "बहुत बढ़िया! आपने खेल पूरा कर लिया।",
        "आपने बारह सेब पकड़े!",
        "यह पिछली बार से बेहतर है। ऐसे ही करते रहिए!",
        "अच्छी कोशिश! अगली बार थोड़ा और आगे तक पहुँचिए।",
    ],
    "ta": [
        "மிகவும் நன்று! நீங்கள் விளையாட்டை முடித்துவிட்டீர்கள்.",
        "நீங்கள் பன்னிரண்டு ஆப்பிள்கள் பிடித்தீர்கள்!",
        "இது கடந்த முறையை விட சிறப்பு. இப்படியே தொடருங்கள்!",
        "நல்ல முயற்சி! அடுத்த முறை இன்னும் கொஞ்சம் தூரம் எட்ட முயற்சி செய்யுங்கள்.",
    ],
    "te": [
        "చాలా బాగుంది! మీరు ఆట పూర్తి చేశారు.",
        "మీరు పన్నెండు ఆపిల్స్ పట్టుకున్నారు!",
        "ఇది గతసారి కంటే మెరుగ్గా ఉంది. ఇలాగే కొనసాగించండి!",
        "మంచి ప్రయత్నం! వచ్చేసారి ఇంకొంచెం దూరం అందుకోవడానికి ప్రయత్నించండి.",
    ],
}
LANG_NAMES = {"hi": "Hindi", "ta": "Tamil", "te": "Telugu"}

PARLER_VOICES = {"hi": ["Divya", "Rohit"], "ta": ["Jaya", "Kavitha"], "te": ["Lalitha", "Prakash"]}
PARLER_STYLE = ("{name} speaks in a cheerful, warm and friendly voice with a slightly high pitch, "
                "at a slow pace. The recording is very clear with no background noise.")

# Paths in the rhasspy/piper-voices repo. Piper has no Tamil voice.
PIPER_VOICES = {
    "hi": ["hi/hi_IN/priyamvada/medium/hi_IN-priyamvada-medium", "hi/hi_IN/rohan/medium/hi_IN-rohan-medium"],
    "te": ["te/te_IN/padmavathi/medium/te_IN-padmavathi-medium", "te/te_IN/venkatesh/medium/te_IN-venkatesh-medium"],
}


def join(clips, sr):
    gap = np.zeros(int(GAP_S * sr), dtype=np.float32)
    return np.concatenate([part for c in clips for part in (c.astype(np.float32), gap)])


def tail_ratio(a, sr):
    """Loudness of the last 150 ms against the clip's median; near 1 means it was cut off mid-word."""
    w = int(0.05 * sr)
    rms = np.sqrt(np.convolve(a ** 2, np.ones(w) / w, mode="valid"))
    return rms[-int(0.15 * sr):].mean() / np.median(rms[rms > 1e-4])


def parler(out):
    import torch
    from parler_tts import ParlerTTSForConditionalGeneration
    from transformers import AutoTokenizer

    dev = "cuda" if torch.cuda.is_available() else "cpu"
    repo = "ai4bharat/indic-parler-tts"
    model = ParlerTTSForConditionalGeneration.from_pretrained(repo).to(dev)
    tok = AutoTokenizer.from_pretrained(repo)
    desc_tok = AutoTokenizer.from_pretrained(model.config.text_encoder._name_or_path)
    sr = model.config.sampling_rate

    for lang, names in PARLER_VOICES.items():
        for name in names:
            d = desc_tok(PARLER_STYLE.format(name=name), return_tensors="pt").to(dev)
            clips = []
            for k, line in enumerate(LINES[lang], 1):
                takes = []
                for seed in range(TAKES):
                    torch.manual_seed(seed)
                    p = tok(line, return_tensors="pt").to(dev)
                    t0 = time.time()
                    a = model.generate(input_ids=d.input_ids, attention_mask=d.attention_mask,
                                       prompt_input_ids=p.input_ids,
                                       prompt_attention_mask=p.attention_mask).cpu().numpy().squeeze()
                    takes.append((seed, a, len(a) / sr, tail_ratio(a, sr), time.time() - t0))
                clean = sorted((t for t in takes if t[3] < 0.1 and t[2] < MAX_S_PER_CHAR * len(line)),
                               key=lambda t: t[2])
                pick = clean[len(clean) // 2] if clean else min(takes, key=lambda t: t[3])
                note = "" if clean else "  NO CLEAN TAKE (may be cut off)"
                print(f"{lang} {name} line {k}: seed {pick[0]}, {pick[2]:.1f}s audio, "
                      f"{pick[4]:.1f}s to make{note}")
                clips.append(pick[1])
            sf.write(out / f"{lang}_parler_{name}.wav", join(clips, sr), sr)


def piper(out):
    from huggingface_hub import hf_hub_download
    from piper import PiperVoice

    for lang, keys in PIPER_VOICES.items():
        for key in keys:
            onnx = hf_hub_download("rhasspy/piper-voices", key + ".onnx")
            hf_hub_download("rhasspy/piper-voices", key + ".onnx.json")
            voice = PiperVoice.load(onnx)
            clips, sr = [], None
            for k, line in enumerate(LINES[lang], 1):
                buf = io.BytesIO()
                t0 = time.time()
                with wave.open(buf, "wb") as wf:
                    voice.synthesize_wav(line, wf)
                buf.seek(0)
                a, sr = sf.read(buf, dtype="float32")
                print(f"{lang} {key.split('/')[2]} line {k}: {len(a) / sr:.1f}s audio, "
                      f"{time.time() - t0:.2f}s to make (CPU)")
                clips.append(a)
            sf.write(out / f"{lang}_piper_{key.split('/')[2]}.wav", join(clips, sr), sr)


def write_listen_page(out):
    rows = []
    for lang, lines in LINES.items():
        rows.append(f"<h2>{LANG_NAMES[lang]}</h2><ol>"
                    + "".join(f"<li>{html.escape(l)}</li>" for l in lines) + "</ol>")
        for f in sorted(out.glob(f"{lang}_*.wav")):
            _, engine, voice = f.stem.split("_", 2)
            rows.append(f'<div class="row"><b>{engine.title()} · {html.escape(voice)}</b>'
                        f'<audio controls src="{f.name}"></audio></div>')
    (out / "listen.html").write_text(
        '<!doctype html><meta charset="utf-8"><title>Sheep voice test</title><style>'
        "body{font:15px system-ui,sans-serif;max-width:780px;margin:24px auto;padding:0 16px}"
        "h2{margin-top:32px;border-bottom:1px solid #ccc}ol{color:#555}"
        ".row{display:flex;align-items:center;gap:12px;margin:6px 0}.row b{width:190px}audio{flex:1}"
        "</style><h1>Sheep voice test</h1>"
        "<p>Same lines per language. Translations are machine-written; have a native speaker check them.</p>"
        + "".join(rows), encoding="utf-8")


if __name__ == "__main__":
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("out")
    out.mkdir(parents=True, exist_ok=True)
    {"parler": parler, "piper": piper}[sys.argv[1]](out)
    write_listen_page(out)
    print("open", (out / "listen.html").resolve())
