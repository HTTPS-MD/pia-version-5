# Staging test report (Version 05)

Tested on 2026-10-26 at https://pia-version-5.pages.dev, which uses the separate PIA-Staging
Supabase project. No real student data was involved.

## What was tested by hand, with real Supabase and Cloudflare

| # | Test | Result |
|---|---|---|
| 1 | Admin sign-in with email and password | Pass |
| 2 | Add a student to a section (TEST-A, condition Assigned) | Pass |
| 3 | Open the class (called "Start attendance" until 2026-10-27), mark the student present, open the OCEAN stage | Pass |
| 4 | Student enters with the student number (Edge Function `join-with-number`, JavaScript version) | Pass |
| 5 | (Old rule, replaced on 2026-10-27) A second attempt was refused and the admin used "Let back in". Now the newest entry wins: see the retest in "To retest after the change" | Replaced |
| 6 | Name confirmation window ("Is this you?") | Pass |
| 7 | OCEAN test, 50 statements, saved; student waits in the waiting room | Pass |
| 8 | Admin opens the tutoring stage; the student page moves on by itself (live updates) | Pass |
| 9 | Math task bank: auto-generate and save 5 questions | Pass |
| 10 | Game: wrong answer, hint (does not give the answer), correct answer, next question | Pass |
| 11 | Admin sees the student online, stage, minutes per stage, active session | Pass |
| 12 | Student quits; active session goes to 0 and the student shows offline | Pass |
| 13 | Admin sends Reset password to the teacher; the email arrives and the link opens "Choose a new password" | Pass |
| 14 | Teacher sets a password and signs in through Teacher / Admin; the teacher OCEAN opens on first sign-in | Pass |
| 15 | Teacher dashboard shows the section, the student, status, stage and attendance (read-only) | Pass |
| 16 | Free choice: student picks a tutor (Ava) and tutoring uses that tutor | Pass |
| 17 | Neutral: no choice, tutor Noel assigned, two-step question solved, errors logged | Pass |
| 17b | Neutral: Request Hint (Tier 1/3) gives a method hint without the answer | Pass |
| 17c | Free choice: Request Hint (Tier 1/3) from Ava gives a method hint without the answer | Pass |
| 18 | Control: questionnaire only, no tutoring ("That is everything for now") | Pass |
| 19 | Students who arrive after the Tutoring switch is on go straight into tutoring (waiting room fix) | Pass |

## Not tested here

- Learning profile with the ML service (the ML service is not connected in staging; the page keeps its default wording).
- A whole class at once (more than 3 students).
- Anything that depends on the real data (old scores, existing sections).

## Notes

- The two Edge Functions are the JavaScript versions and need `supabase/config.toml` to be deployed.
- The staging database was built from a read-only copy of the real database structure (no data).

## To retest after the change of 2026-10-27 (newest entry wins)

- Enter with a student number on device A, then enter with the same number on device B: B gets in, A is signed out with a message.
- The admin row has no "Let back in" button. The number of re-entries is still counted in attendance_marks.refused_count (not shown on the row).
- Needs: deploy the join-with-number function to staging first.

## To retest after the stage-flow changes of 2026-10-27

- Waiting room: a student who already has a tutor (Assigned, Neutral, or Free choice after locking) sees "<Tutor> is ready!" with the tutor's picture. A student still waiting for OCEAN or for the tutor choice sees "Hang tight!".
- Waiting room: when the stage is already open for the section, the student moves on at once (no wait of up to 5 seconds).
- Choose a tutor: after "Yes, lock it in" the student sees "You picked <name>!" for about 2 seconds, then goes to the welcome page if Tutoring is open, or to the waiting room if it is not. There is no Continue button any more.
- Admin: the toggles are called "OCEAN test", "Choose tutor" and "Game" (they were "Character select" and "Tutoring dashboard").

## To check after the new tutor animations of 2026-10-27

- The welcome page (after choosing a tutor, or after the OCEAN for Assigned and Neutral) shows the tutor standing on the classroom stage as a short animation, in the school uniform. The files are in assets/images/welcome (one animated and one still picture per tutor; the still one is used when the device asks for less motion). Replaced on 2026-10-27 with the hair-and-blink idle animations (characters-hair-blink-v2, 384 x 512). The old GIF-based files are gone.
- The waiting room card ("<Tutor> is ready!") shows the same animation.
- Not changed yet: the character selection page and the game itself still use the original pictures (the tutors wear different clothes there).

## To retest after the same-message change of 2026-10-28

- Needs: deploy the join-with-number function to staging first.
- Enter a number that is not on the roster, and a number that is on the roster but not marked present: both show "We could not find you in this class today. Tell your admin." (same words, same status 404).
- A number marked present still gets in.
- Known gap: the name confirmation step ("Is this you?") still shows the name for a number that is on the roster while the class is open.
