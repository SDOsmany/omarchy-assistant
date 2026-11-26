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


class SpeechCleanup(unittest.TestCase):
    def test_strips_markdown_and_urls(self):
        out = a.clean_for_speech("**Done.** See https://example.com\n- one\n- two `x`")
        self.assertEqual(out, "Done. See one two x")

    def test_drops_code_blocks(self):
        self.assertEqual(a.clean_for_speech("Here:\n```bash\nls\n```\nok"), "Here: ok")


if __name__ == "__main__":
    unittest.main()
