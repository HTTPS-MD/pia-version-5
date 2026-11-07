"""Offline tests of the PIA rule-based decision tree and of the service's input rules.
Run from ml-service/:   python3 -m unittest discover -s tests -v
The Cloudflare `workers` module is replaced by a stub, so no Cloudflare tooling is needed.
"""
import asyncio
import importlib.util
import json
import math
import pathlib
import sys
import types
import unittest

stub = types.ModuleType("workers")


class _Entry:
    pass


class _Response:
    def __init__(self, body=None, status=200, headers=None):
        self.body, self.status, self.headers = body, status, headers or {}


stub.WorkerEntrypoint, stub.Response = _Entry, _Response
sys.modules["workers"] = stub
SRC = pathlib.Path(__file__).resolve().parent.parent / "src" / "entry.py"
spec = importlib.util.spec_from_file_location("entry", SRC)
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)

GOOD = dict(recent_accuracy=0.9, average_attempts=1.2, hint_rate=0.1, average_response_time=20,
            correct_response_efficiency=0.8, consecutive_correct=4, consecutive_wrong=0)


def profile(**over):
    data = dict(GOOD, **over)
    return entry.predict_tree(entry.feature_vector(data))[0]


class Tree(unittest.TestCase):
    def test_outstanding_needs_all_five_safeguards(self):
        self.assertEqual(profile(), "outstanding")
        self.assertEqual(profile(consecutive_correct=2), "average")          # streak
        self.assertEqual(profile(hint_rate=0.5), "average")                 # independence
        self.assertEqual(profile(correct_response_efficiency=0.2), "average")  # efficiency
        self.assertEqual(profile(average_attempts=3.5), "average")          # attempts
        self.assertEqual(profile(consecutive_wrong=2), "average")           # wrong streak
        self.assertEqual(profile(recent_accuracy=0.79), "average")          # accuracy

    def test_struggling(self):
        self.assertEqual(profile(recent_accuracy=0.44), "struggling")
        self.assertEqual(profile(recent_accuracy=0.5, average_attempts=4.0, consecutive_wrong=4), "struggling")
        self.assertEqual(profile(recent_accuracy=0.55, average_attempts=4.0, consecutive_wrong=0), "struggling")
        self.assertEqual(profile(recent_accuracy=0.7, average_attempts=4.0, consecutive_wrong=0), "average")

    def test_typical_student_is_average(self):
        self.assertEqual(profile(recent_accuracy=0.7, average_attempts=1.8, hint_rate=0.2,
                                 correct_response_efficiency=0.5, consecutive_correct=2, consecutive_wrong=1), "average")

    def test_boundaries(self):
        self.assertEqual(profile(recent_accuracy=0.45, average_attempts=1, consecutive_wrong=0), "average")
        self.assertEqual(profile(recent_accuracy=math.nextafter(0.45, 0)), "struggling")

    def test_every_leaf_is_a_profile_and_path_ends_at_a_leaf(self):
        import random
        random.seed(7)
        for _ in range(5000):
            d = dict(recent_accuracy=random.random(), average_attempts=1 + random.random() * 6,
                     hint_rate=random.random(), average_response_time=random.random() * 300,
                     correct_response_efficiency=random.random(),
                     consecutive_correct=random.randint(0, 8), consecutive_wrong=random.randint(0, 8))
            p, path = entry.predict_tree(entry.feature_vector(d))
            self.assertIn(p, entry.PROFILES)
            self.assertTrue(1 <= len(path) <= 11)

    def test_response_time_is_only_a_fallback(self):
        d = dict(GOOD)
        del d["correct_response_efficiency"]
        d["average_response_time"] = 20
        self.assertIn(entry.predict_tree(entry.feature_vector(d))[0], entry.PROFILES)
        slow = dict(GOOD, average_response_time=3000)   # explicit efficiency wins over time
        self.assertEqual(entry.predict_tree(entry.feature_vector(slow))[0], "outstanding")


class Input(unittest.TestCase):
    def test_exactly_the_seven_numbers(self):
        self.assertIsNotNone(entry.clean_features(dict(GOOD)))
        self.assertIsNone(entry.clean_features(dict(GOOD, name="x")))
        self.assertIsNone(entry.clean_features(dict(GOOD, learn=True)))
        extra = dict(GOOD); del extra["hint_rate"]
        self.assertIsNone(entry.clean_features(extra))
        self.assertIsNone(entry.clean_features(dict(GOOD, recent_accuracy=1.5)))
        self.assertIsNone(entry.clean_features(dict(GOOD, recent_accuracy=True)))
        self.assertIsNone(entry.clean_features(dict(GOOD, recent_accuracy=float("nan"))))
        self.assertIsNone(entry.clean_features([1, 2]))


class Service(unittest.TestCase):
    def call(self, method="POST", path="/predict", body=None, token="secret", sent="secret"):
        svc = entry.Default()
        svc.env = types.SimpleNamespace(**({"ML_TOKEN": token} if token else {}))

        class Req:
            pass
        r = Req()
        r.method, r.url = method, "https://x.dev" + path
        r.headers = {"Authorization": "Bearer " + sent} if sent else {}

        async def text():
            return body if isinstance(body, str) else json.dumps(body)
        r.text = text
        res = asyncio.run(svc.fetch(r))
        return res.status, json.loads(res.body), res.headers

    def test_needs_the_token(self):
        self.assertEqual(self.call(body=GOOD, sent="wrong")[0], 401)
        self.assertEqual(self.call(body=GOOD, sent=None)[0], 401)
        self.assertEqual(self.call(body=GOOD, token=None)[0], 401)   # not configured: refuses everyone

    def test_answers_only_the_profile_and_no_cors(self):
        status, out, headers = self.call(body=GOOD)
        self.assertEqual((status, out), (200, {"profile": "outstanding"}))
        self.assertFalse([h for h in headers if h.lower().startswith("access-control")])

    def test_other_routes_and_bad_bodies(self):
        self.assertEqual(self.call(method="GET", path="/model")[0], 404)
        self.assertEqual(self.call(method="GET", path="/")[0], 404)
        self.assertEqual(self.call(body="not json")[0], 400)
        self.assertEqual(self.call(body=dict(GOOD, learn=True))[0], 400)
        self.assertEqual(self.call(body="x" * 2000)[0], 413)


if __name__ == "__main__":
    unittest.main()
