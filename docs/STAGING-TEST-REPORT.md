# Staging test report (Version 05)

Tested on 2026-10-26 at https://pia-version-5.pages.dev, which uses the separate PIA-Staging
Supabase project. No real student data was involved.

## What was tested by hand, with real Supabase and Cloudflare

| # | Test | Result |
|---|---|---|
| 1 | Admin sign-in with email and password | Pass |
| 2 | Add a student to a section (TEST-A, condition Assigned) | Pass |
| 3 | Start attendance, mark the student present, open the OCEAN stage | Pass |
| 4 | Student enters with the student number (Edge Function `join-with-number`, JavaScript version) | Pass |
| 5 | Second attempt is refused ("already in on another computer"); admin sees "Tried again" and uses "Let back in" | Pass |
| 6 | Name confirmation window ("Is this you?") | Pass |
| 7 | OCEAN test, 50 statements, saved; student waits in the waiting room | Pass |
| 8 | Admin opens the tutoring stage; the student page moves on by itself (live updates) | Pass |
| 9 | Math task bank: auto-generate and save 5 questions | Pass |
| 10 | Game: wrong answer, hint (does not give the answer), correct answer, next question | Pass |
| 11 | Admin sees the student online, stage, minutes per stage, active session | Pass |
| 12 | Student quits; active session goes to 0 and the student shows offline | Pass |

## Not tested here

- Teacher page (needs a teacher account).
- Learning profile with the ML service (the ML service is not connected in staging; the page keeps its default wording).
- Email links (activation and password reset).
- Conditions other than Assigned (free choice, neutral, control), and a whole class at once.
- Anything that depends on the real data (old scores, existing sections).

## Notes

- The two Edge Functions are the JavaScript versions and need `supabase/config.toml` to be deployed.
- The staging database was built from a read-only copy of the real database structure (no data).
