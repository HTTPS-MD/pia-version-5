# Rule specification and thesis methodology notes

## Classification method

The method is a **manually authored deterministic decision tree**. It uses fixed, interpretable branching conditions. The tree is *not* trained with student examples and does not optimize an impurity measure (information gain, Gini, etc.). No training dataset is required to define the rules. Student interactions are still required to calculate reliable inputs during application use.

The pipeline is:

`student answers -> six derived normalized features -> rule-based decision tree -> struggling/average/outstanding`

## Reused feature engineering

| Normalized feature | Existing calculation | Meaning |
|---|---|---|
| `accuracy_strength` | Clamp `recent_accuracy` to [0,1] | Accuracy of recent responses |
| `attempt_strength` | `1 - clamp((max(1, average_attempts) - 1)/4)` | Higher when fewer attempts are needed |
| `independence_strength` | `accuracy_strength * (1 - clamp(hint_rate))` | Hint independence is credited only alongside accuracy |
| `correct_efficiency_strength` | Clamp explicit `correct_response_efficiency`; otherwise legacy response-time fallback when accuracy > 0 | Efficiency on correct responses |
| `correct_streak_strength` | Clamp `consecutive_correct / 5` | Recent correct-answer streak |
| `wrong_streak_control` | `1 - clamp(consecutive_wrong / 5)` | Higher when there are fewer consecutive wrong responses |

`clamp()` here bounds values to [0,1]. The six old feature weights remain in the `performance_score` reporting calculation. **They do not determine which Decision Tree branch is taken.**

## Current provisional rules

These are preliminary choices for implementation and discussion, **not validated educational standards**.

1. Accuracy below 45% -> `struggling`.
2. Accuracy from 45% to below 80% -> normally `average`.
   - If wrong-streak control is below 0.35 (normally at least four consecutive wrong answers) *and* attempt strength is below 0.50 (more than three attempts on average), return `struggling`.
   - Otherwise, if accuracy is below 60% *and* attempt strength is below 0.35 (more than 3.6 attempts on average), return `struggling`.
3. Accuracy at least 80% -> `outstanding` **only if all of the following are true**:
   - Wrong-streak control >= 0.75 (at most one consecutive wrong answer for integer streaks).
   - Attempt strength >= 0.55 (2.8 attempts or fewer on average).
   - Independence strength >= 0.55 (accuracy-adjusted hint independence).
   - Correct-streak strength >= 0.50 (at least three consecutive correct answers for integer streaks).
   - Correct-efficiency strength >= 0.30.
   - If any check fails, return `average`.

A root-to-leaf path is included in `decision_path` so reviewers can see precisely why a label was given.

## Disclosures important for thesis defense

- This is a **rule-based Decision Tree**, not a trained classification model. Do not report model training, learned feature importance, or ML predictive accuracy.
- The cutoff numbers were authored for a prototype and **must be justified and reviewed** before final research use. They do not automatically become valid merely because the code executes.
- Not all six metrics appear in every path: a Decision Tree checks only the conditions relevant to reaching a leaf.
- The old `performance_score` weights are present for continuity only. The six features influence decisions according to the tree structure, not via a weighted distance.
- No historical student dataset was available in the supplied repository. Future collected student data can be used for **evaluation and refinement** of the manually defined rubric, not automatically as ground truth.
- The legacy missing-field defaults are retained for compatibility; absence of observations may bias a profile. The app should obtain a minimum number of attempted questions before relying on the label.

## Suggested evaluation plan (to complete using real, consented data)

1. Define an educator-reviewed criterion for each category before examining system outputs.
2. Define how many questions must be answered before profile assignment is eligible.
3. Record normalized inputs, decision paths, and the educator's independently assigned level.
4. Compare agreement using a confusion matrix, per-class recall/precision, and agreement rate. If using a small sample, report counts and uncertainty rather than broad accuracy claims.
5. Inspect disagreements, thresholds, response-time sensitivity, and missing-feature cases.
6. Keep an audit trail of any rule changes. If thresholds change after viewing evaluation data, evaluate again on a separate holdout set.


## Observation minimum in PIA

PIA reads the features from the student's last eight graded submissions (a step answered as working and then a final value counts once) and asks the tree only after **four** of them (`MIN_EVENTS` in `supabase/functions/learning-profile/handler.js`). Before that the profile stays `average`. This is an application setting chosen for the prototype, not a validated sufficiency threshold; justify or change it with the educator before the experiment.
