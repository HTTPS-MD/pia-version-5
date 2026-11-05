-- Start attendance: reopen the same record, no silent expiry, lock when the first stage opens, door closes at the lock.
-- Run in the Supabase SQL editor (project PIA-Staging). Safe to run more than once.
-- It adds two columns (checkins.locked_at, attendance_marks.entered_once) and replaces a few functions.
-- No existing row is changed, except that rows already marked as entered get entered_once = true.
--
-- What changes
--  1. Start attendance again, on the same day, REOPENS the newest record of the section (started in the last
--     16 hours) instead of creating a new one. The marks and "Entered" stay, so the one-entry rule cannot be
--     reset by pressing Start twice. A new day (no record in the last 16 hours) creates a new record.
--  2. Everyone in the section is Present the moment a record is created. The admin only toggles Absent.
--  3. No 120-minute expiry. A record stays open until the admin ends it. ends_at is kept only as a 12-hour
--     ceiling, so every query that reads "ends_at > now()" keeps working and nothing stays open overnight.
--  4. LOCK: when the first stage is opened for the section (a stage_overrides row, or a tutoring schedule),
--     the newest record gets locked_at. It is refused while the record is still open, and refused while any
--     student has no mark (Not marked). A locked record cannot be reopened and its marks cannot change.
--  5. The door: a Present student who has never entered cannot enter after the lock (recorded as
--     "Present, did not participate"). A student who entered before can still be let back in by the admin.
--     The check and the entry are one atomic function (pia_claim_entry), so there is no race with the lock.
--  6. admin_attendance_status(section) tells the dashboard: none, open, ended or locked.
--
-- Rollback: put these functions back as in 01-schema.sql / 12 / 13 and:
--   drop trigger if exists tutoring_schedule_lock on public.tutoring_schedule;
--   drop function if exists public.pia_claim_entry(uuid, text), public.admin_attendance_status(text), public.pia_current_checkin(text);
--   (the two columns can stay.)

alter table public.checkins add column if not exists locked_at timestamptz;
alter table public.attendance_marks add column if not exists entered_once boolean not null default false;
update public.attendance_marks set entered_once = true where entered_at is not null and entered_once = false;

-- The record of the section that is "today's": the newest one that started in the last 16 hours.
create or replace function public.pia_current_checkin(p_section text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select c.id
    from public.checkins c
   where c.section = trim(p_section)
     and c.started_at > now() - interval '16 hours'
   order by c.started_at desc
   limit 1;
$$;
revoke all on function public.pia_current_checkin(text) from public, anon, authenticated;

create or replace function public.admin_start_checkin(p_section text, p_minutes integer default 15)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := trim(p_section);
  v_id      uuid;
  v_locked  timestamptz;
begin
  perform public.pia_require_admin();
  if nullif(v_section, '') is null then
    raise exception 'PIA: choose a section.' using errcode = 'P0001';
  end if;

  v_id := public.pia_current_checkin(v_section);
  if v_id is not null then
    select c.locked_at into v_locked from public.checkins c where c.id = v_id;
    if v_locked is not null then
      raise exception 'PIA: attendance is final for this section. A stage was already opened.' using errcode = 'P0001';
    end if;
    -- Same record again: close any other open one, then reopen this one.
    update public.checkins set stopped_at = now()
     where section = v_section and stopped_at is null and id <> v_id;
    update public.checkins
       set stopped_at = null, ends_at = now() + interval '12 hours'
     where id = v_id;
  else
    update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
    insert into public.checkins (section, ends_at, started_by)
    values (v_section, now() + interval '12 hours', public.current_email())
    returning id into v_id;
  end if;

  -- Everyone starts Present. A mark that already exists is never touched.
  insert into public.attendance_marks (checkin_id, email, present)
  select v_id, lower(p.email), true
    from public.profiles p
   where trim(p.section) = v_section
     and lower(trim(coalesce(p.role, 'student'))) = 'student'
     and nullif(trim(coalesce(p.email, '')), '') is not null
  on conflict (checkin_id, email) do nothing;

  return v_id;
end;
$$;

create or replace function public.admin_set_attendance(p_section text, p_email text, p_present boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id      uuid;
  v_stopped timestamptz;
  v_ends    timestamptz;
  v_locked  timestamptz;
  v_email   text := lower(trim(coalesce(p_email, '')));
begin
  perform public.pia_require_admin();
  v_id := public.pia_current_checkin(p_section);
  if v_id is null then
    raise exception 'Attendance is not open for this section.' using errcode = 'P0001';
  end if;
  select c.stopped_at, c.ends_at, c.locked_at into v_stopped, v_ends, v_locked
    from public.checkins c where c.id = v_id;
  if v_locked is not null then
    raise exception 'Attendance is final. It cannot be changed after a stage was opened.' using errcode = 'P0001';
  end if;
  if v_stopped is not null or v_ends <= now() then
    raise exception 'Attendance is not open for this section.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles p
                  where lower(p.email) = v_email and trim(p.section) = trim(p_section)
                    and lower(trim(coalesce(p.role, 'student'))) = 'student') then
    raise exception 'That student is not in this section.' using errcode = 'P0001';
  end if;
  if p_present is null then
    delete from public.attendance_marks where checkin_id = v_id and email = v_email;
  else
    insert into public.attendance_marks (checkin_id, email, present)
    values (v_id, v_email, p_present)
    on conflict (checkin_id, email) do update set present = excluded.present, marked_at = now();
  end if;
end;
$$;

-- none | open | ended | locked, for the newest record of the section.
create or replace function public.admin_attendance_status(p_section text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
  r    record;
begin
  perform public.pia_require_admin();
  v_id := public.pia_current_checkin(p_section);
  if v_id is null then return 'none'; end if;
  select c.stopped_at, c.ends_at, c.locked_at into r from public.checkins c where c.id = v_id;
  if r.locked_at is not null then return 'locked'; end if;
  if r.stopped_at is null and r.ends_at > now() then return 'open'; end if;
  return 'ended';
end;
$$;
revoke all on function public.admin_attendance_status(text) from public, anon;
grant execute on function public.admin_attendance_status(text) to authenticated;

-- Opening a stage (a stage_overrides row, or a tutoring schedule) locks the section's attendance.
create or replace function public.stage_lock_while_session_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  r    record;
begin
  v_id := public.pia_current_checkin(new.section);
  if v_id is null then
    return new;                       -- no attendance taken today: nothing to lock
  end if;
  select c.stopped_at, c.ends_at, c.locked_at into r from public.checkins c where c.id = v_id;
  if r.locked_at is not null then
    return new;                       -- already locked: later stages open freely
  end if;
  if r.stopped_at is null and r.ends_at > now() then
    raise exception 'PIA: end attendance before opening a stage for this section.' using errcode = 'P0001';
  end if;
  if exists (
    select 1 from public.profiles p
     where trim(p.section) = trim(new.section)
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and not exists (select 1 from public.attendance_marks m
                        where m.checkin_id = v_id and m.email = lower(p.email))
  ) then
    raise exception 'PIA: mark every student Present or Absent before opening a stage.' using errcode = 'P0001';
  end if;
  update public.checkins set locked_at = now() where id = v_id;
  return new;
end;
$$;

drop trigger if exists stage_overrides_lock on public.stage_overrides;
create trigger stage_overrides_lock
  before insert or update on public.stage_overrides
  for each row execute function public.stage_lock_while_session_open();

drop trigger if exists tutoring_schedule_lock on public.tutoring_schedule;
create trigger tutoring_schedule_lock
  before insert or update on public.tutoring_schedule
  for each row execute function public.stage_lock_while_session_open();

-- The door's one atomic step: let the student in only if Present, not already in, and (the record is not
-- locked, or the student has entered before and was let back in).
create or replace function public.pia_claim_entry(p_checkin uuid, p_email text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update public.attendance_marks m
     set entered_at = now(), entered_once = true
    from public.checkins c
   where c.id = m.checkin_id
     and m.checkin_id = p_checkin
     and m.email = lower(trim(p_email))
     and m.present
     and m.entered_at is null
     and (c.locked_at is null or m.entered_once);
  get diagnostics v_n = row_count;
  return v_n = 1;
end;
$$;
revoke all on function public.pia_claim_entry(uuid, text) from public, anon, authenticated;
grant execute on function public.pia_claim_entry(uuid, text) to service_role;
