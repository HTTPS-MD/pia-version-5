"""PIA learning-profile service (Cloudflare Python Worker): a rule-based decision tree.

The classifier is a MANUALLY AUTHORED decision tree (from the team's pia-ml-api-main-2), not a trained model:
nothing in this service learns, stores or updates anything. It replaces the earlier weighted nearest-centroid
(K-Means style) classifier. The six normalized features are unchanged; the fixed tree checks them with fixed
cut-offs and answers struggling, average or outstanding. THE CUT-OFFS ARE PROVISIONAL (prototype design
choices, not trained parameters and not validated educational standards): they must be reviewed with an
educator and frozen before the experiment. See ml-service/README.md.

The way the service is exposed is the hardened one, unchanged:

  * server-to-server only: Authorization: Bearer <ML_TOKEN> is required, and no CORS headers are sent, so a
    browser on any website can neither call it nor read it. The only intended caller is the Supabase Edge
    Function `learning-profile`.
  * strict input: exactly the seven numeric features, range checked. Any other field (a name, an email,
    "learn", ...) is rejected, not ignored.
  * minimal output: only {"profile"}. No path, no features, no GET /model.
  * nothing is logged, nothing is written.

Fails closed: without the ML_TOKEN secret configured, every request is refused.
"""
import hmac
import json
import math
from urllib.parse import urlparse

from workers import WorkerEntrypoint, Response

MODEL_NAME = "rule-based-decision-tree-3-profile-v1"
PROFILES = ["struggling", "average", "outstanding"]

# Normalized "performance strength" dimensions, each between 0 and 1.
FEATURES = [
    "accuracy_strength",
    "attempt_strength",
    "independence_strength",
    "correct_efficiency_strength",
    "correct_streak_strength",
    "wrong_streak_control",
]


def clamp(value, low=0.0, high=1.0):
    return max(low, min(high, value))


def as_float(data, key, default=0.0):
    try:
        number = float(data.get(key, default))
        return number if math.isfinite(number) else default
    except (TypeError, ValueError, OverflowError):
        return default


def feature_vector(data):
    accuracy = clamp(as_float(data, "recent_accuracy", 0.5))

    # 1 attempt is strongest. 5+ attempts reaches the bottom of this feature.
    average_attempts = max(1.0, as_float(data, "average_attempts", 1.0))
    attempt_strength = 1.0 - clamp((average_attempts - 1.0) / 4.0)

    hint_rate = clamp(as_float(data, "hint_rate", 0.0))

    # "No hint" must not look impressive when the learner is mostly wrong:
    # independence is only strong when it is paired with accuracy.
    independence_strength = accuracy * (1.0 - hint_rate)

    # Efficiency is calculated ONLY from correct responses. Without it, derive a fallback from the response
    # time, but only when some answers are correct.
    if "correct_response_efficiency" in data:
        correct_efficiency = clamp(as_float(data, "correct_response_efficiency", 0.0))
    else:
        average_response_time = max(0.0, as_float(data, "average_response_time", 120.0))
        correct_efficiency = 1.0 / (1.0 + average_response_time / 30.0) if accuracy > 0 else 0.0

    correct_streak_strength = clamp(as_float(data, "consecutive_correct", 0.0) / 5.0)
    wrong_streak_control = 1.0 - clamp(as_float(data, "consecutive_wrong", 0.0) / 5.0)

    return [
        accuracy,
        attempt_strength,
        independence_strength,
        correct_efficiency,
        correct_streak_strength,
        wrong_streak_control,
    ]


# A value below the threshold goes left, a value at or above it goes right.
def branch(feature, threshold, low, high):
    return {"feature": feature, "threshold": threshold, "left": low, "right": high}


# PROVISIONAL cut-offs (see the top of this file).
#  accuracy < 45%                -> struggling
#  45% to below 80%              -> average, unless repeated difficulty (long wrong streak with many attempts,
#                                   or accuracy below 60% with many attempts) -> struggling
#  80% or more                   -> outstanding only if ALL five safeguards pass (at most one wrong in a row,
#                                   2.8 attempts or fewer, hint independence, three correct in a row,
#                                   efficiency on correct answers); otherwise average.
DECISION_TREE = branch(
    "accuracy_strength", 0.45,
    "struggling",
    branch(
        "accuracy_strength", 0.80,
        branch(
            "wrong_streak_control", 0.35,
            branch("attempt_strength", 0.50, "struggling", "average"),
            branch(
                "accuracy_strength", 0.60,
                branch("attempt_strength", 0.35, "struggling", "average"),
                "average",
            ),
        ),
        branch(
            "wrong_streak_control", 0.75,
            "average",
            branch(
                "attempt_strength", 0.55,
                "average",
                branch(
                    "independence_strength", 0.55,
                    "average",
                    branch(
                        "correct_streak_strength", 0.50,
                        "average",
                        branch("correct_efficiency_strength", 0.30, "average", "outstanding"),
                    ),
                ),
            ),
        ),
    ),
)


def predict_tree(vector):
    """(profile, path): the label and the comparisons that led to it (for tests and audits)."""
    values = dict(zip(FEATURES, vector))
    node = DECISION_TREE
    path = []
    while isinstance(node, dict):
        value = values[node["feature"]]
        go_left = value < node["threshold"]
        path.append({
            "feature": node["feature"],
            "value": value,
            "operator": "<" if go_left else ">=",
            "threshold": node["threshold"],
        })
        node = node["left"] if go_left else node["right"]
    if node not in PROFILES:
        raise ValueError("tree leaf is not a profile")
    return node, path


# The only fields a request may carry, with the range each must lie in.
ALLOWED = {
    "recent_accuracy": (0.0, 1.0),
    "average_attempts": (1.0, 50.0),
    "hint_rate": (0.0, 1.0),
    "average_response_time": (0.0, 3600.0),
    "correct_response_efficiency": (0.0, 1.0),
    "consecutive_correct": (0.0, 100.0),
    "consecutive_wrong": (0.0, 100.0),
}
MAX_BODY_BYTES = 1024


def clean_features(data):
    """The seven numbers, or None if the body is anything else."""
    if not isinstance(data, dict) or set(data.keys()) != set(ALLOWED.keys()):
        return None
    out = {}
    for key, (low, high) in ALLOWED.items():
        value = data[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        if not math.isfinite(value) or value < low or value > high:
            return None
        out[key] = float(value)
    return out


class Default(WorkerEntrypoint):

    def reply(self, payload, status=200):
        # Deliberately NO Access-Control-* headers: browsers cannot use this.
        return Response(
            json.dumps(payload),
            status=status,
            headers={"Content-Type": "application/json", "Cache-Control": "no-store"},
        )

    def authorised(self, request):
        expected = getattr(self.env, "ML_TOKEN", None)
        if not expected:
            return False
        header = request.headers.get("Authorization") or ""
        if not header.startswith("Bearer "):
            return False
        return hmac.compare_digest(
            header[len("Bearer "):].encode("utf-8"), str(expected).encode("utf-8"))

    async def fetch(self, request):
        path = urlparse(request.url).path.rstrip("/") or "/"

        if request.method != "POST" or path != "/predict":
            return self.reply({"error": "Not found."}, status=404)

        if not self.authorised(request):
            return self.reply({"error": "Unauthorised."}, status=401)

        try:
            text = await request.text()
            if len(text.encode("utf-8")) > MAX_BODY_BYTES:
                return self.reply({"error": "Request too large."}, status=413)
            features = clean_features(json.loads(text))
        except Exception:
            features = None
        if features is None:
            return self.reply({"error": "Send exactly the seven numeric features."}, status=400)

        profile, _path = predict_tree(feature_vector(features))
        return self.reply({"profile": profile})
