-- 46: Internal functions are not open to the public.
--
-- Supabase gives every new function to anon and authenticated by default. This database was built from a schema file that only
-- removed PUBLIC, so anyone with the site's public key could run every function, including the ones with no caller check
-- (the *__inner functions, such as the one that sets a password).
-- This file puts back the intended permissions:
--   signed-out visitors: no function at all (the student-number door uses its own service key)
--   signed-in users: the functions the site uses keep working; the 50 internal ones are closed
--   new functions: closed by default; each needs its own GRANT, as the recent files already do
-- enforce_device_limit also gets a fixed search_path.
--
-- No table and no row changes. No Edge Function or browser change is needed. service_role keeps everything.
-- Run in the Supabase SQL editor (PIA-Staging). Safe to run more than once.
-- It ends by showing one row: all of the first three numbers must be 0, and the last must be 0.
-- Rollback if the site breaks: grant execute on all functions in schema public to authenticated;

do $fix$
declare
  v_internal constant text[] := array[
    'admin_create_auth_user__inner', 'admin_delete_user__inner', 'admin_grant_stage__inner',
    'admin_register_teacher__inner', 'admin_reset_password__inner', 'admin_revoke_sessions__inner',
    'check_math_answer', 'consume_hint', 'current_role_name', 'enforce_device_limit', 'pia_answer_matches',
    'pia_auth_user_id', 'pia_bfpt_score', 'pia_choose_assigned_character', 'pia_clock_json',
    'pia_close_idle_game_sessions', 'pia_compute_score', 'pia_eval_expr', 'pia_format_final', 'pia_game_email',
    'pia_game_window', 'pia_has_working', 'pia_idle_game_windows', 'pia_is_final_format',
    'pia_learning_features_calc', 'pia_mask_answers', 'pia_parse_hint', 'pia_protect_admin_target',
    'pia_question_hint_list', 'pia_question_payload', 'pia_record_stage_grant', 'pia_refuse',
    'pia_result_payload', 'pia_step_confirm_kind', 'pia_step_hints', 'pia_step_label', 'pia_step_matches',
    'pia_step_required', 'pia_step_state_json', 'pia_steps_valid', 'pia_student_topic', 'pia_sync_professor',
    'pia_topic_rules', 'pia_tutoring_closed', 'pia_tutoring_closed_for', 'pia_window_expired',
    'record_problem_result', 'record_problem_result_v2', 'reveal_solution', 'serve_problem'
  ];
  f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and pg_get_userbyid(p.proowner) = current_user
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname = any (v_internal) then
      execute format('revoke execute on function %s from authenticated', f.sig);
    end if;
  end loop;
end;
$fix$;

alter function public.enforce_device_limit(text) set search_path to 'public', 'extensions';

-- New functions stay closed until they are granted. The second form is how Postgres removes its built-in PUBLIC default.
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;

select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')) as anon_can_run,
  (select count(*) from pg_proc p where p.proname like '%\_\_inner' and has_function_privilege('authenticated', p.oid, 'execute')) as signed_in_can_run_inner,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')) as definer_without_search_path,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and not has_function_privilege('service_role', p.oid, 'execute')) as service_role_locked_out;
