-- The Game no longer has a start and end time: the admin opens and closes it by hand, like the other stages.
-- Run in the Supabase SQL editor (project PIA-Staging) after the admin screen is deployed. Safe to run more than once.
--
-- It only empties public.tutoring_schedule. The table, its functions and its trigger stay in place, unused.
-- An old row (for example a test end time that already passed) would keep the Game closed for its section,
-- and the screen can no longer clear it.
--
-- Rollback: none needed. The rows were only start and end times.

delete from public.tutoring_schedule;
