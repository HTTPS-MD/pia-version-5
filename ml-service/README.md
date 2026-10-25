# PIA ML service (hardened pia-ml-api)

Model and inference: the original's, unchanged (see the VERBATIM block in `src/entry.py`).
Exposure: server-to-server only; it is called by the `learning-profile` Edge Function.

The test scripts and the untouched copy of the original `entry.py` are kept on the `dev` branch.

## Staging (never production first)
1. `cd ml-service` and log in to the CLI with YOUR Cloudflare account.
2. Python Workers need the `workers` module that only `pywrangler` provides (plain `wrangler dev` fails with "No module named 'workers'"). Needs `uv` and Node on PATH:
   `uv run --with workers-py pywrangler dev --env staging` (local, real workerd/Pyodide runtime; put `ML_TOKEN=<synthetic>` in an untracked `.dev.vars`), then `uv run --with workers-py pywrangler deploy --env staging`.
3. `npx wrangler secret put ML_TOKEN --env staging`  (a long random value; never in the repo or the browser).
4. Optional: bind a KV namespace `ML_MODEL` (read-only use) holding the old model's centres under key `pia_online_kmeans_v2_human_reactions`.
5. Supabase: `supabase functions deploy learning-profile`, then set the secrets
   `PIA_ML_URL` (the staging Worker URL), `PIA_ML_TOKEN` (same value as ML_TOKEN), `PIA_ALLOWED_ORIGINS`.
6. Apply migration 0044 (`learning_features`, in `supabase/database-history.sql`) to the STAGING database first.
7. Try with a synthetic student only. Production only after review.
