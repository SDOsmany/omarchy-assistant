"""Unit tests for the daemon's pure logic. Run: python -m unittest discover tests"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "daemon"))
import assistantd as a  # noqa: E402


class AgentCommand(unittest.TestCase):
    def cfg(self, **kw):
        return {**a.DEFAULTS, **kw}

    def test_safe_mode_has_no_shell_or_file_tools(self):
        cmd = a.agent_command(self.cfg(access="safe"), "hello", False)
        self.assertIn("--tools", cmd)
        self.assertEqual(cmd[cmd.index("--tools") + 1], "WebSearch,WebFetch")
        self.assertIn("--strict-mcp-config", cmd)
        self.assertNotIn("bypassPermissions", cmd)
        self.assertNotIn("--add-dir", cmd)

    def test_full_mode_bypasses_prompts(self):
        cmd = a.agent_command(self.cfg(access="full"), "hello", False)
        self.assertEqual(cmd[cmd.index("--permission-mode") + 1], "bypassPermissions")
        self.assertNotIn("--tools", cmd)

    def test_unknown_access_is_treated_as_safe(self):
        cmd = a.agent_command(self.cfg(access="everything"), "hello", False)
        self.assertNotIn("bypassPermissions", cmd)

    def test_resume_continues_conversation(self):
        self.assertIn("--continue", a.agent_command(self.cfg(), "hi", True))
        self.assertNotIn("--continue", a.agent_command(self.cfg(), "hi", False))

    def test_name_is_in_persona(self):
        cmd = a.agent_command(self.cfg(name="Chloe"), "hi", False)
        prompt = cmd[cmd.index("--append-system-prompt") + 1]
        self.assertIn("You are Chloe", prompt)

    def test_user_text_is_one_argument(self):
        text = "open youtube; rm -rf ~ && echo $HOME"
        cmd = a.agent_command(self.cfg(), text, False)
        self.assertEqual(cmd[cmd.index("-p") + 1], text)


class Endings(unittest.TestCase):
    def test_goodbyes_end_the_conversation(self):
        r = a.endings_for("Chloe")
        for s in ("Thanks.", "thank you Chloe", "That's all", "okay, goodbye!", "Never mind",
                  "Nvm", "Nevermind.", "No, never mind.", "I don't need anything. Go away.",
                  "Nah, I'm good.", "No thanks", "Oh, sorry, I wasn't talking to you.",
                  "Forget it.", "I’m fine, thank you Chloe", "Not now."):
            self.assertTrue(r.match(s), s)

    def test_requests_do_not(self):
        r = a.endings_for("Chloe")
        for s in ("Thanks, now open YouTube", "stop the music", "what's the weather",
                  "Yes", "All right.", "No, open my email instead", "never mind that, play music",
                  ""):
            self.assertFalse(r.match(s), s)

    def test_persona_explains_end_token(self):
        cmd = a.agent_command({**a.DEFAULTS, "name": "Chloe"}, "hi", False)
        self.assertIn(a.END_TOKEN, cmd[cmd.index("--append-system-prompt") + 1])

    def test_name_with_regex_characters(self):
        self.assertTrue(a.endings_for("J.A.R.V.I.S").match("thanks j.a.r.v.i.s"))


class SentenceSplitting(unittest.TestCase):
    def test_streamed_answer_splits_on_sentences_not_decimals(self):
        # Real deltas from `claude -p --output-format stream-json --include-partial-messages`
        deltas = ["The", " Moon is drifting away from", " Earth at", " about 3.8 cent", "imeters (1",
                  ".5 inches) per year", ". It", " is also", " tidally locked to", " Earth, so we",
                  " always see the same side", " of it", "."]
        buf, out, first_at = "", [], None
        for i, d in enumerate(deltas):
            buf += d
            ready, buf = a.split_sentences(buf)
            if ready and first_at is None:
                first_at = i
            out += ready
        out += a.split_sentences(buf, final=True)[0]
        self.assertEqual(out, [
            "The Moon is drifting away from Earth at about 3.8 centimeters (1.5 inches) per year.",
            "It is also tidally locked to Earth, so we always see the same side of it.",
        ])
        self.assertEqual(first_at, 6)  # spoken as soon as the next word arrives

    def test_abbreviations_do_not_split(self):
        self.assertEqual(a.split_sentences("Dr. Smith lives on Main St. in town. He's nice!", final=True)[0],
                         ["Dr. Smith lives on Main St. in town.", "He's nice!"])

    def test_no_is_not_an_abbreviation(self):
        self.assertEqual(a.split_sentences("The answer is no. Sorry about that.", final=True)[0],
                         ["The answer is no.", "Sorry about that."])

    def test_incomplete_sentence_waits(self):
        self.assertEqual(a.split_sentences("Opening YouTube for"), ([], "Opening YouTube for"))

    def test_end_token_stays_with_its_sentence(self):
        ready = a.split_sentences("Alright, I'll be here.<<END>>", final=True)[0]
        self.assertEqual([a.clean_for_speech(s.replace(a.END_TOKEN, "")) for s in ready],
                         ["Alright, I'll be here."])

    def test_first_piece_cuts_at_a_comma(self):
        text = "Octopuses have three hearts, two pumping blood to the gills and one to the rest"
        self.assertEqual(a.split_sentences(text, first=True),
                         (["Octopuses have three hearts,"],
                          "two pumping blood to the gills and one to the rest"))

    def test_first_piece_returns_only_one_piece(self):
        ready, rest = a.split_sentences("Sure thing, here you go. And another sentence. More", first=True)
        self.assertEqual(ready, ["Sure thing, here you go."])
        self.assertEqual(rest, "And another sentence. More")

    def test_first_piece_skips_short_openers_and_thousands(self):
        self.assertEqual(a.split_sentences("Well, about 1,000 of them", first=True),
                         ([], "Well, about 1,000 of them"))

    def test_later_sentences_ignore_commas(self):
        self.assertEqual(a.split_sentences("Octopuses have three hearts, two pumping blood")[0], [])

    def test_line_breaks_split(self):
        self.assertEqual(a.split_sentences("First thing here\nSecond thing", final=True)[0],
                         ["First thing here", "Second thing"])


class TalkingOverHer(unittest.TestCase):
    def feed(self, gate, frames, start=0.0):
        """frames: (mic level, her playing level) pairs, 30 ms apart. Returns the
        index of the frame that fired, or None."""
        for i, (level, playing) in enumerate(frames):
            if gate.feed(level, playing, start + i * 0.03):
                return i
        return None

    def test_speakers_ignore_her_own_echo(self):
        gate = a.BargeGate(echo_free=False)
        frames = [(7800, 4000), (6500, 3500), (300, 2000), (5000, 4500)] * 100   # 12 s of her talking
        self.assertIsNone(self.feed(gate, frames))

    def test_speakers_hear_you_in_her_pauses(self):
        gate = a.BargeGate(echo_free=False)
        quiet = [(80, 0)] * 30                                   # room noise, she's silent
        talking = [(6000, 4000)] * 10 + [(900, 20)] * 5          # her word, then a pause with you in it
        fired = self.feed(gate, quiet + talking)
        self.assertEqual(fired, 30 + 10 + 3)                     # 4th voice frame in her pause

    def test_one_blip_is_not_enough(self):
        gate = a.BargeGate(echo_free=False)
        frames = ([(80, 0)] * 20 + [(2000, 0)] + [(80, 0)] * 40) * 5   # a click every 1.8 s
        self.assertIsNone(self.feed(gate, frames))

    def test_headphones_hear_you_while_she_talks(self):
        gate = a.BargeGate(echo_free=True)
        frames = [(80, 4000)] * 30 + [(900, 4000)] * 5
        self.assertEqual(self.feed(gate, frames), 33)

    def test_quiet_speech_below_voice_level_is_ignored(self):
        gate = a.BargeGate(echo_free=True)
        self.assertIsNone(self.feed(gate, [(80, 0)] * 30 + [(400, 0)] * 30))

    def test_playback_level_window(self):
        track = a.PlaybackTrack()
        self.assertEqual(track.level(5.0), 0.0)                  # nothing played yet
        env = a.np.array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3000, 0, 0, 0, 0, 0, 0, 0, 0, 0], dtype=float)
        track.play(env, 100.0)
        at = lambda frame: track.level(100.0 + 0.03 * frame + 0.001)   # middle-ish of a frame
        self.assertEqual(at(5), 0.0)                             # well before the loud frame
        self.assertEqual(at(8), 0.0)
        self.assertEqual(at(9), 3000.0)                          # one frame ahead: it's coming up
        self.assertEqual(at(16), 3000.0)                         # 6 frames on: echo may still arrive
        self.assertEqual(at(17), 0.0)                            # past the echo window
        self.assertEqual(track.level(100.0 + 10), 0.0)           # long after it ended

    def test_pauses_between_pieces(self):
        self.assertEqual(a.pause_before(None), 0.0)                       # first piece: no delay
        self.assertEqual(a.pause_before("Octopuses have three hearts,"), a.CLAUSE_PAUSE)
        self.assertEqual(a.pause_before("Their blood is blue."), a.SENTENCE_PAUSE)
        self.assertEqual(a.pause_before("Really?"), a.SENTENCE_PAUSE)

    def test_loudness_envelope(self):
        sr = 24000
        t = a.np.arange(sr) / sr
        env = a.loudness_envelope(0.5 * a.np.sin(2 * a.np.pi * 220 * t), sr)
        self.assertEqual(len(env), 33)                           # 30 ms frames in 1 s
        self.assertAlmostEqual(float(env[10]), 0.5 / 2 ** 0.5 * 32768, delta=200)
        self.assertEqual(len(a.loudness_envelope(a.np.zeros(10), sr)), 0)


class SpeechCleanup(unittest.TestCase):
    def test_strips_markdown_and_urls(self):
        out = a.clean_for_speech("**Done.** See https://example.com\n- one\n- two `x`")
        self.assertEqual(out, "Done. See one two x")

    def test_drops_code_blocks(self):
        self.assertEqual(a.clean_for_speech("Here:\n```bash\nls\n```\nok"), "Here: ok")


if __name__ == "__main__":
    unittest.main()
