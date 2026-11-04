-- Let back in keeps working after the session is closed.
-- A student gets in once. A second try is refused and counted on the student's row, and the admin's
-- Let back in lets that student try again. The game starts after the session is closed, so most
-- reconnects happen then: the function must not need the session to be open.
-- Run in the Supabase SQL editor. Safe to run more than once. It changes no table and no row.
--
-- Rollback: put admin_let_back_in back as in 0058 (filter on stopped_at is null and ends_at > now()).

create or replace function public.admin_let_back_in(p_section text, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  update public.attendance_marks m
     set entered_at = null, refused_count = 0
   where m.checkin_id = (
           select c.id from public.checkins c
            where c.section = trim(p_section)
              and c.started_at > now() - interval '16 hours'
            order by c.started_at desc
            limit 1
         )
     and m.email = lower(trim(coalesce(p_email, '')));
end;
$$;
