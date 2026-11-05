# PIA: planned revisions (attendance, teacher module, paper)

Last updated: 2026-11-05. Nothing in sections A to C is built yet unless marked DONE.

## A. Start / End attendance logic

STATUS (2026-11-05): items 1, 2, 3, 3b, 3c and 3d are BUILT on this computer, not yet applied or pushed:
`supabase/staging/15-start-attendance-reopen-and-lock.sql` (run it FIRST in the Supabase SQL editor), the door
(`supabase/functions/join-with-number`, deploy it AFTER the SQL), and the admin screen (`admin/js/students-tools.js`,
`admin/js/stage-controls.js`). Checked with fake data only: the door logic and the checkpoint logic pass, and both
admin scripts load without a top-level error. Not yet checked: the SQL against the real database, and the screen
with a real admin login.

Decided:
1. **Start attendance again reopens the same record of the day** (does not create a new one). Marks and "Entered" stay, so the one-entry rule cannot be reset by pressing Start twice.
2. **Attendance locks for good once any stage opens** for that section. Until the first stage opens (OCEAN), Start attendance again is allowed and a late student can be marked Present. This lock must be enforced in the database, not only on screen.

3. DECIDED: **Checkpoint before the first stage opens:** "Lock attendance and open OCEAN test? 17 Present, 2 Absent: Mark, Ana. After this, attendance cannot be changed." Cancel or Lock and open. Asked once, on the first stage only. No correction after the lock (can be added later).

3b. DECIDED: **No auto-expiry.** Today the 120-minute timer silently closes attendance and unlocks the stages if the admin forgets End. New rule: attendance stays open until the admin presses End or the first stage opens (lock). The 120 minutes goes away; only a very large ceiling (about 12 hours) remains so nothing stays open overnight. Needs `admin_start_checkin`, `admin_set_attendance`, the overview and the stage-lock trigger changed together.

3c. DECIDED: **Everyone is Present the moment attendance starts.** The admin only toggles Absent. No "Mark all present" button and no "Not marked" state. The checkpoint (3) lists the Absent names and refuses to lock while anyone is still Not marked (for example a student added to the section after Start).

3d. DECIDED: **The door closes when attendance locks.** After End attendance, Present students can still enter (the admin waits for everyone). The moment the admin confirms the checkpoint and the first stage opens, a Present student who has not entered yet can no longer enter (recorded as "Present, did not participate"). Let back in is only for a student who already entered and crashed. The checkpoint also lists "Present but not in yet" so the admin can cancel and wait. This replaces the 3-hour cutoff idea for the door.

3e. DECIDED (built locally, SQL 17 not run yet): **the attendance day is the calendar day in Philippine time**, not the last 16 hours. At 12:00 AM the section goes back to "Start attendance". Same rule in the database (`pia_current_checkin`, `admin_attendance`, `admin_let_back_in`) and in the door. Known edge: a session that starts before midnight and runs past it is cut at midnight.
3f. DECIDED and shipped: after the lock, a Present student who never entered shows "Present, did not participate"; a student who is in shows only "Entered".
Note: `docs/session-flowchart-recommended.png` still says "within the last 16 hours" and does not show the checkpoint and lock. Redraw it before the defense.

Proposed, waiting for a decision:
4. A separate **"Start a new session"** button, with a heavy warning, for a truly fresh start on the same day.
5. Define "the day" as the same window the door uses (not midnight).
6. **Entry cutoff of 3 hours from Start** (replaces the 16 hours). The number 3 is my default; confirm.

## B. Hardening

7. Game lock in the database (trigger), like OCEAN and Choose tutor. Today it is on screen only.
8. One log of admin actions: Start, End, every mark change, every stage open and close, every correction (who, when, from, to).
9. Smoke test before every push to the admin page: open it headless and fail on any console error. (The 2026-11-05 outage came from a script that used `window.PIAAdmin` before it existed.)
10. Accepted trade-off, not fixed: a student who quits or crashes needs **Let back in**. Safer than letting them back in alone, because the room is supervised.

## C. Teacher module

11. The teacher roster (`teacher_section_roster`) only reads an open attendance record, so after End the teacher sees "—". Make it read the day's record.
12. **Download attendance** button for the teacher (CSV, opens in Excel). Rows: students marked Present who entered that day. Columns: name, section, date, time entered. **No student number** (it is the login), **no group or personality** (CERC "labeling" concern). Optional: the same button on the admin page.
13. Run a new SQL migration (15) in the Supabase SQL editor for 11 and 12.

## D. Flow and experiment day

14. Keep stage control. Open the Game only when everyone is out of OCEAN and Choose tutor, so the Game window is equal for all conditions. Set a closing time for the Game, then **Sign out all**.
15. Decide what happens to a student in the middle of a problem when the Game closes (today the notice says they can finish and submit what they started).
16. Verify on a real student account: Sign out, Sign out all (modal after the Game closes), Absent and Not marked cannot enter after End, the "Start attendance again?" prompt.

## E. Waiting to be pushed

17. Stage-closed notice as a modal (`assets/js/shared/activity-tracking.js`, student page version bumps). Tested locally, not committed.

## F. Paper and CERC

18. Who can see the personality labels (the Character column in the admin, the teacher view)? CERC reviewer 2 asked.
19. Security and retention of `entry_log` and system logs (CERC asked about encryption and access).
20. Fix the Research Instrument sentence that splits the experimental group into "matching" and "non-matching"; Non-assigned means free choice.
21. Align the paper with the system: k-means (not Decision Tree and scikit-learn), the answer checker, section names (Earth, Jupiter, Mercury).
22. Describe the intervention: how many sessions, how long, which topic, how long the control group is in class.
23. Numbers: 4 groups of 19 is 76, not 73; make "89 students" clear; add a pre-test equality check; consider ANCOVA; choose "randomized" or "quasi-experimental".
24. Write the remaining holes as Limitations and Recommendations (Chapter 5).

## G. Re-entry bell (design in progress, nothing built yet)

A bell at the top with a count of students who tried to sign in again. Let back in moves from the row into the bell.
- DECIDED: the bell shows the student's initials (already visible in the table under Privacy Mode) and the section name.
- DECIDED: tapping Let back in first asks "Is this the real student? Check in the room before you confirm." (the person trying may be someone using the student's number; the newest sign-in wins, so a blind tap would sign the real student out).
- DECIDED: the count covers only the section being viewed, because sessions never run at the same time in two sections. Revisit if that changes.
- Known and accepted: Dismiss is kept in the browser only; the record stays in entry_log and the row keeps a small "Tried again xN".
- Other things the panel may ask: the bell should not grow into a general notification center (scope).
