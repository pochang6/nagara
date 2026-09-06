"""Codex の通知だけを検証する。実機の nagara や音声エンジンは起こさない。"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


HOOK = Path(__file__).resolve().parents[1] / 'hooks/nagara-codex-notify.sh'
TITLE = ('You are a helpful assistant. You will be presented with a user prompt, '
         'and your job is to provide a short title for a task that will be created from that prompt.')
SUGGESTIONS = '# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /example'
SAFETY = 'You are an expert at upholding safety and compliance standards for Codex ambient suggestions.'


class NotifyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.requests = []

        class Receiver(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                cls.requests.append((self.path, None))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{}')

            def do_POST(self):
                data = self.rfile.read(int(self.headers['Content-Length']))
                cls.requests.append((self.path, json.loads(data)))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{}')

            def log_message(self, *args):
                pass

        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.requests.clear()

    def payload(self, text='通常の回答です。', prompt='動作を確認してください。'):
        return {'type': 'agent-turn-complete', 'thread-id': 'test-thread',
                'turn-id': 'test-turn', 'cwd': '/example',
                'input-messages': [prompt], 'last-assistant-message': text}

    def run_hook(self, payload, chain=()):
        raw = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
        env = dict(os.environ, NAGARA_PORT=str(self.server.server_port))
        result = subprocess.run(['bash', str(HOOK), *chain, raw], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return raw

    def test_normal_reply(self):
        self.run_hook(self.payload('  **修正しました。**\n二文目です。  '))
        self.assertEqual(self.requests, [('/status', None),
            ('/speak', {'text': '**修正しました。**\n二文目です。', 'source': 'Codex'})])

    def test_internal_jobs_never_contact_player(self):
        for prompt, text in [(TITLE, '{"title":"A task","description":"A description"}'),
                             (SUGGESTIONS, '{"suggestions":[]}'),
                             (SAFETY, '{"exclude":[]}'),
                             (TITLE, 'A plain text title'),
                             (SAFETY, 'No exclusions.')]:
            with self.subTest(prompt=prompt):
                self.run_hook(self.payload(text, prompt))
                self.assertEqual(self.requests, [])

    def test_whitespace_and_suggestion_count(self):
        prompt = SUGGESTIONS.replace('0 to 3', '1 to 5').replace(' ', '\n')
        self.run_hook(self.payload('{"suggestions":[]}', prompt))
        self.assertEqual(self.requests, [])

    def test_requested_json_is_preserved(self):
        for text in ['{"exclude":[]}', '{"suggestions":[]}',
                     '{"title":"A task","description":"A description"}', '[1,2,3]']:
            with self.subTest(text=text):
                self.requests.clear()
                self.run_hook(self.payload(text, '指定したJSONを返してください。'))
                self.assertEqual(self.requests[-1], ('/speak', {'text': text, 'source': 'Codex'}))

    def test_discussion_of_internal_prompts_is_preserved(self):
        self.run_hook(self.payload('この依頼文の意味を説明します。', '以下の依頼文を説明して：\n' + TITLE))
        self.assertEqual(self.requests[-1][0], '/speak')

    def test_internal_control_reply(self):
        self.run_hook(self.payload('再生を始めました。', '<!-- nagara:internal -->\n再生してください。'))
        self.assertEqual(self.requests, [])

    def test_missing_inputs_keeps_cli_compatibility(self):
        payload = self.payload()
        del payload['input-messages']
        self.run_hook(payload)
        self.assertEqual(self.requests[-1][0], '/speak')

    def test_invalid_notifications_never_contact_player(self):
        cases = ['not json', '[]', 'null', '{}',
                 dict(self.payload(), type='other'),
                 dict(self.payload(), **{'last-assistant-message': None}),
                 dict(self.payload(), **{'last-assistant-message': {'text': 'wrong type'}}),
                 dict(self.payload(), **{'last-assistant-message': '  '}),
                 dict(self.payload(), **{'input-messages': 'wrong type'}),
                 dict(self.payload(), **{'input-messages': [None]})]
        for payload in cases:
            with self.subTest(payload=payload):
                self.run_hook(payload)
                self.assertEqual(self.requests, [])

    def test_chain_always_receives_original_payload_and_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / 'capture.json'
            program = Path(directory) / 'previous.py'
            program.write_text('import json,sys\nfrom pathlib import Path\n'
                               'Path(sys.argv[1]).write_text(json.dumps(sys.argv[2:]))\n')
            for payload in [self.payload(), self.payload('{"exclude":[]}', SAFETY), 'bad json']:
                with self.subTest(payload=payload):
                    raw = self.run_hook(payload, [sys.executable, str(program), str(capture), 'arg with spaces'])
                    self.assertEqual(json.loads(capture.read_text()), ['arg with spaces', raw])

    def test_no_arguments_is_noop(self):
        result = subprocess.run(['bash', str(HOOK)], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.requests, [])


if __name__ == '__main__':
    unittest.main()
