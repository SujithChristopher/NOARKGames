# Avatar guide — voice research (paused)

**Status:** paused 2026-11-02, to revisit. Nothing is built in the game yet; this records the
idea, what was decided, and a voice spike (`tts_spike.py`, beside this file).

## The idea

An avatar guide for each game, starting with Random Reach: a sheep that speaks to the patient,
tells them their score and encourages them to do better — positive encouragement only.
Each trial is 1 minute; when it ends, the guide appears in a separate scene for 5–10 s and
explains the score, then play goes on (retry / menu).

## Leaning (not yet agreed)

- **Pre-generated clips, no speech synthesis at runtime.** Lines are generated once on the dev
  PC with a neural TTS, checked by a native speaker, and shipped as `.ogg`. It sounds the same on
  the Radxa and the tablet (in BLE mode Godot runs on Android, not the board), costs the board
  nothing, and the guide can never say something odd to a patient.
- **Numbers on screen, not spoken.** The spoken line is picked by how the trial went (best yet,
  better than last time, a good try, …); the score itself shows in the speech bubble. Stitching
  spoken numbers from clips works but sounds choppy.
- **Languages:** Hindi, Tamil, Telugu.
- **Engine for the clips:** Indic Parler-TTS — the one model that covers all three.

## Ways to make the voice

| Option | How | For | Against |
|---|---|---|---|
| OS speech (`DisplayServer.tts_speak`) | Godot asks the device's own engine; needs `audio/general/text_to_speech` on | Any sentence, numbers too; nothing to record; pitch/rate params; callbacks to drive a mouth | Android (Google TTS) is decent; the Radxa gets speech-dispatcher / espeak — robotic, and a package to install |
| **Pre-generated clips** | Neural TTS (or a person) on the PC → `.ogg` in the repo | Best quality, same everywhere, zero runtime cost, tone controlled | Fixed set of lines; numbers not spoken |
| Neural TTS at runtime | Piper binary on the board via `OS.execute` → `.wav` → `AudioStreamWAV` | Any sentence in a good voice | Extra binary + ~60 MB model per voice; not Tamil; Android needs a different build (sherpa-onnx) |

Runtime Piper on the Radxa (Dragon Q6A, QCS6490, 4× A78) looked feasible — Piper runs faster
than real time on a Raspberry Pi 4 — but it was **not measured on the board**. The tracker uses
~170 % CPU at 85–87 °C while a game runs, which is the thing to watch.

## Spike results (2026-11-02, RTX 4060 laptop)

Same 4 lines per language: *well done, you finished · you got twelve apples · better than last
time, keep it up · good try, reach a little further next time*.

| | Hindi | Tamil | Telugu |
|---|---|---|---|
| Indic Parler-TTS | Divya, Rohit — clean | **Jaya**: nearly every take ends loud — likely cut off mid-word (or a noisy voice); **Kavitha**: the same line came out 4.5–16 s from run to run (clean takes exist, picked by seed) | Lalitha, Prakash — clean |
| Piper | priyamvada, rohan | no voice | padmavathi, venkatesh |

- **Speed.** Parler: 3–7 s per line on the GPU — slower than the speech itself, so it is for
  pre-generating only. Piper: 0.04–0.9 s per line on the PC's CPU.
- **Parler varies run to run**, worst in Tamil. Making the final clips means several takes per
  line and a person choosing; `tts_spike.py` already drops takes that end loud or run long and
  keeps the middle one. At ~30 lines × 3 languages that is manageable.
- **The translations are machine-written** — a native speaker must check every line.
- None of it sounds like a sheep yet; these are human voices.

## Models

| Model | Languages | Licence | Notes |
|---|---|---|---|
| [Indic Parler-TTS](https://huggingface.co/ai4bharat/indic-parler-tts) (AI4Bharat) | 21 incl. hi, ta, te | Apache 2.0, gated | 0.9 B params; voice described in a text prompt; named speakers per language (hi Rohit/Divya, ta Jaya/Kavitha, te Prakash/Lalitha/Kiran) |
| [IndicF5](https://huggingface.co/ai4bharat/IndicF5) (AI4Bharat) | 11 incl. hi, ta, te | MIT, gated | 0.4 B; clones a voice from a short reference clip + transcript — one sheep voice across all three languages. Only clone a voice with its owner's consent. **Not tried.** |
| [Piper](https://huggingface.co/rhasspy/piper-voices) | hi, te (no ta) | per voice — **not checked** | Small, fast, runs on ARM |

## Open when we come back

1. Which voice — nobody has listened and chosen yet.
2. Is the score spoken aloud, or only shown?
3. Language per patient or per site, and where it is stored.
4. Native-speaker review of every line.
5. Making it a sheep: pitch up (live with `AudioEffectPitchShift`, or baked into the clips), a
   "baa", mouth animation while it speaks.
6. The line set: which outcomes get which lines (first trial, best ever, better, same, lower).
7. The guide scene in Random Reach: where it hooks into game over, 5 or 10 s, skippable, what
   follows (retry / menu). Random Reach still has its own copy of the `GameSession` logic.
8. Try IndicF5 for one consistent voice across languages.
9. Licences of any Piper voice before it ships.

## Re-running the spike

Setup and usage are in the docstring of `tts_spike.py`. Point the output outside the repo:
`python tts_spike.py parler C:\temp\sheep` (roughly 10 min on the RTX 4060 at 4 takes a line, after the 3.5 GB download),
then open `listen.html` there. Piper takes seconds and needs no GPU or login.
