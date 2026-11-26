# Omarchy Assistant

A voice assistant for [Omarchy](https://omarchy.org). Say its name, ask anything, and hear the answer in a natural voice, like JARVIS. You name it yourself.

- **Wake word you choose.** Call it Chloe, Jarvis, Friday, anything. No training needed.
- **Natural voice.** [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) runs on your CPU, with 11 voices to choose from by ear during setup.
- **Real conversations.** Ask follow-ups without repeating its name; it remembers the last few minutes.
- **Interrupt it.** Talk over it and it stops to listen, like OpenAI's voice mode: instantly with headphones, at its next pause on laptop speakers.
- **Does things (optional).** With full access, it opens apps and sites, plays videos, reads your email and calendar, and runs commands, powered by [Claude Code](https://claude.com/claude-code).
- **Lives in your bar.** An icon shows when it's listening, thinking or speaking.

Works on x86-64 and ARM, including Apple Silicon Macs running Asahi Linux.

## Install

```bash
omarchy plugin add https://github.com/SDOsmany/omarchy-assistant --enable
```

Then click the new ⚙ icon in the bar. A setup wizard installs what's missing, asks for a name, plays the voices so you can pick one, and starts the assistant. It takes about five minutes, mostly downloads.

**You need:** Omarchy 4.5 or newer and [Claude Code](https://claude.com/claude-code), signed in. If you don't have Claude Code, install it with `omarchy default agent claude`.

## Use it

Say the name, wait for the chime, then ask.

| | |
|---|---|
| "Chloe" … "what's the weather tomorrow?" | Ask anything |
| "Chloe" … "play the latest Mr. Beast video" | Do things (full access) |
| "thanks" / "that's all", or stay quiet | End the conversation |
| `Super + Alt + A` | Talk without saying the name, or stop it |
| `Super + Alt + Escape` | Stop it right away |
| `Super + Alt + M` | Mute or unmute the wake word |
| Bar icon | Click: talk or stop · Right-click: mute · Middle-click: log |

From a terminal, the `omarchy-assistant` command (and a shortcut named after your assistant, such as `chloe`) does the same:

```bash
omarchy-assistant talk | stop | mute | unmute | status
omarchy-assistant say "Hello"
omarchy-assistant setup      # change name, voice, access, ...
omarchy-assistant logs
```

## Access levels

You choose during setup, and can change it by running setup again.

- **Safe (default):** answers questions and searches the web. It can't touch your computer.
- **Full:** controls your desktop through Claude Code without permission prompts. It still asks out loud before deleting, sending or buying anything. **Anyone near your mic, or a video playing, can give it orders**, and text in an email or web page could try to trick it. Turn this on only if you're comfortable with that.

For email and calendar, connect Gmail and Google Calendar at claude.ai → Settings → Connectors. The assistant can draft emails but not send them.

## Privacy

- The wake word is detected on your computer by [omawake](https://github.com/jacob-vincent-mink/omawake). Nothing leaves your machine until you say the name.
- After that, what you say is transcribed by Superwhisper (if you use it) or by Whisper running locally, and the text goes to Claude.
- The voice is generated on your computer.

## Settings

`~/.config/omarchy-assistant/config.json`, also opened by `omarchy-assistant config`:

| Key | Default | |
|---|---|---|
| `name` | | Wake word and how it introduces itself |
| `voice` | `af_heart` | Kokoro voice id |
| `speed` | `1.0` | Speaking speed |
| `stt` | `superwhisper` | `superwhisper` or `whisper` (local) |
| `model` | `sonnet` | Claude model: `haiku` is faster, `opus` is smarter |
| `access` | `safe` | `safe` or `full` |
| `first_wait` | `10` | Seconds it waits for you to start talking after the chime |
| `followup_wait` | `8` | Seconds it waits for a follow-up |
| `end_silence` | `1.2` | Pause, in seconds, that means you're done talking |
| `continue_window` | `600` | Seconds within which it remembers the last conversation |
| `barge_in` | `auto` | Talk over it to interrupt: `auto` or `never` |

## How it works

```
omawake (wake word) ──► omarchy-assistant wake ──► assistantd (systemd user service)
                                                     ├─ records until you pause
                                                     ├─ Superwhisper / Whisper → text
                                                     ├─ claude -p, streamed (persona + access level)
                                                     ├─ Kokoro → speech, sentence by sentence
                                                     └─ state → bar widget
```

It starts speaking as soon as the first phrase of the answer arrives: the answer streams in, is cut into sentences, and each sentence is turned into speech while the previous one plays.

To hear you over itself, it tracks how loud each word it plays is. With headphones it can hear you any time. On speakers its own voice reaches the mic about as loud as yours, so it listens for you in the pauses between its words and sentences, usually within a second or two of you starting to talk.

## Remove

```bash
omarchy-assistant uninstall
omarchy plugin remove io.github.sdosmany.assistant
```

This removes the service, wake word and shortcuts, and asks before deleting models and settings.

## Develop

```bash
git clone https://github.com/SDOsmany/omarchy-assistant && cd omarchy-assistant
./install.sh                     # links the clone into Omarchy's plugins
omarchy-assistant logs
python -m unittest discover tests
```

The daemon is `daemon/assistantd.py`, the bar widget is `BarWidget.qml`, and setup is `install.sh`. Bar widget edits reload on save; daemon edits need `omarchy-assistant restart`.

## License

MIT
