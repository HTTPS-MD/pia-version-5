-- A permanent record of refused second tries and of every Let back in.
-- The number on the student's row ("Blocked x2") goes back to 0 when the admin taps Let back in, so on its
-- own it leaves no trace of who was blocked. This table keeps one line for each event.
-- Run in the Supabase SQL editor. Safe to run more than once. It adds a table and replaces one function;
-- no existing row is changed. Nobody can read or write the table through the API: it is read here in the
-- SQL editor, and written by the join-with-number function (refused) and admin_let_back_in (let_back_in).
--
-- To read it:
--   select l.at, l.kind, l.email, l.by_admin, c.section
--     from public.entry_log l join public.checkins c on c.id = l.checkin_id
--    order by l.at desc;
--
-- Rollback: drop table if exists public.entry_log;
--           and put admin_let_back_in back as in 13-let-back-in-after-close.sql.

create table if not exists public.entry_log (
  id         bigint generated always as identity primary key,
  checkin_id uuid        not null,
  email      text        not null,
  kind       text        not null check (kind in ('refused', 'let_back_in')),
  by_admin   text,
  at         timestamptz not null default now()
);
create index if not exists entry_log_checkin_email on public.entry_log (checkin_id, email);

alter table public.entry_log enable row level security;
revoke all on public.entry_log from public, anon, authenticated;

create or replace function public.admin_let_back_in(p_section text, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id    uuid;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  perform public.pia_require_admin();
  select c.id into v_id
    from public.checkins c
   where c.section = trim(p_section)
     and c.started_at > now() - interval '16 hours'
   order by c.started_at desc
   limit 1;

  insert into public.entry_log (checkin_id, email, kind, by_admin)
  select m.checkin_id, m.email, 'let_back_in', public.current_email()
    from public.attendance_marks m
   where m.checkin_id = v_id and m.email = v_email;

  update public.attendance_marks m
     set entered_at = null, refused_count = 0
   where m.checkin_id = v_id and m.email = v_email;
end;
$$;
