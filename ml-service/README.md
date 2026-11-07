# PIA learning-profile service (rule-based decision tree)

A manually authored decision tree classifies a student's recent performance as `struggling`, `average` or `outstanding`.
It replaces the earlier weighted nearest-centroid (K-Means style) classifier. The six normalized features are the same.
Source of the tree: the team's `pia-ml-api-main-2` (checked identical on 200,000 random inputs).

**It is not a trained model.** The cut-offs are provisional prototype choices, not trained parameters and not validated
educational standards. Do not report training, learned feature importance or predictive accuracy. Review the rules with an
educator and freeze them before the experiment; if they change after looking at results, evaluate again on new data.
The full rule list and the suggested evaluation plan are in [docs/rule-methodology.md](docs/rule-methodology.md).

## How it is exposed (unchanged, hardened)
- Server-to-server only. It is called by the `learning-profile` Edge Function, never by a browser.
- `POST /predict` needs `Authorization: Bearer <ML_TOKEN>`; without the secret configured, every request is refused.
- No CORS headers, no `GET /model`, nothing logged, nothing written.
- Input: exactly the seven numeric features, range checked (anything else is rejected). Output: `{"profile": "..."}` only.
  The Edge Function adds `confidence: null` for the page, because a tree has no probability. The page uses only the profile.
- Nothing a request says can change the rules: there is no learning.

## Test (no Cloudflare tools needed)
```
cd ml-service
python3 -m unittest discover -s tests -v
```

## Staging (never production first)
1. `cd ml-service` and log in to the CLI with YOUR Cloudflare account.
2. Python Workers need the `workers` module that only `pywrangler` provides. Needs `uv` and Node on PATH:
   `uv run --with workers-py pywrangler dev --env staging` (local; put `ML_TOKEN=<synthetic>` in an untracked `.dev.vars`),
   then `uv run --with workers-py pywrangler deploy --env staging`.
3. `npx wrangler secret put ML_TOKEN --env staging` (a long random value; never in the repo or the browser). Keep the same value.
4. Supabase: `supabase functions deploy learning-profile` (it now accepts an answer without `confidence`), with the existing
   secrets `PIA_ML_URL`, `PIA_ML_TOKEN`, `PIA_ALLOWED_ORIGINS`.
5. Try with a synthetic student only. The old KV namespace is no longer read.
