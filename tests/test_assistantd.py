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


class SpeechCleanup(unittest.TestCase):
    def test_strips_markdown_and_urls(self):
        out = a.clean_for_speech("**Done.** See https://example.com\n- one\n- two `x`")
        self.assertEqual(out, "Done. See one two x")

    def test_drops_code_blocks(self):
        self.assertEqual(a.clean_for_speech("Here:\n```bash\nls\n```\nok"), "Here: ok")


if __name__ == "__main__":
    unittest.main()
