-- ============================================================================
-- PIA -- database history (read-only reference)
-- ============================================================================
-- Every database change made so far, in the order it was applied (by number).
-- The 64 separate migration files were combined into this one file so the
-- history can be read top to bottom.
--
-- This is NOT a script that builds a database from nothing: the first tables
-- (such as public.profiles) were created before migrations were used, so they
-- are not in here. To rebuild the database, take a pg_dump --schema-only of
-- the live project instead.
--
-- Note: migration 0063 is dated before 0061; the order below is by number.
-- ============================================================================


-- ############################################################################
-- MIGRATION 20260822_0001_profile_write_guard
-- ############################################################################

-- ============================================================================
-- PIA 0001 -- PROFILE WRITE GUARD  (fixes CRITICAL 3: privilege escalation)
-- ============================================================================
-- Bakit trigger at hindi column-level GRANT:
--   Ang admin at ang estudyante ay PAREHONG gumagamit ng `authenticated` na
--   database role -- ang "admin" ay isang VALUE lang sa profiles.role, hindi
--   isang DB role. Kaya ang REVOKE UPDATE (role, ocean_e, ...) ay sabay na
--   sumisira sa admin score entry, retake flows, at student registration.
--   Isang trigger lang ang nakakakita ng pagkakaiba ng dalawa.
--
-- Paano nakakalusot ang mga lehitimong RPC:
--   Ang PostgREST ay tumatakbo bilang `authenticated` kapag direktang table
--   write mula sa browser. Ang SECURITY DEFINER na function na pag-aari ng
--   postgres ay tumatakbo na may current_user = 'postgres'. Kaya ang tseke
--   na `current_user <> 'authenticated'` ang siyang nagbubukas ng pinto para
--   sa LAHAT ng definer RPC -- pati ang mga umiiral na (admin_grant_stage,
--   release_device, admin_delete_user) -- nang hindi ko sila hinahawakan.
-- ============================================================================

-- Ang sariling role ng caller, RLS-bypassing para hindi mag-recurse ang
-- SELECT policy ng profiles sa loob ng trigger na nasa profiles din.
create or replace function public.pia_caller_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select lower(trim(coalesce(p.role, 'student')))
  from public.profiles p
  where p.email = (auth.jwt() ->> 'email')
  limit 1;
$$;

revoke all on function public.pia_caller_role() from public, anon;
grant execute on function public.pia_caller_role() to authenticated;


create or replace function public.enforce_profile_write_scope()
returns trigger
language plpgsql
security invoker              -- MAHALAGA: invoker, para totoo ang current_user
set search_path = public
as $$
declare
  -- Ang TANGING mga column na kayang baguhin ng estudyante sa SARILING row.
  -- Lahat ng iba (role, email, group_type, is_ocean_done, ocean_*,
  -- current_stage, stage_started_at, pre_test_score, post_test_score,
  -- max_devices, section, full_name) ay protektado by default -- pati na ang
  -- anumang bagong column na idadagdag mo sa hinaharap.
  v_student_writable constant text[] := array[
    'selected_character',
    'is_in_game', 'current_problem', 'current_difficulty',
    'hints_used', 'consecutive_correct',
    'active_devices',
    'status',
    'last_seen', 'updated_at'
  ];
  v_caller_email text := auth.jwt() ->> 'email';
  v_caller_role  text;
begin
  -- (1) Hindi galing sa browser: SECURITY DEFINER RPC o service_role. Trusted.
  if current_user <> 'authenticated' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  v_caller_role := public.pia_caller_role();

  -- (2) Admin: walang pagbabago sa dating asal.
  if v_caller_role = 'admin' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- (3) Estudyante/teacher na direktang sumusulat mula sa browser.
  if tg_op = 'INSERT' then
    raise exception 'PIA: hindi ka pwedeng gumawa ng profile row (role=%).', coalesce(v_caller_role, 'unknown')
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    raise exception 'PIA: hindi ka pwedeng magbura ng profile row (role=%).', coalesce(v_caller_role, 'unknown')
      using errcode = '42501';
  end if;

  -- Sariling row lang, at hindi pwedeng ilipat ang row sa ibang email.
  if v_caller_email is null
     or old.email is distinct from v_caller_email
     or new.email is distinct from old.email then
    raise exception 'PIA: hindi ka pwedeng magbago ng profile na hindi sa iyo.'
      using errcode = '42501';
  end if;

  -- Ihambing ang lahat ng column MALIBAN sa whitelist. Kung may naiba doon,
  -- may sinusubukang i-forge -- ibagsak ang buong statement.
  if (to_jsonb(old) - v_student_writable) is distinct from (to_jsonb(new) - v_student_writable) then
    raise exception
      'PIA: bawal ang direktang pagsulat sa protektadong profile column. Gamitin ang submit_ocean_results() / set_student_stage().'
      using errcode = '42501';
  end if;

  return new;
end;
$$;


-- ============================================================================
-- RECONCILIATION -- profiles_guard_privileged_columns
-- ============================================================================
-- May umiiral nang BEFORE-trigger sa profiles. Ito ang buong katawan nito:
--
--   begin
--     if exists (select 1 from public.profiles
--                 where email = auth.jwt() ->> 'email'
--                   and lower(trim(role)) = 'admin') then
--       return new;
--     end if;
--     new.role            := old.role;
--     new.group_type      := old.group_type;
--     new.pre_test_score  := old.pre_test_score;
--     new.post_test_score := old.post_test_score;
--     new.max_devices     := old.max_devices;
--     new.email           := old.email;
--     new.section         := old.section;
--     return new;
--   end;
--
-- Tatlong bagay ang mahalaga dito:
--
-- (1) TAHIMIK ITONG NAGBABALIK, hindi nagtatapon ng error. Ang
--     update({role:'admin'}) ng estudyante ay nagbabalik ng HTTP 200 na parang
--     nagtagumpay -- pero walang nangyayari. Protektado nga, pero walang
--     nakakaalam na may sumubok.
--
-- (2) PITONG column lang ang binabantayan nito. WALA rito ang is_ocean_done,
--     ocean_e/a/c/n/o, at current_stage -- kaya bukas na bukas pa rin ang
--     pagpepeke ng OCEAN scores at ang stage bypass. Iyon ang CRITICAL 2 at 3.
--
-- (3) KUNG PAGSASABAYIN SILA, magkakamali ang resulta. Ang mga BEFORE row
--     trigger ay tumatakbo nang ALPABETIKO ayon sa pangalan, kaya
--     'profiles_guard_...' (p) ang mauuna sa 'trg_enforce_...' (t). Isasauli
--     muna nito ang NEW pabalik sa OLD, tapos ang akin naman ay ikukumpara ang
--     OLD sa NEW -- pareho na sila, kaya PAPAYAGAN ko ang forge attempt sa
--     halip na i-403 ito. Pareho pa rin ang seguridad, pero mali ang mensahe
--     at mali ang mababasa sa VERIFY_write_paths.sql.
--
-- Ang whitelist sa ibaba ay STRICT SUPERSET ng pitong column nito (wala ni isa
-- sa role/group_type/pre_test_score/post_test_score/max_devices/email/section
-- ang student-writable), kaya walang proteksyong nawawala sa pagpapalit.
--
-- PARA IBALIK ITO (rollback):
--   create trigger profiles_guard_privileged_columns
--     before update on public.profiles
--     for each row execute function public.profiles_guard_privileged_columns();
--   drop trigger trg_enforce_profile_write_scope on public.profiles;
--
-- Ang FUNCTION ay sinasadyang hindi binubura -- ang restore ay isang statement
-- lang. Ang trigger lang ang tinatanggal.
-- ============================================================================

drop trigger if exists profiles_guard_privileged_columns on public.profiles;

drop trigger if exists trg_enforce_profile_write_scope on public.profiles;

create trigger trg_enforce_profile_write_scope
  before insert or update or delete on public.profiles
  for each row execute function public.enforce_profile_write_scope();


-- ############################################################################
-- MIGRATION 20260822_0002_ocean_server_side
-- ############################################################################

-- ============================================================================
-- PIA 0002 -- SERVER-SIDE OCEAN SCORING  (fixes CRITICAL 2)
-- ============================================================================
-- Dati, ang browser ang KUMU-COMPUTE at NAGSU-SULAT ng ocean_e/a/c/n/o. Kahit
-- ilipat lang natin ang WRITE sa isang RPC, kaya pa ring mag-POST ng gawa-gawang
-- E/A/C/N/O ng estudyante. Kaya ang PINAPADALA na ngayon ay ang 50 raw na
-- Likert responses, at ang SERVER ang nag-i-score gamit ang IPIP-50 key.
--
-- BONUS PARA SA THESIS: itinatago na ang per-item responses. Dati, itinatapon
-- ang mga ito pagkatapos mag-compute -- kaya imposibleng gawin ang Cronbach's
-- alpha o anumang item analysis. Ngayon, meron ka nang raw data.
-- ============================================================================

create table if not exists public.ocean_submissions (
  id           bigint generated always as identity primary key,
  email        text        not null,
  responses    smallint[]  not null,
  ocean_e      smallint    not null check (ocean_e between 0 and 40),
  ocean_a      smallint    not null check (ocean_a between 0 and 40),
  ocean_c      smallint    not null check (ocean_c between 0 and 40),
  ocean_n      smallint    not null check (ocean_n between 0 and 40),
  ocean_o      smallint    not null check (ocean_o between 0 and 40),
  submitted_at timestamptz not null default now(),
  constraint ocean_submissions_50_items check (array_length(responses, 1) = 50)
);

create index if not exists ocean_submissions_email_idx on public.ocean_submissions (email);

alter table public.ocean_submissions enable row level security;

-- Walang INSERT/UPDATE/DELETE policy: ang SECURITY DEFINER na RPC lang ang
-- nagsusulat dito. Ang admin lang ang nakakabasa (para sa data export).
drop policy if exists ocean_submissions_admin_read on public.ocean_submissions;
create policy ocean_submissions_admin_read on public.ocean_submissions
  for select to authenticated
  using (public.pia_caller_role() = 'admin');

revoke all on public.ocean_submissions from anon, authenticated;
grant select on public.ocean_submissions to authenticated;


-- Binabasa ang stage flag anuman ang naka-store na hugis (jsonb true,
-- jsonb "true", o boolean) -- katulad ng ginagawa ng isStageOpen() sa JS.
create or replace function public.pia_stage_open(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select trim(both '"' from s.value::text) = 'true'
     from public.settings s where s.key = p_key limit 1),
    false);
$$;

revoke all on function public.pia_stage_open(text) from public, anon;
grant execute on function public.pia_stage_open(text) to authenticated;


-- ============================================================================
-- submit_ocean_results(p_responses)
--   p_responses: 50 na Likert item (1..5), nasa pagkakasunod ng questions[]
--                array sa ocean-test.js.
--   Nagbabalik ng { ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, next_stage }.
-- ============================================================================
create or replace function public.submit_ocean_results(p_responses integer[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  r         integer[] := p_responses;   -- integer[] (hindi smallint[]) para
                                        -- maayos ang JSON array coercion ng PostgREST
  v_e int; v_a int; v_c int; v_es int; v_n int; v_o int;
  v_needs_character boolean;
  v_next_stage text;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: walang profile para sa session na ito.' using errcode = '42501';
  end if;

  -- Isang beses lang. Ang admin retake flow ang nagse-set pabalik ng
  -- is_ocean_done = false kapag pinayagan nilang umulit ang estudyante.
  if coalesce(v_profile.is_ocean_done, false) then
    raise exception 'PIA: naisumite na ang OCEAN test mo. Humingi ng retake sa admin.'
      using errcode = '42501';
  end if;

  -- Istriktong validation ng hugis ng input.
  if r is null or array_length(r, 1) is distinct from 50 then
    raise exception 'PIA: kailangan ng eksaktong 50 na sagot (natanggap: %).',
      coalesce(array_length(r, 1), 0) using errcode = '22023';
  end if;

  if exists (select 1 from unnest(r) v where v is null or v < 1 or v > 5) then
    raise exception 'PIA: bawat sagot ay dapat nasa 1..5.' using errcode = '22023';
  end if;

  -- IPIP-50 scoring key -- port ng dating client-side na computation sa
  -- ocean-test.js (kasama ang Emotional Stability -> Neuroticism inversion).
  -- Lahat ng lima ay may theoretical range na 0..40.
  v_e  := 20 + r[1]  - r[6]  + r[11] - r[16] + r[21] - r[26] + r[31] - r[36] + r[41] - r[46];
  v_a  := 14 - r[2]  + r[7]  - r[12] + r[17] - r[22] + r[27] - r[32] + r[37] + r[42] + r[47];
  v_c  := 14 + r[3]  - r[8]  + r[13] - r[18] + r[23] - r[28] + r[33] - r[38] + r[43] + r[48];
  v_es := 38 - r[4]  + r[9]  - r[14] + r[19] - r[24] - r[29] - r[34] - r[39] - r[44] - r[49];
  v_n  := 40 - v_es;
  v_o  := 8  + r[5]  - r[10] + r[15] - r[20] + r[25] - r[30] + r[35] + r[40] + r[45] + r[50];

  -- Susunod na stage -- sa server na napagpapasyahan, hindi na sa browser.
  v_needs_character :=
    lower(trim(coalesce(v_profile.group_type, ''))) in ('non-assigned', 'non_assigned')
    and v_profile.selected_character is null;

  if v_needs_character then
    v_next_stage := case when public.pia_stage_open('stage_char')
                         then 'Character Selection' else 'Waiting Room' end;
  else
    v_next_stage := case when public.pia_stage_open('stage_dash')
                         then 'Tutoring Dashboard' else 'Waiting Room' end;
  end if;

  insert into public.ocean_submissions (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o)
  values (v_email, r::smallint[], v_e, v_a, v_c, v_n, v_o);

  update public.profiles set
    is_ocean_done    = true,
    ocean_e          = v_e,
    ocean_a          = v_a,
    ocean_c          = v_c,
    ocean_n          = v_n,
    ocean_o          = v_o,
    current_stage    = v_next_stage,
    stage_started_at = now()
  where email = v_email;

  return jsonb_build_object(
    'ocean_e', v_e, 'ocean_a', v_a, 'ocean_c', v_c, 'ocean_n', v_n, 'ocean_o', v_o,
    'next_stage', v_next_stage);
end;
$$;

revoke all on function public.submit_ocean_results(integer[]) from public, anon;
grant execute on function public.submit_ocean_results(integer[]) to authenticated;


-- ############################################################################
-- MIGRATION 20260822_0003_stage_transitions
-- ############################################################################

-- ============================================================================
-- PIA 0003 -- VALIDATED STAGE TRANSITIONS
-- ============================================================================
-- Fixes:
--   * "hasTargetedGrant" bypass -- ang current_stage mismo ang ginagamit na
--     grant marker, pero ang BROWSER ng estudyante ang nagsusulat nito. Kaya
--     kayang bigyan ng kahit sinong estudyante ang sarili nila ng kahit anong
--     stage sa isang linya sa console. Pagkatapos ng 0001, ang current_stage
--     ay hindi na nila kayang sulatan nang direkta; dito na dumadaan lahat, at
--     may server-side prerequisite check.
--   * "Sarado na ang stage pero nasa loob pa rin sila" -- ang pag-close ng
--     stage ay HINDI dating nagpapaalis ng mga nakapasok na. Nagpapaalis na.
-- ============================================================================

-- Isang source of truth sa server para sa prerequisite chain -- eksaktong
-- katumbas ng canEnterStage() sa assets/js/function.js.
--
-- TANDAAN: SCALAR ang mga parameter, hindi `public.profiles`. Ang function na
-- ang unang argumento ay row type ng isang table ay itinuturing ng PostgREST na
-- COMPUTED COLUMN ng table na iyon -- at dahil dalawa ang kailangan nitong
-- argumento, bumabagsak ang `select=*` at nagiging 500 ang bawat REST read sa
-- profiles. Tingnan ang 0005 hotfix. Huwag itong ibalik sa row type.
create or replace function public.pia_can_enter_stage(
  p_is_ocean_done      boolean,
  p_group_type         text,
  p_selected_character text,
  p_stage              text)
returns boolean
language sql
immutable
as $$
  select case p_stage
    when 'OCEAN' then
      not coalesce(p_is_ocean_done, false)
    when 'Character Selection' then
      coalesce(p_is_ocean_done, false)
      and lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
      and p_selected_character is null
    when 'Tutoring Dashboard' then
      coalesce(p_is_ocean_done, false)
      and not (lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
               and p_selected_character is null)
    when 'Waiting Room' then
      true
    else false
  end;
$$;


-- ============================================================================
-- set_student_stage(p_stage)
--   Ini-anunsyo ng estudyante kung saang stage sila pumapasok. Sine-check ng
--   server ang prerequisite chain AT ang stage flag bago sumulat.
--   Kung hindi sila pwede doon, 'Waiting Room' ang naitatala at ibinabalik --
--   hindi ito error, ito ang normal na "sarado pa" na daloy.
--   Nagbabalik ng { stage, granted }.
-- ============================================================================
create or replace function public.set_student_stage(p_stage text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_flag    text;
  v_ok      boolean := false;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard', 'Waiting Room') then
    raise exception 'PIA: hindi kilalang stage: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: walang profile para sa session na ito.' using errcode = '42501';
  end if;

  v_flag := case p_stage
              when 'OCEAN'              then 'stage_ocean'
              when 'Character Selection' then 'stage_char'
              when 'Tutoring Dashboard' then 'stage_dash'
              else null
            end;

  -- (a) prerequisite chain  AT  (b) bukas na flag o naunang admin grant.
  if public.pia_can_enter_stage(v_profile.is_ocean_done, v_profile.group_type,
                                v_profile.selected_character, p_stage) then
    v_ok := v_flag is null
            or public.pia_stage_open(v_flag)
            or v_profile.current_stage is not distinct from p_stage;  -- targeted grant ng admin
  end if;

  if not v_ok then
    -- Hindi pinapayagan: itala silang nasa Waiting Room, huwag magtapon ng error.
    if v_profile.current_stage is distinct from 'Waiting Room' then
      update public.profiles
         set current_stage = 'Waiting Room', stage_started_at = now()
       where email = v_email;
    end if;
    return jsonb_build_object('stage', 'Waiting Room', 'granted', false);
  end if;

  if v_profile.current_stage is distinct from p_stage then
    update public.profiles
       set current_stage = p_stage, stage_started_at = now()
     where email = v_email;
  end if;

  return jsonb_build_object('stage', p_stage, 'granted', true);
end;
$$;

revoke all on function public.set_student_stage(text) from public, anon;
grant execute on function public.set_student_stage(text) to authenticated;


-- ============================================================================
-- admin_set_stage_open(p_stage, p_open)
--   Pinapalitan ang direktang `settings` upsert ng admin dashboard.
--   Kapag NAGSASARA: ibinabalik sa Waiting Room ang lahat ng nasa stage na
--   iyon. Kung wala nito, ang mga nakapasok na ay nananatili doon dahil ang
--   sarili nilang current_stage ay nagsisilbing targeted grant.
--   Nagbabalik ng { stage, open, evicted }.
-- ============================================================================
create or replace function public.admin_set_stage_open(p_stage text, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label    text;
  v_evicted  int := 0;
  v_valtype  text;
begin
  if public.pia_caller_role() <> 'admin' then
    raise exception 'PIA: admin lang ang pwedeng magbukas/magsara ng stage.' using errcode = '42501';
  end if;

  if p_stage not in ('ocean', 'char', 'dash') then
    raise exception 'PIA: hindi kilalang stage key: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  v_label := case p_stage when 'ocean' then 'OCEAN'
                          when 'char'  then 'Character Selection'
                          else 'Tutoring Dashboard' end;

  -- Ang settings.value ay maaaring jsonb o boolean depende sa kung paano ito
  -- unang nagawa. Dumadaan sa text cast para gumana sa dalawa.
  select atttypid::regtype::text into v_valtype
    from pg_attribute
   where attrelid = 'public.settings'::regclass and attname = 'value';

  execute format(
    'insert into public.settings (key, value) values ($1, $2::%s)
       on conflict (key) do update set value = excluded.value', v_valtype)
    using 'stage_' || p_stage, case when p_open then 'true' else 'false' end;

  if not p_open then
    with evicted as (
      update public.profiles
         set current_stage = 'Waiting Room', stage_started_at = now()
       where current_stage = v_label
         and lower(trim(coalesce(role, 'student'))) = 'student'
      returning 1)
    select count(*) into v_evicted from evicted;
  end if;

  return jsonb_build_object('stage', p_stage, 'open', p_open, 'evicted', v_evicted);
end;
$$;

revoke all on function public.admin_set_stage_open(text, boolean) from public, anon;
grant execute on function public.admin_set_stage_open(text, boolean) to authenticated;


-- ############################################################################
-- MIGRATION 20260822_0004_server_side_tutoring
-- ############################################################################

-- ============================================================================
-- PIA 0004 -- SERVER-OWNED TUTORING TELEMETRY   (fixes HIGH 1 at HIGH 2)
-- ============================================================================
-- HIGH 1: ang record_problem_result ay tumatanggap ng p_classification,
--   p_hints_used, p_time_taken_ms, p_level_before/after mula sa BROWSER. Tama
--   na ang is_correct ay muling sinusuri laban sa answer key -- pero ang
--   'smooth' vs 'struggling' na label ay MISMONG finding ng thesis, at ang
--   browser ang nagde-deklara nito. Isang linya sa console:
--     await supabaseClient.rpc('record_problem_result', {..., p_classification:'smooth', p_hints_used:0, p_time_taken_ms:1200})
--
-- HIGH 2: ang mga hint ay nasa client (math-problems.js), at ang huling hint
--   ay ang mismong solusyon ('x = 40 - 15'). Kaya (a) nababasa lahat ng sagot
--   sa view-source, at (b) ang pagbabasa nila sa ganoong paraan ay HINDI
--   nagpapataas ng hints_used -- kaya naitatala pa rin silang 'smooth'.
--   Tahimik nitong pinapataas ang performance ng experimental group.
--
-- Solusyon: ang server na ang may-ari ng hints, ng timing, at ng buong
-- Decision Tree. Ang browser ay nagsasabi na lang ng "nasa problem X ako" at
-- "tapos na ako dito" -- wala na itong maide-deklarang anumang sukatan.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. HINTS -- inilipat mula sa client patungo sa DB
-- ---------------------------------------------------------------------------
create table if not exists public.math_hints (
  problem_id text    not null,
  hint_index int     not null check (hint_index >= 1),
  hint_text  text    not null,
  primary key (problem_id, hint_index)
);

-- WALANG select grant: ang consume_hint()/reveal_solution() lang ang
-- nakakabasa nito. Ganito rin ang math_answers -- hindi ito naaabot ng client.
alter table public.math_hints enable row level security;
revoke all on public.math_hints from anon, authenticated;


create table if not exists public.hint_consumptions (
  id            bigint generated always as identity primary key,
  session_id    uuid    not null,
  student_email text    not null,
  problem_id    text    not null,
  hint_index    int     not null,
  consumed_at   timestamptz not null default now(),
  unique (session_id, student_email, problem_id, hint_index)
);

create index if not exists hint_consumptions_lookup_idx
  on public.hint_consumptions (student_email, session_id, problem_id);

alter table public.hint_consumptions enable row level security;
revoke all on public.hint_consumptions from anon, authenticated;


-- ---------------------------------------------------------------------------
-- 2. SERVE TIMESTAMPS -- para hindi na ang browser ang magsabi ng oras
-- ---------------------------------------------------------------------------
create table if not exists public.problem_serves (
  session_id     uuid    not null,
  student_email  text    not null,
  problem_id     text    not null,
  problem_number int     not null,
  served_at      timestamptz not null default now(),
  primary key (session_id, problem_id)
);

alter table public.problem_serves enable row level security;
revoke all on public.problem_serves from anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. DECISION TREE -- iisang implementasyon, nasa server
--    'smooth'     -> consecutive_correct++, +1 level kada 3 (max 3)
--    'struggling' -> struggling streak++,   -1 level kada 2 (min 1)
--    Eksaktong port ng applyDecisionTree() sa tutoring-dashboard.js.
-- ---------------------------------------------------------------------------
create or replace function public.pia_replay_decision_tree(p_classifications text[])
returns jsonb
language plpgsql
immutable
as $$
declare
  v_level int := 1;
  v_cc    int := 0;
  v_ss    int := 0;
  c       text;
begin
  foreach c in array coalesce(p_classifications, array[]::text[]) loop
    if c = 'smooth' then
      v_cc := v_cc + 1;
      v_ss := 0;
      if v_cc >= 3 and v_level < 3 then
        v_level := v_level + 1;
        v_cc := 0;
      end if;
    else
      v_cc := 0;
      v_ss := v_ss + 1;
      if v_ss >= 2 and v_level > 1 then
        v_level := v_level - 1;
        v_ss := 0;
      end if;
    end if;
  end loop;

  return jsonb_build_object('level', v_level, 'consecutive_correct', v_cc, 'struggling_streak', v_ss);
end;
$$;


-- Ang kasalukuyang estado ng isang session, buo mula sa naitalang kasaysayan.
create or replace function public.pia_session_state(p_session_id uuid, p_email text)
returns jsonb
language sql
stable
as $$
  select public.pia_replay_decision_tree(
    coalesce(array_agg(t.classification order by t.problem_number), array[]::text[]))
  from public.tutoring_attempts t
  where t.session_id = p_session_id and t.student_email = p_email;
$$;


-- ---------------------------------------------------------------------------
-- 4. serve_problem() -- tinatatakan ang oras, ibinibigay ang authoritative level
-- ---------------------------------------------------------------------------
create or replace function public.serve_problem(
  p_session_id uuid, p_problem_id text, p_problem_number int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_state jsonb;
  v_hints int;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  if not exists (select 1 from public.math_answers where problem_id = p_problem_id) then
    raise exception 'PIA: hindi kilalang problem_id: %', p_problem_id using errcode = '22023';
  end if;

  -- Ang UNANG serve lang ang tumatatak ng oras. Ang pag-refresh ng page ay
  -- hindi nagre-reset ng orasan -- kung hindi, libre ang dagdag na oras.
  insert into public.problem_serves (session_id, student_email, problem_id, problem_number)
  values (p_session_id, v_email, p_problem_id, greatest(1, least(50, p_problem_number)))
  on conflict (session_id, problem_id) do nothing;

  select count(*) into v_hints from public.math_hints where problem_id = p_problem_id;
  v_state := public.pia_session_state(p_session_id, v_email);

  return jsonb_build_object(
    'level',               v_state ->> 'level',
    'consecutive_correct', v_state ->> 'consecutive_correct',
    'hints_available',     v_hints);
end;
$$;

revoke all on function public.serve_problem(uuid, text, int) from public, anon;
grant execute on function public.serve_problem(uuid, text, int) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. consume_hint() -- ang hint text ay galing sa DB, at BINIBILANG ng server
-- ---------------------------------------------------------------------------
create or replace function public.consume_hint(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_used  int;
  v_total int;
  v_next  int;
  v_text  text;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  select count(*) into v_total from public.math_hints where problem_id = p_problem_id;
  if v_total = 0 then
    raise exception 'PIA: walang hint para sa problem na ito.' using errcode = '22023';
  end if;

  select count(*) into v_used
    from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if v_used >= v_total then
    return jsonb_build_object('hint_text', null, 'hints_used', v_used,
                              'hints_left', 0, 'exhausted', true);
  end if;

  v_next := v_used + 1;
  select hint_text into v_text
    from public.math_hints where problem_id = p_problem_id and hint_index = v_next;

  insert into public.hint_consumptions (session_id, student_email, problem_id, hint_index)
  values (p_session_id, v_email, p_problem_id, v_next)
  on conflict do nothing;

  return jsonb_build_object('hint_text', v_text, 'hints_used', v_next,
                            'hints_left', v_total - v_next,
                            'exhausted', v_next >= v_total);
end;
$$;

revoke all on function public.consume_hint(uuid, text) from public, anon;
grant execute on function public.consume_hint(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. reveal_solution() -- ang huling hint, PAGKATAPOS lang malock ang problema
--    Hindi ito binibilang bilang hint: resolba na ang problema sa puntong ito.
--    Ang gate ang mahalaga -- kung wala ito, ito na ang bagong answer leak.
-- ---------------------------------------------------------------------------
create or replace function public.reveal_solution(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email  text := auth.jwt() ->> 'email';
  v_used   int;
  v_ok     boolean;
  v_text   text;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  select count(*), coalesce(bool_or(was_correct), false) into v_used, v_ok
    from public.math_attempt_log
   where student_email = v_email and session_id = p_session_id and problem_id = p_problem_id;

  -- Katulad ng lock rule ng check_math_answer: tama na, o ubos na ang 2 attempts.
  if not (v_ok or v_used >= 2) then
    raise exception 'PIA: hindi pa tapos ang problemang ito.' using errcode = '42501';
  end if;

  select hint_text into v_text
    from public.math_hints where problem_id = p_problem_id order by hint_index desc limit 1;

  return jsonb_build_object('solution', v_text);
end;
$$;

revoke all on function public.reveal_solution(uuid, text) from public, anon;
grant execute on function public.reveal_solution(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. record_problem_result_v2() -- LAHAT ay derived, WALANG client input
--    Dalawang argumento lang: aling session, aling problem. Wala nang ibang
--    masasabi ang browser tungkol sa performance ng estudyante.
-- ---------------------------------------------------------------------------
create or replace function public.record_problem_result_v2(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email    text := auth.jwt() ->> 'email';
  v_attempts int;
  v_correct  boolean;
  v_hints    int;
  v_served   timestamptz;
  v_last     timestamptz;
  v_ms       bigint;
  v_number   int;
  v_class    text;
  v_before   jsonb;
  v_after    jsonb;
  v_smooth   boolean;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  -- (a) Attempts at pagkatama -- mula sa math_attempt_log, isinulat mismo ng
  --     check_math_answer. Hindi ito naaabot ng client.
  select count(*), coalesce(bool_or(was_correct), false), max(attempted_at)
    into v_attempts, v_correct, v_last
    from public.math_attempt_log
   where student_email = v_email and session_id = p_session_id and problem_id = p_problem_id;

  -- (b) Hints -- server-owned counter, hindi na ang p_hints_used ng browser.
  select count(*) into v_hints
    from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- (c) Timing -- mula sa serve stamp, hindi sa Date.now() ng browser.
  select served_at, problem_number into v_served, v_number
    from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;

  if v_served is null then
    raise exception 'PIA: hindi pa naiseserve ang problemang ito.' using errcode = '42501';
  end if;

  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  -- (d) Classification -- eksaktong rule ng tutoring-dashboard.js, sa server:
  --     smooth = tama, walang hint, walang retry, at <= 30s.
  v_smooth := v_correct and v_hints = 0 and v_attempts <= 1 and v_ms <= 30000;
  v_class  := case when v_smooth then 'smooth' else 'struggling' end;

  -- (e) Level -- ni-replay mula sa naitalang kasaysayan ng session.
  v_before := public.pia_session_state(p_session_id, v_email);
  v_after  := public.pia_replay_decision_tree(
                (select coalesce(array_agg(t.classification order by t.problem_number), array[]::text[])
                   from public.tutoring_attempts t
                  where t.session_id = p_session_id and t.student_email = v_email)
                || array[v_class]);

  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, coalesce(v_number, 1),
    (v_before ->> 'level')::int, (v_after ->> 'level')::int,
    least(10, v_attempts), least(10, v_hints),
    v_ms, v_correct, v_class)
  on conflict (session_id, problem_number) do nothing;

  return jsonb_build_object(
    'is_correct',          v_correct,
    'classification',      v_class,
    'attempts_used',       v_attempts,
    'hints_used',          v_hints,
    'time_taken_ms',       v_ms,
    'level_before',        (v_before ->> 'level')::int,
    'level',               (v_after ->> 'level')::int,
    'consecutive_correct', (v_after ->> 'consecutive_correct')::int,
    'levelled_up',         (v_after ->> 'level')::int > (v_before ->> 'level')::int);
end;
$$;

revoke all on function public.record_problem_result_v2(uuid, text) from public, anon;
grant execute on function public.record_problem_result_v2(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 8. Isara ang lumang forgeable RPC.
--    Hindi ito dini-drop (baka may naitalang data na naka-depende sa signature),
--    inaalis lang ang karapatang tawagin ito mula sa browser. Dynamic ang
--    paghahanap ng signature para hindi ko kailangang hulaan ang arg types.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'record_problem_result'
  loop
    execute format('revoke all on function %s from authenticated, anon, public', r.sig);
    raise notice 'PIA: naialis ang execute sa lumang %', r.sig;
  end loop;
end;
$$;
insert into public.math_hints (problem_id, hint_index, hint_text) values
  ('l1-1', 1, 'Alisin ang +15 sa magkabilang panig ng equation.'),
  ('l1-1', 2, 'x = 40 - 15'),
  ('l1-2', 1, 'Idagdag ang 8 sa magkabilang panig.'),
  ('l1-2', 2, 'x = 12 + 8'),
  ('l1-3', 1, 'Hatiin ang magkabilang panig ng 3.'),
  ('l1-3', 2, 'x = 21 ÷ 3'),
  ('l1-4', 1, 'I-multiply ang magkabilang panig ng 4.'),
  ('l1-4', 2, 'x = 6 × 4'),
  ('l1-5', 1, 'Alisin muna ang +5: 2x = 17 - 5.'),
  ('l1-5', 2, '2x = 12, kaya x = 12 ÷ 2'),
  ('l1-6', 1, 'Idagdag ang 9 sa magkabilang panig.'),
  ('l1-6', 2, 'x = -3 + 9'),
  ('l1-7', 1, 'Alisin ang +7 sa magkabilang panig ng equation.'),
  ('l1-7', 2, 'x = 23 - 7'),
  ('l1-8', 1, 'Hatiin ang magkabilang panig ng 5.'),
  ('l1-8', 2, 'x = 45 ÷ 5'),
  ('l1-9', 1, 'I-multiply ang magkabilang panig ng 3.'),
  ('l1-9', 2, 'x = 8 × 3'),
  ('l1-10', 1, 'Idagdag muna ang 6: 4x = 18 + 6.'),
  ('l1-10', 2, '4x = 24, kaya x = 24 ÷ 4'),
  ('l2-1', 1, 'Ilipat ang 3x sa kaliwa: 5x - 3x = 12.'),
  ('l2-1', 2, '2x = 12, kaya x = 12 ÷ 2'),
  ('l2-2', 1, 'Ilipat ang 2x sa kaliwa at ang -4 sa kanan: 7x - 2x = 16 + 4.'),
  ('l2-2', 2, '5x = 20, kaya x = 20 ÷ 5'),
  ('l2-3', 1, 'Ilipat ang 2x sa kaliwa at ang 3 sa kanan: 6x - 2x = 19 - 3.'),
  ('l2-3', 2, '4x = 16, kaya x = 16 ÷ 4'),
  ('l2-4', 1, 'Ilipat ang 4x sa kaliwa at ang -5 sa kanan: 9x - 4x = 20 + 5.'),
  ('l2-4', 2, '5x = 25, kaya x = 25 ÷ 5'),
  ('l2-5', 1, 'Ilipat ang x sa kaliwa at ang 8 sa kanan: 3x - x = 20 - 8.'),
  ('l2-5', 2, '2x = 12, kaya x = 12 ÷ 2'),
  ('l2-6', 1, 'Ilipat ang 5x sa kaliwa: 8x - 5x = 21.'),
  ('l2-6', 2, '3x = 21, kaya x = 21 ÷ 3'),
  ('l2-7', 1, 'Ilipat ang 2x sa kaliwa at ang 9 sa kanan: 4x - 2x = 23 - 9.'),
  ('l2-7', 2, '2x = 14, kaya x = 14 ÷ 2'),
  ('l2-8', 1, 'Ilipat ang 6x sa kaliwa at ang -7 sa kanan: 10x - 6x = 13 + 7.'),
  ('l2-8', 2, '4x = 20, kaya x = 20 ÷ 4'),
  ('l2-9', 1, 'Ilipat ang 2x sa kaliwa at ang 6 sa kanan: 5x - 2x = 18 - 6.'),
  ('l2-9', 2, '3x = 12, kaya x = 12 ÷ 3'),
  ('l2-10', 1, 'Ilipat ang 3x sa kaliwa at ang -2 sa kanan: 7x - 3x = 14 + 2.'),
  ('l2-10', 2, '4x = 16, kaya x = 16 ÷ 4'),
  ('l3-1', 1, 'I-distribute muna: 4x + 8 = 3x + 15.'),
  ('l3-1', 2, 'Ilipat ang 3x at 8: 4x - 3x = 15 - 8'),
  ('l3-2', 1, 'I-distribute muna: 6x - 2 = 5x + 20.'),
  ('l3-2', 2, 'Ilipat ang 5x at -2: 6x - 5x = 20 + 2'),
  ('l3-3', 1, 'I-distribute muna: 3x + 12 = 2x + 18.'),
  ('l3-3', 2, 'Ilipat ang 2x at 12: 3x - 2x = 18 - 12'),
  ('l3-4', 1, 'I-distribute muna: 5x - 10 = 3x + 12.'),
  ('l3-4', 2, 'Ilipat ang 3x at -10: 5x - 3x = 12 + 10'),
  ('l3-5', 1, 'I-distribute muna: 2x + 10 = 3x + 3.'),
  ('l3-5', 2, 'Ilipat ang 2x at 3: 10 - 3 = 3x - 2x'),
  ('l3-6', 1, 'I-distribute muna: 6x - 6 = 4x + 12.'),
  ('l3-6', 2, 'Ilipat ang 4x at -6: 6x - 4x = 12 + 6'),
  ('l3-7', 1, 'I-distribute muna: 6x + 3 = 5x + 20.'),
  ('l3-7', 2, 'Ilipat ang 5x at 3: 6x - 5x = 20 - 3'),
  ('l3-8', 1, 'I-distribute muna: 4x + 20 = 2x + 22.'),
  ('l3-8', 2, 'Ilipat ang 2x at 20: 4x - 2x = 22 - 20'),
  ('l3-9', 1, 'I-distribute muna: 5x + 15 = 4x + 24.'),
  ('l3-9', 2, 'Ilipat ang 4x at 15: 5x - 4x = 24 - 15'),
  ('l3-10', 1, 'I-distribute muna: 8x - 6 = 6x + 6.'),
  ('l3-10', 2, 'Ilipat ang 6x at -6: 8x - 6x = 6 + 6')
on conflict (problem_id, hint_index) do update set hint_text = excluded.hint_text;


-- ############################################################################
-- MIGRATION 20260822_0005_hotfix_pia_can_enter_stage
-- ############################################################################

-- ============================================================================
-- PIA 0005 -- HOTFIX: 500 sa GET /rest/v1/profiles?select=*
-- ============================================================================
-- SINTOMAS: pagkatapos ng 0003, ang bawat SELECT sa profiles sa pamamagitan ng
-- PostgREST ay nagbabalik ng 500 Internal Server Error. Kasama rito ang
-- profile fetch pagkatapos ng sign-in, kaya walang sinuman ang makakapasok --
-- pati ang admin.
--
-- SANHI: sa 0003 ay ginawa ko itong may composite-type na unang parameter:
--
--     pia_can_enter_stage(p_profile public.profiles, p_stage text)
--
-- Ang isang function na ang UNANG argumento ay ang row type ng isang table ay
-- itinuturing ng PostgREST na COMPUTED COLUMN ng table na iyon. Kapag
-- pinalawak nito ang `select=*`, sinusubukan nitong tawagin ang
-- `pia_can_enter_stage(profiles)` -- na kulang ng pangalawang argumento. Ang
-- na-generate na SQL ay bumabagsak, at 500 ang ibinabalik ng PostgREST.
--
-- Dahil ang profiles lang ang table na may ganitong function, ang profiles lang
-- ang naapektuhan -- kaya tumutugma ito nang eksakto sa nakitang sintomas.
--
-- AKING PAGKAKAMALI: ang pagpasa ng buong row ay mas malinis basahin, pero sa
-- isang schema na ini-expose ng PostgREST, ang composite-type na parameter ay
-- hindi lang basta istilo -- nagbabago ito ng hugis ng REST API. Scalar na
-- lang ang parameter dito. Hindi nagbabago ang lohika ni katiting.
-- ============================================================================

-- Kailangang i-drop muna: ibang signature = bagong overload, at mananatili ang
-- sirang luma bilang computed column.
drop function if exists public.pia_can_enter_stage(public.profiles, text);


create or replace function public.pia_can_enter_stage(
  p_is_ocean_done      boolean,
  p_group_type         text,
  p_selected_character text,
  p_stage              text)
returns boolean
language sql
immutable
as $$
  select case p_stage
    when 'OCEAN' then
      not coalesce(p_is_ocean_done, false)
    when 'Character Selection' then
      coalesce(p_is_ocean_done, false)
      and lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
      and p_selected_character is null
    when 'Tutoring Dashboard' then
      coalesce(p_is_ocean_done, false)
      and not (lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
               and p_selected_character is null)
    when 'Waiting Room' then
      true
    else false
  end;
$$;


-- Muling itinatakda ang set_student_stage para sa bagong signature. Wala nang
-- ibang pagbabago -- pareho pa rin ang bawat tuntunin.
create or replace function public.set_student_stage(p_stage text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_flag    text;
  v_ok      boolean := false;
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard', 'Waiting Room') then
    raise exception 'PIA: hindi kilalang stage: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: walang profile para sa session na ito.' using errcode = '42501';
  end if;

  v_flag := case p_stage
              when 'OCEAN'              then 'stage_ocean'
              when 'Character Selection' then 'stage_char'
              when 'Tutoring Dashboard' then 'stage_dash'
              else null
            end;

  if public.pia_can_enter_stage(v_profile.is_ocean_done, v_profile.group_type,
                                v_profile.selected_character, p_stage) then
    v_ok := v_flag is null
            or public.pia_stage_open(v_flag)
            or v_profile.current_stage is not distinct from p_stage;  -- targeted grant ng admin
  end if;

  if not v_ok then
    if v_profile.current_stage is distinct from 'Waiting Room' then
      update public.profiles
         set current_stage = 'Waiting Room', stage_started_at = now()
       where email = v_email;
    end if;
    return jsonb_build_object('stage', 'Waiting Room', 'granted', false);
  end if;

  if v_profile.current_stage is distinct from p_stage then
    update public.profiles
       set current_stage = p_stage, stage_started_at = now()
     where email = v_email;
  end if;

  return jsonb_build_object('stage', p_stage, 'granted', true);
end;
$$;

revoke all on function public.set_student_stage(text) from public, anon;
grant execute on function public.set_student_stage(text) to authenticated;

-- Pilitin ang PostgREST na i-reload ang schema cache agad.
notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260822_0006_fix_profiles_policy_recursion
-- ############################################################################

-- ============================================================================
-- PIA 0006 -- AYUSIN ANG INFINITE RECURSION SA PROFILES POLICIES
-- ============================================================================
-- ERROR: 42P17 infinite recursion detected in policy for relation "profiles"
--
-- SANHI: ang policy na `profiles_select_teacher` ay may LITERAL na subquery sa
-- profiles sa loob mismo ng USING clause nito:
--
--   is_teacher()
--   AND NOT (section IS DISTINCT FROM (
--        SELECT t.section FROM profiles t WHERE t.email = current_email()))
--                          ^^^^^^^^ bumabasa ng profiles sa loob ng policy
--                                   ng profiles -- ito ang loop.
--
-- Para masuri ang subquery na iyon, kailangang i-apply ang SELECT policies ng
-- profiles; para magawa iyon, kailangang suriin ang subquery; walang katapusan.
--
-- BAKIT LAHAT ANG APEKTADO, hindi lang ang teacher: ang mga PERMISSIVE policy
-- ay pinagsasama sa pamamagitan ng OR, at SINUSURI ANG LAHAT sa bawat SELECT.
-- Kaya kahit admin ka o estudyante, dinadaanan pa rin ng query mo ang sirang
-- policy na ito. Iyon ang dahilan kung bakit hindi ito mukhang admin-only.
--
-- HINDI NAWAWALA ANG TEACHER ACCESS: ginagawa na ito ng
-- `profiles_select_teacher_section` --
--   current_user_role() = 'teacher' AND section = current_user_section()
--   AND jwt_is_current()
-- -- na hindi bumabasa ng profiles nang inline, at may kasama pang
-- jwt_is_current() na revocation check na WALA sa lumang policy.
--
-- PARA IBALIK ITO (rollback -- babalik ang recursion):
--   create policy profiles_select_teacher on public.profiles
--     for select using (
--       is_teacher() and not (section is distinct from (
--         select t.section from public.profiles t where t.email = current_email())));
-- ============================================================================

drop policy if exists profiles_select_teacher on public.profiles;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260822_0007_fix_role_null
-- ############################################################################

-- ============================================================================
-- PIA 0007 -- AYUSIN ANG NULL NA role (dahilan ng walang laman na roster)
-- ============================================================================
-- Ang handleRegisterStudent() ay hindi kailanman nagtakda ng `role` sa insert,
-- kaya NULL ang role ng bawat estudyanteng ginawa sa dashboard. Ang roster ay
-- sinasala ng .neq('role','admin') -> `role <> 'admin'`, at sa SQL ang
-- NULL <> 'admin' ay NULL -- hindi TRUE. Ang mga row na NULL ang role ay
-- tahimik na naiiwan sa labas.
--
-- Kaya lumabas ang lahat ng 4 na row sa unfiltered fetch pero 0 sa roster:
-- hindi RLS ang may kasalanan, ang three-valued logic.
--
-- LIGTAS ANG BACKFILL: ang mga NULL lang ang hinahawakan. Ang admin mo ay
-- role='admin' na (kaya TRUE ang is_admin()), at ang mga teacher ay 'teacher',
-- kaya wala sa kanilang maaapektuhan.
--
-- Tumatakbo ito sa SQL Editor bilang `postgres`, kaya pinapayagan ito ng
-- trg_enforce_profile_write_scope (current_user <> 'authenticated').
-- ============================================================================

update public.profiles set role = 'student' where role is null;

alter table public.profiles alter column role set default 'student';
alter table public.profiles alter column role set not null;

notify pgrst, 'reload schema';


-- ============================================================================
-- ULAT -- ito ang huling statement kaya ito ang ipapakita ng editor.
-- Dalawang bagay ang sinasagot nito nang sabay:
--   (1) tama ba ang naging role distribution pagkatapos ng backfill, at
--   (2) ANONG COLUMN ANG TOTOONG MERON ang profiles -- ito ang kailangan
--       para maayos ang 42703 na 400 error sa updateStageCounters().
-- ============================================================================
select 'role: ' || role || ' = ' || count(*)::text as report
  from public.profiles group by role
union all
select '--- columns of public.profiles ---'
union all
select string_agg(column_name, ', ' order by ordinal_position)
  from information_schema.columns
 where table_schema = 'public' and table_name = 'profiles';


-- ############################################################################
-- MIGRATION 20260822_0008_ensure_tracking_columns
-- ############################################################################

-- ============================================================================
-- PIA 0008 -- TIYAKING UMIIRAL ANG MGA TRACKING COLUMN
-- ============================================================================
-- Ang updateStageCounters() ay bumabagsak sa 42703 (undefined column) ->
-- HTTP 400. Umiiral ang `id`, kaya `current_stage` o `is_in_game` ang wala.
--
-- Sa halip na hulaan kung alin, IDEMPOTENT ang lahat ng ALTER sa ibaba: ang
-- `add column if not exists` ay walang ginagawa kung meron na. Kaya naaayos
-- nito ang 400 anuman ang nawawala, at ligtas itong patakbuhin kahit kumpleto
-- na ang table.
--
-- Ito ang buong hanay ng column na TALAGANG isinusulat o sinasala ng app --
-- kung may kulang pa rito, ang susunod na 400 ay galing sa syncGameProgress()
-- o sa Active Game view, hindi na sa mga counter.
--
-- Ang `is_in_game`, `current_problem`, `current_difficulty`, `hints_used`, at
-- `consecutive_correct` ay nasa student whitelist ng
-- trg_enforce_profile_write_scope. Ang `current_stage` at `stage_started_at`
-- ay SADYANG WALA doon -- sa set_student_stage() RPC lang sila nababago.
-- ============================================================================

alter table public.profiles add column if not exists current_stage       text;
alter table public.profiles add column if not exists stage_started_at    timestamptz;
alter table public.profiles add column if not exists is_in_game          boolean not null default false;
alter table public.profiles add column if not exists current_problem     int     not null default 0;
alter table public.profiles add column if not exists current_difficulty  text;
alter table public.profiles add column if not exists hints_used          int     not null default 0;
alter table public.profiles add column if not exists consecutive_correct int     not null default 0;

notify pgrst, 'reload schema';


-- ============================================================================
-- ULAT -- isang row bawat item, kaya HINDI ito maaaring ma-truncate.
-- Dalawang bagay:
--   (1) SINO ang may role='admin'. Dalawa sila. Kilala mo ba pareho?
--   (2) Ang totoong listahan ng column ng profiles.
-- ============================================================================
select '1. ADMIN' as sort_key, email as detail
  from public.profiles where lower(trim(role)) = 'admin'
union all
select '2. TEACHER', email
  from public.profiles where lower(trim(role)) = 'teacher'
union all
select '3. column', column_name
  from information_schema.columns
 where table_schema = 'public' and table_name = 'profiles'
 order by sort_key, detail;


-- ############################################################################
-- MIGRATION 20260822_0009_close_revocation_gap
-- ############################################################################

-- ============================================================================
-- PIA 0009 -- ISARA ANG REVOCATION GAP SA PROFILES POLICIES
-- ============================================================================
-- May DALAWANG henerasyon ng policy sa profiles. Ang mas luma ay walang
-- jwt_is_current(), at dahil ang mga PERMISSIVE policy ay pinagsasama sa
-- pamamagitan ng OR, ang luma ang NANANAIG -- kaya walang epekto ang
-- revocation check ng mas bago:
--
--   profiles_select_own   : email = auth.jwt()->>'email' AND jwt_is_current()
--   profiles_select_self   : email = current_email()            <-- WALANG check
--   profiles_admin_all     : is_admin()                          <-- WALANG check
--   profiles_update_self   : email = current_email()             <-- WALANG check
--
-- Ibig sabihin: hindi gumagana ang "Revoke Sessions" ng admin. Umaasa ang
-- requireStudentSession() sa assets/js/function.js na haharangin ng
-- jwt_is_current() ang SELECT para matukoy ang na-revoke na session -- at
-- nilalampasan ito ng mga lumang policy. Sa isang lab na 76 estudyante ang
-- naghahati sa mga PC, ang revocation ang paraan mo ng pagkontrol sa device
-- slots, kaya mahalaga ito.
--
-- ANG GINAGAWA:
--   1. TANGGALIN ang profiles_select_self -- eksaktong dobleng-kopya ng
--      profiles_select_own, maliban sa walang revocation check.
--   2. PALITAN ang profiles_admin_all -- HINDI ito basta tinatanggal: FOR ALL
--      ito, kaya ito rin ang write path ng admin (scores, retake, register).
--      Dinadagdagan lang ng jwt_is_current().
--   3. PALITAN ang profiles_update_self -- dinagdagan ng jwt_is_current() at
--      ng WITH CHECK, para hindi mailipat ang row sa ibang email.
--
-- PARA IBALIK (rollback):
--   create policy profiles_select_self on public.profiles
--     for select using (email = current_email());
--   drop policy profiles_admin_all on public.profiles;
--   create policy profiles_admin_all on public.profiles for all using (is_admin());
--   drop policy profiles_update_self on public.profiles;
--   create policy profiles_update_self on public.profiles
--     for update using (email = current_email());
-- ============================================================================

begin;

drop policy if exists profiles_select_self on public.profiles;

drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles
  for all to authenticated
  using       (public.is_admin() and public.jwt_is_current())
  with check  (public.is_admin() and public.jwt_is_current());

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated
  using       (email = (auth.jwt() ->> 'email') and public.jwt_is_current())
  with check  (email = (auth.jwt() ->> 'email') and public.jwt_is_current());


-- ============================================================================
-- SELF-VERIFICATION -- tumatakbo BAGO ang commit.
-- Kung mali ang naging resulta, nagtatapon ito ng exception at IBINABALIK ang
-- BUONG transaction -- kaya imposibleng ma-lock out ka ng migration na ito.
-- ============================================================================
do $$
declare
  v_admin   text;
  v_student text;
  v_total   int;
  n         int;
begin
  select count(*) into v_total from public.profiles;
  select email into v_admin   from public.profiles where lower(trim(role)) = 'admin'   order by email limit 1;
  select email into v_student from public.profiles where lower(trim(role)) = 'student' order by email limit 1;

  -- (1) Dapat pa ring makita ng admin ang LAHAT ng row.
  perform set_config('request.jwt.claims',
    json_build_object('email', v_admin, 'role', 'authenticated',
                      'iat', extract(epoch from now())::bigint)::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.profiles;
  execute 'reset role';

  if n <> v_total then
    raise exception
      'PIA ABORT: ang admin (%) ay % row lang ang nakikita sa % -- ibinabalik ang lahat.',
      v_admin, n, v_total using errcode = 'P0001';
  end if;

  -- (2) Dapat SARILI lang ang nakikita ng estudyante.
  if v_student is not null then
    perform set_config('request.jwt.claims',
      json_build_object('email', v_student, 'role', 'authenticated',
                        'iat', extract(epoch from now())::bigint)::text, true);
    execute 'set local role authenticated';
    select count(*) into n from public.profiles;
    execute 'reset role';

    if n <> 1 then
      raise exception
        'PIA ABORT: ang estudyante (%) ay % row ang nakikita, dapat 1 -- ibinabalik ang lahat.',
        v_student, n using errcode = 'P0001';
    end if;
  end if;

  raise notice 'PIA OK: admin nakakakita ng % row; estudyante nakakakita ng sarili lang.', v_total;
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Huling ulat -- ito ang ipapakita ng editor.
select policyname,
       cmd,
       case when coalesce(qual, '') like '%jwt_is_current%'
                 or cmd = 'INSERT' then 'may revocation check'
            else '*** WALANG CHECK ***' end as revocation
  from pg_policies
 where schemaname = 'public' and tablename = 'profiles'
 order by cmd, policyname;


-- ############################################################################
-- MIGRATION 20260822_0010_unique_email
-- ############################################################################

-- ============================================================================
-- PIA 0010 -- UNIQUE(email) SA PROFILES
-- ============================================================================
-- PATAKBUHIN LANG PAGKATAPOS MABURA ANG DUPLICATE. Tumatanggi itong tumakbo
-- habang may natitirang duplicate -- sadya iyon: ang pagpili kung aling row
-- ang buburahin ay desisyon mo, hindi awtomatiko.
--
-- BAKIT MAHALAGA ITO, higit pa sa maayos na UI:
--   * Ang LAHAT ng telemetry table (tutoring_attempts, math_attempt_log,
--     ocean_submissions, problem_serves, hint_consumptions) ay naka-key sa
--     student_email bilang TEXT. Sa dalawang row na iisa ang email, walang
--     paraan para malaman kung kanino ang isang session.
--   * Ang .maybeSingle() -- ginagamit sa login at sa requireStudentSession() --
--     ay NAG-E-ERROR kapag higit sa isa ang tumugma. Hindi makaka-login ang
--     estudyanteng may duplicate.
--   * Ang saveBatchScores() ay gumagamit ng .upsert(..., {onConflict:'email'}).
--     KAILANGAN nito ng tunay na UNIQUE constraint sa `email` -- hindi sapat
--     ang unique index sa isang expression. Kaya idinagdag ang dalawa sa ibaba.
-- ============================================================================

begin;

-- (1) HARANG: tumigil kung may duplicate pa rin.
do $$
declare
  v_dups text;
begin
  select string_agg(norm || ' (' || cnt || ' rows)', ', ')
    into v_dups
    from (select lower(trim(email)) as norm, count(*) as cnt
            from public.profiles
           group by lower(trim(email))
          having count(*) > 1) d;

  if v_dups is not null then
    raise exception
      'PIA ABORT: may duplicate pa: %. Patakbuhin muna ang DIAGNOSE_duplicate_emails.sql at burahin ang tamang row.',
      v_dups using errcode = 'P0001';
  end if;
end;
$$;

-- (2) I-normalize sa lowercase/trimmed. Lowercase ang iniimbak ng Supabase
--     Auth, at eksaktong tugma ang hinahanap ng .eq('email', user.email) --
--     kaya ang 'Juan@ue.edu.ph' sa profiles ay tahimik na sumisira ng login.
--     Ligtas ito rito: kadedeklara pa lang natin na walang case-variant dups.
update public.profiles
   set email = lower(trim(email))
 where email is distinct from lower(trim(email));

-- (3) Ang tunay na UNIQUE constraint -- ito ang kailangan ng
--     upsert(onConflict:'email').
alter table public.profiles drop constraint if exists profiles_email_key;
alter table public.profiles add  constraint profiles_email_key unique (email);

-- (4) Karagdagang sapin: pumipigil sa case-variant na duplicate sa hinaharap
--     ('A@x.com' vs 'a@x.com'), na hindi nahuhuli ng plain UNIQUE.
drop index if exists public.profiles_email_lower_uidx;
create unique index profiles_email_lower_uidx on public.profiles (lower(email));

commit;

notify pgrst, 'reload schema';


-- Ulat: dapat 0 ang duplicate, at dapat nakalista ang dalawang constraint.
select 'natitirang duplicate' as item, count(*)::text as value
  from (select lower(trim(email)) from public.profiles
         group by lower(trim(email)) having count(*) > 1) d
union all
select 'kabuuang profiles', count(*)::text from public.profiles
union all
select 'index: ' || indexname, 'ok'
  from pg_indexes
 where schemaname = 'public' and tablename = 'profiles'
   and indexname in ('profiles_email_key', 'profiles_email_lower_uidx');


-- ############################################################################
-- MIGRATION 20260822_0011_close_backend_surface
-- ############################################################################

-- ============================================================================
-- PIA 0011 -- ISARA ANG NATITIRANG BACKEND SURFACE
-- ============================================================================
--   PART 1: bawiin ang lahat ng anon grant (telemetry + settings + lahat)
--   PART 2: ayusin ang column-level grant sa profiles (3 legit na block)
--   PART 3: bantayan ang mga admin_* RPC ng internal role check
--   PART 4: ulat
--
-- Isang transaction lang ang lahat. Kung may pumalya, WALANG mababago.
-- ============================================================================

begin;

-- ===========================================================================
-- PART 1 -- ANON
-- Ang `anon` ay ang role ng publishable key na nakikita ng LAHAT sa
-- view-source. Ang DELETE/UPDATE/TRUNCATE doon ay nangangahulugang kayang
-- burahin ng kahit sino sa internet ang buong research data mo nang HINDI
-- naglo-log in. Wala ni isang pahina ang bumabasa ng table bago mag-login --
-- ang isStageOpen() ay tumatakbo pagkatapos ng session -- kaya ang tamang
-- antas ng access ng anon ay WALA.
-- ===========================================================================
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

-- Para hindi na maulit sa mga bagong table/function sa hinaharap.
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;


-- ===========================================================================
-- PART 2 -- PROFILES GRANTS
-- "permission denied for table profiles" ang tatlong legit na path. Iyon ay
-- GRANT error, hindi RLS -- ang RLS ay nagbabalik ng 0 row o ng "new row
-- violates row-level security policy".
--
-- Sanhi: column-level ang mga grant ng authenticated, at ang column na
-- idinagdag ng 0008 (ALTER TABLE ADD COLUMN) ay WALANG minamana kahit anong
-- grant. Kaya ang update na humahawak sa is_in_game / current_problem /
-- hints_used ay tinatanggihan bago pa masuri ang RLS.
--
-- Ang tamang antas ay TABLE-level, dahil ang enforcement ay nasa
-- trg_enforce_profile_write_scope -- na nakakakilala ng admin laban sa
-- student, bagay na HINDI kayang gawin ng grant. Hindi ito nagpapaluwag:
-- pinapatakbo lang nito ang tseke sa tamang layer.
-- ===========================================================================
revoke all on public.profiles from authenticated;
grant select, insert, update on public.profiles to authenticated;
-- Sinasadyang WALANG delete: ang admin_delete_user() RPC lang ang bumubura.


-- ===========================================================================
-- PART 3 -- ADMIN RPC GUARD
-- Ang admin_create_auth_user / admin_delete_user / atbp. ay SECURITY DEFINER
-- na WALANG role check, at may EXECUTE ang authenticated. Ibig sabihin, kayang
-- tawagin ng kahit sinong naka-login na estudyante ang admin_delete_user()
-- mula sa console at burahin ang kahit sinong account.
--
-- Hindi ko binabago ang lohika ng kahit alin sa kanila -- hindi ko pa nakikita
-- ang mga katawan nila. Sa halip, bawat isa ay PINAPALITAN NG PANGALAN tungo
-- sa <pangalan>__inner, at isang wrapper na PAREHO ang pangalan at signature
-- ang inilalagay sa harap nito. Kaya:
--   * walang kailangang baguhin sa JS -- pareho ang pangalan at argumento;
--   * hindi nababago ang orihinal na lohika;
--   * ang __inner ay hindi na matatawag ng authenticated.
-- ===========================================================================
do $$
declare
  r          record;
  v_args     text;
  v_params   text;
  v_ret      text;
  v_body     text;
  v_wrapped  int := 0;
  v_skipped  text := '';
begin
  for r in
    select p.oid,
           p.proname,
           pg_get_function_arguments(p.oid)          as decl_args,
           pg_get_function_identity_arguments(p.oid) as ident_args,
           pg_get_function_result(p.oid)             as ret,
           p.proretset,
           p.proargnames,
           p.pronargs
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and p.proname like 'admin\_%'
       and p.prosecdef                                        -- SECURITY DEFINER
       and p.proname not like '%\_\_inner'                     -- hindi pa nabalot
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and pg_get_functiondef(p.oid) !~* '(is_admin|current_user_role|pia_caller_role)'
  loop
    -- Kailangan ng pangalan ng parameter para maipasa sa loob. Walang pangalan
    -- = laktawan (at iulat) sa halip na masira ang function.
    if r.pronargs > 0 and (r.proargnames is null or array_length(r.proargnames,1) < r.pronargs) then
      v_skipped := v_skipped || r.proname || ' (walang pangalan ang parameter), ';
      continue;
    end if;

    v_params := case when r.pronargs = 0 then ''
                     else array_to_string(r.proargnames[1:r.pronargs], ', ') end;

    execute format('alter function public.%I(%s) rename to %I',
                   r.proname, r.ident_args, r.proname || '__inner');

    if r.ret = 'void' then
      v_body := format('perform public.%I(%s);', r.proname || '__inner', v_params);
    elsif r.proretset then
      v_body := format('return query select * from public.%I(%s);', r.proname || '__inner', v_params);
    else
      v_body := format('return public.%I(%s);', r.proname || '__inner', v_params);
    end if;

    execute format($f$
      create function public.%I(%s)
      returns %s
      language plpgsql
      security definer
      set search_path = public
      as $inner$
      begin
        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: admin lang ang pwedeng tumawag ng %I().'
            using errcode = '42501';
        end if;
        %s
      end;
      $inner$;$f$, r.proname, r.decl_args, r.ret, r.proname, v_body);

    execute format('revoke all on function public.%I(%s) from public, anon, authenticated',
                   r.proname || '__inner', r.ident_args);
    execute format('grant execute on function public.%I(%s) to authenticated',
                   r.proname, r.ident_args);

    v_wrapped := v_wrapped + 1;
  end loop;

  raise notice 'PIA: % admin RPC ang nabalot. Nilaktawan: %',
    v_wrapped, coalesce(nullif(v_skipped, ''), 'wala');
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ===========================================================================
-- PART 4 -- ULAT
-- ===========================================================================
select 'anon: ' || table_name as item, string_agg(distinct privilege_type, ',') as detail
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee = 'anon'
 group by table_name
union all
select 'anon grants', case when not exists (
         select 1 from information_schema.role_table_grants
          where table_schema='public' and grantee='anon')
       then 'WALA NA (tama)' else '*** may natitira pa ***' end
union all
select 'profiles grant: authenticated',
       string_agg(distinct privilege_type, ',')
  from information_schema.role_table_grants
 where table_schema='public' and table_name='profiles' and grantee='authenticated'
union all
select 'admin RPC: ' || p.proname,
       case when pg_get_functiondef(p.oid) ~* 'pia_caller_role' then 'may guard'
            when p.proname like '%\_\_inner' then
                 case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
                      then '*** inner, tawagable pa ***' else 'inner, naka-lock' end
            else '*** WALANG GUARD ***' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname like 'admin\_%'
 order by item;


-- ############################################################################
-- MIGRATION 20260822_0012_searchpath_and_device_atomicity
-- ############################################################################

-- ============================================================================
-- PIA 0012 -- (A) AYUSIN ANG gen_salt SEARCH_PATH   (B) ATOMIC DEVICE SLOTS
-- ============================================================================

begin;

-- ===========================================================================
-- PART A -- search_path regression mula sa 0011
--
-- Ang wrapper na ginawa ng 0011 ay may `set search_path = public`. Ang isang
-- SECURITY DEFINER function na WALANG sariling SET clause ay minamana ang
-- search_path na umiiral sa oras ng pagtawag -- kaya nang paliitin ito ng
-- wrapper tungo sa `public` lang, nawala sa __inner ang `extensions`, kung
-- saan naka-install ng Supabase ang pgcrypto. Doon nakatira ang gen_salt().
--
-- Gumagana ang admin_create_auth_user bago ang 0011; ang wrapper ko ang
-- sumira nito. Ang pag-aalis ng SET clause ay magsasaayos nito pero magbubukas
-- ng search_path injection sa isang definer function -- kaya PINAPALAWAK natin
-- ito, hindi inaalis.
--
-- Nilalapatan ang PAREHONG wrapper at __inner: kapag may sariling SET ang
-- __inner, hindi ito naaabot ng pagbabago sa wrapper.
-- ===========================================================================
do $$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
     where n2.nspname = 'public'
       and p.prokind = 'f'
       and p.proname like 'admin\_%'
       and p.prosecdef
  loop
    execute format('alter function %s set search_path = public, extensions', r.sig);
    n := n + 1;
  end loop;
  raise notice 'PIA: % admin function ang naitakda sa search_path = public, extensions', n;
end;
$$;


-- ===========================================================================
-- PART B -- ATOMIC DEVICE SLOTS
--
-- Ang enforceDeviceLimit() sa assets/js/function.js ay read-then-write:
--     basahin ang active_devices -> tingnan ang haba -> i-push -> isulat
-- Walang locking sa pagitan. Sa isang computer lab kung saan sabay-sabay
-- naglo-log in ang 76 estudyante, dalawang magkasabay na login ng IISANG
-- account ay parehong nakakabasa ng lumang array, parehong nagpu-push, at ang
-- huling sumulat ang mananaig -- kaya may device na tahimik na nawawala sa
-- listahan, o nakakalusot ang dalawang device sa limit na isa.
--
-- Ang parehong pattern ay nasa tatlong revoke path ng admin: kung mag-login
-- ang estudyante habang binabawi ng admin ang device nila, may mawawala sa
-- dalawang operasyon.
--
-- Ang SELECT ... FOR UPDATE ay nagse-seryalisa ng magkasabay na tawag sa
-- IISANG row: naghihintay ang pangalawa hanggang matapos ang una, kaya
-- nakikita nito ang na-update nang listahan.
-- ===========================================================================

create or replace function public.claim_device(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_max     int;
  v_devices text[];
begin
  if v_email is null then
    raise exception 'PIA: walang authenticated session.' using errcode = '42501';
  end if;

  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'PIA: kailangan ng device id.' using errcode = '22023';
  end if;

  -- FOR UPDATE: dito nagseseryalisa ang magkasabay na login.
  select coalesce(p.max_devices, 1), coalesce(p.active_devices, '{}')
    into v_max, v_devices
    from public.profiles p
   where p.email = v_email
     for update;

  if not found then
    raise exception 'PIA: walang profile para sa session na ito.' using errcode = '42501';
  end if;

  -- Kilala na ang device na ito -- walang gagawin (idempotent).
  if p_device_id = any(v_devices) then
    return jsonb_build_object('allowed', true, 'devices', v_devices, 'max', v_max);
  end if;

  if coalesce(array_length(v_devices, 1), 0) >= v_max then
    return jsonb_build_object(
      'allowed', false,
      'reason', v_max || ' device limit lang. Mag-sign out muna sa kabilang device.',
      'devices', v_devices, 'max', v_max);
  end if;

  update public.profiles
     set active_devices = array_append(v_devices, p_device_id)
   where email = v_email;

  return jsonb_build_object('allowed', true,
                            'devices', array_append(v_devices, p_device_id),
                            'max', v_max);
end;
$$;

revoke all on function public.claim_device(text) from public, anon;
grant execute on function public.claim_device(text) to authenticated;


-- Atomic na revoke para sa admin. Ang p_device_id na NULL ay nag-aalis ng
-- LAHAT ng device ng account na iyon.
create or replace function public.admin_revoke_device(p_email text, p_device_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_devices text[];
  v_new     text[];
begin
  if public.pia_caller_role() is distinct from 'admin' then
    raise exception 'PIA: admin lang ang pwedeng mag-revoke ng device.' using errcode = '42501';
  end if;

  select coalesce(p.active_devices, '{}') into v_devices
    from public.profiles p where p.email = p_email
     for update;

  if not found then
    raise exception 'PIA: walang profile na %', p_email using errcode = '22023';
  end if;

  if p_device_id is null then
    v_new := '{}';
  else
    select coalesce(array_agg(d), '{}') into v_new
      from unnest(v_devices) d where d is distinct from p_device_id;
  end if;

  update public.profiles set active_devices = v_new where email = p_email;

  return jsonb_build_object('devices', v_new,
                            'removed', coalesce(array_length(v_devices,1),0) - coalesce(array_length(v_new,1),0));
end;
$$;

revoke all on function public.admin_revoke_device(text, text) from public, anon;
grant execute on function public.admin_revoke_device(text, text) to authenticated;

commit;

notify pgrst, 'reload schema';


-- Ulat: dapat may `public, extensions` na lahat ng admin function.
select p.proname as fn,
       coalesce(array_to_string(p.proconfig, ', '), '*** WALANG search_path ***') as config
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and (p.proname like 'admin\_%' or p.proname in ('claim_device'))
 order by p.proname;


-- ############################################################################
-- MIGRATION 20260822_0013_english_messages
-- ############################################################################

-- ============================================================================
-- PIA 0013 -- TRANSLATE SERVER-SIDE MESSAGES TO ENGLISH
-- ============================================================================
-- These strings surface in the admin UI, in browser consoles, and in the audit
-- scripts, so they are operator-facing diagnostics.
--
-- Rather than retyping every function body (which risks silently changing
-- logic), this reads each function's own definition via pg_get_functiondef(),
-- substitutes only the message text, and re-executes it. Behaviour is
-- guaranteed identical -- only the strings differ.
--
-- It also picks up the admin_* wrappers generated by 0011, whose guard message
-- was written inline by that migration's DO block.
--
-- NOT TRANSLATED: the PIA agent's dialogue to students in
-- student/js/tutoring-dashboard.js. That is Filipino instructional content for
-- Grade 7 learners, not incidental hardcoding -- see the note in the summary.
-- ============================================================================

do $$
declare
  r     record;
  v_def text;
  v_new text;
  i     int;
  n     int := 0;
  v_map text[][] := array[
    array['PIA: walang authenticated session.',
          'PIA: no authenticated session.'],
    array['PIA: walang profile para sa session na ito.',
          'PIA: no profile found for this session.'],
    array['PIA: walang profile na %',
          'PIA: no profile found for %'],
    array['PIA: bawal ang direktang pagsulat sa protektadong profile column. Gamitin ang submit_ocean_results() / set_student_stage().',
          'PIA: direct writes to protected profile columns are not allowed. Use submit_ocean_results() / set_student_stage().'],
    array['PIA: hindi ka pwedeng gumawa ng profile row (role=%).',
          'PIA: you are not allowed to create a profile row (role=%).'],
    array['PIA: hindi ka pwedeng magbura ng profile row (role=%).',
          'PIA: you are not allowed to delete a profile row (role=%).'],
    array['PIA: hindi ka pwedeng magbago ng profile na hindi sa iyo.',
          'PIA: you are not allowed to modify a profile that is not yours.'],
    array['PIA: naisumite na ang OCEAN test mo. Humingi ng retake sa admin.',
          'PIA: your OCEAN test has already been submitted. Ask an admin for a retake.'],
    array['PIA: kailangan ng eksaktong 50 na sagot (natanggap: %).',
          'PIA: exactly 50 responses are required (received: %).'],
    array['PIA: bawat sagot ay dapat nasa 1..5.',
          'PIA: every response must be between 1 and 5.'],
    array['PIA: hindi kilalang stage: %',
          'PIA: unknown stage: %'],
    array['PIA: hindi kilalang stage key: %',
          'PIA: unknown stage key: %'],
    array['PIA: hindi kilalang problem_id: %',
          'PIA: unknown problem_id: %'],
    array['PIA: admin lang ang pwedeng magbukas/magsara ng stage.',
          'PIA: only an admin can open or close a stage.'],
    array['PIA: admin lang ang pwedeng mag-revoke ng device.',
          'PIA: only an admin can revoke a device.'],
    array['PIA: admin lang ang pwedeng tumawag ng',
          'PIA: only an admin may call'],
    array['PIA: kailangan ng device id.',
          'PIA: a device id is required.'],
    array[' device limit lang. Mag-sign out muna sa kabilang device.',
          ' device limit reached. Please sign out on your other device first.'],
    array['PIA: hindi pa naiseserve ang problemang ito.',
          'PIA: this problem has not been served yet.'],
    array['PIA: hindi pa tapos ang problemang ito.',
          'PIA: this problem is not finished yet.'],
    array['PIA: walang hint para sa problem na ito.',
          'PIA: there are no hints for this problem.']
  ];
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%PIA%'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;

    for i in 1 .. array_length(v_map, 1) loop
      v_new := replace(v_new, v_map[i][1], v_map[i][2]);
    end loop;

    if v_new is distinct from v_def then
      execute v_new;
      n := n + 1;
    end if;
  end loop;

  raise notice 'PIA: translated messages in % function(s).', n;
end;
$$;

notify pgrst, 'reload schema';


-- Report: anything still holding a Tagalog message.
select p.proname as function_name,
       case when pg_get_functiondef(p.oid) ~ '(walang|hindi|bawal|kailangan|lamang|pwede|ang |ng )'
            then '*** still has Tagalog ***' else 'english' end as status
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind = 'f'
   and pg_get_functiondef(p.oid) like '%PIA%'
 order by status desc, p.proname;


-- ############################################################################
-- MIGRATION 20260822_0014_english_messages_round2
-- ############################################################################

-- ============================================================================
-- PIA 0014 -- TRANSLATE REMAINING TAGALOG MESSAGES (round 2)
-- ============================================================================
-- 0013 covered the functions I authored. This covers the pre-existing admin_*
-- functions, whose message strings I had never seen -- notably the `skipped`
-- reasons returned by admin_grant_stage, which the dashboard renders verbatim
-- in its "Partially Granted" alert.
--
-- Same technique as 0013: read each function's own definition, substitute only
-- the message text, re-execute. Logic cannot drift because the body is the
-- database's own copy.
--
-- Every mapping below is a literal replace, so an entry that does not match is
-- simply a no-op. That makes it safe to include likely variants alongside the
-- two confirmed strings.
--
-- The closing report uses a CORRECTED detector. The one in 0013 was wrong:
-- it included 'ng ', which matches "using " -- and every function here
-- contains `using errcode`, so it flagged all 17 regardless.
-- ============================================================================

do $$
declare
  r     record;
  v_def text;
  v_new text;
  i     int;
  n     int := 0;
  v_map text[][] := array[
    -- confirmed present in admin_grant_stage__inner
    array['Hindi pa tapos ang OCEAN test',        'OCEAN test not yet completed'],
    array['Hindi non-assigned ang grupo',         'Group is not non-assigned'],
    -- likely siblings; no-ops if absent
    array['May napili nang character',            'A character has already been selected'],
    array['Wala pang napiling character',         'No character selected yet'],
    array['Tapos na ang OCEAN test',              'OCEAN test already completed'],
    array['Walang ganitong email',                'No such email'],
    array['Hindi mahanap ang profile',            'Profile not found'],
    array['Hindi mahanap ang user',               'User not found'],
    array['Walang profile',                       'No profile'],
    array['Hindi awtorisado',                     'Not authorized'],
    array['Walang pahintulot',                    'Permission denied'],
    array['Kailangan ng admin',                   'Admin required'],
    array['admin lang ang pwede',                 'admin only'],
    array['Hindi wasto ang',                      'Invalid'],
    array['Hindi kilalang',                       'Unknown'],
    array['Naabot na ang limitasyon para sa problemang ito ngayong araw.',
          'Daily attempt limit reached for this problem.'],
    array['Masyadong mabilis ang mga sagot. Sandali lang po.',
          'Answers are coming in too quickly. Please slow down.'],
    array['Tapos na ang session na ito.',         'This session has already ended.'],
    array['Isang aktibong session lang bawat estudyante.',
          'Only one active session per student.']
  ];
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public' and p.prokind = 'f'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;

    for i in 1 .. array_length(v_map, 1) loop
      v_new := replace(v_new, v_map[i][1], v_map[i][2]);
    end loop;

    if v_new is distinct from v_def then
      execute v_new;
      n := n + 1;
      raise notice 'PIA: translated %', r.proname;
    end if;
  end loop;

  raise notice 'PIA: % function(s) updated.', n;
end;
$$;

notify pgrst, 'reload schema';


-- ============================================================================
-- CORRECTED REPORT -- string literals only, and no 'ng '/'ang ' keywords
-- (those matched "using ", which is why 0013's report was useless).
-- Anything listed here is genuinely untranslated user-facing text.
-- Empty result = the backend is fully English.
-- ============================================================================
select p.proname as function_name,
       m[1]      as remaining_tagalog_string
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral regexp_matches(
        pg_get_functiondef(p.oid),
        '''([^'']{4,200}?(?:[Ww]alang|[Hh]indi|[Bb]awal|[Kk]ailangan|[Pp]wede|[Dd]apat|[Nn]apili|[Gg]rupo|[Tt]apos na|[Mm]asyado|[Ss]andali|[Ii]sang aktibo)[^'']{0,200}?)''',
        'g') as m
 where n.nspname = 'public' and p.prokind = 'f'
 order by p.proname, m[1];


-- ############################################################################
-- MIGRATION 20260822_0015_settings_lockdown_and_strings
-- ############################################################################

-- ============================================================================
-- PIA 0015 -- (A) REMOVE global_password + LOCK settings  (B) LAST 3 STRINGS
-- ============================================================================

begin;

-- ===========================================================================
-- PART A1 -- delete the credential
--
-- `settings` is readable by every signed-in student, because isStageOpen()
-- needs the stage_* flags. `global_password` sat in that same table, so any
-- student could read it with one console call:
--     await supabaseClient.from('settings').select('*')
--
-- A comment in admin-dashboard.js states this key was already removed as a
-- security fix. It was not. Nothing in the codebase could contradict that
-- claim, because the database layer was never versioned -- which is exactly
-- the failure mode these migrations exist to end.
--
-- No code reads this key any more (verified by grep across all JS and HTML);
-- accounts are provisioned with generateSecurePassword() per student.
-- ===========================================================================
delete from public.settings where key = 'global_password';


-- ===========================================================================
-- PART A2 -- stop it happening again
--
-- Deleting the row fixes today. A RESTRICTIVE policy fixes tomorrow: whatever
-- key anyone adds to `settings` later, students can only ever read stage_*.
--
-- RESTRICTIVE policies are ANDed with the permissive ones, so this ADDS a
-- constraint without touching the 3 existing policies:
--     final access = (any permissive policy) AND (every restrictive policy)
--
-- Admins keep full read. pia_stage_open() only ever reads stage_* keys, so it
-- is unaffected either way.
-- ===========================================================================
drop policy if exists settings_non_admin_stage_only on public.settings;

create policy settings_non_admin_stage_only on public.settings
  as restrictive
  for select
  to authenticated
  using (key like 'stage\_%' or public.pia_caller_role() = 'admin');


-- ===========================================================================
-- PART B -- the last three user-facing strings
-- ===========================================================================
do $$
declare
  r     record;
  v_def text;
  v_new text;
  i     int;
  n     int := 0;
  v_map text[][] := array[
    array['Group is not non-assigned -- walang character selection para sa kanila.',
          'Group is not non-assigned -- character selection does not apply to them.'],
    array['Non-assigned pero wala pang napiling character.',
          'Non-assigned but no character has been selected yet.'],
    array['Masyadong maraming session. Sandali lang po.',
          'Too many sessions started. Please wait a moment.']
  ];
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public' and p.prokind = 'f'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;
    for i in 1 .. array_length(v_map, 1) loop
      v_new := replace(v_new, v_map[i][1], v_map[i][2]);
    end loop;
    if v_new is distinct from v_def then
      execute v_new;
      n := n + 1;
      raise notice 'PIA: translated %', r.proname;
    end if;
  end loop;
  raise notice 'PIA: % function(s) updated.', n;
end;
$$;


-- ===========================================================================
-- SELF-VERIFICATION -- runs BEFORE commit. If anything is wrong this raises
-- and the whole migration rolls back, so it cannot lock you out.
-- ===========================================================================
do $$
declare
  v_student text;
  v_admin   text;
  n_student int;
  n_admin   int;
begin
  select email into v_student from public.profiles
   where lower(trim(coalesce(role,'student'))) = 'student' order by email limit 1;
  select email into v_admin from public.profiles
   where lower(trim(coalesce(role,''))) = 'admin' order by email limit 1;

  -- Sentinel non-stage key, removed again before commit.
  insert into public.settings (key, value) values ('pia_sentinel_check', to_jsonb('x'::text))
    on conflict (key) do update set value = excluded.value;

  perform set_config('request.jwt.claims',
    json_build_object('email', v_student, 'role','authenticated',
                      'iat', extract(epoch from now())::bigint)::text, true);
  execute 'set local role authenticated';
  select count(*) into n_student from public.settings;
  execute 'reset role';

  perform set_config('request.jwt.claims',
    json_build_object('email', v_admin, 'role','authenticated',
                      'iat', extract(epoch from now())::bigint)::text, true);
  execute 'set local role authenticated';
  select count(*) into n_admin from public.settings;
  execute 'reset role';

  delete from public.settings where key = 'pia_sentinel_check';

  -- Student must NOT see the sentinel; admin must.
  if n_student <> 3 then
    raise exception 'PIA ABORT: student sees % settings rows, expected 3 stage flags only.', n_student
      using errcode = 'P0001';
  end if;
  if n_admin < 4 then
    raise exception 'PIA ABORT: admin sees only % settings rows -- admin read is broken.', n_admin
      using errcode = 'P0001';
  end if;

  raise notice 'PIA OK: student sees % (stage flags only); admin sees %.', n_student, n_admin;
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Final report: settings contents + any remaining Tagalog message strings.
select 'settings key' as item, key as detail from public.settings
union all
select 'remaining tagalog', p.proname || ': ' || m[1]
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  cross join lateral regexp_matches(pg_get_functiondef(p.oid),
    '''([^'']{4,200}?(?:[Ww]alang|[Hh]indi|[Bb]awal|[Kk]ailangan|[Pp]wede|[Dd]apat|[Nn]apili|[Mm]asyado|[Ss]andali)[^'']{0,200}?)''','g') as m
 where n.nspname = 'public' and p.prokind = 'f'
   and m[1] !~ '^\s*;?\s*(--|end if|then|v_)'      -- skip inline comments caught mid-body
 order by item, detail;


-- ############################################################################
-- MIGRATION 20260822_0016_resume_game_session
-- ############################################################################

-- ============================================================================
-- PIA 0016 -- RESUME AN INTERRUPTED TUTORING SESSION
-- ============================================================================
-- Today, tutoring-dashboard.js always calls start_game_session(), which opens a
-- fresh session and closes the previous one. So a student who taps Home and
-- comes back to Mission restarts from problem 1 -- and the partial session is
-- left behind as an abandoned record.
--
-- This returns the student's most recent UNFINISHED session together with
-- enough state for the client to pick up exactly where it stopped, and only
-- falls through to start_game_session() when there is nothing to resume.
--
-- It deliberately does NOT need the game-session table: everything is derived
-- from problem_serves and tutoring_attempts, which I can see.
-- ============================================================================

create or replace function public.resume_or_start_game_session()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_session uuid;
  v_answered int;
  v_correct  int;
  v_served   text[];
  v_pending  text;
  v_state    jsonb;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  -- Most recent session this student was actually served a problem in.
  select ps.session_id into v_session
    from public.problem_serves ps
   where ps.student_email = v_email
   order by ps.served_at desc
   limit 1;

  if v_session is not null then
    select count(*), coalesce(count(*) filter (where is_correct), 0)
      into v_answered, v_correct
      from public.tutoring_attempts
     where session_id = v_session and student_email = v_email;

    -- Resumable only if started but not finished. 10 = SESSION_TARGET.
    if v_answered > 0 and v_answered < 10 then

      select coalesce(array_agg(ps.problem_id), '{}') into v_served
        from public.problem_serves ps
       where ps.session_id = v_session and ps.student_email = v_email;

      -- A problem that was served but never resolved: they left mid-question.
      select ps.problem_id into v_pending
        from public.problem_serves ps
       where ps.session_id = v_session
         and ps.student_email = v_email
         and not exists (select 1 from public.tutoring_attempts ta
                          where ta.session_id = ps.session_id
                            and ta.problem_id = ps.problem_id)
       order by ps.served_at desc
       limit 1;

      -- Restart that problem's clock. served_at drives time_taken_ms, and
      -- without this the minutes spent away would be counted as time on task
      -- and would misclassify the attempt as 'struggling'. We measure time
      -- solving, not time the tab sat closed.
      if v_pending is not null then
        update public.problem_serves
           set served_at = now()
         where session_id = v_session and problem_id = v_pending;
      end if;

      v_state := public.pia_session_state(v_session, v_email);

      return jsonb_build_object(
        'session_id',          v_session,
        'resumed',             true,
        'problems_answered',   v_answered,
        'correct_count',       v_correct,
        'level',               (v_state ->> 'level')::int,
        'consecutive_correct', (v_state ->> 'consecutive_correct')::int,
        'served_problem_ids',  to_jsonb(v_served),
        'pending_problem_id',  v_pending);
    end if;
  end if;

  -- Nothing to resume: normal fresh start.
  return jsonb_build_object(
    'session_id',          public.start_game_session(),
    'resumed',             false,
    'problems_answered',   0,
    'correct_count',       0,
    'level',               1,
    'consecutive_correct', 0,
    'served_problem_ids',  to_jsonb(array[]::text[]),
    'pending_problem_id',  null);
end;
$$;

revoke all on function public.resume_or_start_game_session() from public, anon;
grant execute on function public.resume_or_start_game_session() to authenticated;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260823_0017_close_console_surface
-- ############################################################################

-- ============================================================================
-- PIA 0017 -- CLOSE THE CONSOLE-CREATED SURFACE
-- ============================================================================
-- Migrations 0001-0016 hardened every object that existed as a FILE. This one
-- closes the objects that were created in the Supabase console and therefore
-- were never reviewed: tutoring_attempts, math_attempt_log, session_start_log,
-- professors, and the grants on the two export views.
--
-- WHAT THIS DOES NOT TOUCH -- so it cannot lock you out of the console:
--   * public.profiles          (login + the admin role check read it)
--   * auth.*                   (untouched entirely)
--   * public.settings          (0015 owns it)
--   * public.ocean_submissions (0002 owns it)
--   * any function body        (0011 owns the admin wrappers)
-- The worst case is a panel that renders empty, and PART 7 aborts the whole
-- transaction before that can happen. Signing in cannot break.
--
-- WHY THE THREE LOG TABLES KEEP `select`:
--   v_tutoring_session_summary and v_student_tutoring_export are
--   security_invoker=on, so they check permissions AS THE CALLER. Revoking
--   select on the base tables would break the student summary screen and your
--   own data export. Writes are revoked instead, and RLS scopes the reads.
--
-- RUN IT ALL AT ONCE. It is one transaction: if any assertion fails, nothing
-- changes. The rollback block is at the bottom.
-- ============================================================================

begin;

-- ===========================================================================
-- PART 1 -- PREFLIGHT. Refuse to run against a schema I did not expect.
-- ===========================================================================
do $$
declare
  v_missing text := '';
  v_t       text;
begin
  if to_regprocedure('public.pia_caller_role()') is null then
    raise exception 'PIA 0017: pia_caller_role() is missing. Run 0001 first.';
  end if;

  foreach v_t in array array['tutoring_attempts','professors'] loop
    if to_regclass('public.' || v_t) is null then
      v_missing := v_missing || v_t || ', ';
    end if;
  end loop;

  if v_missing <> '' then
    raise exception 'PIA 0017: expected table(s) not found: %', v_missing;
  end if;
end;
$$;


-- ===========================================================================
-- PART 2 -- SURPRISE CHECK
-- I have never seen pg_policies for this database. If a target table already
-- carries a policy, adding mine could WIDEN access (permissive policies OR
-- together). Abort and show me what is there instead of guessing.
-- ===========================================================================
do $$
declare
  v_found text := '';
  r       record;
begin
  for r in
    select tablename, policyname, cmd, permissive
      from pg_policies
     where schemaname = 'public'
       and tablename in ('tutoring_attempts','math_attempt_log',
                         'session_start_log','professors')
       and policyname not like 'pia0017\_%'
  loop
    v_found := v_found || format('%s.%s (%s %s); ',
                                 r.tablename, r.policyname, r.permissive, r.cmd);
  end loop;

  if v_found <> '' then
    raise exception E'PIA 0017 ABORTED -- pre-existing policies found:\n  %\n'
      'Nothing was changed. Send these to review before re-running, so the new '
      'policies do not OR together with them and widen access.', v_found;
  end if;
end;
$$;


-- ===========================================================================
-- PART 3 -- GRANT HYGIENE
-- TRUNCATE is never reachable through PostgREST, and RLS does not filter it
-- at all -- so it is a latent hole with no legitimate use. REFERENCES and
-- TRIGGER let a client attach objects to your research tables. None of the
-- three has a caller in the codebase. Same for every write on the two views.
-- ===========================================================================
do $$
declare
  v_t text;
begin
  foreach v_t in array array['tutoring_attempts','math_attempt_log',
                             'session_start_log','professors','sections',
                             'v_student_tutoring_export','v_tutoring_session_summary'] loop
    if to_regclass('public.' || v_t) is not null then
      execute format(
        'revoke truncate, references, trigger on public.%I from authenticated', v_t);
    end if;
  end loop;
end;
$$;

-- Views are read-only reporting surfaces. The insert/update/delete grants on
-- them came from a blanket `grant all` and mean nothing -- remove the noise so
-- the next person reading role_table_grants is not misled.
do $$
declare
  v_v text;
begin
  foreach v_v in array array['v_student_tutoring_export','v_tutoring_session_summary'] loop
    if to_regclass('public.' || v_v) is not null then
      execute format('revoke insert, update, delete on public.%I from authenticated', v_v);
    end if;
  end loop;
end;
$$;

-- The browser never writes these three tables -- every write goes through a
-- SECURITY DEFINER RPC, which runs as postgres and ignores these grants.
-- Verified: no `.from('tutoring_attempts'|'math_attempt_log'|
-- 'session_start_log')` call exists anywhere in the JS.
do $$
declare
  v_t text;
begin
  foreach v_t in array array['tutoring_attempts','math_attempt_log','session_start_log'] loop
    if to_regclass('public.' || v_t) is not null then
      execute format('revoke insert, update, delete on public.%I from authenticated', v_t);
      execute format('grant  select on public.%I to authenticated', v_t);  -- views need it
    end if;
  end loop;
end;
$$;

-- professors: admin_register_teacher() (SECURITY DEFINER) is the only writer.
revoke insert, update, delete on public.professors from authenticated;
grant  select                  on public.professors to authenticated;

-- LIVE BUG FIX: admin-dashboard.js:2784 calls sections.insert(), but
-- `authenticated` was never granted INSERT -- "Add section" fails today with
-- a grant error. RLS in PART 5 restricts it to admins.
grant select, insert on public.sections to authenticated;

-- Stop the next console-created table from inheriting anything by default.
alter default privileges in schema public revoke all on tables    from authenticated;
alter default privileges in schema public revoke all on sequences from authenticated;


-- ===========================================================================
-- PART 4 -- RLS ON THE RESEARCH TABLES
-- The owner column is DETECTED, not assumed. tutoring_attempts uses
-- student_email (confirmed in 0016); the other two were never in a file, so
-- if neither table exposes a recognisable owner column this raises and the
-- whole migration rolls back rather than locking rows away.
-- ===========================================================================
do $$
declare
  v_t   text;
  v_col text;
begin
  foreach v_t in array array['tutoring_attempts','math_attempt_log','session_start_log'] loop
    continue when to_regclass('public.' || v_t) is null;

    select c.column_name into v_col
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = v_t
       and c.column_name in ('student_email','user_email','participant_email','email')
     order by array_position(array['student_email','user_email','participant_email','email'],
                             c.column_name)
     limit 1;

    if v_col is null then
      raise exception
        E'PIA 0017 ABORTED -- no owner column on public.%.\n'
        'Looked for student_email / user_email / participant_email / email. '
        'Nothing was changed. Send me its column list and I will adjust.', v_t;
    end if;

    execute format('alter table public.%I enable row level security', v_t);

    -- Admin: full read, for the export view and the console.
    execute format('drop policy if exists pia0017_%s_admin_read on public.%I', v_t, v_t);
    execute format($p$
      create policy pia0017_%s_admin_read on public.%I
        for select to authenticated
        using (public.pia_caller_role() = 'admin')$p$, v_t, v_t);

    -- Student: own rows only, so the summary view keeps working for them.
    execute format('drop policy if exists pia0017_%s_own_read on public.%I', v_t, v_t);
    execute format($p$
      create policy pia0017_%s_own_read on public.%I
        for select to authenticated
        using (%I = (auth.jwt() ->> 'email'))$p$, v_t, v_t, v_col);

    -- The SECURITY DEFINER RPCs still have to WRITE these tables. A table
    -- owner bypasses RLS, but only if the function's owner IS the table owner
    -- and carries BYPASSRLS -- which I cannot verify from here. Rather than
    -- bet the tutoring flow on it, this reuses the exact test 0001 already
    -- proves in trg_enforce_profile_write_scope: PostgREST arrives as
    -- `authenticated`, a definer RPC arrives as its owner. Anything that is
    -- not the browser keeps full access; the browser gets nothing.
    execute format('drop policy if exists pia0017_%s_server_write on public.%I', v_t, v_t);
    execute format($p$
      create policy pia0017_%s_server_write on public.%I
        for all to public
        using (current_user <> 'authenticated')
        with check (current_user <> 'authenticated')$p$, v_t, v_t);

    raise notice 'PIA 0017: RLS on public.% scoped by %', v_t, v_col;
  end loop;
end;
$$;


-- ===========================================================================
-- PART 5 -- RLS ON professors AND sections
-- Faculty rows carry staff PII and were readable by every participant.
-- ===========================================================================
alter table public.professors enable row level security;

drop policy if exists pia0017_professors_admin_all on public.professors;
create policy pia0017_professors_admin_all on public.professors
  for select to authenticated
  using (public.pia_caller_role() = 'admin');

-- teacher-dashboard.js:207 reads its own row as a fallback for section/name.
drop policy if exists pia0017_professors_own_read on public.professors;
create policy pia0017_professors_own_read on public.professors
  for select to authenticated
  using (email = (auth.jwt() ->> 'email'));

drop policy if exists pia0017_professors_server_write on public.professors;
create policy pia0017_professors_server_write on public.professors
  for all to public
  using (current_user <> 'authenticated')
  with check (current_user <> 'authenticated');

alter table public.sections enable row level security;

-- Every signed-in role needs the section list (admin filters, teacher label).
drop policy if exists pia0017_sections_read on public.sections;
create policy pia0017_sections_read on public.sections
  for select to authenticated
  using (true);

drop policy if exists pia0017_sections_admin_insert on public.sections;
create policy pia0017_sections_admin_insert on public.sections
  for insert to authenticated
  with check (public.pia_caller_role() = 'admin');


-- ===========================================================================
-- PART 6 -- REPORT UNGUARDED FUNCTIONS (report only -- changes nothing)
-- 0011 wrapped the admin_* functions that existed WHEN IT RAN. It skipped any
-- with unnamed parameters and reported that only via `raise notice`, which the
-- SQL editor does not display. These three are called from the browser and
-- were never `admin_`-prefixed, so 0011 never considered them:
--   check_math_answer, end_game_session, release_device
-- end_game_session(p_session_id) and release_device(p_device_id) both take an
-- identifier as an argument. If either fails to verify that the object belongs
-- to the caller, a participant can end a peer's session mid-experiment.
-- I have not seen their bodies, so this only reports. Do not skip the output.
-- ===========================================================================
do $$
declare
  r       record;
  v_bad   text := '';
begin
  for r in
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and pg_get_functiondef(p.oid) !~* 'pia_caller_role|is_admin|auth\.jwt|auth\.uid'
  loop
    v_bad := v_bad || r.proname || ', ';
  end loop;

  if v_bad <> '' then
    raise warning E'\n*** PIA 0017: SECURITY DEFINER functions callable by any '
      'signed-in user with no visible caller check: %\n'
      '*** Review each body before the pilot. Not changed by this migration.', v_bad;
  else
    raise notice 'PIA 0017: every definer function reachable by authenticated references a caller check.';
  end if;
end;
$$;


-- ===========================================================================
-- PART 7 -- POSTFLIGHT. Abort rather than ship a broken console.
-- ===========================================================================
do $$
declare
  v_n int;
begin
  -- profiles must still be readable, or nobody can sign in at all.
  select count(*) into v_n from information_schema.role_table_grants
   where table_schema='public' and table_name='profiles'
     and grantee='authenticated' and privilege_type='SELECT';
  if v_n = 0 then
    raise exception 'PIA 0017 ABORTED -- profiles lost its SELECT grant. Rolled back.';
  end if;

  -- The admin console reads these four. A missing SELECT = an empty panel.
  select count(distinct table_name) into v_n from information_schema.role_table_grants
   where table_schema='public' and grantee='authenticated' and privilege_type='SELECT'
     and table_name in ('profiles','sections','professors','settings');
  if v_n < 4 then
    raise exception 'PIA 0017 ABORTED -- an admin-console table lost SELECT. Rolled back.';
  end if;

  -- Every RLS-enabled target must own at least one admin policy, or the
  -- console goes blank the moment RLS starts filtering.
  select count(*) into v_n from pg_policies
   where schemaname='public' and policyname like 'pia0017\_%'
     and qual like '%pia_caller_role%';
  if v_n < 3 then
    raise exception 'PIA 0017 ABORTED -- admin read policies missing (found %). Rolled back.', v_n;
  end if;

  raise notice 'PIA 0017: postflight passed.';
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ===========================================================================
-- VERIFY -- run separately after committing. Expect no '***' rows.
-- ===========================================================================
select c.relname as object,
       case when c.relrowsecurity then 'RLS ON' else '*** RLS OFF ***' end as rls,
       coalesce(string_agg(distinct g.privilege_type, ','), 'none') as authenticated_has
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join information_schema.role_table_grants g
         on g.table_schema='public' and g.table_name=c.relname and g.grantee='authenticated'
 where n.nspname='public' and c.relkind in ('r','v')
 group by c.relname, c.relrowsecurity
 order by c.relname;


-- ===========================================================================
-- ROLLBACK -- paste and run as one block to undo everything above.
-- ===========================================================================
-- begin;
--   drop policy if exists pia0017_tutoring_attempts_admin_read on public.tutoring_attempts;
--   drop policy if exists pia0017_tutoring_attempts_own_read   on public.tutoring_attempts;
--   drop policy if exists pia0017_math_attempt_log_admin_read  on public.math_attempt_log;
--   drop policy if exists pia0017_math_attempt_log_own_read    on public.math_attempt_log;
--   drop policy if exists pia0017_session_start_log_admin_read on public.session_start_log;
--   drop policy if exists pia0017_session_start_log_own_read   on public.session_start_log;
--   drop policy if exists pia0017_tutoring_attempts_server_write on public.tutoring_attempts;
--   drop policy if exists pia0017_math_attempt_log_server_write  on public.math_attempt_log;
--   drop policy if exists pia0017_session_start_log_server_write on public.session_start_log;
--   drop policy if exists pia0017_professors_server_write        on public.professors;
--   drop policy if exists pia0017_professors_admin_all         on public.professors;
--   drop policy if exists pia0017_professors_own_read          on public.professors;
--   drop policy if exists pia0017_sections_read                on public.sections;
--   drop policy if exists pia0017_sections_admin_insert        on public.sections;
--   alter table public.tutoring_attempts  disable row level security;
--   alter table public.math_attempt_log   disable row level security;
--   alter table public.session_start_log  disable row level security;
--   alter table public.professors         disable row level security;
--   alter table public.sections           disable row level security;
--   grant all on public.tutoring_attempts, public.math_attempt_log,
--                public.session_start_log, public.professors to authenticated;
-- commit;
-- notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260926_0018_bfpt_scoring_admin_only_results
-- ############################################################################

-- ============================================================================
-- PIA 0018 -- BFPT SCORING, AND ASSESSMENT RESULTS FOR ADMINS ONLY
-- ============================================================================
-- Source of truth: 20260722_Table BFPT.pdf -- "The Big Five Personality Test
-- (BFPT)", openpsychometrics.org printable, 50 items on a 1-5 scale, five
-- traits each scored 0-40 by the math strings on its scoring sheet (pp. 5-6).
--
-- WHAT CHANGES
--
--   1. SCORING FOLLOWS THE SHEET EXACTLY. The key now lives in ONE function,
--      public.pia_bfpt_score(), transcribed term for term from the sheet.
--      E, A, C and O are unchanged from 0002. N IS NOT: 0002 computed the
--      sheet's N string and then stored 40 minus it. The sheet has no such
--      step, so this migration drops it. Every stored submission is re-scored
--      from its saved answers, so old and new results share one key.
--
--      Read the N note before interpreting results. The sheet's N string
--      SUBTRACTS the eight stress items ("Get stressed out easily", "Worry
--      about things", ...) and ADDS "Am relaxed most of the time" and "Seldom
--      feel blue". Scored as written, a HIGHER N means CALMER answers -- the
--      reverse of the sheet's own prose definition of Neuroticism. The admin
--      drawer says so beside the score. To score N the other way, change the
--      N line of pia_bfpt_score() to `40 - (38 - ...)` and re-run PART 2;
--      the raw answers are kept, so nothing is lost either way.
--
--   2. RESULTS ARE READABLE BY ADMINS AND NOBODY ELSE. Until now the five
--      scores were also copied onto profiles -- a row every student can read
--      about themselves, and every teacher can read for their section. So a
--      student could see their own scores from the browser console, and the
--      login screen's select('*') already downloaded them. From here:
--        * scores exist ONLY in public.ocean_submissions, whose single RLS
--          policy admits an admin with a current session;
--        * profiles.ocean_e/a/c/n/o are cleared, and a CHECK constraint
--          stops any code path ever writing a score there again;
--        * submit_ocean_results() returns { next_stage } and nothing else,
--          so the student's own network tab shows no score either.
--      profiles.is_ocean_done stays: it is a completion flag, not a result,
--      and the stage chain depends on it.
--
--   3. NOTHING IS LOST. Retakes append a row instead of erasing one (the
--      admin drawer shows the latest), and any scores that existed only on
--      profiles -- from before 0002 kept raw answers -- are copied into
--      ocean_submissions before profiles is cleared.
--
-- WHAT THIS DOES NOT TOUCH
--   auth.*, the login path, the stage chain, sections, tutoring tables.
--
-- RUN IT ALL AT ONCE. One transaction: PART 6 proves the result against the
-- sheet's worked example, the access rules and an end-to-end submission, and
-- if any check fails NOTHING changes. Rollback notes are at the bottom.
-- ============================================================================

begin;

-- ===========================================================================
-- PART 1 -- THE SCORING KEY
-- One function, so the questionnaire, the re-score below and the self-test
-- all run exactly the same arithmetic. Each line is the sheet's math string
-- with (n) replaced by r[n], the answer to item n.
-- ===========================================================================
create or replace function public.pia_bfpt_score(r integer[])
returns table (ocean_e integer, ocean_a integer, ocean_c integer, ocean_n integer, ocean_o integer)
language sql
immutable
strict
set search_path = public
as $$
  select
    -- E = 20 + (1) - (6) + (11) - (16) + (21) - (26) + (31) - (36) + (41) - (46)
    20 + r[1]  - r[6]  + r[11] - r[16] + r[21] - r[26] + r[31] - r[36] + r[41] - r[46],
    -- A = 14 - (2) + (7) - (12) + (17) - (22) + (27) - (32) + (37) + (42) + (47)
    14 - r[2]  + r[7]  - r[12] + r[17] - r[22] + r[27] - r[32] + r[37] + r[42] + r[47],
    -- C = 14 + (3) - (8) + (13) - (18) + (23) - (28) + (33) - (38) + (43) + (48)
    14 + r[3]  - r[8]  + r[13] - r[18] + r[23] - r[28] + r[33] - r[38] + r[43] + r[48],
    -- N = 38 - (4) + (9) - (14) + (19) - (24) - (29) - (34) - (39) - (44) - (49)
    38 - r[4]  + r[9]  - r[14] + r[19] - r[24] - r[29] - r[34] - r[39] - r[44] - r[49],
    -- O = 8 + (5) - (10) + (15) - (20) + (25) - (30) + (35) + (40) + (45) + (50)
     8 + r[5]  - r[10] + r[15] - r[20] + r[25] - r[30] + r[35] + r[40] + r[45] + r[50]
$$;

-- Server-side only. The SECURITY DEFINER submit function calls it with the
-- owner's rights; no client role needs to.
revoke all on function public.pia_bfpt_score(integer[]) from public, anon, authenticated;


-- ===========================================================================
-- PART 2 -- ocean_submissions: provenance, and one key for every row
-- ===========================================================================
alter table public.ocean_submissions
  add column if not exists scoring_key text,
  add column if not exists source      text;

-- A row copied from profiles (PART 3) has scores but no raw answers, because
-- none were kept before 0002. Every other row must still carry all 50.
alter table public.ocean_submissions alter column responses drop not null;
alter table public.ocean_submissions drop constraint if exists ocean_submissions_50_items;
alter table public.ocean_submissions add constraint ocean_submissions_50_items
  check (responses is null or array_length(responses, 1) = 50);

do $$
declare
  v_rows int;
  v_n_changed int;
begin
  select count(*) into v_n_changed
    from public.ocean_submissions s
    cross join lateral public.pia_bfpt_score(s.responses::integer[]) k
   where s.responses is not null and s.ocean_n is distinct from k.ocean_n;

  update public.ocean_submissions s
     set (ocean_e, ocean_a, ocean_c, ocean_n, ocean_o) =
         (select k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o
            from public.pia_bfpt_score(s.responses::integer[]) k),
         scoring_key = 'bfpt-2026-07-22',
         source      = coalesce(s.source, 'questionnaire')
   where s.responses is not null;
  get diagnostics v_rows = row_count;

  raise notice 'PIA 0018: re-scored % submission(s) with the BFPT sheet; N changed on %.', v_rows, v_n_changed;
end;
$$;


-- ===========================================================================
-- PART 3 -- move every score off profiles
-- ===========================================================================
do $$
declare
  v_copied int;
  v_partial int;
  v_cleared int;
begin
  -- Scores that exist ONLY on profiles: full sets with no submission row.
  -- Written by the pre-0002 browser, which used the same key as 0002 --
  -- including its 40-minus step on N -- so the sheet's N is 40 minus the
  -- stored value, and E/A/C/O copy across unchanged.
  insert into public.ocean_submissions
         (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, scoring_key, source)
  select p.email, null, p.ocean_e, p.ocean_a, p.ocean_c, 40 - p.ocean_n, p.ocean_o,
         'bfpt-2026-07-22', 'legacy-profile'
    from public.profiles p
   where p.ocean_e is not null and p.ocean_a is not null and p.ocean_c is not null
     and p.ocean_n is not null and p.ocean_o is not null
     and not exists (select 1 from public.ocean_submissions s where lower(s.email) = lower(p.email));
  get diagnostics v_copied = row_count;

  -- An incomplete set cannot be a result; it is reported, then cleared.
  select count(*) into v_partial
    from public.profiles p
   where num_nonnulls(p.ocean_e, p.ocean_a, p.ocean_c, p.ocean_n, p.ocean_o) between 1 and 4;

  -- Runs as the migration owner, so the profile write guard (0001) lets it
  -- through: that guard only polices writes arriving as `authenticated`.
  update public.profiles
     set ocean_e = null, ocean_a = null, ocean_c = null, ocean_n = null, ocean_o = null
   where num_nonnulls(ocean_e, ocean_a, ocean_c, ocean_n, ocean_o) > 0;
  get diagnostics v_cleared = row_count;

  raise notice 'PIA 0018: copied % legacy result(s) into ocean_submissions; cleared scores from % profile(s); % incomplete set(s) discarded.',
    v_copied, v_cleared, v_partial;
end;
$$;

-- Every row now has a key and a source; make that permanent.
alter table public.ocean_submissions alter column scoring_key set not null;
alter table public.ocean_submissions alter column source      set not null;
alter table public.ocean_submissions drop constraint if exists ocean_submissions_answers_or_legacy;
alter table public.ocean_submissions add constraint ocean_submissions_answers_or_legacy
  check (responses is not null or source = 'legacy-profile');

-- The columns stay so that old scripts selecting them keep working -- but no
-- code path can ever put a score back where students and teachers can read it.
alter table public.profiles drop constraint if exists profiles_ocean_scores_admin_only;
alter table public.profiles add constraint profiles_ocean_scores_admin_only
  check (ocean_e is null and ocean_a is null and ocean_c is null and ocean_n is null and ocean_o is null);


-- ===========================================================================
-- PART 4 -- who may read the results: admins, with a current session
-- ===========================================================================
alter table public.ocean_submissions enable row level security;

-- Exactly one policy may exist. Anything else on this table -- a console-made
-- "own read", say -- would be OR-ed with it and reopen the results.
do $$
declare
  p record;
begin
  for p in
    select policyname from pg_policies
     where schemaname = 'public' and tablename = 'ocean_submissions'
       and policyname <> 'ocean_submissions_admin_read'
  loop
    execute format('drop policy %I on public.ocean_submissions', p.policyname);
    raise notice 'PIA 0018: dropped extra policy % on ocean_submissions.', p.policyname;
  end loop;
end;
$$;

drop policy if exists ocean_submissions_admin_read on public.ocean_submissions;
create policy ocean_submissions_admin_read on public.ocean_submissions
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());

-- Reads only; every write goes through submit_ocean_results().
revoke all on public.ocean_submissions from anon, authenticated;
grant select on public.ocean_submissions to authenticated;

-- A view over this table that runs with its OWNER's rights would bypass the
-- policy above for anyone granted the view. Make every such view check the
-- caller instead, so the policy applies through it.
do $$
declare
  v record;
begin
  for v in
    select distinct c.oid::regclass as view_name
      from pg_depend d
      join pg_rewrite w on w.oid = d.objid
      join pg_class   c on c.oid = w.ev_class
     where d.classid  = 'pg_rewrite'::regclass
       and d.refobjid = 'public.ocean_submissions'::regclass
       and c.relkind = 'v'
       and not coalesce('security_invoker=true' = any(c.reloptions)
                     or 'security_invoker=on'   = any(c.reloptions), false)
  loop
    execute format('alter view %s set (security_invoker = true)', v.view_name);
    raise notice 'PIA 0018: view % now checks the caller''s rights.', v.view_name;
  end loop;
end;
$$;


-- ===========================================================================
-- PART 5 -- submit_ocean_results(p_responses)
--   p_responses: the 50 answers (1..5), in the order of window.PIA_BFPT.items
--                (assets/js/bfpt-items.js).
--   Returns { next_stage } ONLY. No score, trait or persona leaves the server.
--
-- Messages are neutral on purpose: the questionnaire page shows a failure
-- message to the student verbatim, so none of them names the instrument.
-- ===========================================================================
create or replace function public.submit_ocean_results(p_responses integer[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  r         integer[];
  k         record;
  v_needs_character boolean;
  v_next_stage text;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- Once only. The admin retake action sets is_ocean_done back to false.
  if coalesce(v_profile.is_ocean_done, false) then
    raise exception 'PIA: this questionnaire has already been submitted. Ask an admin for a retake.'
      using errcode = '42501';
  end if;

  if p_responses is null or array_length(p_responses, 1) is distinct from 50 then
    raise exception 'PIA: exactly 50 responses are required (received: %).',
      coalesce(array_length(p_responses, 1), 0) using errcode = '22023';
  end if;

  -- Re-based to 1..50 in order, so r[n] is item n even if a caller crafts an
  -- array with a different lower bound.
  r := array(select x from unnest(p_responses) with ordinality as t(x, i) order by i);

  if exists (select 1 from unnest(r) v where v is null or v < 1 or v > 5) then
    raise exception 'PIA: every response must be between 1 and 5.' using errcode = '22023';
  end if;

  select * into k from public.pia_bfpt_score(r);

  -- Next stage -- decided here, never in the browser. Unchanged from 0002.
  v_needs_character :=
    lower(trim(coalesce(v_profile.group_type, ''))) in ('non-assigned', 'non_assigned')
    and v_profile.selected_character is null;

  if v_needs_character then
    v_next_stage := case when public.pia_stage_open('stage_char')
                         then 'Character Selection' else 'Waiting Room' end;
  else
    v_next_stage := case when public.pia_stage_open('stage_dash')
                         then 'Tutoring Dashboard' else 'Waiting Room' end;
  end if;

  insert into public.ocean_submissions
         (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, scoring_key, source)
  values (v_email, r::smallint[], k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o,
          'bfpt-2026-07-22', 'questionnaire');

  -- The completion flag and the stage. Deliberately no score.
  update public.profiles set
    is_ocean_done    = true,
    current_stage    = v_next_stage,
    stage_started_at = now()
  where email = v_email;

  return jsonb_build_object('next_stage', v_next_stage);
end;
$$;

revoke all on function public.submit_ocean_results(integer[]) from public, anon;
grant execute on function public.submit_ocean_results(integer[]) to authenticated;


-- ===========================================================================
-- PART 6 -- SELF-VERIFICATION. Runs before COMMIT. Any failure raises, and
-- the whole migration rolls back: a mistake here cannot reach live data.
-- ===========================================================================
do $$
declare
  -- The sheet's worked example ("BFPT Completed Example"): all 50 answers,
  -- read off its five math strings, which between them use every item once.
  v_example constant integer[] := array[
    1,1,5,4,5,  4,4,1,2,1,  3,1,5,5,2,  5,5,1,4,2,  4,3,4,2,4,
    3,5,2,4,3,  2,3,5,3,5,  5,3,1,2,4,  1,5,5,3,5,  4,4,5,2,5];
  -- The items the sheet SUBTRACTS. Answering each of these 5 and every other
  -- item 1 must drive all five traits to 0; the mirror image, to 40.
  v_minus constant integer[] := array[
    6,16,26,36,46,  2,12,22,32,  8,18,28,38,  4,14,24,29,34,39,44,49,  10,20,30];
  v_floor   integer[];
  v_ceil    integer[];
  k         record;
  v_row     record;
  v_result  jsonb;
  v_keys    text[];
  n         int;
  v_total   int;
  v_admin   text;
  v_student text;
  v_teacher text;
  v_reader  text;
begin
  -- (1) The sheet's own worked example: E 10, A 32, C 38, N 19, O 32.
  select * into k from public.pia_bfpt_score(v_example);
  if (k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o) is distinct from (10, 32, 38, 19, 32) then
    raise exception 'PIA ABORT: the worked example scored E% A% C% N% O%; the sheet says E10 A32 C38 N19 O32.',
      k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o using errcode = 'P0001';
  end if;

  -- (2) "Each personality trait will have a score between zero and forty."
  v_floor := array(select case when g.i = any(v_minus) then 5 else 1 end
                     from generate_series(1, 50) as g(i) order by g.i);
  v_ceil  := array(select case when g.i = any(v_minus) then 1 else 5 end
                     from generate_series(1, 50) as g(i) order by g.i);

  select * into k from public.pia_bfpt_score(v_floor);
  if (k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o) is distinct from (0, 0, 0, 0, 0) then
    raise exception 'PIA ABORT: the lowest possible answers scored E% A% C% N% O%, expected all 0.',
      k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o using errcode = 'P0001';
  end if;

  select * into k from public.pia_bfpt_score(v_ceil);
  if (k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o) is distinct from (40, 40, 40, 40, 40) then
    raise exception 'PIA ABORT: the highest possible answers scored E% A% C% N% O%, expected all 40.',
      k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o using errcode = 'P0001';
  end if;

  -- (3) Every stored answer set carries the sheet's scores, and one key.
  select count(*) into n
    from public.ocean_submissions s
    cross join lateral public.pia_bfpt_score(s.responses::integer[]) k2
   where s.responses is not null
     and (s.ocean_e, s.ocean_a, s.ocean_c, s.ocean_n, s.ocean_o)
         is distinct from (k2.ocean_e, k2.ocean_a, k2.ocean_c, k2.ocean_n, k2.ocean_o);
  if n <> 0 then
    raise exception 'PIA ABORT: % submission(s) do not match the BFPT key after re-scoring.', n
      using errcode = 'P0001';
  end if;

  select count(*) into n from public.ocean_submissions where scoring_key <> 'bfpt-2026-07-22';
  if n <> 0 then
    raise exception 'PIA ABORT: % submission(s) carry a scoring key other than bfpt-2026-07-22.', n
      using errcode = 'P0001';
  end if;

  -- (4) No score left anywhere a student or teacher can read.
  select count(*) into n from public.profiles
   where num_nonnulls(ocean_e, ocean_a, ocean_c, ocean_n, ocean_o) > 0;
  if n <> 0 then
    raise exception 'PIA ABORT: % profile(s) still carry a score.', n using errcode = 'P0001';
  end if;

  -- (5) Access, as each kind of user actually sees it.
  select count(*) into v_total from public.ocean_submissions;
  select email into v_admin   from public.profiles where lower(trim(role)) = 'admin'   order by email limit 1;
  select email into v_teacher from public.profiles where lower(trim(role)) = 'teacher' order by email limit 1;
  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;

  if v_admin is not null then
    perform set_config('request.jwt.claims',
      json_build_object('email', v_admin, 'role', 'authenticated',
                        'iat', extract(epoch from now())::bigint)::text, true);
    execute 'set local role authenticated';
    select count(*) into n from public.ocean_submissions;
    execute 'reset role';
    if n <> v_total then
      raise exception 'PIA ABORT: the admin (%) sees % of % results -- the dashboard would be blind.',
        v_admin, n, v_total using errcode = 'P0001';
    end if;
  end if;

  foreach v_reader in array array_remove(array[v_student, v_teacher], null) loop
    perform set_config('request.jwt.claims',
      json_build_object('email', v_reader, 'role', 'authenticated',
                        'iat', extract(epoch from now())::bigint)::text, true);
    execute 'set local role authenticated';
    select count(*) into n from public.ocean_submissions;
    execute 'reset role';
    if n <> 0 then
      raise exception 'PIA ABORT: % (not an admin) can read % result row(s).', v_reader, n
        using errcode = 'P0001';
    end if;
  end loop;

  -- (6) End to end, as a real student submission -- inside a subtransaction
  -- that is ALWAYS rolled back, so the test leaves no trace. Only the
  -- sentinel code PX999 is caught; a failed check propagates and aborts.
  if v_student is not null then
    begin
      update public.profiles set is_ocean_done = false where email = v_student;

      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from now())::bigint)::text, true);
      v_result := public.submit_ocean_results(v_example);

      select array_agg(t.key order by t.key) into v_keys from jsonb_object_keys(v_result) as t(key);
      if v_keys is distinct from array['next_stage'] then
        raise exception 'PIA ABORT: submit_ocean_results returned %; it may return next_stage only.', v_result
          using errcode = 'P0001';
      end if;

      select * into v_row from public.ocean_submissions
       where email = v_student order by submitted_at desc, id desc limit 1;
      if (v_row.ocean_e, v_row.ocean_a, v_row.ocean_c, v_row.ocean_n, v_row.ocean_o)
           is distinct from (10, 32, 38, 19, 32)
         or v_row.scoring_key is distinct from 'bfpt-2026-07-22'
         or array_length(v_row.responses, 1) is distinct from 50 then
        raise exception 'PIA ABORT: an end-to-end submission stored E% A% C% N% O% (key %).',
          v_row.ocean_e, v_row.ocean_a, v_row.ocean_c, v_row.ocean_n, v_row.ocean_o, v_row.scoring_key
          using errcode = 'P0001';
      end if;

      if exists (select 1 from public.profiles
                  where email = v_student
                    and (num_nonnulls(ocean_e, ocean_a, ocean_c, ocean_n, ocean_o) > 0
                         or is_ocean_done is not true)) then
        raise exception 'PIA ABORT: the submission left a score on profiles, or did not mark it done.'
          using errcode = 'P0001';
      end if;

      raise exception 'self-test complete' using errcode = 'PX999';
    exception
      when sqlstate 'PX999' then null;   -- the test's own writes are undone here
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);

  raise notice 'PIA 0018 OK: worked example E10 A32 C38 N19 O32; range 0-40; % result row(s) re-verified; admin reads all, students and teachers read none; submission returns next_stage only.',
    v_total;
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Final report -- what the SQL editor shows after a successful run.
select 'ocean_submissions' as object, count(*)::text as detail from public.ocean_submissions
union all
select 'results with raw answers', count(*)::text from public.ocean_submissions where responses is not null
union all
select 'legacy results (no answers kept)', count(*)::text from public.ocean_submissions where source = 'legacy-profile'
union all
select 'profiles still holding a score', count(*)::text from public.profiles
 where num_nonnulls(ocean_e, ocean_a, ocean_c, ocean_n, ocean_o) > 0
union all
select 'policy: ' || policyname, coalesce(qual, '') from pg_policies
 where schemaname = 'public' and tablename = 'ocean_submissions';


-- ============================================================================
-- ROLLBACK NOTES
-- ----------------------------------------------------------------------------
-- The re-score is reversible from the raw answers at any time: edit the N line
-- of pia_bfpt_score() and re-run PART 2. To restore 0002's N convention, that
-- line becomes:
--     40 - (38 - r[4] + r[9] - r[14] + r[19] - r[24] - r[29] - r[34] - r[39] - r[44] - r[49]),
--
-- To put scores back on profiles (NOT recommended -- it reopens them to the
-- student themselves and to their teacher):
--   alter table public.profiles drop constraint profiles_ocean_scores_admin_only;
--   update public.profiles p set (ocean_e, ocean_a, ocean_c, ocean_n, ocean_o) =
--     (select s.ocean_e, s.ocean_a, s.ocean_c, s.ocean_n, s.ocean_o
--        from public.ocean_submissions s where lower(s.email) = lower(p.email)
--       order by s.submitted_at desc, s.id desc limit 1);
-- and restore submit_ocean_results() from 0002.
-- ============================================================================


-- ############################################################################
-- MIGRATION 20260927_0019_password_recovery_override
-- ############################################################################

-- ============================================================================
-- PIA 0019 -- HYBRID PASSWORD RECOVERY: ADMIN OVERRIDE + FORCED CHANGE
-- ============================================================================
-- Three ways back into an account, one of them new:
--
--   1. SELF-SERVICE (no change here). resetPasswordForEmail() sends a link
--      and a code; the student picks the new password themselves.
--
--   2. ADMIN OVERRIDE (new). For a student who cannot receive that email, an
--      admin sets a temporary password through the Edge Function
--      supabase/functions/admin-set-temp-password, which calls the Auth Admin
--      API (updateUserById) with the service-role key -- a key that never
--      leaves the server. The function then sets must_change_password.
--
--   3. FORCED CHANGE (new). A flagged student is routed to a Set New Password
--      screen at sign-in and blocked from every other page until they choose
--      a password only they know. The admin knew the temporary one; nobody
--      but the student knows the next.
--
-- WHAT THIS MIGRATION ADDS
--   * profiles.must_change_password, plus who set the temporary password and
--     when (temp_password_set_by / temp_password_set_at) for accountability.
--   * public.pia_auth_user_id(email): the auth user id behind an email, for
--     the Edge Function's updateUserById call. service_role only.
--   * A trigger on auth.users that clears must_change_password WHEN THE
--     PASSWORD ACTUALLY CHANGES. That is the only way the flag comes down:
--     students cannot write it (the 0001 write guard does not whitelist it),
--     so a student cannot skip the screen by faking the profile update --
--     the flag is cleared by the change itself, server-side.
--
--   Order inside the Edge Function matters and is deliberate: it sets the
--   password FIRST (the trigger fires and clears any old flag), THEN raises
--   the flag. The next password change -- the student's own -- clears it.
--
-- RUN IT ALL AT ONCE. One transaction; PART 4 proves the trigger, the lookup
-- and the write guard before COMMIT, and any failure changes nothing.
-- ============================================================================

begin;

-- ===========================================================================
-- PART 1 -- the flag, and its audit trail
-- ===========================================================================
alter table public.profiles
  add column if not exists must_change_password boolean not null default false,
  add column if not exists temp_password_set_at timestamptz,
  add column if not exists temp_password_set_by text;

comment on column public.profiles.must_change_password is
  'True after an admin sets a temporary password. Cleared only by the auth.users trigger when the password changes.';


-- ===========================================================================
-- PART 2 -- email -> auth user id, for the Edge Function only
-- ===========================================================================
create or replace function public.pia_auth_user_id(p_email text)
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.id
    from auth.users u
   where lower(u.email) = lower(trim(p_email))
   limit 1;
$$;

-- Never callable from a browser: it would let anyone map emails to account
-- ids. The Edge Function calls it with the service-role key.
revoke all on function public.pia_auth_user_id(text) from public, anon, authenticated;
grant execute on function public.pia_auth_user_id(text) to service_role;


-- ===========================================================================
-- PART 3 -- the flag comes down only when the password changes
-- ===========================================================================
create or replace function public.pia_on_password_changed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Runs as the function owner, so the 0001 write guard lets it through:
  -- that guard only polices writes arriving as `authenticated`.
  update public.profiles
     set must_change_password = false
   where lower(email) = lower(new.email)
     and must_change_password;
  return null;   -- AFTER trigger: the return value is ignored
end;
$$;

revoke all on function public.pia_on_password_changed() from public, anon, authenticated;

drop trigger if exists pia_password_changed on auth.users;
create trigger pia_password_changed
  after update of encrypted_password on auth.users
  for each row
  when (old.encrypted_password is distinct from new.encrypted_password)
  execute function public.pia_on_password_changed();


-- ===========================================================================
-- PART 4 -- SELF-VERIFICATION. Any failed check raises and rolls back all of
-- the above. The trigger test runs in a subtransaction that is ALWAYS rolled
-- back, so no real password or flag is left changed.
-- ===========================================================================
do $$
declare
  v_student text;
  v_uid     uuid;
  v_flag    boolean;
  v_blocked boolean;
  v_rows    int;
begin
  -- (1) The columns exist with the right default.
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles'
                    and column_name = 'must_change_password'
                    and column_default = 'false' and is_nullable = 'NO') then
    raise exception 'PIA ABORT: profiles.must_change_password is missing or mis-defined.' using errcode = 'P0001';
  end if;

  -- (2) The lookup is server-only.
  if has_function_privilege('authenticated', 'public.pia_auth_user_id(text)', 'execute')
     or has_function_privilege('anon', 'public.pia_auth_user_id(text)', 'execute') then
    raise exception 'PIA ABORT: pia_auth_user_id() is callable from the browser.' using errcode = 'P0001';
  end if;
  if not has_function_privilege('service_role', 'public.pia_auth_user_id(text)', 'execute') then
    raise exception 'PIA ABORT: the Edge Function (service_role) cannot call pia_auth_user_id().' using errcode = 'P0001';
  end if;

  -- A real student with a sign-in account, for the live checks below.
  select p.email, u.id into v_student, v_uid
    from public.profiles p
    join auth.users u on lower(u.email) = lower(p.email)
   where lower(trim(coalesce(p.role, 'student'))) = 'student'
   order by p.email
   limit 1;

  if v_student is null then
    raise notice 'PIA 0019: no student with a sign-in account yet -- live trigger checks skipped.';
  else
    -- (3) The lookup returns that account.
    if public.pia_auth_user_id(upper(v_student)) is distinct from v_uid then
      raise exception 'PIA ABORT: pia_auth_user_id() did not find the account for %.', v_student using errcode = 'P0001';
    end if;

    -- (4) The trigger, end to end, always rolled back.
    begin
      update public.profiles set must_change_password = true where email = v_student;

      -- Touching another column must NOT clear the flag.
      update auth.users set raw_user_meta_data = raw_user_meta_data where id = v_uid;
      select must_change_password into v_flag from public.profiles where email = v_student;
      if v_flag is not true then
        raise exception 'PIA ABORT: the flag cleared without a password change.' using errcode = 'P0001';
      end if;

      -- A password change MUST clear it.
      update auth.users set encrypted_password = encrypted_password || '#selftest' where id = v_uid;
      select must_change_password into v_flag from public.profiles where email = v_student;
      if v_flag is not false then
        raise exception 'PIA ABORT: a password change did not clear must_change_password.' using errcode = 'P0001';
      end if;

      raise exception 'trigger self-test complete' using errcode = 'PX999';
    exception
      when sqlstate 'PX999' then null;                 -- undone, as intended
      when insufficient_privilege then
        raise notice 'PIA 0019: this role cannot write auth.users, so the trigger was not exercised here. It is installed; verify with one real temporary-password reset.';
    end;

    -- (5) A flagged student cannot clear their own flag and skip the screen.
    -- The flag is raised first: clearing an already-false flag is a no-op the
    -- guard rightly allows, and would prove nothing. Rolled back either way.
    -- (PL/pgSQL variables are not transactional, so v_blocked survives it.)
    v_blocked := false;
    begin
      update public.profiles set must_change_password = true where email = v_student;
      begin
        perform set_config('request.jwt.claims',
          json_build_object('email', v_student, 'role', 'authenticated',
                            'iat', extract(epoch from now())::bigint)::text, true);
        execute 'set local role authenticated';
        execute format('update public.profiles set must_change_password = false where email = %L', v_student);
        get diagnostics v_rows = row_count;
        execute 'reset role';
        v_blocked := (v_rows = 0);          -- filtered out by RLS also counts as blocked
      exception when others then
        begin execute 'reset role'; exception when others then null; end;
        v_blocked := true;                  -- the write guard raised: blocked
      end;
      raise exception 'guard self-test complete' using errcode = 'PX999';
    exception
      when sqlstate 'PX999' then null;
    end;
    perform set_config('request.jwt.claims', '', true);

    if not v_blocked then
      raise exception 'PIA ABORT: a student can write must_change_password directly.' using errcode = 'P0001';
    end if;
  end if;

  raise notice 'PIA 0019 OK: flag + audit columns in place; lookup is service_role only; the flag clears on a password change and on nothing else; students cannot clear it themselves.';
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Final report.
select 'profiles flagged to change password' as check_name,
       count(*)::text as result
  from public.profiles where must_change_password
union all
select 'trigger on auth.users', string_agg(tgname, ', ')
  from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'pia_password_changed'
union all
select 'pia_auth_user_id callable by browser roles',
       (has_function_privilege('authenticated', 'public.pia_auth_user_id(text)', 'execute'))::text;


-- ============================================================================
-- ROLLBACK
--   drop trigger if exists pia_password_changed on auth.users;
--   drop function if exists public.pia_on_password_changed();
--   drop function if exists public.pia_auth_user_id(text);
--   alter table public.profiles drop column if exists must_change_password,
--     drop column if exists temp_password_set_at, drop column if exists temp_password_set_by;
-- Drop the flag column only AFTER reverting the frontend: it degrades safely
-- when the column is missing, but the admin override would stop working.
-- ============================================================================


-- ############################################################################
-- MIGRATION 20260928_0020_document_auth_device_functions
-- ############################################################################

-- ============================================================================
-- PIA 0020 -- DOCUMENT THE LIVE AUTH / DEVICE FUNCTIONS
-- ============================================================================
-- Four functions the app depends on were created directly in the Supabase
-- dashboard and never lived in this repo:
--
--   jwt_is_current()                     the revocation check inside the
--                                        profiles RLS policies (0009)
--   release_device(p_device_id)          frees a device slot on sign-out
--                                        (executeForceLogout, function.js)
--   admin_revoke_sessions__inner(email)  "Sign out everywhere", behind the
--                                        admin guard 0011 put in front of it
--   admin_delete_user__inner(email)      "Delete participant", same guard
--
-- The bodies are copied VERBATIM from production (pg_get_functiondef,
-- 2026-09-28), comments included. Against production this migration changes
-- no behaviour: CREATE OR REPLACE with an identical body keeps each
-- function's owner and privileges, columns are added only if missing, the
-- guarded wrappers are created only if missing, and the two explicit grants
-- to `authenticated` restate access that role already has. Against a fresh
-- database it rebuilds what production has.
--
-- WHAT THEY ACTUALLY DO -- read before relying on them:
--
--   * admin_delete_user__inner deletes the profiles row and the auth.users
--     row, and NOTHING else. The response tables (ocean_submissions,
--     hint_consumptions, problem_serves, ...) key their rows by email with no
--     cascading foreign key, so a deleted participant's answers stay in the
--     database, no longer linked to any account. The admin console's delete
--     dialog currently says every response is removed; it is not.
--
--   * admin_revoke_sessions__inner stamps profiles.sessions_revoked_at and
--     empties active_devices. jwt_is_current() then rejects every access
--     token issued BEFORE that stamp. It does not touch auth.sessions, so the
--     student's refresh token still works: the next automatic refresh issues
--     a token that passes. The browser checks in function.js
--     (requireStudentSession, validateDeviceOnLoad) are what sign the student
--     out, on their next page load.
--
--   * release_device only edits the CALLER's own list (email from the JWT),
--     so it cannot free another account's slot -- the concern 0017 raised
--     without having seen the body.
--
-- The postflight at the end aborts (and rolls everything back) if any of the
-- six functions is missing, if an __inner function is callable from the
-- browser, or if a wrapper has lost its admin guard.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Columns these functions read and write. Production already has them (they
-- were added outside the migrations too); IF NOT EXISTS makes these no-ops.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists max_devices         int         default 1;
alter table public.profiles add column if not exists active_devices      text[]      default '{}';
alter table public.profiles add column if not exists sessions_revoked_at timestamptz;


-- ---------------------------------------------------------------------------
-- 1. jwt_is_current -- verbatim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jwt_is_current()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_revoked timestamptz; v_iat bigint;
begin
    v_iat := nullif(auth.jwt() ->> 'iat', '')::bigint;
    if v_iat is null then return false; end if;
    select sessions_revoked_at into v_revoked from public.profiles where email = auth.jwt() ->> 'email';
    return v_revoked is null or to_timestamp(v_iat) >= v_revoked;
end;
$function$;


-- ---------------------------------------------------------------------------
-- 2. release_device -- verbatim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_device(p_device_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_email text := auth.jwt() ->> 'email';
begin
    if v_email is null then return; end if;
    update public.profiles set active_devices = coalesce(array_remove(active_devices, p_device_id), '{}') where email = v_email;
end;
$function$;


-- ---------------------------------------------------------------------------
-- 3. admin_revoke_sessions__inner -- verbatim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_revoke_sessions__inner(p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
    if not exists (select 1 from public.profiles where email = auth.jwt() ->> 'email' and lower(trim(role)) = 'admin') then
        raise exception 'Only an admin may revoke sessions.';
    end if;
    update public.profiles set sessions_revoked_at = now(), active_devices = '{}' where email = p_email;
end;
$function$;


-- ---------------------------------------------------------------------------
-- 4. admin_delete_user__inner -- verbatim
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_delete_user__inner(target_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
BEGIN
  -- 1. Burahin muna sa profiles para maiwasan ang foreign key constraint block
  DELETE FROM public.profiles WHERE email = target_email;

  -- 2. Saka burahin sa mismong auth.users
  DELETE FROM auth.users WHERE email = target_email;
END;
$function$;


-- ---------------------------------------------------------------------------
-- Privileges. Production already has exactly these (0011 locked the __inner
-- functions); on a fresh database CREATE FUNCTION would otherwise leave them
-- executable by PUBLIC -- i.e. any signed-in student could delete any account.
-- release_device and jwt_is_current only need to be callable by signed-in
-- users; their PUBLIC grant is left as it is so production stays untouched.
-- ---------------------------------------------------------------------------
revoke all on function public.admin_delete_user__inner(text)     from public, anon, authenticated;
revoke all on function public.admin_revoke_sessions__inner(text) from public, anon, authenticated;
grant execute on function public.release_device(text) to authenticated;
grant execute on function public.jwt_is_current()     to authenticated;


-- ---------------------------------------------------------------------------
-- The guarded wrappers the browser calls. 0011 generated them and 0013
-- translated their message; this recreates them in that final form ONLY if
-- they are missing (a fresh database), and never touches production's.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.admin_delete_user(text)') is null then
    execute $w$
      create function public.admin_delete_user(target_email text)
      returns void
      language plpgsql
      security definer
      set search_path = public, extensions
      as $body$
      begin
        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_delete_user().'
            using errcode = '42501';
        end if;
        perform public.admin_delete_user__inner(target_email);
      end;
      $body$;
    $w$;
    revoke all on function public.admin_delete_user(text) from public, anon;
    grant execute on function public.admin_delete_user(text) to authenticated;
    raise notice 'PIA 0020: created missing wrapper admin_delete_user(text).';
  end if;

  if to_regprocedure('public.admin_revoke_sessions(text)') is null then
    execute $w$
      create function public.admin_revoke_sessions(p_email text)
      returns void
      language plpgsql
      security definer
      set search_path = public, extensions
      as $body$
      begin
        if public.pia_caller_role() is distinct from 'admin' then
          raise exception 'PIA: only an admin may call admin_revoke_sessions().'
            using errcode = '42501';
        end if;
        perform public.admin_revoke_sessions__inner(p_email);
      end;
      $body$;
    $w$;
    revoke all on function public.admin_revoke_sessions(text) from public, anon;
    grant execute on function public.admin_revoke_sessions(text) to authenticated;
    raise notice 'PIA 0020: created missing wrapper admin_revoke_sessions(text).';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- abort and roll back rather than leave a hole.
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn       text;
  v_problems text := '';
begin
  foreach v_fn in array array[
    'public.jwt_is_current()',
    'public.release_device(text)',
    'public.admin_revoke_sessions__inner(text)',
    'public.admin_delete_user__inner(text)',
    'public.admin_revoke_sessions(text)',
    'public.admin_delete_user(text)'
  ] loop
    if to_regprocedure(v_fn) is null then
      v_problems := v_problems || v_fn || ' is missing; ';
    end if;
  end loop;

  if v_problems = '' then
    if has_function_privilege('authenticated', 'public.admin_delete_user__inner(text)', 'EXECUTE')
       or has_function_privilege('anon', 'public.admin_delete_user__inner(text)', 'EXECUTE') then
      v_problems := v_problems || 'admin_delete_user__inner is callable from the browser; ';
    end if;
    if has_function_privilege('authenticated', 'public.admin_revoke_sessions__inner(text)', 'EXECUTE')
       or has_function_privilege('anon', 'public.admin_revoke_sessions__inner(text)', 'EXECUTE') then
      v_problems := v_problems || 'admin_revoke_sessions__inner is callable from the browser; ';
    end if;
    if pg_get_functiondef('public.admin_delete_user(text)'::regprocedure) !~ 'pia_caller_role' then
      v_problems := v_problems || 'admin_delete_user has no admin guard; ';
    end if;
    if pg_get_functiondef('public.admin_revoke_sessions(text)'::regprocedure) !~ 'pia_caller_role' then
      v_problems := v_problems || 'admin_revoke_sessions has no admin guard; ';
    end if;
    if not has_function_privilege('authenticated', 'public.release_device(text)', 'EXECUTE') then
      v_problems := v_problems || 'signed-in users cannot call release_device; ';
    end if;
    if not has_function_privilege('authenticated', 'public.jwt_is_current()', 'EXECUTE') then
      v_problems := v_problems || 'signed-in users cannot call jwt_is_current (the profiles policies would fail); ';
    end if;
  end if;

  if v_problems <> '' then
    raise exception 'PIA 0020 ABORT: %', v_problems using errcode = 'P0001';
  end if;

  raise notice 'PIA 0020 OK: all six functions present, __inner locked, wrappers guarded.';
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report -- what the SQL editor shows after running.
select p.oid::regprocedure::text as function,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 'callable by signed-in users' else 'locked' end as browser_access,
       case when pg_get_functiondef(p.oid) ~ 'pia_caller_role' then 'admin guard'
            when p.proname like '%\_\_inner' then 'inner (behind wrapper)'
            else '-' end as guard
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('jwt_is_current', 'release_device',
                     'admin_revoke_sessions', 'admin_revoke_sessions__inner',
                     'admin_delete_user', 'admin_delete_user__inner')
 order by 1;


-- ############################################################################
-- MIGRATION 20260928_0021_hard_delete_and_session_revocation
-- ############################################################################

-- ============================================================================
-- PIA 0021 -- TRUE HARD DELETE, INSTANT SESSION REVOCATION, NO DEVICE BYPASS
-- ============================================================================
-- Three fixes to the functions 0020 documented. Each closes a gap between
-- what the admin console promises and what the database did.
--
-- 1. DELETE PARTICIPANT REMOVES EVERYTHING
--    admin_delete_user__inner removed only the profiles row and the auth.users
--    row. Every answer the participant gave stayed behind, keyed by an email
--    that no longer belonged to anyone -- while the console's dialog promised
--    "every collected response for this participant is removed". For a
--    participant who withdraws consent, the data must go too. It now deletes,
--    children before parents:
--      hint_consumptions, problem_serves, math_attempt_log, tutoring_attempts,
--      ocean_submissions,
--      then ANY other public table with a student_email, user_email or
--      participant_email column (and session_start_log by its email) -- this
--      covers session_start_log and the tutoring-session table
--      start_game_session() writes, both created outside this repo, and any
--      such table added later,
--      then the profile, then the sign-in account.
--    Matching is case-insensitive: GoTrue stores auth emails lower-cased, and
--    the telemetry rows carry the JWT's email, so a profile typed as
--    "Juan@School.edu" used to leave both its auth user and its answers.
--
-- 2. "SIGN OUT EVERYWHERE" ENDS THE SESSIONS THEMSELVES
--    admin_revoke_sessions__inner stamped sessions_revoked_at, which makes
--    jwt_is_current() reject older access tokens -- but the refresh tokens
--    lived on, and the next automatic refresh minted a token that passed. It
--    now also deletes the account's auth.sessions (their refresh tokens go
--    with them) and any legacy refresh token not tied to a session. The
--    revoked browser can no longer renew; its current access token is
--    refused by every RLS policy at once and simply runs out.
--
-- 3. STUDENTS CAN NO LONGER EDIT THEIR OWN DEVICE LIST
--    0001's write guard let a student UPDATE their own active_devices, so the
--    browser console could empty the list and walk past the device limit. No
--    page ever needed that: every device change goes through claim_device,
--    release_device or admin_revoke_device, which are SECURITY DEFINER and
--    pass the guard's trusted path. 'active_devices' is removed from the
--    guard's student whitelist. The guard is edited IN PLACE from its live
--    definition (the way 0013 translated it), so nothing else in it changes.
--
-- SAFE TO RE-RUN: CREATE OR REPLACE keeps each function's owner and
-- privileges, and step 3 skips itself once the column is gone.
--
-- The preflight aborts before changing anything if a table or column this
-- relies on is missing, or if the functions' owner lacks DELETE on the auth
-- tables. The postflight proves the device bypass is closed by attempting it
-- as a real student under RLS, and rolls everything back if it succeeds.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner    text;
  v_problems text := '';
  r          record;
begin
  -- The response tables and the column each is keyed by.
  for r in
    select * from (values
      ('hint_consumptions', 'student_email'),
      ('problem_serves',    'student_email'),
      ('math_attempt_log',  'student_email'),
      ('tutoring_attempts', 'student_email'),
      ('ocean_submissions', 'email')
    ) as t(tbl, col)
  loop
    if not exists (
      select 1
        from pg_attribute a
        join pg_class c     on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = r.tbl
         and a.attname = r.col and not a.attisdropped
    ) then
      v_problems := v_problems || format('public.%s.%s is missing; ', r.tbl, r.col);
    end if;
  end loop;

  if to_regclass('auth.sessions') is null then
    v_problems := v_problems || 'auth.sessions is missing; ';
  end if;
  if to_regclass('auth.refresh_tokens') is null then
    v_problems := v_problems || 'auth.refresh_tokens is missing; ';
  end if;

  -- CREATE OR REPLACE keeps the current owner, so THAT role must be able to
  -- delete from the auth tables.
  select pg_get_userbyid(p.proowner) into v_owner
    from pg_proc p where p.oid = 'public.admin_revoke_sessions__inner(text)'::regprocedure;

  if v_problems = '' then
    if not has_table_privilege(v_owner, 'auth.sessions', 'DELETE') then
      v_problems := v_problems || format('%s cannot DELETE from auth.sessions; ', v_owner);
    end if;
    if not has_table_privilege(v_owner, 'auth.refresh_tokens', 'DELETE') then
      v_problems := v_problems || format('%s cannot DELETE from auth.refresh_tokens; ', v_owner);
    end if;
    if not has_table_privilege(v_owner, 'auth.users', 'DELETE') then
      v_problems := v_problems || format('%s cannot DELETE from auth.users; ', v_owner);
    end if;
  end if;

  if v_problems <> '' then
    raise exception 'PIA 0021 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Hard delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_delete_user__inner(target_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := lower(trim(target_email));
  r       record;
begin
  if v_email is null or v_email = '' then
    raise exception 'PIA: an email address is required.' using errcode = '22023';
  end if;

  -- 1. Every collected response, children before parents (the same order as
  --    WIPE_test_data.sql, so any foreign key between them stays satisfied).
  delete from public.hint_consumptions where lower(student_email) = v_email;
  delete from public.problem_serves    where lower(student_email) = v_email;
  delete from public.math_attempt_log  where lower(student_email) = v_email;
  delete from public.tutoring_attempts where lower(student_email) = v_email;
  delete from public.ocean_submissions where lower(email)         = v_email;

  -- 2. Any other per-participant table, found by its owner column the way
  --    0017 found them: student_email / user_email / participant_email, plus
  --    session_start_log's plain `email` (0017 allowed any of the four for
  --    it). This covers session_start_log and whatever table
  --    start_game_session() writes -- both created outside this repo -- and
  --    anything added later. Runs after step 1, so the tables above that
  --    point at a session are already empty for this participant.
  for r in
    select c.relname, a.attname
      from pg_attribute a
      join pg_class c     on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and not a.attisdropped
       and (a.attname in ('student_email', 'user_email', 'participant_email')
            or (c.relname = 'session_start_log' and a.attname = 'email'))
       and c.relname not in ('hint_consumptions', 'problem_serves',
                             'math_attempt_log', 'tutoring_attempts')
  loop
    execute format('delete from public.%I where lower(%I) = $1', r.relname, r.attname)
      using v_email;
  end loop;

  -- 3. The profile, then the sign-in account. Deleting the auth user also
  --    removes its sessions and refresh tokens.
  delete from public.profiles where lower(email) = v_email;
  delete from auth.users      where lower(email) = v_email;
end;
$function$;


-- ---------------------------------------------------------------------------
-- 2. Instant session revocation
--    The original admin check and profile update are unchanged; the two
--    deletes at the end are new.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_revoke_sessions__inner(p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
    if not exists (select 1 from public.profiles where email = auth.jwt() ->> 'email' and lower(trim(role)) = 'admin') then
        raise exception 'Only an admin may revoke sessions.';
    end if;
    update public.profiles set sessions_revoked_at = now(), active_devices = '{}' where email = p_email;

    -- End the sessions themselves, not just the tokens' standing: without a
    -- refresh token the revoked browser cannot mint a new access token that
    -- would pass jwt_is_current(). Refresh tokens cascade with their session;
    -- the second delete catches any legacy token that was never tied to one.
    delete from auth.sessions
     where user_id in (select u.id from auth.users u where lower(u.email) = lower(p_email));
    delete from auth.refresh_tokens
     where user_id in (select u.id::text from auth.users u where lower(u.email) = lower(p_email));
end;
$function$;


-- ---------------------------------------------------------------------------
-- 3. Take active_devices off the student whitelist, in place.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.enforce_profile_write_scope()'::regprocedure);

  if position('''active_devices''' in v_def) = 0 then
    raise notice 'PIA 0021: active_devices is already off the student whitelist.';
    return;
  end if;

  v_new := regexp_replace(v_def, '''active_devices'',\s*', '');

  if v_new = v_def or position('''active_devices''' in v_new) > 0 then
    raise exception
      'PIA 0021 ABORT: the whitelist in enforce_profile_write_scope() is not in the expected form; edit it by hand.'
      using errcode = 'P0001';
  end if;

  execute v_new;
  raise notice 'PIA 0021: active_devices removed from the student whitelist.';
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_def      text;
  v_problems text := '';
  v_student  text;
  v_rows     int;
begin
  v_def := pg_get_functiondef('public.admin_delete_user__inner(text)'::regprocedure);
  if v_def !~ 'ocean_submissions' or v_def !~ 'tutoring_attempts' or v_def !~ 'student_email' then
    v_problems := v_problems || 'admin_delete_user__inner does not clear the response tables; ';
  end if;

  v_def := pg_get_functiondef('public.admin_revoke_sessions__inner(text)'::regprocedure);
  if v_def !~ 'auth\.sessions' then
    v_problems := v_problems || 'admin_revoke_sessions__inner does not end auth.sessions; ';
  end if;

  if has_function_privilege('authenticated', 'public.admin_delete_user__inner(text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.admin_revoke_sessions__inner(text)', 'EXECUTE') then
    v_problems := v_problems || 'an __inner function is callable from the browser; ';
  end if;

  if v_problems <> '' then
    raise exception 'PIA 0021 ABORT: %', v_problems using errcode = 'P0001';
  end if;

  -- Prove the device bypass is closed: act as a real student, under RLS, and
  -- try to add a device to their own list. The write guard must refuse with
  -- 42501. Every change is rolled back either way.
  select email into v_student
    from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student'
   order by email limit 1;

  if v_student is null then
    raise notice 'PIA 0021: no student profile to test the device guard with -- skipped.';
  else
    perform set_config('request.jwt.claims',
      json_build_object('email', v_student, 'role', 'authenticated',
                        'iat', extract(epoch from now())::bigint)::text, true);
    begin
      execute 'set local role authenticated';
      update public.profiles
         set active_devices = coalesce(active_devices, '{}') || 'pia-0021-probe'::text
       where email = v_student;
      get diagnostics v_rows = row_count;
      execute 'reset role';

      if v_rows > 0 then
        raise exception
          'PIA 0021 ABORT: a student can still write active_devices -- rolling everything back.'
          using errcode = 'P0001';
      end if;
      raise notice 'PIA 0021: the probe matched no row (RLS hid it), so the guard could not be exercised.';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0021 OK: a student writing active_devices is refused (42501).';
    end;
    perform set_config('request.jwt.claims', '', true);
  end if;
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report -- what "Delete participant" now clears, in order.
select 1 as step, 'public.' || t.tbl || ' (' || t.col || ')' as deletes_from
  from (values ('hint_consumptions', 'student_email'), ('problem_serves', 'student_email'),
               ('math_attempt_log', 'student_email'), ('tutoring_attempts', 'student_email'),
               ('ocean_submissions', 'email')) as t(tbl, col)
union all
select 2, 'public.' || c.relname || ' (' || a.attname || ', found automatically)'
  from pg_attribute a
  join pg_class c     on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind in ('r', 'p') and not a.attisdropped
   and (a.attname in ('student_email', 'user_email', 'participant_email')
        or (c.relname = 'session_start_log' and a.attname = 'email'))
   and c.relname not in ('hint_consumptions', 'problem_serves', 'math_attempt_log', 'tutoring_attempts')
union all
select 3, 'public.profiles, then auth.users (with its sessions)'
 order by 1, 2;


-- ############################################################################
-- MIGRATION 20260928_0022_revocation_check_all_roles
-- ############################################################################

-- ============================================================================
-- PIA 0022 -- A REVOKED SESSION IS REFUSED EVERYWHERE, FOR EVERY ROLE
-- ============================================================================
-- After "Sign out everywhere" (0021), a revoked browser can no longer renew
-- its token, and the profiles policies refuse the token it still holds. Two
-- kinds of access ignored that until the token expired:
--
--   * SECURITY DEFINER functions -- the student functions and the admin_*
--     functions. They bypass RLS and take the caller's identity straight from
--     auth.jwt(), so a revoked token could still save answers, claim a device
--     slot, open a stage or delete an account.
--   * Every admin / teacher check built on pia_caller_role() -- the admin_*
--     wrappers (0011), the policies on settings, sections, professors and the
--     research tables (0017, 0018), and the profile write guard (0001).
--
-- This closes both with the same test the profiles policies already use,
-- jwt_is_current() (documented in 0020): a token issued before
-- profiles.sessions_revoked_at is stale.
--
-- 1. STUDENT FUNCTIONS refuse a revoked token first thing:
--        if not public.jwt_is_current() then
--          raise exception 'PIA: this session was signed out. Please sign in again.'
--            using errcode = '42501';
--        end if;
--    submit_ocean_results, set_student_stage, claim_device, serve_problem,
--    consume_hint, reveal_solution, record_problem_result_v2,
--    record_problem_result (if present), resume_or_start_game_session,
--    start_game_session, check_math_answer, end_game_session.
--
-- 2. pia_caller_role() RETURNS NULL FOR A REVOKED TOKEN, so every role check
--    built on it treats the caller as nobody -- admin, teacher and student
--    alike, in functions and in policies.
--
-- 3. ADMIN FUNCTIONS get the same explicit check as the student ones: every
--    admin_* function signed-in users can call (the 0011 wrappers and the
--    ones with their own guard). With (2) they would already refuse; this
--    makes them refuse with the "signed out" message rather than "only an
--    admin may call", and covers any that check the role another way.
--
-- Deliberately NOT guarded:
--   release_device    a signing-out device must still be able to free its
--                     slot (and revocation already empties the list);
--   jwt_is_current, pia_stage_open, pia_can_enter_stage, pia_session_state,
--   pia_replay_decision_tree -- read-only helpers with no side effects;
--   admin_*__inner    not callable from the browser; their wrapper is guarded.
--
-- HOW -- for (1) and (3) the check is INSERTED into each live definition
-- instead of the function being retyped from a migration file: 0013 rewrote
-- the messages inside many of these in place, and several were never in a
-- file (start_game_session, check_math_answer, end_game_session, and admin
-- functions created in the dashboard). Each definition is read with
-- pg_get_functiondef(), the check goes in right after the body's first
-- BEGIN, and the result is re-executed -- nothing else changes, and owners
-- and privileges are kept. pia_caller_role() is a one-line SQL function
-- defined only in 0001, so (2) replaces it outright, after confirming the
-- live copy is that definition.
--
-- SAFE TO RE-RUN: anything already calling jwt_is_current() is skipped. A
-- missing student function is reported and skipped. SQL-language functions
-- cannot take an IF, so they are reported instead of changed.
--
-- The postflight proves it with real accounts under the authenticated role:
-- a revoked student and a revoked admin are refused, and a current student
-- and a current admin still get through. Any failure rolls back all of it.
-- Every probe is itself rolled back, so no data changes.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1 + 3. Insert the check into the student and admin functions.
-- ---------------------------------------------------------------------------
do $$
declare
  v_students text[] := array[
    'submit_ocean_results', 'set_student_stage', 'claim_device',
    'serve_problem', 'consume_hint', 'reveal_solution',
    'record_problem_result_v2', 'record_problem_result',
    'resume_or_start_game_session', 'start_game_session',
    'check_math_answer', 'end_game_session'
  ];
  -- Real line breaks inside one plain literal: no escape processing to get
  -- wrong, and the inserted lines read like the rest of each body.
  v_guard text := '
  if not public.jwt_is_current() then
    raise exception ''PIA: this session was signed out. Please sign in again.''
      using errcode = ''42501'';
  end if;
';
  v_name    text;
  r         record;
  v_def     text;
  v_new     text;
  v_guarded text := '';
  v_already text := '';
  v_sql     text := '';
  v_missing text := '';
begin
  foreach v_name in array v_students loop
    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_name
    ) then
      v_missing := v_missing || v_name || ', ';
    end if;
  end loop;

  -- Every overload of each student function, and every admin function the
  -- browser can reach.
  for r in
    select p.oid, p.oid::regprocedure::text as sig, l.lanname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_language l  on l.oid = p.prolang
     where n.nspname = 'public'
       and p.prokind = 'f'
       and (p.proname = any (v_students)
            or (p.proname like 'admin\_%'
                and p.proname not like '%\_\_inner'
                and has_function_privilege('authenticated', p.oid, 'EXECUTE')))
     order by p.proname
  loop
    v_def := pg_get_functiondef(r.oid);

    if v_def ~ 'jwt_is_current' then
      v_already := v_already || r.sig || ', ';
      continue;
    end if;

    if r.lanname <> 'plpgsql' then
      v_sql := v_sql || r.sig || ' (' || r.lanname || '), ';
      continue;
    end if;

    -- pg_get_functiondef always opens the body with a dollar-quote on the AS
    -- line. In Postgres the FIRST quantifier decides whether the whole match
    -- is shortest or longest, so both are lazy (*?): the match ends at the
    -- FIRST whole-word BEGIN after the AS line -- the end of the DECLARE
    -- section -- never at a later nested BEGIN.
    v_new := regexp_replace(v_def, '(AS \$[a-z_0-9]*?\$.*?\mbegin\M)', '\1' || v_guard, 'i');

    if v_new = v_def then
      raise exception 'PIA 0022 ABORT: could not find the body''s BEGIN in %. Nothing was changed.', r.sig
        using errcode = 'P0001';
    end if;

    -- A malformed result fails here, and the whole migration rolls back.
    execute v_new;
    v_guarded := v_guarded || r.sig || ', ';
  end loop;

  raise notice 'PIA 0022 guarded: %', coalesce(nullif(v_guarded, ''), 'none');
  raise notice 'PIA 0022 already guarded: %', coalesce(nullif(v_already, ''), 'none');
  raise notice 'PIA 0022 student functions not found (skipped): %', coalesce(nullif(v_missing, ''), 'none');
  if v_sql <> '' then
    raise warning 'PIA 0022: SQL-language functions cannot take the check and were left unchanged: %', v_sql;
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 2. pia_caller_role() -- NULL for a revoked token.
--    Confirm production still has 0001's definition before replacing it.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text := pg_get_functiondef('public.pia_caller_role()'::regprocedure);
begin
  if v_def !~ 'jwt_is_current' and v_def !~ 'coalesce\(p\.role, ''student''\)' then
    raise exception
      'PIA 0022 ABORT: pia_caller_role() is not the definition from 0001, so it was not replaced. Nothing was changed.'
      using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.pia_caller_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  -- The caller's role, RLS-bypassing so the profiles policies do not recurse
  -- -- and NULL once their session has been revoked (0022), so every admin,
  -- teacher and student check built on this refuses a stale token.
  select case when public.jwt_is_current() then
    (select lower(trim(coalesce(p.role, 'student')))
       from public.profiles p
      where p.email = (auth.jwt() ->> 'email')
      limit 1)
  end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- prove it with real accounts, in both directions, for a
-- student (claim_device) and an admin (admin_revoke_device, asked to remove
-- a device that does not exist). Each probe runs in its own sub-block and is
-- rolled back, so no row changes.
-- ---------------------------------------------------------------------------
do $$
declare
  v_student text;
  v_admin   text;
begin
  if pg_get_functiondef('public.claim_device(text)'::regprocedure) !~ 'jwt_is_current' then
    raise exception 'PIA 0022 ABORT: claim_device did not receive the check.' using errcode = 'P0001';
  end if;
  if pg_get_functiondef('public.pia_caller_role()'::regprocedure) !~ 'jwt_is_current' then
    raise exception 'PIA 0022 ABORT: pia_caller_role() was not replaced.' using errcode = 'P0001';
  end if;

  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;
  select email into v_admin from public.profiles
   where lower(trim(role)) = 'admin' order by email limit 1;

  -- ---- STUDENT ----------------------------------------------------------
  if v_student is null then
    raise notice 'PIA 0022: no student profile to probe with -- skipped.';
  else
    -- (a) A token issued BEFORE a revocation is refused.
    begin
      update public.profiles set sessions_revoked_at = now() where email = v_student;
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from now())::bigint - 60)::text, true);
      execute 'set local role authenticated';
      perform public.claim_device('pia-0022-probe');
      execute 'reset role';
      raise exception 'PIA 0022 ABORT: a revoked student token could still call claim_device -- rolling back.'
        using errcode = 'P0001';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0022 OK: a revoked student token is refused (42501).';
    end;

    -- (b) A CURRENT token still gets through. The deliberate P0002 rolls
    --     back whatever claim_device changed.
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      perform public.claim_device('pia-0022-probe');
      execute 'reset role';
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0022 OK: a current student token is let through.';
      when insufficient_privilege then
        raise exception 'PIA 0022 ABORT: the check refused a CURRENT student token -- students would be locked out. Rolling back.'
          using errcode = 'P0001';
    end;
  end if;

  -- ---- ADMIN ------------------------------------------------------------
  if v_admin is null then
    raise notice 'PIA 0022: no admin profile to probe with -- skipped.';
  else
    -- (c) A revoked admin token: pia_caller_role() is NULL, and an admin
    --     function refuses it.
    begin
      update public.profiles set sessions_revoked_at = now() where email = v_admin;
      perform set_config('request.jwt.claims',
        json_build_object('email', v_admin, 'role', 'authenticated',
                          'iat', extract(epoch from now())::bigint - 60)::text, true);
      execute 'set local role authenticated';
      if public.pia_caller_role() is not null then
        raise exception 'PIA 0022 ABORT: pia_caller_role() still answers for a revoked admin token -- rolling back.'
          using errcode = 'P0001';
      end if;
      perform public.admin_revoke_device(v_admin, 'pia-0022-probe');
      execute 'reset role';
      raise exception 'PIA 0022 ABORT: a revoked admin token could still call admin_revoke_device -- rolling back.'
        using errcode = 'P0001';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0022 OK: a revoked admin token is refused (42501).';
    end;

    -- (d) A CURRENT admin token still works: pia_caller_role() says admin,
    --     and the admin function runs (removing nothing).
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_admin, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      if public.pia_caller_role() is distinct from 'admin' then
        raise exception 'PIA 0022 ABORT: pia_caller_role() no longer recognises a CURRENT admin -- rolling back.'
          using errcode = 'P0001';
      end if;
      perform public.admin_revoke_device(v_admin, 'pia-0022-probe');
      execute 'reset role';
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0022 OK: a current admin token is let through.';
      when insufficient_privilege then
        raise exception 'PIA 0022 ABORT: the check refused a CURRENT admin token -- admins would be locked out. Rolling back.'
          using errcode = 'P0001';
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report -- (1) every SECURITY DEFINER function signed-in users can call
-- (these bypass RLS, so each needs its own check), and (2) every policy
-- signed-in users are subject to. Anything not revocation-aware is listed
-- first, marked REVIEW.
with items as (
  select 'function' as kind,
         p.oid::regprocedure::text as name,
         case when pg_get_functiondef(p.oid) ~ 'jwt_is_current'  then 'revocation check'
              when pg_get_functiondef(p.oid) ~ 'pia_caller_role' then 'admin guard (revocation-aware via pia_caller_role)'
              when p.proname in ('release_device', 'jwt_is_current', 'pia_stage_open',
                                 'pia_can_enter_stage', 'pia_session_state',
                                 'pia_replay_decision_tree', 'pia_caller_role')
                   then 'unguarded by design'
              else '*** REVIEW: no check ***' end as guard
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  union all
  select 'policy',
         tablename || ' / ' || policyname || ' (' || cmd || ')',
         case when coalesce(qual, '') || ' ' || coalesce(with_check, '') ~ '(jwt_is_current|pia_caller_role)'
                   then 'revocation-aware'
              when coalesce(qual, 'false') = 'false' and coalesce(with_check, 'false') = 'false'
                   then 'denies everything'
              else '*** REVIEW: not revocation-aware ***' end
    from pg_policies
   where schemaname = 'public'
     and (roles && array['authenticated', 'public']::name[])
)
select kind, name, guard
  from items
 order by guard like '***%' desc, kind, name;


-- ############################################################################
-- MIGRATION 20260928_0023_revocation_aware_policies
-- ############################################################################

-- ============================================================================
-- PIA 0023 -- EVERY POLICY AND FUNCTION IS REVOCATION-AWARE
-- ============================================================================
-- 0022's report listed what was still reachable by a revoked token:
--
--   17 POLICIES -- older rules written in the dashboard before the migrations
--   existed (profiles_select_self, settings_admin_write, "Allow public access
--   to sections", attempts_select_teacher, ...). Permissive policies are
--   OR-ed, so each one is a door on its own: while any of them ignores
--   revocation, a revoked token still gets through it. Three are on profiles
--   and are the very policies 0009 set out to fix -- 0009's changes are not
--   in production (its self-verification most likely aborted it), so until
--   now the profiles revocation check was bypassed too.
--
--   2 FUNCTIONS with side effects -- enforce_device_limit(text), the old
--   device RPC that claim_device (0012) replaced and the app no longer
--   calls, and guard_session_start().
--
--   6 HELPERS -- current_email, current_role_name, current_user_role,
--   current_user_section, is_admin, is_teacher. They only report facts about
--   the caller and grant nothing by themselves; access comes from the
--   policies and functions that use them, which are all revocation-aware
--   once this runs. The postflight confirms they write nothing.
--
-- WHAT THIS DOES
--
-- 1. Every permissive policy signed-in users are subject to that does not yet
--    consult revocation gets "and the token is current" added:
--        USING      ((<existing>) and (select public.jwt_is_current()))
--        WITH CHECK ((<existing>) and (select public.jwt_is_current()))
--    For a current token each policy allows EXACTLY what it allowed before;
--    only a revoked token is turned away. Nothing is dropped, so no page
--    loses access it relies on. (The sub-select lets Postgres evaluate the
--    check once per query instead of once per row.)
--
-- 2. enforce_device_limit(text) can no longer be called from the browser.
--    Nothing in the app calls it, and as SECURITY DEFINER it was a second,
--    unguarded way to write active_devices. Its execute grant is revoked,
--    not the function dropped: restoring it is one GRANT.
--
-- 3. guard_session_start() gets the same "signed out" check as 0022's
--    functions, inserted into its live definition the same way.
--
-- NOT CHANGED, and why: restrictive policies (they only ever narrow access,
-- e.g. 0015's settings lockdown), deny-all policies, and policies that
-- already use jwt_is_current() or pia_caller_role().
--
-- WHAT THIS DOES NOT DECIDE: several of these older policies duplicate the
-- ones 0017 wrote, and at least one looks far too broad ("Allow public
-- access to sections", FOR ALL). After this migration they are all
-- revocation-aware, but removing them needs their exact definitions. The
-- report at the end prints every policy's full definition for that review.
--
-- SAFE TO RE-RUN: anything already revocation-aware is skipped.
--
-- The postflight proves it on profiles with real accounts under the
-- authenticated role: a current student sees their own row and a current
-- admin sees every row; revoked, both see nothing. Any failure rolls back
-- all of it. Every probe is itself rolled back.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Policies.
-- ---------------------------------------------------------------------------
do $$
declare
  v_cond  constant text := '(select public.jwt_is_current())';
  r       record;
  v_using text;
  v_check text;
  v_done  text := '';
begin
  for r in
    select pol.polname,
           c.relname,
           pg_get_expr(pol.polqual,      pol.polrelid) as qual,
           pg_get_expr(pol.polwithcheck, pol.polrelid) as with_check
      from pg_policy pol
      join pg_class c     on c.oid = pol.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and pol.polpermissive
       -- PUBLIC (0) or authenticated: the policies a signed-in token meets.
       and (0 = any (pol.polroles) or 'authenticated'::regrole::oid = any (pol.polroles))
     order by c.relname, pol.polname
  loop
    continue when coalesce(r.qual, '') || ' ' || coalesce(r.with_check, '')
                  ~ '(jwt_is_current|pia_caller_role)';
    continue when coalesce(r.qual, 'false') = 'false' and coalesce(r.with_check, 'false') = 'false';

    v_using := case when r.qual       is not null then format('(%s) and %s', r.qual,       v_cond) end;
    v_check := case when r.with_check is not null then format('(%s) and %s', r.with_check, v_cond) end;

    if v_using is not null and v_check is not null then
      execute format('alter policy %I on public.%I using (%s) with check (%s)',
                     r.polname, r.relname, v_using, v_check);
    elsif v_using is not null then
      execute format('alter policy %I on public.%I using (%s)', r.polname, r.relname, v_using);
    else
      execute format('alter policy %I on public.%I with check (%s)', r.polname, r.relname, v_check);
    end if;

    v_done := v_done || r.relname || ' / ' || r.polname || ', ';
  end loop;

  raise notice 'PIA 0023 made revocation-aware: %', coalesce(nullif(v_done, ''), 'none');
end;
$$;


-- ---------------------------------------------------------------------------
-- 2. enforce_device_limit -- out of the browser's reach.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'enforce_device_limit'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    raise notice 'PIA 0023: % is no longer callable from the browser.', r.sig;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. guard_session_start -- the 0022 check, inserted into the live body.
-- ---------------------------------------------------------------------------
do $$
declare
  v_guard text := '
  if not public.jwt_is_current() then
    raise exception ''PIA: this session was signed out. Please sign in again.''
      using errcode = ''42501'';
  end if;
';
  r     record;
  v_def text;
  v_new text;
begin
  for r in
    select p.oid, p.oid::regprocedure::text as sig, l.lanname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_language l  on l.oid = p.prolang
     where n.nspname = 'public' and p.proname = 'guard_session_start'
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def ~ 'jwt_is_current' then
      raise notice 'PIA 0023: % already checks revocation.', r.sig;
      continue;
    end if;
    if r.lanname <> 'plpgsql' then
      raise warning 'PIA 0023: % is %, not plpgsql; left unchanged -- send me its definition.', r.sig, r.lanname;
      continue;
    end if;

    -- Same insertion as 0022: right after the body's first BEGIN (both
    -- quantifiers lazy, so never at a later nested BEGIN).
    v_new := regexp_replace(v_def, '(AS \$[a-z_0-9]*?\$.*?\mbegin\M)', '\1' || v_guard, 'i');
    if v_new = v_def then
      raise exception 'PIA 0023 ABORT: could not find the body''s BEGIN in %. Nothing was changed.', r.sig
        using errcode = 'P0001';
    end if;

    execute v_new;
    raise notice 'PIA 0023: % now refuses a revoked token.', r.sig;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_total   int;
  v_student text;
  v_admin   text;
  v_seen    int;
  v_fn      text;
begin
  -- The six helpers must be read-only, or "grants nothing by itself" is false.
  foreach v_fn in array array['current_email', 'current_role_name', 'current_user_role',
                              'current_user_section', 'is_admin', 'is_teacher'] loop
    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_fn
         and pg_get_functiondef(p.oid) ~* '\m(insert|update|delete|truncate)\M'
    ) then
      raise exception 'PIA 0023 ABORT: helper %() writes data -- it needs its own check. Rolling back.', v_fn
        using errcode = 'P0001';
    end if;
  end loop;

  select count(*) into v_total from public.profiles;
  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;
  select email into v_admin from public.profiles
   where lower(trim(role)) = 'admin' order by email limit 1;

  -- ---- STUDENT: current sees exactly their own row -----------------------
  if v_student is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      select count(*) into v_seen from public.profiles;
      execute 'reset role';
      -- Zero means locked out. More than one is not a revocation problem
      -- (it is whatever the policies allow a student to see), so it is
      -- reported, not treated as a failure.
      if v_seen < 1 then
        raise exception 'PIA 0023 ABORT: a current student can no longer see their own profile -- students would be locked out. Rolling back.'
          using errcode = 'P0001';
      end if;
      raise exception 'probe done: %', v_seen using errcode = 'P0002';
    exception when sqlstate 'P0002' then
      raise notice 'PIA 0023 OK: a current student can read their profile (sees % row(s)).', substring(sqlerrm from '[0-9]+$');
    end;

    -- ---- STUDENT: revoked sees nothing -------------------------------------
    begin
      update public.profiles set sessions_revoked_at = now() where email = v_student;
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from now())::bigint - 60)::text, true);
      execute 'set local role authenticated';
      select count(*) into v_seen from public.profiles;
      execute 'reset role';
      if v_seen <> 0 then
        raise exception 'PIA 0023 ABORT: a revoked student still sees % profile row(s). Rolling back.', v_seen
          using errcode = 'P0001';
      end if;
      raise exception 'probe done' using errcode = 'P0002';
    exception when sqlstate 'P0002' then
      raise notice 'PIA 0023 OK: a revoked student sees nothing.';
    end;
  end if;

  -- ---- ADMIN: current sees every row ---------------------------------------
  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_admin, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      select count(*) into v_seen from public.profiles;
      execute 'reset role';
      if v_seen < v_total then
        raise exception 'PIA 0023 ABORT: a current admin sees only % of % profile rows. Rolling back.', v_seen, v_total
          using errcode = 'P0001';
      end if;
      raise exception 'probe done' using errcode = 'P0002';
    exception when sqlstate 'P0002' then
      raise notice 'PIA 0023 OK: a current admin sees all % profiles.', v_total;
    end;

    -- ---- ADMIN: revoked sees nothing ---------------------------------------
    begin
      update public.profiles set sessions_revoked_at = now() where email = v_admin;
      perform set_config('request.jwt.claims',
        json_build_object('email', v_admin, 'role', 'authenticated',
                          'iat', extract(epoch from now())::bigint - 60)::text, true);
      execute 'set local role authenticated';
      select count(*) into v_seen from public.profiles;
      execute 'reset role';
      if v_seen <> 0 then
        raise exception 'PIA 0023 ABORT: a revoked admin still sees % profile row(s). Rolling back.', v_seen
          using errcode = 'P0001';
      end if;
      raise exception 'probe done' using errcode = 'P0002';
    exception when sqlstate 'P0002' then
      raise notice 'PIA 0023 OK: a revoked admin sees nothing.';
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report -- every function and policy a signed-in user meets, what makes it
-- revocation-aware, and each policy's full definition (for the review of the
-- older, duplicated ones). Anything still open is listed first.
with items as (
  select 'function' as kind,
         p.oid::regprocedure::text as name,
         case when pg_get_functiondef(p.oid) ~ 'jwt_is_current'  then 'revocation check'
              when pg_get_functiondef(p.oid) ~ 'pia_caller_role' then 'admin guard (via pia_caller_role)'
              when p.proname in ('release_device', 'jwt_is_current', 'pia_stage_open',
                                 'pia_can_enter_stage', 'pia_session_state',
                                 'pia_replay_decision_tree', 'pia_caller_role',
                                 'current_email', 'current_role_name', 'current_user_role',
                                 'current_user_section', 'is_admin', 'is_teacher')
                   then 'read-only helper, by design'
              else '*** REVIEW: no check ***' end as guard,
         null::text as definition
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  union all
  select 'policy',
         tablename || ' / ' || policyname,
         case when permissive = 'RESTRICTIVE' then 'restrictive (narrows only)'
              when coalesce(qual, '') || ' ' || coalesce(with_check, '') ~ '(jwt_is_current|pia_caller_role)'
                   then 'revocation-aware'
              when coalesce(qual, 'false') = 'false' and coalesce(with_check, 'false') = 'false'
                   then 'denies everything'
              else '*** REVIEW: not revocation-aware ***' end,
         cmd || ' to ' || array_to_string(roles, ',')
             || coalesce(' USING ' || qual, '')
             || coalesce(' CHECK ' || with_check, '')
    from pg_policies
   where schemaname = 'public'
     and (roles && array['authenticated', 'public']::name[])
)
select kind, name, guard, definition
  from items
 order by guard like '***%' desc, kind, name;


-- ############################################################################
-- MIGRATION 20260928_0024_cleanup_policies_and_admin_guard
-- ############################################################################

-- ============================================================================
-- PIA 0024 -- ADMIN GUARD, POLICY CLEANUP, AND THE REST OF 0017
-- ============================================================================
-- Written from 0023's report of every policy in production. Three parts.
--
-- 1. ADMIN GUARD. admin_delete_user refuses to remove the caller's own
--    account, or the last administrator. Every admin row is locked first, so
--    two admins removing each other at the same moment are serialised: the
--    second one waits, then sees the first removal and is refused.
--
-- 2. POLICY CLEANUP. Permissive policies are OR-ed, so the broadest one on a
--    table decides. From the report:
--      sections / "Allow public access to sections"   FOR ALL, USING (true)
--          Any signed-in user -- every student -- could insert, rename or
--          delete sections. DROPPED. sections_read_auth (everyone signed in
--          reads) and sections_admin_write (admins write) remain.
--      settings / "Enable read access for all users"  SELECT, USING (true)
--          A second copy of settings_read_all. DROPPED. settings_read_all is
--          narrowed to `authenticated` (anon has no table grants since 0011,
--          so this changes nothing today; it stops the policy relying on that).
--      profiles / profiles_select_self    = profiles_select_own, twice
--      profiles / profiles_select_admin   inside profiles_admin_all
--          Duplicates. DROPPED -- and the postflight checks EVERY account:
--          admins still read every profile, everyone else still reads their
--          own (teachers' section view comes from a policy left untouched).
--
-- 3. THE REST OF 0017. 0017 aborted at its own "pre-existing policies" check
--    (it found the policies listed above), so none of it reached production.
--    With those policies now reviewed, its intent is applied here:
--      * TRUNCATE, REFERENCES and TRIGGER are revoked from signed-in users on
--        every public table, now and for future tables. TRUNCATE ignores RLS
--        entirely; none of the three has a caller in the app.
--      * The research log tables (tutoring_attempts, math_attempt_log,
--        session_start_log, game_sessions, math_attempts) and professors lose
--        INSERT / UPDATE / DELETE for signed-in users: the browser never
--        writes them -- the SECURITY DEFINER functions do, and those do not
--        need the grants. SELECT stays where 0017 kept it (the tutoring
--        summary view reads as the caller; teachers read their faculty row).
--      * sections gets INSERT for signed-in users (and its id sequence) --
--        0017's fix for "Add section" -- with RLS limiting it to admins.
--      * ROW LEVEL SECURITY IS SWITCHED ON for every public table. A policy
--        does nothing while RLS is off, and production's RLS state for the
--        tables created in the dashboard was never visible. Every table the
--        app reads directly (profiles, settings, sections, professors,
--        ocean_submissions) already has the policies it needs -- the
--        postflight proves it for every account. Tables read only through
--        SECURITY DEFINER functions (the answer keys, the logs) need none:
--        those functions bypass RLS as the table owner.
--      * Deliberately NO new "students read their own log rows" policies.
--        AUDIT_answer_key_reachability.sql treats a student reading
--        math_attempt_log as a leak risk, and nothing in the app reads the
--        logs directly. tutoring_attempts already lets a student read their
--        own rows, which is what the tutoring summary view needs; if that
--        view ever returns nothing, the dashboard already falls back to the
--        numbers it has on screen.
--
-- SAFE TO RE-RUN. The postflight, run after everything above, checks every
-- account under the authenticated role and rolls the WHOLE migration back on
-- any failure:
--   * every admin still reads every row of profiles, settings, sections,
--     professors and ocean_submissions;
--   * every student and teacher still reads their own profile, every stage
--     flag and every section; every teacher still reads their faculty row;
--   * an admin can still add a section, and a student cannot;
--   * an admin cannot remove their own account, and the last admin cannot
--     be removed.
-- Every probe is itself rolled back, so no data changes.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Admin guard. The 0021 body, with the new checks before any delete.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_delete_user__inner(target_email text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email    text := lower(trim(target_email));
  v_caller   text := lower(auth.jwt() ->> 'email');
  v_is_admin boolean;
  v_admins   int;
  r          record;
begin
  if v_email is null or v_email = '' then
    raise exception 'PIA: an email address is required.' using errcode = '22023';
  end if;

  -- 0024: never the caller's own account. (No JWT -- the SQL editor -- has no
  -- caller, so this check does not apply there; the last-admin one does.)
  if v_caller is not null and v_email = v_caller then
    raise exception 'PIA: you cannot remove your own account. Ask another administrator to do it.';
  end if;

  -- 0024: lock every admin row before counting, so two admins removing each
  -- other at once are serialised -- the second waits for the first, then
  -- sees its removal.
  perform 1 from public.profiles where lower(trim(role)) = 'admin' for update;

  select exists (select 1 from public.profiles
                  where lower(email) = v_email and lower(trim(role)) = 'admin')
    into v_is_admin;

  if v_is_admin then
    select count(*) into v_admins from public.profiles where lower(trim(role)) = 'admin';
    if v_admins <= 1 then
      raise exception 'PIA: % is the last administrator and cannot be removed.', v_email;
    end if;
  end if;

  -- The caller may have been removed by another admin while this waited.
  if v_caller is not null and not exists (
       select 1 from public.profiles where lower(email) = v_caller and lower(trim(role)) = 'admin') then
    raise exception 'PIA: your administrator account no longer exists.' using errcode = '42501';
  end if;

  -- From here on, unchanged from 0021.
  delete from public.hint_consumptions where lower(student_email) = v_email;
  delete from public.problem_serves    where lower(student_email) = v_email;
  delete from public.math_attempt_log  where lower(student_email) = v_email;
  delete from public.tutoring_attempts where lower(student_email) = v_email;
  delete from public.ocean_submissions where lower(email)         = v_email;

  for r in
    select c.relname, a.attname
      from pg_attribute a
      join pg_class c     on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r', 'p')
       and not a.attisdropped
       and (a.attname in ('student_email', 'user_email', 'participant_email')
            or (c.relname = 'session_start_log' and a.attname = 'email'))
       and c.relname not in ('hint_consumptions', 'problem_serves',
                             'math_attempt_log', 'tutoring_attempts')
  loop
    execute format('delete from public.%I where lower(%I) = $1', r.relname, r.attname)
      using v_email;
  end loop;

  delete from public.profiles where lower(email) = v_email;
  delete from auth.users      where lower(email) = v_email;
end;
$function$;


-- ---------------------------------------------------------------------------
-- 2. Policy cleanup.
-- ---------------------------------------------------------------------------
drop policy if exists "Allow public access to sections"  on public.sections;
drop policy if exists "Enable read access for all users" on public.settings;
drop policy if exists profiles_select_self               on public.profiles;
drop policy if exists profiles_select_admin              on public.profiles;

do $$
begin
  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename = 'settings' and policyname = 'settings_read_all') then
    alter policy settings_read_all on public.settings to authenticated;
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. The rest of 0017.
-- ---------------------------------------------------------------------------

-- 3a. No TRUNCATE / REFERENCES / TRIGGER for signed-in users, now or later.
do $$
declare
  r record;
begin
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
  loop
    execute format('revoke truncate, references, trigger on public.%I from authenticated, anon', r.relname);
  end loop;
end;
$$;
alter default privileges in schema public revoke truncate, references, trigger on tables from authenticated;

-- 3b. The browser never writes these; their SECURITY DEFINER writers do not
--     need the grants. SELECT stays: the summary view reads as the caller.
do $$
declare
  v_t text;
begin
  foreach v_t in array array['tutoring_attempts', 'math_attempt_log', 'session_start_log',
                             'game_sessions', 'math_attempts', 'professors'] loop
    if to_regclass('public.' || v_t) is not null then
      execute format('revoke insert, update, delete on public.%I from authenticated', v_t);
    end if;
  end loop;

  -- SELECT only where 0017 kept it: the three tables the tutoring views read
  -- as the caller, and professors (the teacher dashboard reads its own row).
  -- RLS decides which rows; nothing new is granted on game_sessions or
  -- math_attempts.
  foreach v_t in array array['tutoring_attempts', 'math_attempt_log', 'session_start_log', 'professors'] loop
    if to_regclass('public.' || v_t) is not null then
      execute format('grant select on public.%I to authenticated', v_t);
    end if;
  end loop;
end;
$$;

-- 3c. "Add section" (admin-dashboard.js) inserts into sections directly.
--     RLS (sections_admin_write) keeps it to admins. A serial id also needs
--     its sequence, so that is granted too -- for this table's sequences only.
grant select, insert on public.sections to authenticated;
do $$
declare
  r record;
begin
  for r in
    select s.oid::regclass::text as seq
      from pg_class s
      join pg_depend d on d.objid = s.oid and d.deptype in ('a', 'i')
     where s.relkind = 'S' and d.refobjid = 'public.sections'::regclass
  loop
    execute format('grant usage on sequence %s to authenticated', r.seq);
  end loop;
end;
$$;

-- 3d. RLS on for every public table.
do $$
declare
  r      record;
  v_done text := '';
begin
  for r in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity
  loop
    execute format('alter table public.%I enable row level security', r.relname);
    v_done := v_done || r.relname || ', ';
  end loop;
  raise notice 'PIA 0024: RLS switched on for: %', coalesce(nullif(v_done, ''), 'none (already on everywhere)');
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- every account, under the authenticated role.
-- ---------------------------------------------------------------------------
do $$
declare
  t_profiles   int;  t_settings  int;  t_stage int;  t_sections int;
  t_professors int;  t_ocean     int;
  c_own int; c_profiles int; c_settings int; c_stage int; c_sections int;
  c_professors int; c_ocean int; c_fac_self int; v_fac_expected int;
  u         record;
  v_role    text;
  v_fail    text := '';
  v_checked int := 0;
begin
  select count(*) into t_profiles   from public.profiles;
  select count(*) into t_settings   from public.settings;
  select count(*) into t_stage      from public.settings where key like 'stage\_%';
  select count(*) into t_sections   from public.sections;
  select count(*) into t_professors from public.professors;
  select count(*) into t_ocean      from public.ocean_submissions;

  for u in select email, lower(trim(coalesce(role, 'student'))) as role
             from public.profiles where email is not null order by email loop
    select count(*) into v_fac_expected from public.professors where lower(email) = lower(u.email);

    perform set_config('request.jwt.claims',
      json_build_object('email', u.email, 'role', 'authenticated',
                        'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
    execute 'set local role authenticated';
    select count(*) into c_own        from public.profiles where email = u.email;
    select count(*) into c_profiles   from public.profiles;
    select count(*) into c_settings   from public.settings;
    select count(*) into c_stage      from public.settings where key like 'stage\_%';
    select count(*) into c_sections   from public.sections;
    select count(*) into c_professors from public.professors;
    select count(*) into c_fac_self   from public.professors where lower(email) = lower(u.email);
    select count(*) into c_ocean      from public.ocean_submissions;
    execute 'reset role';
    v_checked := v_checked + 1;

    if u.role = 'admin' then
      if c_profiles <> t_profiles or c_settings <> t_settings or c_sections <> t_sections
         or c_professors <> t_professors or c_ocean <> t_ocean then
        v_fail := v_fail || format('admin %s sees profiles %s/%s, settings %s/%s, sections %s/%s, professors %s/%s, results %s/%s; ',
          u.email, c_profiles, t_profiles, c_settings, t_settings, c_sections, t_sections,
          c_professors, t_professors, c_ocean, t_ocean);
      end if;
    else
      if c_own < 1 then
        v_fail := v_fail || format('%s %s cannot read their own profile; ', u.role, u.email);
      end if;
      if c_stage <> t_stage then
        v_fail := v_fail || format('%s %s sees %s of %s stage flags; ', u.role, u.email, c_stage, t_stage);
      end if;
      if c_sections <> t_sections then
        v_fail := v_fail || format('%s %s sees %s of %s sections; ', u.role, u.email, c_sections, t_sections);
      end if;
      if u.role = 'teacher' and c_fac_self < v_fac_expected then
        v_fail := v_fail || format('teacher %s cannot read their faculty row; ', u.email);
      end if;
    end if;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  if v_fail <> '' then
    raise exception 'PIA 0024 ABORT (nothing changed): %', v_fail using errcode = 'P0001';
  end if;
  raise notice 'PIA 0024 OK: all % accounts keep their access.', v_checked;
end;
$$;

-- Writes and the admin guard.
do $$
declare
  v_admin   text;
  v_student text;
  v_rows    int;
begin
  select email into v_admin from public.profiles
   where lower(trim(role)) = 'admin' order by email limit 1;
  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;

  -- (a) An admin can add a section.
  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_admin, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      insert into public.sections (name) values ('pia-0024-probe');
      execute 'reset role';
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0024 OK: an admin can add a section.';
      when others then
        raise exception 'PIA 0024 ABORT: an admin can no longer add a section (%). Rolling back.', sqlerrm
          using errcode = 'P0001';
    end;
  end if;

  -- (b) A student cannot.
  if v_student is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      insert into public.sections (name) values ('pia-0024-probe');
      get diagnostics v_rows = row_count;
      execute 'reset role';
      raise exception 'PIA 0024 ABORT: a student could add a section. Rolling back.' using errcode = 'P0001';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0024 OK: a student cannot add a section.';
    end;
  end if;

  -- (c) An admin cannot remove their own account.
  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_admin, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      perform public.admin_delete_user(v_admin);
      execute 'reset role';
      raise exception 'PIA 0024 ABORT: an admin removed their own account. Rolling back.' using errcode = 'P0001';
    exception
      when others then
        if sqlerrm not like '%cannot remove your own account%' then raise; end if;
        raise notice 'PIA 0024 OK: an admin cannot remove their own account.';
    end;

    -- (d) The last admin cannot be removed. Every other admin is demoted
    --     inside this probe so v_admin is the last one; all of it rolls back.
    perform set_config('request.jwt.claims', '', true);
    begin
      update public.profiles set role = 'teacher'
       where lower(trim(role)) = 'admin' and email <> v_admin;
      begin
        perform public.admin_delete_user__inner(v_admin);
        raise exception 'PIA 0024 ABORT: removing the only remaining admin was allowed. Rolling back.'
          using errcode = 'P0001';
      exception
        when others then
          -- Match the guard's own wording exactly, so this ABORT above can
          -- never be mistaken for the guard firing.
          if sqlerrm not like '%is the last administrator and cannot be removed%' then raise; end if;
          raise notice 'PIA 0024 OK: the last administrator cannot be removed.';
      end;
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then null;
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report -- every public table (RLS state and who may touch it), every
-- policy, every function a signed-in user can call. Anything still open is
-- listed first, marked REVIEW.
with items as (
  select 'table' as kind,
         c.relname::text as name,
         case when not c.relrowsecurity then '*** REVIEW: RLS off ***' else 'RLS on' end as guard,
         'policies: ' || (select count(*) from pg_policy p where p.polrelid = c.oid)
           || '; authenticated: ' || coalesce((select string_agg(privilege_type, ',' order by privilege_type)
                                                 from information_schema.role_table_grants g
                                                where g.table_schema = 'public' and g.table_name = c.relname
                                                  and g.grantee = 'authenticated'), 'none')
           || '; anon: ' || coalesce((select string_agg(privilege_type, ',' order by privilege_type)
                                        from information_schema.role_table_grants g
                                       where g.table_schema = 'public' and g.table_name = c.relname
                                         and g.grantee = 'anon'), 'none') as definition
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')
  union all
  select 'policy',
         tablename || ' / ' || policyname,
         case when permissive = 'RESTRICTIVE' then 'restrictive (narrows only)'
              when coalesce(qual, '') || ' ' || coalesce(with_check, '') ~ '(jwt_is_current|pia_caller_role)'
                   then 'revocation-aware'
              when coalesce(qual, 'false') = 'false' and coalesce(with_check, 'false') = 'false'
                   then 'denies everything'
              else '*** REVIEW: not revocation-aware ***' end,
         cmd || ' to ' || array_to_string(roles, ',')
             || coalesce(' USING ' || qual, '')
             || coalesce(' CHECK ' || with_check, '')
    from pg_policies
   where schemaname = 'public'
  union all
  select 'function',
         p.oid::regprocedure::text,
         case when pg_get_functiondef(p.oid) ~ 'jwt_is_current'  then 'revocation check'
              when pg_get_functiondef(p.oid) ~ 'pia_caller_role' then 'admin guard (via pia_caller_role)'
              when p.proname = 'release_device' then 'unguarded by design (frees the caller''s own slot)'
              when p.proname in ('pia_stage_open', 'pia_can_enter_stage', 'pia_session_state',
                                 'pia_replay_decision_tree', 'current_email', 'current_role_name',
                                 'current_user_role', 'current_user_section', 'is_admin', 'is_teacher')
                   then 'read-only helper, by design'
              else '*** REVIEW: no check ***' end,
         null
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.prosecdef
     and p.prorettype <> 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
)
select kind, name, guard, definition
  from items
 order by guard like '***%' desc, kind, name;


-- ############################################################################
-- MIGRATION 20260928_0025_self_service_device_reset
-- ############################################################################

-- ============================================================================
-- PIA 0025 -- SELF-SERVICE "SIGN OUT OF OTHER DEVICES"
-- ============================================================================
-- A student or teacher who closed a browser without signing out used to be
-- stuck at "1 device limit reached" on every other computer until an admin
-- cleared their slot. Now the refused sign-in offers "Sign out of other
-- devices": the site emails a one-time code, and once it is entered on THIS
-- device, reset_my_devices() below
--   * ends every other session of the account -- their refresh tokens are
--     deleted, and every access token issued before this one is refused by
--     jwt_is_current() (0022-0024);
--   * keeps THIS session alive;
--   * makes this device the account's only registered device.
--
-- WHY THE EMAIL CODE, AND HOW IT IS ENFORCED HERE
-- The sign-in form already checked the password. The code adds proof that
-- the person also controls the mailbox, so a shared or leaked password is
-- not enough to push the real owner off their device. That proof is checked
-- HERE, not only in the browser: the caller's token must carry an email-based
-- authentication method (amr) -- a code, a magic link, a recovery or an
-- invite -- from the last 15 minutes. A session opened with only a password
-- cannot call this, even straight from the browser console.
--
-- KEEPING THIS SESSION
--   * sessions_revoked_at is stamped with THIS token's issue time, so every
--     token issued earlier (the other devices) is stale and this one is not.
--   * auth.sessions is emptied for the account EXCEPT this token's session
--     (the session_id claim), so only the other devices lose their refresh
--     tokens.
--
-- Emails are sent by Supabase Auth (signInWithOtp), not by this function.
-- The "Magic Link" email template must show the code -- {{ .Token }} -- for
-- the code to reach the student; see the notes that came with this change.
--
-- The postflight tries it as a real student under the authenticated role:
-- a password-only session is refused, an email-verified one succeeds and
-- leaves exactly this device registered with this session current. Every
-- probe rolls back.
-- ============================================================================

begin;

create or replace function public.reset_my_devices(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text   := auth.jwt() ->> 'email';
  v_uid     uuid   := nullif(auth.jwt() ->> 'sub', '')::uuid;
  v_sid     uuid   := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_iat     bigint := nullif(auth.jwt() ->> 'iat', '')::bigint;
  v_device  text   := trim(coalesce(p_device_id, ''));
  v_fresh   boolean;
begin
  if v_email is null or v_uid is null or v_iat is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  if v_device = '' or length(v_device) > 120 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- The mailbox proof: an email-based sign-in on this session, recently.
  select exists (
    select 1
      from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) as m
     where m ->> 'method' in ('otp', 'magiclink', 'recovery', 'invite', 'email/signup')
       and nullif(m ->> 'timestamp', '')::bigint >= extract(epoch from now())::bigint - 900
  ) into v_fresh;

  if not v_fresh then
    raise exception 'PIA: confirm it is you with the code from your email first.' using errcode = '42501';
  end if;

  -- Every token issued before this one is now stale; this one is not.
  update public.profiles
     set sessions_revoked_at = greatest(coalesce(sessions_revoked_at, '-infinity'::timestamptz),
                                        to_timestamp(v_iat)),
         active_devices      = array[v_device]
   where email = v_email;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- The other devices' sessions and refresh tokens go; this session stays.
  -- (With no session_id claim there is nothing to spare, so all go -- this
  -- device then keeps working until its current token expires.)
  delete from auth.sessions
   where user_id = v_uid and (v_sid is null or id <> v_sid);
  delete from auth.refresh_tokens
   where user_id = v_uid::text and (v_sid is null or session_id is distinct from v_sid);

  return jsonb_build_object('ok', true, 'devices', array[v_device]);
end;
$$;

revoke all on function public.reset_my_devices(text) from public, anon;
grant execute on function public.reset_my_devices(text) to authenticated;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_student text;
  v_uid     uuid;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 1;
  v_sid     uuid   := gen_random_uuid();
  v_devices text[];
  v_current boolean;
begin
  if has_function_privilege('anon', 'public.reset_my_devices(text)', 'EXECUTE') then
    raise exception 'PIA 0025 ABORT: reset_my_devices is callable without signing in.' using errcode = 'P0001';
  end if;

  select p.email, u.id into v_student, v_uid
    from public.profiles p join auth.users u on lower(u.email) = lower(p.email)
   where lower(trim(coalesce(p.role, 'student'))) = 'student'
   order by p.email limit 1;

  if v_student is null then
    raise notice 'PIA 0025: no student with a sign-in account to probe with -- skipped.';
    return;
  end if;

  -- (a) A password-only session is refused.
  begin
    perform set_config('request.jwt.claims', json_build_object(
      'email', v_student, 'sub', v_uid, 'role', 'authenticated', 'iat', v_iat, 'session_id', v_sid,
      'amr', json_build_array(json_build_object('method', 'password', 'timestamp', v_iat)))::text, true);
    execute 'set local role authenticated';
    perform public.reset_my_devices('pia-0025-probe');
    execute 'reset role';
    raise exception 'PIA 0025 ABORT: a password-only session reset the devices. Rolling back.' using errcode = 'P0001';
  exception
    when insufficient_privilege then
      if sqlerrm not like '%code from your email%' then raise; end if;
      raise notice 'PIA 0025 OK: a password-only session is refused.';
  end;

  -- (b) An email-verified session succeeds: this device alone is registered,
  --     and this token is still current afterwards.
  begin
    perform set_config('request.jwt.claims', json_build_object(
      'email', v_student, 'sub', v_uid, 'role', 'authenticated', 'iat', v_iat, 'session_id', v_sid,
      'amr', json_build_array(json_build_object('method', 'otp', 'timestamp', v_iat)))::text, true);
    execute 'set local role authenticated';
    perform public.reset_my_devices('pia-0025-probe');
    v_current := public.jwt_is_current();
    execute 'reset role';

    select active_devices into v_devices from public.profiles where email = v_student;
    if v_devices is distinct from array['pia-0025-probe'] then
      raise exception 'PIA 0025 ABORT: the device list is % after a reset. Rolling back.', v_devices
        using errcode = 'P0001';
    end if;
    if not v_current then
      raise exception 'PIA 0025 ABORT: the reset signed out the very session that asked for it. Rolling back.'
        using errcode = 'P0001';
    end if;
    raise exception 'probe done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0025 OK: an email-verified reset keeps this session and registers only this device.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260928_0026_teacher_live_monitor
-- ############################################################################

-- ============================================================================
-- PIA 0026 -- TEACHER LIVE MONITOR, WITHIN THE CERC REDLINES
-- ============================================================================
-- The ethics protocol (CERC 2025-1-PTCS-231, p. 6) says teachers "will not
-- have access to individual personality labels", and every personality and
-- group detail stays with the research team. Until now a teacher could read
-- every column of every student row in their section (policy
-- profiles_select_teacher_section) -- ocean_*, group_type,
-- selected_character, pre/post-test scores -- and their dashboard's realtime
-- channel streamed those full rows on every change. Hiding columns in the page
-- does not help: the browser console can ask for them directly.
--
-- This replaces that access with ONE door that returns only what a teacher
-- running a 75-minute session needs:
--
--   teacher_class_status()   SECURITY DEFINER, teacher only, own section only.
--     Per student: display name, a status, problems finished this lesson, and
--     whether they need the teacher's attention (and why). Nothing else. The
--     function never selects a research column, so none can reach a teacher.
--
--   Statuses are deliberately GROUP-BLIND. "Character Selection" happens only
--   for the Non-Assigned group, so it is reported together with the OCEAN
--   questionnaire as one "Getting set up" -- a teacher cannot tell who chose
--   a tutor and who was given one.
--
--   "Needs attention" is BEHAVIOURAL, never a score: stuck on one problem 5+
--   minutes, idle 3+ minutes in the lesson, or dropped offline mid-lesson. It
--   asks the teacher to help with focus, access or navigation. Correctness
--   is deliberately not a trigger: it would invite math tutoring, which the
--   traditional-classroom comparison (H0c) must not get from a teacher
--   inside PIA sessions, and it would label children as weak in class.
--
-- ONLINE, HONESTLY. profiles had no reliable "is this student here" signal
-- (is_in_game is written by the student's own browser, and only during the
-- lesson). Student pages now call touch_presence() every 45 seconds; the
-- server stamps the time itself. It lives in its own small table so the
-- heartbeat does not churn profiles (every profiles change is broadcast to
-- the admin console). Its column is student_email, so "Delete participant"
-- (0021/0024) removes it with everything else.
--
-- REMOVED: profiles_select_teacher_section and
-- tutoring_attempts / attempts_select_teacher. Teachers keep their own
-- profile and faculty row; everything about students goes through the
-- function.
--
-- The postflight proves it with real accounts under the authenticated role:
-- a teacher can no longer read any student row directly, the function gives
-- them exactly their own section, a student cannot call it, and the result
-- carries no research column. Any failure rolls everything back.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Presence.
-- ---------------------------------------------------------------------------
create table if not exists public.student_presence (
  student_email text primary key,
  last_seen     timestamptz not null default now()
);

alter table public.student_presence enable row level security;
revoke all on public.student_presence from public, anon, authenticated;

create or replace function public.touch_presence(p_online boolean default true)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  -- Only students are monitored; a staff heartbeat is simply ignored.
  if public.pia_caller_role() is distinct from 'student' then
    return;
  end if;

  if p_online then
    insert into public.student_presence (student_email, last_seen)
    values (v_email, now())
    on conflict (student_email) do update set last_seen = excluded.last_seen;
  else
    delete from public.student_presence where student_email = v_email;
  end if;
end;
$$;

revoke all on function public.touch_presence(boolean) from public, anon;
grant execute on function public.touch_presence(boolean) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. The teacher's one door.
-- ---------------------------------------------------------------------------
create or replace function public.teacher_class_status()
returns table (
  student_key          text,     -- opaque row id (md5 of the email), not the email
  full_name            text,
  activity             text,     -- offline | waiting | setting_up | not_started
                                 -- | solving | idle | finished
  problems_done        int,
  problems_target      int,
  attention            text,     -- null | stuck | idle | dropped
  attention_minutes    int,
  seconds_since_active int,      -- since the last lesson action; null if none
  online               boolean
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_email    text := lower(auth.jwt() ->> 'email');
  v_section  text;
  -- Keep in step with SESSION_TARGET in student/js/student-dashboard.js.
  c_target   constant int      := 10;
  c_online   constant interval := '2 minutes';   -- heartbeat is every 45 s
  c_idle     constant interval := '3 minutes';
  c_stuck    constant interval := '5 minutes';
  c_dropped  constant interval := '15 minutes';
  c_window   constant interval := '3 hours';     -- "this class", generously
  r          record;
  v_seen     timestamptz;
  v_session  uuid;
  v_done     int;
  v_served   timestamptz;
  v_number   int;
  v_answered boolean;
  v_last     timestamptz;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can view a class.' using errcode = '42501';
  end if;

  -- The same section the teacher dashboard shows: the teacher's profile,
  -- else the faculty record the admin assigned.
  select coalesce(
           nullif(trim(p.section), ''),
           (select nullif(trim(f.assigned_section), '') from public.professors f
             where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p
   where lower(p.email) = v_email
   limit 1;

  if v_section is null then
    return;
  end if;

  for r in
    select p.email, p.full_name, p.current_stage
      from public.profiles p
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
     order by p.full_name
  loop
    v_session := null; v_done := 0; v_served := null; v_number := null;
    v_answered := false; v_last := null;

    select sp.last_seen into v_seen
      from public.student_presence sp where sp.student_email = lower(r.email);

    -- This lesson: the student's most recent session in the class window.
    select ps.session_id into v_session
      from public.problem_serves ps
     where lower(ps.student_email) = lower(r.email) and ps.served_at > now() - c_window
     order by ps.served_at desc
     limit 1;

    if v_session is not null then
      select count(*) into v_done
        from public.tutoring_attempts t
       where t.session_id = v_session and lower(t.student_email) = lower(r.email);

      select ps.served_at, ps.problem_number into v_served, v_number
        from public.problem_serves ps
       where ps.session_id = v_session and lower(ps.student_email) = lower(r.email)
       order by ps.served_at desc
       limit 1;

      select exists (select 1 from public.tutoring_attempts t
                      where t.session_id = v_session and lower(t.student_email) = lower(r.email)
                        and t.problem_number = v_number)
        into v_answered;

      -- Any action counts: a new problem, an answer attempt, a hint.
      select greatest(
               v_served,
               (select max(a.attempted_at) from public.math_attempt_log a
                 where a.session_id = v_session and lower(a.student_email) = lower(r.email)),
               (select max(h.consumed_at) from public.hint_consumptions h
                 where h.session_id = v_session and lower(h.student_email) = lower(r.email)))
        into v_last;
    end if;

    student_key          := md5(lower(r.email));
    full_name            := coalesce(nullif(trim(r.full_name), ''), 'Unnamed student');
    problems_done        := least(v_done, c_target);
    problems_target      := c_target;
    online               := v_seen is not null and v_seen > now() - c_online;
    seconds_since_active := case when v_last is null then null
                                 else greatest(0, extract(epoch from now() - v_last))::int end;
    attention            := null;
    attention_minutes    := null;

    if not online then
      activity := 'offline';
      if v_session is not null and v_done < c_target and v_last > now() - c_dropped then
        attention := 'dropped';
        attention_minutes := floor(extract(epoch from now() - coalesce(v_seen, v_last)) / 60)::int;
      end if;
    elsif r.current_stage in ('OCEAN', 'Character Selection') then
      activity := 'setting_up';        -- one label for both: group-blind
    elsif r.current_stage is distinct from 'Tutoring Dashboard' then
      activity := 'waiting';
    elsif v_done >= c_target then
      activity := 'finished';
    elsif v_session is null then
      activity := 'not_started';
    elsif v_last > now() - c_idle then
      activity := 'solving';
    else
      activity := 'idle';
      attention := 'idle';
      attention_minutes := floor(extract(epoch from now() - v_last) / 60)::int;
    end if;

    -- On the same problem too long -- even while trying things, since hints
    -- and attempts keep "last action" fresh.
    if online and activity in ('solving', 'idle') and v_served is not null
       and not v_answered and v_served < now() - c_stuck then
      attention := 'stuck';
      attention_minutes := floor(extract(epoch from now() - v_served) / 60)::int;
    end if;

    return next;
  end loop;
end;
$$;

revoke all on function public.teacher_class_status() from public, anon;
grant execute on function public.teacher_class_status() to authenticated;


-- ---------------------------------------------------------------------------
-- 3. No more direct reads of student rows by teachers.
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_teacher_section on public.profiles;
drop policy if exists attempts_select_teacher          on public.tutoring_attempts;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_result   text := pg_get_function_result('public.teacher_class_status()'::regprocedure);
  v_teacher  text;
  v_section  text;
  v_student  text;
  v_expected int;
  v_seen     int;
begin
  if v_result ~* '(ocean|group|character|persona|pre_test|post_test|email|score)' then
    raise exception 'PIA 0026 ABORT: teacher_class_status returns a research column: %', v_result
      using errcode = 'P0001';
  end if;

  if exists (select 1 from pg_policies
              where schemaname = 'public' and tablename in ('profiles', 'tutoring_attempts')
                and coalesce(qual, '') ~ 'teacher') then
    raise exception 'PIA 0026 ABORT: a policy still grants teachers direct access to student rows.'
      using errcode = 'P0001';
  end if;

  -- A teacher with a section, resolved the same way the function does.
  select p.email,
         coalesce(nullif(trim(p.section), ''),
                  (select nullif(trim(f.assigned_section), '') from public.professors f
                    where lower(f.email) = lower(p.email) limit 1))
    into v_teacher, v_section
    from public.profiles p
   where lower(trim(p.role)) = 'teacher'
     and coalesce(nullif(trim(p.section), ''),
                  (select nullif(trim(f.assigned_section), '') from public.professors f
                    where lower(f.email) = lower(p.email) limit 1)) is not null
   order by p.email limit 1;

  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;

  if v_teacher is null then
    raise notice 'PIA 0026: no teacher with a section to probe with -- skipped the teacher checks.';
  else
    select count(*) into v_expected from public.profiles
     where section = v_section and lower(trim(coalesce(role, 'student'))) = 'student';

    perform set_config('request.jwt.claims',
      json_build_object('email', v_teacher, 'role', 'authenticated',
                        'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
    execute 'set local role authenticated';
    select count(*) into v_seen from public.profiles
     where lower(trim(coalesce(role, 'student'))) = 'student';
    if v_seen <> 0 then
      execute 'reset role';
      raise exception 'PIA 0026 ABORT: teacher % can still read % student row(s) directly.', v_teacher, v_seen
        using errcode = 'P0001';
    end if;
    select count(*) into v_seen from public.teacher_class_status();
    execute 'reset role';

    if v_seen <> v_expected then
      raise exception 'PIA 0026 ABORT: teacher_class_status shows % of the % students in section %.',
        v_seen, v_expected, v_section using errcode = 'P0001';
    end if;
    raise notice 'PIA 0026 OK: teacher % sees all % students of section %, and no student row directly.',
      v_teacher, v_expected, v_section;
  end if;

  if v_student is not null then
    -- A student cannot open the class view.
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      perform count(*) from public.teacher_class_status();
      execute 'reset role';
      raise exception 'PIA 0026 ABORT: a student could open the class view.' using errcode = 'P0001';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0026 OK: a student cannot open the class view.';
    end;

    -- A student's heartbeat is recorded by the server (rolled back).
    begin
      perform set_config('request.jwt.claims',
        json_build_object('email', v_student, 'role', 'authenticated',
                          'iat', extract(epoch from clock_timestamp())::bigint + 1)::text, true);
      execute 'set local role authenticated';
      perform public.touch_presence(true);
      execute 'reset role';
      if not exists (select 1 from public.student_presence where student_email = lower(v_student)) then
        raise exception 'PIA 0026 ABORT: touch_presence did not record the student.' using errcode = 'P0001';
      end if;
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0026 OK: a student''s heartbeat is recorded by the server.';
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260929_0027_student_single_active_session
-- ############################################################################

-- ============================================================================
-- PIA 0027 -- ONE ACTIVE SESSION PER STUDENT (THE LATEST SIGN-IN WINS)
-- ============================================================================
-- A student signed in on two devices at once can answer on one while reading
-- hints on the other, and both write to the same research rows. Until now a
-- second sign-in was REFUSED at the device limit (claim_device, max_devices),
-- which mostly punished the honest case: a lab PC closed without signing out.
--
-- Now, for STUDENTS ONLY, the newest sign-in takes over, like Spotify:
--
--   claim_student_session(p_device_id)
--     Called by the sign-in form (auth.js) right after the password check.
--     Records THIS auth session (the JWT's session_id claim) as the account's
--     only active one, and cuts every other device off at the database:
--       * sessions_revoked_at is stamped with this token's issue time, so
--         jwt_is_current() (0020-0024) refuses every older token at once --
--         in every RLS policy and every student function. A superseded device
--         cannot save one more answer, even before its page notices.
--       * the other devices' auth.sessions and refresh tokens are deleted, so
--         they cannot mint a fresh token that would pass that check.
--       * active_devices becomes this device alone, so the existing device
--         checks in function.js keep agreeing with the database.
--     This is the same cut reset_my_devices() (0025) makes, without the
--     email code: the password was just checked, and taking over your own
--     account is now the intended behaviour rather than an exception.
--
--   check_student_session()
--     The 10-second heartbeat asks this. It answers for the CALLER only:
--       'active'    carry on
--       'replaced'  another device signed in after this one
--       'revoked'   an admin used "Sign out everywhere"
--       'none'      no profile (account deleted) or no identity
--     Deliberately NOT refused for a stale token: a superseded device must
--     still be able to learn WHY it was cut off, so it can say so. It returns
--     nothing but that one word about the caller's own account.
--
-- TEACHERS AND ADMINS ARE UNTOUCHED. Both functions check the role on the
-- profile row and do nothing for staff: no stamp, no deleted sessions, and
-- check_student_session() always answers 'active'. Teachers keep the device
-- slots of claim_device(); admins keep no limit at all.
--
-- ACCOUNTS ALREADY SIGNED IN WHEN THIS RUNS have no active session yet. The
-- first heartbeat from such an account adopts its session as the active one,
-- so nobody is thrown out by the deploy itself; if a student happens to be on
-- two devices at that moment, the first to check in keeps the account.
--
-- A token without a session_id claim (only very old GoTrue versions issue
-- one) cannot be tracked, so it is never enforced against -- fail open for
-- availability. Every Supabase project today issues the claim.
--
-- STUDENTS CANNOT WRITE THE NEW COLUMNS. The profile write guard (0001) is a
-- whitelist, so a column added later is protected automatically. The
-- postflight proves it as a real student under RLS.
--
-- SAFE TO RE-RUN: columns are added only if missing, functions are replaced.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT -- the pieces this relies on.
-- ---------------------------------------------------------------------------
do $$
declare
  v_problems text := '';
begin
  if to_regprocedure('public.jwt_is_current()') is null then
    v_problems := v_problems || 'jwt_is_current() is missing (run 0020 first); ';
  end if;
  if to_regclass('auth.sessions') is null then
    v_problems := v_problems || 'auth.sessions is missing; ';
  end if;
  if to_regclass('auth.refresh_tokens') is null then
    v_problems := v_problems || 'auth.refresh_tokens is missing; ';
  end if;
  if v_problems = '' then
    if not has_table_privilege(current_user, 'auth.sessions', 'DELETE') then
      v_problems := v_problems || format('%s cannot DELETE from auth.sessions; ', current_user);
    end if;
    if not has_table_privilege(current_user, 'auth.refresh_tokens', 'DELETE') then
      v_problems := v_problems || format('%s cannot DELETE from auth.refresh_tokens; ', current_user);
    end if;
  end if;

  if v_problems <> '' then
    raise exception 'PIA 0027 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Columns.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists active_session_id uuid;
alter table public.profiles add column if not exists active_session_at timestamptz;

comment on column public.profiles.active_session_id is
  'Students only: the auth session (JWT session_id) that may use this account. '
  'Written by claim_student_session(); a newer sign-in replaces it (0027).';
comment on column public.profiles.active_session_at is
  'When active_session_id was last claimed (0027).';


-- ---------------------------------------------------------------------------
-- 2. The claim -- the sign-in form calls this right after the password check.
-- ---------------------------------------------------------------------------
create or replace function public.claim_student_session(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email  text   := auth.jwt() ->> 'email';
  v_uid    uuid   := nullif(auth.jwt() ->> 'sub', '')::uuid;
  v_sid    uuid   := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_iat    bigint := nullif(auth.jwt() ->> 'iat', '')::bigint;
  v_device text   := trim(coalesce(p_device_id, ''));
  v_role   text;
  v_active uuid;
begin
  if v_email is null or v_uid is null or v_iat is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  -- A token an admin already revoked may not take the account back.
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  if v_device = '' or length(v_device) > 120 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- FOR UPDATE: two sign-ins racing on one account are served one after the
  -- other, so exactly one of them ends up active. The role is read from the
  -- row itself -- the claim must work before anything else on the page does.
  select lower(trim(coalesce(p.role, 'student'))), p.active_session_id
    into v_role, v_active
    from public.profiles p
   where p.email = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- Staff are never limited to one session.
  if v_role in ('admin', 'teacher') then
    return jsonb_build_object('ok', true, 'enforced', false);
  end if;

  -- Cannot be tracked without the claim; let the sign-in through.
  if v_sid is null then
    return jsonb_build_object('ok', true, 'enforced', false);
  end if;

  -- Already the active session (a repeated call): nothing to cut off.
  if v_active is not distinct from v_sid then
    return jsonb_build_object('ok', true, 'enforced', true);
  end if;

  update public.profiles
     set active_session_id   = v_sid,
         active_session_at   = now(),
         -- Every token issued before this one is now stale; this one is not.
         sessions_revoked_at = greatest(coalesce(sessions_revoked_at, '-infinity'::timestamptz),
                                        to_timestamp(v_iat)),
         active_devices      = array[v_device]
   where email = v_email;

  -- The other devices lose their refresh tokens; this session stays.
  delete from auth.sessions
   where user_id = v_uid and id <> v_sid;
  delete from auth.refresh_tokens
   where user_id = v_uid::text and session_id is distinct from v_sid;

  return jsonb_build_object('ok', true, 'enforced', true);
end;
$$;

revoke all on function public.claim_student_session(text) from public, anon;
grant execute on function public.claim_student_session(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. The heartbeat check.
-- ---------------------------------------------------------------------------
create or replace function public.check_student_session()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email  text := auth.jwt() ->> 'email';
  v_sid    uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_role   text;
  v_active uuid;
begin
  if v_email is null then
    return jsonb_build_object('status', 'none');
  end if;

  select lower(trim(coalesce(p.role, 'student'))), p.active_session_id
    into v_role, v_active
    from public.profiles p
   where p.email = v_email;

  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  if v_role in ('admin', 'teacher') then
    return jsonb_build_object('status', 'active');
  end if;

  -- Checked BEFORE the revocation test on purpose: a takeover also stamps
  -- sessions_revoked_at, and the student should be told the real reason.
  if v_active is not null and v_sid is not null and v_active <> v_sid then
    return jsonb_build_object('status', 'replaced');
  end if;

  if not public.jwt_is_current() then
    return jsonb_build_object('status', 'revoked');
  end if;

  -- Signed in before 0027 existed: adopt this session. "is null" in the
  -- WHERE keeps it first-come -- a second device checking in a moment later
  -- finds the slot taken and is told 'replaced' on its next beat.
  if v_active is null and v_sid is not null then
    update public.profiles
       set active_session_id = v_sid,
           active_session_at = now()
     where email = v_email and active_session_id is null;
  end if;

  return jsonb_build_object('status', 'active');
end;
$$;

revoke all on function public.check_student_session() from public, anon;
grant execute on function public.check_student_session() to authenticated;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- as a real student and a real teacher, under the
-- authenticated role. Every probe rolls back (P0002), including the session
-- deletes the claim performs.
-- ---------------------------------------------------------------------------
do $$
declare
  v_student text;
  v_uid     uuid;
  v_teacher text;
  v_tuid    uuid;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 1;
  v_sid_a   uuid   := gen_random_uuid();
  v_sid_b   uuid   := gen_random_uuid();
  v_res     jsonb;
  v_status  text;
  v_rows    int;
begin
  if has_function_privilege('anon', 'public.claim_student_session(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.check_student_session()', 'EXECUTE') then
    raise exception 'PIA 0027 ABORT: a session function is callable without signing in.' using errcode = 'P0001';
  end if;

  select p.email, u.id into v_student, v_uid
    from public.profiles p join auth.users u on lower(u.email) = lower(p.email)
   where lower(trim(coalesce(p.role, 'student'))) = 'student'
   order by p.email limit 1;

  if v_student is null then
    raise notice 'PIA 0027: no student with a sign-in account to probe with -- skipped.';
  else
    -- (a) Device A signs in, then device B: B is active, A is replaced, and
    --     A's older token is refused by jwt_is_current() everywhere.
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'sub', v_uid, 'role', 'authenticated',
        'iat', v_iat, 'session_id', v_sid_a)::text, true);
      execute 'set local role authenticated';
      perform public.claim_student_session('pia-0027-device-a');

      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'sub', v_uid, 'role', 'authenticated',
        'iat', v_iat + 5, 'session_id', v_sid_b)::text, true);
      perform public.claim_student_session('pia-0027-device-b');
      v_status := public.check_student_session() ->> 'status';
      if v_status <> 'active' then
        raise exception 'PIA 0027 ABORT: the newest sign-in reads as %, not active. Rolling back.', v_status
          using errcode = 'P0001';
      end if;

      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'sub', v_uid, 'role', 'authenticated',
        'iat', v_iat, 'session_id', v_sid_a)::text, true);
      v_status := public.check_student_session() ->> 'status';
      if v_status <> 'replaced' then
        raise exception 'PIA 0027 ABORT: the superseded device reads as %, not replaced. Rolling back.', v_status
          using errcode = 'P0001';
      end if;
      if public.jwt_is_current() then
        raise exception 'PIA 0027 ABORT: the superseded device''s token is still accepted. Rolling back.'
          using errcode = 'P0001';
      end if;
      execute 'reset role';
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0027 OK: the latest sign-in is active; the earlier device is told "replaced" and its token is refused.';
    end;

    -- (b) A student cannot write the new columns from the browser.
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'role', 'authenticated', 'iat', v_iat + 10)::text, true);
      execute 'set local role authenticated';
      update public.profiles
         set active_session_id = gen_random_uuid()
       where email = v_student;
      get diagnostics v_rows = row_count;
      execute 'reset role';
      if v_rows > 0 then
        raise exception 'PIA 0027 ABORT: a student can write active_session_id. Rolling back.'
          using errcode = 'P0001';
      end if;
      raise notice 'PIA 0027: the write probe matched no row (RLS hid it), so the guard could not be exercised.';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0027 OK: a student writing active_session_id is refused (42501).';
    end;
  end if;

  -- (c) A teacher is never limited: the claim changes nothing and the check
  --     always answers active.
  select p.email, u.id into v_teacher, v_tuid
    from public.profiles p join auth.users u on lower(u.email) = lower(p.email)
   where lower(trim(p.role)) = 'teacher'
   order by p.email limit 1;

  if v_teacher is null then
    raise notice 'PIA 0027: no teacher with a sign-in account to probe with -- skipped.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_teacher, 'sub', v_tuid, 'role', 'authenticated',
        'iat', v_iat, 'session_id', v_sid_a)::text, true);
      execute 'set local role authenticated';
      v_res := public.claim_student_session('pia-0027-teacher');
      v_status := public.check_student_session() ->> 'status';
      execute 'reset role';
      if (v_res ->> 'enforced')::boolean or v_status <> 'active' then
        raise exception 'PIA 0027 ABORT: a teacher was put under the one-session rule. Rolling back.'
          using errcode = 'P0001';
      end if;
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0027 OK: teachers stay multi-device.';
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report -- what the SQL editor shows after running.
select p.oid::regprocedure::text as function,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 'callable by signed-in users' else 'locked' end as browser_access,
       case when has_function_privilege('anon', p.oid, 'EXECUTE')
            then 'OPEN TO ANON' else 'not anon' end as anon_access
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('claim_student_session', 'check_student_session')
 order by 1;


-- ############################################################################
-- MIGRATION 20260929_0028_math_task_bank
-- ############################################################################

-- ============================================================================
-- PIA 0028 -- MATH TASK BANK (question_bank + app_config), ADMIN ONLY
-- ============================================================================
-- The admin console's new "Math Task" view manages sentence problems for
-- three topics -- EASY (finding a percentage), MEDIUM (percentage increase),
-- HARD (percentage decrease) -- each with a step-by-step breakdown and three
-- tiers of hints, plus the adaptive rules per topic. It was built by a team
-- member against their own Supabase project; these are its two tables,
-- created here with the SAME column names so rows exported from that project
-- import unchanged.
--
--   question_bank   one row per problem.
--     hint          TEXT holding JSON: {"defaultHint": "...", "steps": [
--                     {"prompt","answer","hint1","hint2","hint3"}, ...]}.
--                   Plain text from older rows is still accepted by the page.
--   app_config      exactly one row (id = 1): per-topic mastery threshold,
--                   questions to level up, wrong answers to level down, and
--                   one max_points for all topics.
--
-- ADMIN ONLY, READS INCLUDED. Every row carries its final answer and every
-- step answer. A student who could SELECT this table would have the answer
-- key -- the leak AUDIT_answer_key_reachability.sql exists to catch. So
-- students and teachers get no access at all, and anon is revoked. When the
-- tutoring page starts serving these problems, it must do so through a
-- SECURITY DEFINER function that returns the problem without its answers,
-- the way serve_problem() and check_math_answer() already work.
--
-- NOT YET WIRED TO STUDENTS. The tutoring dashboard still serves the
-- built-in algebra set (student/js/math-problems.js) and levels students up
-- with the server's own decision tree. Nothing saved here changes what a
-- student sees until that is built -- the console says so on the page.
--
-- SAFE TO RE-RUN: tables and columns are created only if missing, policies
-- are dropped and recreated, the config row is inserted only if absent.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0028 ABORT (nothing changed): pia_caller_role() / jwt_is_current() are missing -- run 0001 and 0020-0022 first.'
      using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. question_bank
-- ---------------------------------------------------------------------------
create table if not exists public.question_bank (
  id           bigint generated by default as identity primary key,
  difficulty   text        not null default 'EASY',
  question     text        not null default '',
  final_answer text        not null default '',
  hint         text,
  points       int         not null default 10,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- A table that already existed (made by hand) gets whatever it is missing.
alter table public.question_bank add column if not exists difficulty   text        not null default 'EASY';
alter table public.question_bank add column if not exists question     text        not null default '';
alter table public.question_bank add column if not exists final_answer text        not null default '';
alter table public.question_bank add column if not exists hint         text;
alter table public.question_bank add column if not exists points       int         not null default 10;
alter table public.question_bank add column if not exists created_at   timestamptz not null default now();
alter table public.question_bank add column if not exists updated_at   timestamptz not null default now();

-- The page validates these too; the database is what holds them. NOT VALID
-- keeps an existing table's odd rows from blocking the migration while every
-- new or edited row is still checked.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'question_bank_difficulty_check') then
    alter table public.question_bank add constraint question_bank_difficulty_check
      check (difficulty in ('EASY', 'MEDIUM', 'HARD')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'question_bank_points_check') then
    alter table public.question_bank add constraint question_bank_points_check
      check (points between 1 and 500) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'question_bank_text_len_check') then
    alter table public.question_bank add constraint question_bank_text_len_check
      check (length(question) <= 2000 and length(final_answer) <= 200
             and length(coalesce(hint, '')) <= 20000) not valid;
  end if;
end;
$$;

create index if not exists question_bank_difficulty_idx on public.question_bank (difficulty, id);

create or replace function public.pia_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists question_bank_touch on public.question_bank;
create trigger question_bank_touch
  before update on public.question_bank
  for each row execute function public.pia_touch_updated_at();


-- ---------------------------------------------------------------------------
-- 2. app_config -- one row
-- ---------------------------------------------------------------------------
create table if not exists public.app_config (
  id                   int primary key default 1,
  easy_mastery         int not null default 80,
  easy_max_errors      int not null default 3,
  easy_min_questions   int not null default 3,
  medium_mastery       int not null default 80,
  medium_max_errors    int not null default 3,
  medium_min_questions int not null default 3,
  hard_mastery         int not null default 80,
  hard_max_errors      int not null default 3,
  hard_min_questions   int not null default 3,
  max_points           int not null default 10,
  updated_at           timestamptz not null default now()
);

alter table public.app_config add column if not exists easy_mastery         int not null default 80;
alter table public.app_config add column if not exists easy_max_errors      int not null default 3;
alter table public.app_config add column if not exists easy_min_questions   int not null default 3;
alter table public.app_config add column if not exists medium_mastery       int not null default 80;
alter table public.app_config add column if not exists medium_max_errors    int not null default 3;
alter table public.app_config add column if not exists medium_min_questions int not null default 3;
alter table public.app_config add column if not exists hard_mastery         int not null default 80;
alter table public.app_config add column if not exists hard_max_errors      int not null default 3;
alter table public.app_config add column if not exists hard_min_questions   int not null default 3;
alter table public.app_config add column if not exists max_points           int not null default 10;
alter table public.app_config add column if not exists updated_at           timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_config_single_row') then
    alter table public.app_config add constraint app_config_single_row check (id = 1) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'app_config_ranges') then
    alter table public.app_config add constraint app_config_ranges check (
      easy_mastery   between 50 and 100 and medium_mastery   between 50 and 100 and hard_mastery   between 50 and 100
      and easy_max_errors    between 1 and 10 and medium_max_errors    between 1 and 10 and hard_max_errors    between 1 and 10
      and easy_min_questions between 1 and 10 and medium_min_questions between 1 and 10 and hard_min_questions between 1 and 10
      and max_points between 1 and 500
    ) not valid;
  end if;
end;
$$;

drop trigger if exists app_config_touch on public.app_config;
create trigger app_config_touch
  before update on public.app_config
  for each row execute function public.pia_touch_updated_at();

insert into public.app_config (id) values (1) on conflict (id) do nothing;


-- ---------------------------------------------------------------------------
-- 3. Access: admins only, for reading as well as writing.
-- ---------------------------------------------------------------------------
alter table public.question_bank enable row level security;
alter table public.app_config    enable row level security;

-- Anything else a hand-made table may have carried goes first.
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public' and tablename in ('question_bank', 'app_config')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end;
$$;

create policy question_bank_admin_all on public.question_bank
  for all to authenticated
  using      (public.pia_caller_role() = 'admin' and public.jwt_is_current())
  with check (public.pia_caller_role() = 'admin' and public.jwt_is_current());

create policy app_config_admin_all on public.app_config
  for all to authenticated
  using      (public.pia_caller_role() = 'admin' and public.jwt_is_current())
  with check (public.pia_caller_role() = 'admin' and public.jwt_is_current());

revoke all on public.question_bank from public, anon, authenticated;
revoke all on public.app_config    from public, anon, authenticated;
grant select, insert, update, delete on public.question_bank to authenticated;
grant select, insert, update         on public.app_config    to authenticated;

-- The id sequence, whatever it is called (identity or a hand-made serial).
do $$
declare v_seq text := pg_get_serial_sequence('public.question_bank', 'id');
begin
  if v_seq is not null then
    execute format('grant usage on sequence %s to authenticated', v_seq);
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- a real student and a real admin, under RLS. Rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_student text;
  v_admin   text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 1;
  v_rows    int;
begin
  if has_table_privilege('anon', 'public.question_bank', 'SELECT') then
    raise exception 'PIA 0028 ABORT: anon can read question_bank.' using errcode = 'P0001';
  end if;

  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;
  select email into v_admin from public.profiles
   where lower(trim(role)) = 'admin' order by email limit 1;

  -- (a) A student sees no question and no config, and cannot write either.
  if v_student is not null then
    begin
      insert into public.question_bank (difficulty, question, final_answer, points)
      values ('EASY', 'pia-0028-probe', '42', 10);

      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';

      select count(*) into v_rows from public.question_bank;
      if v_rows > 0 then
        raise exception 'PIA 0028 ABORT: a student can read the question bank (answers included). Rolling back.'
          using errcode = 'P0001';
      end if;
      select count(*) into v_rows from public.app_config;
      if v_rows > 0 then
        raise exception 'PIA 0028 ABORT: a student can read app_config. Rolling back.' using errcode = 'P0001';
      end if;

      begin
        insert into public.question_bank (difficulty, question, final_answer, points)
        values ('EASY', 'pia-0028-student-write', '1', 10);
        raise exception 'PIA 0028 ABORT: a student can add questions. Rolling back.' using errcode = 'P0001';
      exception when insufficient_privilege then
        null;   -- refused by RLS, as it should be
      end;

      execute 'reset role';
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0028 OK: a student can neither read nor write the question bank or the config.';
    end;
  else
    raise notice 'PIA 0028: no student profile to probe with -- skipped.';
  end if;

  -- (b) An admin can add, read, change and delete.
  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';

      insert into public.question_bank (difficulty, question, final_answer, points)
      values ('HARD', 'pia-0028-admin-probe', '25%', 10);
      update public.question_bank set points = 20 where question = 'pia-0028-admin-probe';
      get diagnostics v_rows = row_count;
      if v_rows <> 1 then
        raise exception 'PIA 0028 ABORT: an admin cannot edit questions. Rolling back.' using errcode = 'P0001';
      end if;
      update public.app_config set max_points = 12 where id = 1;
      get diagnostics v_rows = row_count;
      if v_rows <> 1 then
        raise exception 'PIA 0028 ABORT: an admin cannot save the config. Rolling back.' using errcode = 'P0001';
      end if;
      delete from public.question_bank where question = 'pia-0028-admin-probe';

      execute 'reset role';
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0028 OK: an admin can add, edit and delete questions and save the config.';
    end;
  else
    raise notice 'PIA 0028: no admin profile to probe with -- skipped.';
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report
select 'question_bank' as "table", count(*) as rows from public.question_bank
union all
select 'app_config', count(*) from public.app_config;


-- ############################################################################
-- MIGRATION 20260929_0029_percentages_go_live
-- ############################################################################

-- ============================================================================
-- PIA 0029 -- THE TUTORING SESSION SERVES THE PERCENTAGES QUESTION BANK
-- ============================================================================
-- The study topic is Percentages: Topic 1 Finding a percentage (EASY),
-- Topic 2 Percentage increase (MEDIUM), Topic 3 Percentage decrease (HARD).
-- The algebra set (student/js/math-problems.js with math_answers/math_hints)
-- is retired; the student dashboard now takes every question from
-- question_bank (0028), chosen by the server.
--
-- WHAT THE BROWSER CAN AND CANNOT SEE
--   question_bank stays admin-only (0028). Every student call below is a
--   SECURITY DEFINER function, and none of them returns a final answer or a
--   step answer while the question is open:
--     serve_next_question   the problem statement, counts, and the hints the
--                           student has ALREADY taken (so a reload shows them)
--     consume_question_hint the next hint, counted
--     check_question_answer right/wrong and attempts left -- never the key
--     reveal_question_solution  the answer and worked steps, only once the
--                           question is closed (solved, or both tries used)
--   The question is copied into served_questions when it is served, so an
--   admin editing or deleting it mid-lesson cannot change what the student
--   is graded against. That table has no grants at all.
--
-- HINTS: THREE TIERS PER STEP, IN ORDER
--   Step 1 Concept, Setup, Worked calculation; then Step 2 ...; empty tiers are
--   skipped. An older question with only a plain-text hint gives that one
--   hint. Each hint comes with its step's prompt (never its answer). Hints
--   are counted in hint_consumptions exactly as before, so the smooth /
--   struggling classification keeps its meaning.
--
-- TOPIC PROGRESSION: THE ADMIN'S RULES (app_config), NOT THE OLD TREE
--   The algebra "decision tree" (3 smooth -> up, 2 struggling -> down) is not
--   used for these sessions. Instead, after each question:
--     * UP one topic when, in the current topic, the student has SOLVED at
--       least "Solved to level up" (min_questions) questions AND accuracy is
--       at least the mastery threshold (correct / answered, in this topic).
--     * DOWN one topic when wrong answers in the current topic reach "Wrong
--       to level down" (max_errors). On Topic 1 there is nowhere lower, so the
--       count starts afresh instead ('floor_reset').
--     * Up is checked before down. Counting starts over whenever the topic
--       changes. "Correct" = solved within the two tries (hints allowed);
--       "wrong" = both tries used without the answer.
--   Progress belongs to the STUDENT, not to one session: the next session
--   starts on the topic the last one ended on. Every change is logged in
--   topic_changes with the rule values that applied, for the analysis.
--   The smooth/struggling classification is computed and stored exactly as
--   before (correct, no hint, one try, within 30 s).
--
-- ANSWER MATCHING
--   Commas are ignored; when the key holds one number, the answer must hold
--   exactly one number and it must be equal ("25", "25%", "25 %" all match
--   "25%"; "0.25" does not). A key with no number is compared as text.
--
-- LEFT IN PLACE, BUT DISCONNECTED: the algebra functions (serve_problem,
-- consume_hint, reveal_solution, record_problem_result_v2, check_math_answer)
-- and their tables keep their data; signed-in users can no longer call them.
-- Earlier sessions' records are untouched. The teacher monitor (0026) also
-- counts answers from the new attempt table as activity.
--
-- The postflight runs a whole lesson as a real student under RLS -- serve,
-- hint, wrong, right, level up, level down, reveal -- asserting at every step
-- that no answer reaches the browser. Everything it does is rolled back.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_problems text := '';
  t          text;
begin
  foreach t in array array['question_bank', 'app_config', 'problem_serves',
                           'hint_consumptions', 'tutoring_attempts'] loop
    if to_regclass('public.' || t) is null then
      v_problems := v_problems || 'public.' || t || ' is missing; ';
    end if;
  end loop;
  if to_regprocedure('public.start_game_session()') is null then
    v_problems := v_problems || 'start_game_session() is missing; ';
  end if;
  if to_regprocedure('public.teacher_class_status()') is null then
    v_problems := v_problems || 'teacher_class_status() is missing (run 0026 first); ';
  end if;
  if v_problems <> '' then
    raise exception 'PIA 0029 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Tables. None has a grant: only the functions below touch them, except
--    the two an admin may read for the analysis.
-- ---------------------------------------------------------------------------
create table if not exists public.served_questions (
  session_id     uuid        not null,
  student_email  text        not null,
  problem_id     text        not null,           -- 'qb-<question_bank.id>'
  problem_number int         not null,
  question_id    bigint      not null,
  topic          int         not null,           -- the question's topic
  student_topic  int         not null,           -- the student's topic when served
  question       text        not null,
  final_answer   text        not null,
  steps          jsonb       not null default '[]'::jsonb,
  default_hint   text,
  served_at      timestamptz not null default now(),
  primary key (session_id, problem_id)
);
create index if not exists served_questions_student_idx on public.served_questions (student_email, question_id);

create table if not exists public.question_attempts (
  id             bigint generated always as identity primary key,
  session_id     uuid        not null,
  student_email  text        not null,
  problem_id     text        not null,
  attempt_number int         not null check (attempt_number between 1 and 2),
  submitted      text        not null,
  was_correct    boolean     not null,
  attempted_at   timestamptz not null default now(),
  unique (session_id, student_email, problem_id, attempt_number)
);

create table if not exists public.student_topic_progress (
  student_email  text primary key,
  topic          int  not null default 1 check (topic between 1 and 3),
  stint_answered int  not null default 0,
  stint_correct  int  not null default 0,
  stint_wrong    int  not null default 0,
  updated_at     timestamptz not null default now()
);

create table if not exists public.topic_changes (
  id             bigint generated always as identity primary key,
  student_email  text        not null,
  session_id     uuid,
  problem_number int,
  from_topic     int         not null,
  to_topic       int         not null,
  reason         text        not null,           -- mastered | error_limit | floor_reset
  stint_answered int         not null,
  stint_correct  int         not null,
  stint_wrong    int         not null,
  mastery        int         not null,
  min_solved     int         not null,
  max_errors     int         not null,
  changed_at     timestamptz not null default now()
);
create index if not exists topic_changes_student_idx on public.topic_changes (student_email, changed_at);

alter table public.served_questions       enable row level security;
alter table public.question_attempts      enable row level security;
alter table public.student_topic_progress enable row level security;
alter table public.topic_changes          enable row level security;

revoke all on public.served_questions       from public, anon, authenticated;
revoke all on public.question_attempts      from public, anon, authenticated;
revoke all on public.student_topic_progress from public, anon, authenticated;
revoke all on public.topic_changes          from public, anon, authenticated;

-- Progress and topic changes are research data: readable by admins only.
drop policy if exists student_topic_progress_admin_read on public.student_topic_progress;
create policy student_topic_progress_admin_read on public.student_topic_progress
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());
drop policy if exists topic_changes_admin_read on public.topic_changes;
create policy topic_changes_admin_read on public.topic_changes
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());
grant select on public.student_topic_progress to authenticated;
grant select on public.topic_changes          to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Helpers (not callable from the browser)
-- ---------------------------------------------------------------------------

-- question_bank.hint is TEXT holding {"defaultHint", "steps": [...]}; older
-- rows hold a plain sentence.
create or replace function public.pia_parse_hint(p_hint text)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare j jsonb;
begin
  if p_hint is null or trim(p_hint) = '' then
    return jsonb_build_object('defaultHint', '', 'steps', '[]'::jsonb);
  end if;
  begin
    j := p_hint::jsonb;
  exception when others then
    return jsonb_build_object('defaultHint', p_hint, 'steps', '[]'::jsonb);
  end;
  if jsonb_typeof(j) <> 'object' then
    return jsonb_build_object('defaultHint', p_hint, 'steps', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'defaultHint', coalesce(j ->> 'defaultHint', ''),
    'steps', case when jsonb_typeof(j -> 'steps') = 'array' then j -> 'steps' else '[]'::jsonb end);
end;
$$;

-- The hints of one question, in the order they are given.
create or replace function public.pia_question_hint_list(p_steps jsonb, p_default text)
returns table (idx int, step int, steps_total int, tier int, step_prompt text, hint text)
language plpgsql
immutable
set search_path = public
as $$
declare
  v_steps jsonb := case when jsonb_typeof(p_steps) = 'array' then p_steps else '[]'::jsonb end;
  v_total int;
  v_n     int := 0;
  v_step  jsonb;
  v_text  text;
  i       int;
  t       int;
begin
  v_total := jsonb_array_length(v_steps);
  for i in 0 .. v_total - 1 loop
    v_step := v_steps -> i;
    for t in 1 .. 3 loop
      v_text := nullif(trim(coalesce(v_step ->> ('hint' || t), '')), '');
      if v_text is not null then
        v_n := v_n + 1;
        idx := v_n;
        step := i + 1;
        steps_total := v_total;
        tier := t;
        step_prompt := nullif(trim(coalesce(v_step ->> 'prompt', '')), '');
        hint := v_text;
        return next;
      end if;
    end loop;
  end loop;

  if v_n = 0 and nullif(trim(coalesce(p_default, '')), '') is not null then
    idx := 1; step := null; steps_total := 0; tier := 1; step_prompt := null; hint := trim(p_default);
    return next;
  end if;
end;
$$;

create or replace function public.pia_tier_label(p_tier int)
returns text
language sql
immutable
as $$
  select case p_tier when 1 then 'Concept' when 2 then 'Setup' when 3 then 'Worked calculation' else 'Hint' end;
$$;

-- Does the student's answer match the key? See the header for the rule.
create or replace function public.pia_answer_matches(p_submitted text, p_key text)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  s      text := replace(lower(coalesce(p_submitted, '')), ',', '');
  k      text := replace(lower(coalesce(p_key, '')), ',', '');
  s_nums text[];
  k_nums text[];
  s_text text;
begin
  select array_agg(m[1]) into s_nums from regexp_matches(s, '(-?[0-9]*\.?[0-9]+)', 'g') as m;
  select array_agg(m[1]) into k_nums from regexp_matches(k, '(-?[0-9]*\.?[0-9]+)', 'g') as m;

  if coalesce(array_length(k_nums, 1), 0) = 1 then
    return coalesce(array_length(s_nums, 1), 0) = 1
       and abs(s_nums[1]::numeric - k_nums[1]::numeric) < 0.000001;
  end if;

  s_text := regexp_replace(s, '[^a-z0-9%.-]', '', 'g');
  return s_text <> '' and s_text = regexp_replace(k, '[^a-z0-9%.-]', '', 'g');
end;
$$;

-- The student's current topic; creates their progress row on first use.
create or replace function public.pia_student_topic(p_email text)
returns int
language plpgsql
set search_path = public
as $$
declare v_topic int;
begin
  insert into public.student_topic_progress (student_email) values (p_email)
  on conflict (student_email) do nothing;
  select topic into v_topic from public.student_topic_progress where student_email = p_email;
  return coalesce(v_topic, 1);
end;
$$;

-- What the browser receives about a served question: never an answer.
create or replace function public.pia_question_payload(p public.served_questions)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_total    int;
  v_used     int;
  v_attempts int;
  v_correct  boolean;
  v_hints    jsonb;
begin
  select count(*) into v_total from public.pia_question_hint_list(p.steps, p.default_hint);

  select count(*) into v_used
    from public.hint_consumptions h
   where h.session_id = p.session_id and h.student_email = p.student_email and h.problem_id = p.problem_id;

  select count(*), coalesce(bool_or(a.was_correct), false) into v_attempts, v_correct
    from public.question_attempts a
   where a.session_id = p.session_id and a.student_email = p.student_email and a.problem_id = p.problem_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'index', l.idx, 'step', l.step, 'steps_total', l.steps_total,
           'tier', l.tier, 'tier_label', public.pia_tier_label(l.tier),
           'step_prompt', l.step_prompt, 'text', l.hint) order by l.idx), '[]'::jsonb)
    into v_hints
    from public.pia_question_hint_list(p.steps, p.default_hint) l
   where l.idx <= v_used;

  return jsonb_build_object(
    'done',            false,
    'problem_id',      p.problem_id,
    'problem_number',  p.problem_number,
    'question',        p.question,
    'topic',           p.student_topic,
    'question_topic',  p.topic,
    'hints_total',     v_total,
    'hints_used',      v_used,
    'hints_left',      greatest(v_total - v_used, 0),
    'hints',           v_hints,
    'attempts_used',   v_attempts,
    'attempts_left',   case when v_correct then 0 else greatest(2 - v_attempts, 0) end,
    'locked',          v_correct or v_attempts >= 2);
end;
$$;

-- The recorded outcome of one question, rebuilt from the stored rows.
create or replace function public.pia_result_payload(p_session_id uuid, p_email text, p_problem_id text)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  t        record;
  v_reason text;
  v_streak int := 0;
  v_count  int;
  r        record;
begin
  select * into t from public.tutoring_attempts
   where session_id = p_session_id and student_email = p_email and problem_id = p_problem_id;
  if not found then return null; end if;

  select c.reason into v_reason from public.topic_changes c
   where c.session_id = p_session_id and c.student_email = p_email and c.problem_number = t.problem_number
   order by c.id desc limit 1;

  for r in select a.is_correct from public.tutoring_attempts a
            where a.session_id = p_session_id and a.student_email = p_email and a.problem_id like 'qb-%'
            order by a.problem_number desc loop
    exit when not r.is_correct;
    v_streak := v_streak + 1;
  end loop;

  select count(*) into v_count from public.tutoring_attempts a
   where a.session_id = p_session_id and a.student_email = p_email and a.problem_id like 'qb-%';

  return jsonb_build_object(
    'is_correct',        t.is_correct,
    'classification',    t.classification,
    'attempts_used',     t.attempts_used,
    'hints_used',        t.hints_used,
    'time_taken_ms',     t.time_taken_ms,
    'topic_before',      t.level_before,
    'topic',             t.level_after,
    'topic_change',      case when t.level_after > t.level_before then 'up'
                              when t.level_after < t.level_before then 'down' end,
    'reason',            v_reason,
    'streak',            v_streak,
    'problems_answered', v_count);
end;
$$;

revoke all on function public.pia_parse_hint(text)                              from public, anon, authenticated;
revoke all on function public.pia_question_hint_list(jsonb, text)               from public, anon, authenticated;
revoke all on function public.pia_answer_matches(text, text)                    from public, anon, authenticated;
revoke all on function public.pia_student_topic(text)                           from public, anon, authenticated;
revoke all on function public.pia_question_payload(public.served_questions)     from public, anon, authenticated;
revoke all on function public.pia_result_payload(uuid, text, text)              from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. The student's calls
-- ---------------------------------------------------------------------------

-- The next question for this session, picked by the server: the student's
-- topic first, then questions this student has seen least, then at random.
-- A question still open comes back unchanged, so a reload cannot swap a hard
-- question for an easier one.
create or replace function public.serve_next_question(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email    text := auth.jwt() ->> 'email';
  c_target   constant int := 10;       -- SESSION_TARGET in student-dashboard.js
  v_sq       public.served_questions%rowtype;
  v_answered int;
  v_topic    int;
  v_q        record;
  v_parsed   jsonb;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'student' then
    raise exception 'PIA: only students take lessons.' using errcode = '42501';
  end if;
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;

  -- One serve or record at a time per student.
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select sq.* into v_sq
    from public.served_questions sq
   where sq.session_id = p_session_id and sq.student_email = v_email
     and not exists (select 1 from public.tutoring_attempts t
                      where t.session_id = sq.session_id and t.student_email = sq.student_email
                        and t.problem_id = sq.problem_id)
   order by sq.problem_number desc
   limit 1;

  if found then
    return public.pia_question_payload(v_sq);
  end if;

  select count(*) into v_answered
    from public.tutoring_attempts t
   where t.session_id = p_session_id and t.student_email = v_email and t.problem_id like 'qb-%';

  if v_answered >= c_target then
    return jsonb_build_object('done', true, 'reason', 'target', 'problems_answered', v_answered);
  end if;

  v_topic := public.pia_student_topic(v_email);

  select q.id, q.question, q.final_answer, q.hint,
         case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end as topic
    into v_q
    from public.question_bank q
   where upper(q.difficulty) in ('EASY', 'MEDIUM', 'HARD')
     and trim(coalesce(q.question, '')) <> ''
     and trim(coalesce(q.final_answer, '')) <> ''
     and not exists (select 1 from public.served_questions s
                      where s.session_id = p_session_id and s.student_email = v_email
                        and s.question_id = q.id)
   order by abs((case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end) - v_topic),
            (select count(*) from public.served_questions s2
              where s2.student_email = v_email and s2.question_id = q.id),
            random()
   limit 1;

  if not found then
    return jsonb_build_object('done', true, 'reason', 'bank_empty', 'problems_answered', v_answered);
  end if;

  v_parsed := public.pia_parse_hint(v_q.hint);

  insert into public.served_questions (
    session_id, student_email, problem_id, problem_number, question_id,
    topic, student_topic, question, final_answer, steps, default_hint)
  values (
    p_session_id, v_email, 'qb-' || v_q.id, v_answered + 1, v_q.id,
    v_q.topic, v_topic, v_q.question, coalesce(v_q.final_answer, ''),
    v_parsed -> 'steps', nullif(v_parsed ->> 'defaultHint', ''))
  returning * into v_sq;

  -- The serve stamp that timing (and the teacher monitor) already use.
  insert into public.problem_serves (session_id, student_email, problem_id, problem_number)
  values (p_session_id, v_email, v_sq.problem_id, v_sq.problem_number)
  on conflict (session_id, problem_id) do nothing;

  return public.pia_question_payload(v_sq);
end;
$$;


create or replace function public.check_question_answer(p_session_id uuid, p_problem_id text, p_submitted text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sub     text := left(trim(coalesce(p_submitted, '')), 60);
  v_sq      public.served_questions%rowtype;
  v_used    int;
  v_ok      boolean;
  v_correct boolean;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if v_sub = '' then
    raise exception 'PIA: an answer is required.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  select count(*), coalesce(bool_or(was_correct), false) into v_used, v_ok
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- Closed: solved, both tries used, or already recorded. Nothing is checked.
  if v_ok or v_used >= 2 or exists (
       select 1 from public.tutoring_attempts t
        where t.session_id = p_session_id and t.student_email = v_email and t.problem_id = p_problem_id) then
    return jsonb_build_object('correct', v_ok, 'attempts_used', v_used, 'attempts_left', 0, 'locked', true);
  end if;

  v_correct := public.pia_answer_matches(v_sub, v_sq.final_answer);

  insert into public.question_attempts (session_id, student_email, problem_id, attempt_number, submitted, was_correct)
  values (p_session_id, v_email, p_problem_id, v_used + 1, v_sub, v_correct);

  return jsonb_build_object(
    'correct',       v_correct,
    'attempts_used', v_used + 1,
    'attempts_left', case when v_correct then 0 else greatest(1 - v_used, 0) end,
    'locked',        v_correct or v_used + 1 >= 2);
end;
$$;


create or replace function public.consume_question_hint(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_sq    public.served_questions%rowtype;
  v_total int;
  v_used  int;
  v_att   int;
  v_ok    boolean;
  l       record;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  select count(*) into v_used from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select count(*) into v_total from public.pia_question_hint_list(v_sq.steps, v_sq.default_hint);

  select count(*), coalesce(bool_or(was_correct), false) into v_att, v_ok
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- A closed question takes no more hints; its worked solution comes from
  -- reveal_question_solution().
  if v_ok or v_att >= 2 then
    return jsonb_build_object('hint', null, 'hints_used', v_used, 'hints_left', 0,
                              'exhausted', true, 'locked', true);
  end if;

  if v_used >= v_total then
    return jsonb_build_object('hint', null, 'hints_used', v_used, 'hints_left', 0,
                              'exhausted', true, 'locked', false);
  end if;

  select * into l from public.pia_question_hint_list(v_sq.steps, v_sq.default_hint) h
   where h.idx = v_used + 1;

  insert into public.hint_consumptions (session_id, student_email, problem_id, hint_index)
  values (p_session_id, v_email, p_problem_id, v_used + 1)
  on conflict do nothing;

  return jsonb_build_object(
    'hint', jsonb_build_object(
      'index', l.idx, 'step', l.step, 'steps_total', l.steps_total,
      'tier', l.tier, 'tier_label', public.pia_tier_label(l.tier),
      'step_prompt', l.step_prompt, 'text', l.hint),
    'hints_used', v_used + 1,
    'hints_left', v_total - v_used - 1,
    'exhausted',  v_used + 1 >= v_total,
    'locked',     false);
end;
$$;


create or replace function public.reveal_question_solution(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  v_sq    public.served_questions%rowtype;
  v_att   int;
  v_ok    boolean;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  select count(*), coalesce(bool_or(was_correct), false) into v_att, v_ok
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- The gate: without it this would be the answer leak.
  if not (v_ok or v_att >= 2) then
    raise exception 'PIA: this question is not finished yet.' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'final_answer', v_sq.final_answer,
    'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                       'step', e.ord, 'prompt', e.s ->> 'prompt',
                       'answer', e.s ->> 'answer', 'worked', e.s ->> 'hint3') order by e.ord), '[]'::jsonb)
                from jsonb_array_elements(v_sq.steps) with ordinality as e(s, ord)));
end;
$$;


-- Records a closed question -- everything derived on the server -- and
-- applies the topic rules. Safe to call twice: the second call returns the
-- first result.
create or replace function public.record_question_result(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sq      public.served_questions%rowtype;
  v_att     int;
  v_ok      boolean;
  v_last    timestamptz;
  v_hints   int;
  v_served  timestamptz;
  v_ms      bigint;
  v_class   text;
  v_cfg     public.app_config%rowtype;
  v_prog    public.student_topic_progress%rowtype;
  v_mastery int;
  v_min     int;
  v_maxerr  int;
  v_from    int;
  v_to      int;
  v_reason  text;
  v_a       int;
  v_c       int;
  v_w       int;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if not found then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  if exists (select 1 from public.tutoring_attempts
              where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) then
    return public.pia_result_payload(p_session_id, v_email, p_problem_id);
  end if;

  -- (a) Attempts and correctness -- written only by check_question_answer.
  select count(*), coalesce(bool_or(was_correct), false), max(attempted_at)
    into v_att, v_ok, v_last
    from public.question_attempts
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if not (v_ok or v_att >= 2) then
    raise exception 'PIA: answer this question first.' using errcode = '42501';
  end if;

  -- (b) Hints -- the server's own count.
  select count(*) into v_hints from public.hint_consumptions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  -- (c) Time -- from the serve stamp, never the browser's clock.
  select served_at into v_served from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;
  if v_served is null then
    raise exception 'PIA: this question was not served.' using errcode = '42501';
  end if;
  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  -- (d) Classification -- the same rule as every earlier session.
  v_class := case when v_ok and v_hints = 0 and v_att <= 1 and v_ms <= 30000
                  then 'smooth' else 'struggling' end;

  -- (e) Topic -- the admin's rules for the student's CURRENT topic.
  select * into v_cfg from public.app_config where id = 1;

  insert into public.student_topic_progress (student_email) values (v_email)
  on conflict (student_email) do nothing;
  select * into v_prog from public.student_topic_progress where student_email = v_email for update;

  v_from := v_prog.topic;
  v_a := v_prog.stint_answered + 1;
  v_c := v_prog.stint_correct + case when v_ok then 1 else 0 end;
  v_w := v_prog.stint_wrong + case when v_ok then 0 else 1 end;

  v_mastery := coalesce(case v_from when 1 then v_cfg.easy_mastery
                                    when 2 then v_cfg.medium_mastery
                                    else v_cfg.hard_mastery end, 80);
  v_min     := coalesce(case v_from when 1 then v_cfg.easy_min_questions
                                    when 2 then v_cfg.medium_min_questions
                                    else v_cfg.hard_min_questions end, 3);
  v_maxerr  := coalesce(case v_from when 1 then v_cfg.easy_max_errors
                                    when 2 then v_cfg.medium_max_errors
                                    else v_cfg.hard_max_errors end, 3);

  v_to := v_from;
  v_reason := null;
  if v_from < 3 and v_c >= v_min and v_c * 100 >= v_mastery * v_a then
    v_to := v_from + 1;
    v_reason := 'mastered';
  elsif v_w >= v_maxerr then
    if v_from > 1 then
      v_to := v_from - 1;
      v_reason := 'error_limit';
    else
      v_reason := 'floor_reset';
    end if;
  end if;

  if v_reason is not null then
    insert into public.topic_changes (
      student_email, session_id, problem_number, from_topic, to_topic, reason,
      stint_answered, stint_correct, stint_wrong, mastery, min_solved, max_errors)
    values (
      v_email, p_session_id, v_sq.problem_number, v_from, v_to, v_reason,
      v_a, v_c, v_w, v_mastery, v_min, v_maxerr);

    update public.student_topic_progress
       set topic = v_to, stint_answered = 0, stint_correct = 0, stint_wrong = 0, updated_at = now()
     where student_email = v_email;
  else
    update public.student_topic_progress
       set stint_answered = v_a, stint_correct = v_c, stint_wrong = v_w, updated_at = now()
     where student_email = v_email;
  end if;

  -- level_before / level_after now hold the TOPIC (1-3) for these rows.
  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, v_sq.problem_number,
    v_from, v_to, least(10, v_att), least(10, v_hints),
    v_ms, v_ok, v_class)
  on conflict (session_id, problem_number) do nothing;

  return public.pia_result_payload(p_session_id, v_email, p_problem_id);
end;
$$;


-- Resume only a PERCENTAGES session: an unfinished algebra session is left
-- where it is, and the student starts fresh.
create or replace function public.resume_or_start_game_session()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email    text := auth.jwt() ->> 'email';
  v_session  uuid;
  v_answered int;
  v_correct  int;
  v_pending  text;
  v_streak   int := 0;
  r          record;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  select ps.session_id into v_session
    from public.problem_serves ps
   where ps.student_email = v_email and ps.problem_id like 'qb-%'
   order by ps.served_at desc
   limit 1;

  if v_session is not null then
    select count(*), coalesce(count(*) filter (where is_correct), 0)
      into v_answered, v_correct
      from public.tutoring_attempts
     where session_id = v_session and student_email = v_email and problem_id like 'qb-%';

    if v_answered < 10 then
      select sq.problem_id into v_pending
        from public.served_questions sq
       where sq.session_id = v_session and sq.student_email = v_email
         and not exists (select 1 from public.tutoring_attempts t
                          where t.session_id = sq.session_id and t.student_email = sq.student_email
                            and t.problem_id = sq.problem_id)
       order by sq.problem_number desc
       limit 1;

      -- Time away is not time on task (as in 0016): the open question's
      -- clock restarts when the student comes back.
      if v_pending is not null then
        update public.problem_serves set served_at = now()
         where session_id = v_session and problem_id = v_pending;
      end if;

      for r in select a.is_correct from public.tutoring_attempts a
                where a.session_id = v_session and a.student_email = v_email and a.problem_id like 'qb-%'
                order by a.problem_number desc loop
        exit when not r.is_correct;
        v_streak := v_streak + 1;
      end loop;

      return jsonb_build_object(
        'session_id',          v_session,
        'resumed',             true,
        'problems_answered',   v_answered,
        'correct_count',       v_correct,
        'topic',               public.pia_student_topic(v_email),
        'consecutive_correct', v_streak,
        'pending_problem_id',  v_pending);
    end if;
  end if;

  return jsonb_build_object(
    'session_id',          public.start_game_session(),
    'resumed',             false,
    'problems_answered',   0,
    'correct_count',       0,
    'topic',               public.pia_student_topic(v_email),
    'consecutive_correct', 0,
    'pending_problem_id',  null);
end;
$$;

revoke all on function public.serve_next_question(uuid)                   from public, anon;
revoke all on function public.check_question_answer(uuid, text, text)     from public, anon;
revoke all on function public.consume_question_hint(uuid, text)           from public, anon;
revoke all on function public.reveal_question_solution(uuid, text)        from public, anon;
revoke all on function public.record_question_result(uuid, text)          from public, anon;
revoke all on function public.resume_or_start_game_session()              from public, anon;
grant execute on function public.serve_next_question(uuid)                to authenticated;
grant execute on function public.check_question_answer(uuid, text, text)  to authenticated;
grant execute on function public.consume_question_hint(uuid, text)        to authenticated;
grant execute on function public.reveal_question_solution(uuid, text)     to authenticated;
grant execute on function public.record_question_result(uuid, text)       to authenticated;
grant execute on function public.resume_or_start_game_session()           to authenticated;


-- ---------------------------------------------------------------------------
-- 4. Teacher monitor: answers in question_attempts count as activity.
--    Edited IN PLACE from the live definition (as 0022 did), one subquery
--    added; nothing else in it changes.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def    text := pg_get_functiondef('public.teacher_class_status()'::regprocedure);
  v_anchor text := '(select max(h.consumed_at) from public.hint_consumptions h';
  v_new    text;
begin
  if position('question_attempts' in v_def) > 0 then
    raise notice 'PIA 0029: teacher_class_status already reads question_attempts.';
    return;
  end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'PIA 0029 ABORT: teacher_class_status has changed shape; cannot add the new activity source.'
      using errcode = 'P0001';
  end if;

  v_new := replace(v_def, v_anchor,
    '(select max(q.attempted_at) from public.question_attempts q' || chr(10) ||
    '                 where q.session_id = v_session and lower(q.student_email) = lower(r.email)),' || chr(10) ||
    '               ' || v_anchor);
  execute v_new;
  raise notice 'PIA 0029: teacher_class_status now counts answers from question_attempts.';
end;
$$;


-- ---------------------------------------------------------------------------
-- 5. Disconnect the algebra set. The functions and their data stay; the
--    browser can no longer call them.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('serve_problem', 'consume_hint', 'reveal_solution',
                         'record_problem_result_v2', 'check_math_answer')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    raise notice 'PIA 0029: % is no longer callable from the browser.', r.sig;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- a whole lesson as a real student, rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_student text;
  v_uid     uuid;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_sid     uuid   := gen_random_uuid();
  v_p       jsonb;
  v_r       jsonb;
  v_h       jsonb;
  v_c       jsonb;
  v_pid     text;
  v_steps   text := '[{"prompt":"PIA probe step","answer":"0.4725","hint1":"probe concept","hint2":"probe setup","hint3":"probe worked"}]';
  i         int;
  v_blocked boolean;
begin
  foreach v_pid in array array['public.serve_next_question(uuid)', 'public.check_question_answer(uuid,text,text)',
                               'public.consume_question_hint(uuid,text)', 'public.reveal_question_solution(uuid,text)',
                               'public.record_question_result(uuid,text)'] loop
    if has_function_privilege('anon', v_pid, 'EXECUTE') then
      raise exception 'PIA 0029 ABORT: % is callable without signing in.', v_pid using errcode = 'P0001';
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.pia_question_payload(public.served_questions)', 'EXECUTE') then
    raise exception 'PIA 0029 ABORT: an internal helper is callable from the browser.' using errcode = 'P0001';
  end if;

  select p.email, u.id into v_student, v_uid
    from public.profiles p join auth.users u on lower(u.email) = lower(p.email)
   where lower(trim(coalesce(p.role, 'student'))) = 'student'
   order by p.email limit 1;

  if v_student is null then
    raise notice 'PIA 0029: no student with a sign-in account to rehearse with -- skipped.';
    return;
  end if;

  begin
    -- A known bank and known rules, for the rehearsal only.
    delete from public.question_bank;
    for i in 1 .. 3 loop
      insert into public.question_bank (difficulty, question, final_answer, hint, points)
      values ('EASY',   'PIA-0029 probe, topic one, number ' || i || '.',   '47.25%',
              '{"defaultHint":"probe concept","steps":' || v_steps || '}', 10),
             ('MEDIUM', 'PIA-0029 probe, topic two, number ' || i || '.',   '47.25%',
              '{"defaultHint":"probe concept","steps":' || v_steps || '}', 10);
    end loop;
    insert into public.app_config (id) values (1) on conflict (id) do nothing;
    update public.app_config
       set easy_mastery = 80, easy_min_questions = 3, easy_max_errors = 3,
           medium_mastery = 80, medium_min_questions = 3, medium_max_errors = 3
     where id = 1;
    delete from public.student_topic_progress where student_email = v_student;

    perform set_config('request.jwt.claims', json_build_object(
      'email', v_student, 'sub', v_uid, 'role', 'authenticated',
      'iat', v_iat, 'session_id', gen_random_uuid())::text, true);
    execute 'set local role authenticated';

    -- The snapshot and attempt tables are closed to the student.
    v_blocked := false;
    begin
      perform count(*) from public.served_questions;
    exception when insufficient_privilege then v_blocked := true;
    end;
    if not v_blocked then
      raise exception 'PIA 0029 ABORT: a student can read served_questions. Rolling back.' using errcode = 'P0001';
    end if;

    -- Q1: served in topic 1, with no answer anywhere in what comes back.
    v_p := public.serve_next_question(v_sid);
    if (v_p ->> 'done')::boolean or (v_p ->> 'question_topic') <> '1' then
      raise exception 'PIA 0029 ABORT: the first question was not a topic 1 question: %', v_p using errcode = 'P0001';
    end if;
    if v_p::text ~ '47\.25|0\.4725' then
      raise exception 'PIA 0029 ABORT: an answer reached the browser in serve_next_question: %', v_p using errcode = 'P0001';
    end if;
    v_pid := v_p ->> 'problem_id';

    if public.serve_next_question(v_sid) ->> 'problem_id' <> v_pid then
      raise exception 'PIA 0029 ABORT: asking again swapped the open question. Rolling back.' using errcode = 'P0001';
    end if;

    v_h := public.consume_question_hint(v_sid, v_pid);
    if v_h -> 'hint' ->> 'tier' <> '1' or v_h -> 'hint' ->> 'text' <> 'probe concept' or v_h::text ~ '47\.25|0\.4725' then
      raise exception 'PIA 0029 ABORT: the first hint is wrong or leaks an answer: %', v_h using errcode = 'P0001';
    end if;
    if public.serve_next_question(v_sid)::text ~ '47\.25|0\.4725' then
      raise exception 'PIA 0029 ABORT: an answer reached the browser after a hint. Rolling back.' using errcode = 'P0001';
    end if;

    v_blocked := false;
    begin
      perform public.reveal_question_solution(v_sid, v_pid);
    exception when insufficient_privilege then v_blocked := true;
    end;
    if not v_blocked then
      raise exception 'PIA 0029 ABORT: the solution was revealed before the question closed. Rolling back.' using errcode = 'P0001';
    end if;

    v_c := public.check_question_answer(v_sid, v_pid, '12');
    if (v_c ->> 'correct')::boolean or (v_c ->> 'attempts_left') <> '1' or v_c::text ~ '47\.25|0\.4725' then
      raise exception 'PIA 0029 ABORT: a wrong answer was handled wrongly: %', v_c using errcode = 'P0001';
    end if;
    v_c := public.check_question_answer(v_sid, v_pid, ' 47.25 ');
    if not (v_c ->> 'correct')::boolean then
      raise exception 'PIA 0029 ABORT: "47.25" did not match the key "47.25%%": %', v_c using errcode = 'P0001';
    end if;
    v_r := public.record_question_result(v_sid, v_pid);
    if not (v_r ->> 'is_correct')::boolean or v_r ->> 'classification' <> 'struggling' or v_r ->> 'topic' <> '1' then
      raise exception 'PIA 0029 ABORT: question 1 was recorded wrongly: %', v_r using errcode = 'P0001';
    end if;
    if public.record_question_result(v_sid, v_pid) ->> 'topic' <> '1' then
      raise exception 'PIA 0029 ABORT: recording twice changed the result. Rolling back.' using errcode = 'P0001';
    end if;

    -- Q2, Q3: right first time -> 3 solved, 100% >= 80% -> topic 2.
    for i in 2 .. 3 loop
      v_p := public.serve_next_question(v_sid);
      if (v_p ->> 'question_topic') <> '1' then
        raise exception 'PIA 0029 ABORT: question % was not topic 1: %', i, v_p using errcode = 'P0001';
      end if;
      v_pid := v_p ->> 'problem_id';
      perform public.check_question_answer(v_sid, v_pid, '47.25%');
      v_r := public.record_question_result(v_sid, v_pid);
    end loop;
    if v_r ->> 'topic' <> '2' or v_r ->> 'topic_change' <> 'up' or v_r ->> 'reason' <> 'mastered' then
      raise exception 'PIA 0029 ABORT: mastering topic 1 did not move the student up: %', v_r using errcode = 'P0001';
    end if;

    -- Q4-Q6: topic 2, both tries wrong each time -> 3 wrong -> back to topic 1.
    for i in 4 .. 6 loop
      v_p := public.serve_next_question(v_sid);
      if (v_p ->> 'question_topic') <> '2' then
        raise exception 'PIA 0029 ABORT: question % was not topic 2: %', i, v_p using errcode = 'P0001';
      end if;
      v_pid := v_p ->> 'problem_id';
      perform public.check_question_answer(v_sid, v_pid, '1');
      perform public.check_question_answer(v_sid, v_pid, '2');
      v_c := public.check_question_answer(v_sid, v_pid, '47.25');
      if not (v_c ->> 'locked')::boolean or (v_c ->> 'correct')::boolean then
        raise exception 'PIA 0029 ABORT: a third try was checked: %', v_c using errcode = 'P0001';
      end if;
      v_r := public.record_question_result(v_sid, v_pid);
    end loop;
    if v_r ->> 'topic' <> '1' or v_r ->> 'topic_change' <> 'down' or v_r ->> 'reason' <> 'error_limit' then
      raise exception 'PIA 0029 ABORT: three wrong answers in topic 2 did not move the student down: %', v_r using errcode = 'P0001';
    end if;

    -- Closed: now the worked solution may be shown.
    v_r := public.reveal_question_solution(v_sid, v_pid);
    if v_r ->> 'final_answer' <> '47.25%' then
      raise exception 'PIA 0029 ABORT: the closed question did not reveal its answer: %', v_r using errcode = 'P0001';
    end if;

    execute 'reset role';
    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0029 OK: a full lesson ran as a real student -- no answer reached the browser, topic 1 -> 2 on mastery, 2 -> 1 on the error limit.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report
select p.oid::regprocedure::text as function,
       case when has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 'callable by signed-in users' else 'locked' end as browser_access
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('serve_next_question', 'check_question_answer', 'consume_question_hint',
                     'reveal_question_solution', 'record_question_result', 'resume_or_start_game_session',
                     'serve_problem', 'consume_hint', 'reveal_solution', 'record_problem_result_v2',
                     'check_math_answer')
 order by 2, 1;


-- ############################################################################
-- MIGRATION 20260929_0030_revoke_device_ends_session
-- ############################################################################

-- ============================================================================
-- PIA 0030 -- REVOKING A DEVICE ENDS ITS SESSION, ON THE SERVER
-- ============================================================================
-- Until now a "device" was only a label in profiles.active_devices. Revoking
-- one removed the label; the login on that device kept working, because
-- nothing tied the label to the auth session that registered it, and no
-- policy or function ever read the list. The admin console's Revoke button
-- said "That session has been signed out", which was not true.
--
-- WHAT CHANGES
--   profiles.device_sessions   jsonb, { "<device id>": "<auth session id>" }.
--                              Written by claim_device() from the JWT's
--                              session_id claim, dropped by release_device().
--                              reset_my_devices() (0025) and
--                              claim_student_session() (0027), which also
--                              write the device list, keep it in step.
--   admin_revoke_device()      now ends the session recorded for each device
--                              it removes: the row in auth.sessions and its
--                              refresh tokens are deleted, so that browser can
--                              no longer renew its login.
--   jwt_is_current()           now also refuses a token whose session no
--                              longer exists in auth.sessions. Without this
--                              the revoked browser would keep working until
--                              its access token expired on its own (up to an
--                              hour). It is the one test every policy and
--                              every protected function already runs, so a
--                              deleted session is refused everywhere at once.
--
-- WHAT IT CANNOT DO
--   A device registered BEFORE this migration has no recorded session, so
--   revoking it can only remove it from the list. admin_revoke_device()
--   reports how many devices were in that position ("unbound") and the
--   console says so instead of claiming a kill. "Sign out everywhere"
--   (admin_revoke_sessions) still ends every session of an account and is
--   the way to reach those. Each device registers its session the next time
--   it loads a page, so the gap closes by itself.
--
-- ORDER. Apply this AFTER 0027 and 0029 if they have not been run yet: their
-- postflights rehearse a lesson with an invented session_id that does not
-- exist in auth.sessions, which the check above (correctly) refuses. This
-- migration's own postflight uses real sessions and rolls everything back.
--
-- ROLLBACK, if jwt_is_current() ever has to be put back as it was (0020):
--   the body is  v_iat := ...; select sessions_revoked_at ...;
--   return v_revoked is null or to_timestamp(v_iat) >= v_revoked;
--   i.e. this function without the auth.sessions test. The added column and
--   the other functions are harmless to leave in place.
--
-- SAFE TO RE-RUN.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_problems text := '';
  v_fn       text;
begin
  foreach v_fn in array array['public.jwt_is_current()', 'public.pia_caller_role()',
                              'public.claim_device(text)', 'public.release_device(text)',
                              'public.admin_revoke_device(text,text)'] loop
    if to_regprocedure(v_fn) is null then
      v_problems := v_problems || v_fn || ' is missing; ';
    end if;
  end loop;

  if to_regclass('auth.sessions') is null or to_regclass('auth.refresh_tokens') is null then
    v_problems := v_problems || 'auth.sessions / auth.refresh_tokens is missing; ';
  else
    if not has_table_privilege(current_user, 'auth.sessions', 'DELETE') then
      v_problems := v_problems || format('%s cannot DELETE from auth.sessions; ', current_user);
    end if;
    if not has_table_privilege(current_user, 'auth.sessions', 'SELECT') then
      v_problems := v_problems || format('%s cannot SELECT from auth.sessions; ', current_user);
    end if;
  end if;

  if v_problems <> '' then
    raise exception 'PIA 0030 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Which session registered which device.
--    Not on the student write whitelist (0001 is a whitelist), so a student
--    cannot edit it; the postflight proves that.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists device_sessions jsonb not null default '{}'::jsonb;

comment on column public.profiles.device_sessions is
  '{ device id: auth session id } for the devices in active_devices. Written by claim_device(); '
  'lets admin_revoke_device() end the session behind a device (0030).';


-- ---------------------------------------------------------------------------
-- 2. jwt_is_current -- the 0020 body, plus: the token's session must still
--    exist. A token without a session_id claim (very old tokens) is judged by
--    the revocation stamp alone, exactly as before.
-- ---------------------------------------------------------------------------
create or replace function public.jwt_is_current()
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_revoked timestamptz;
  v_iat     bigint;
  v_sid     uuid;
begin
  v_iat := nullif(auth.jwt() ->> 'iat', '')::bigint;
  if v_iat is null then return false; end if;

  select sessions_revoked_at into v_revoked from public.profiles where email = auth.jwt() ->> 'email';
  if v_revoked is not null and to_timestamp(v_iat) < v_revoked then return false; end if;

  begin
    v_sid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  exception when invalid_text_representation then
    v_sid := null;
  end;

  -- The session was deleted (a device revoked, "Sign out everywhere", an
  -- account removed): this token is finished, whatever its expiry says.
  if v_sid is not null and not exists (select 1 from auth.sessions s where s.id = v_sid) then
    return false;
  end if;

  return true;
end;
$function$;

grant execute on function public.jwt_is_current() to authenticated;


-- ---------------------------------------------------------------------------
-- 3. claim_device -- the production body, plus recording the session.
--    An already-known device refreshes its recorded session (a device that
--    signs in again has a new one).
-- ---------------------------------------------------------------------------
create or replace function public.claim_device(p_device_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sid     text := nullif(auth.jwt() ->> 'session_id', '');
  v_max     int;
  v_devices text[];
  v_map     jsonb;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- FOR UPDATE: two sign-ins racing on one account are served one after the other.
  select coalesce(p.max_devices, 1), coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_max, v_devices, v_map
    from public.profiles p
   where p.email = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- Known device: nothing to add (idempotent), but keep its session current.
  if p_device_id = any(v_devices) then
    if v_sid is not null and (v_map ->> p_device_id) is distinct from v_sid then
      update public.profiles
         set device_sessions = v_map || jsonb_build_object(p_device_id, v_sid)
       where email = v_email;
    end if;
    return jsonb_build_object('allowed', true, 'devices', v_devices, 'max', v_max);
  end if;

  if coalesce(array_length(v_devices, 1), 0) >= v_max then
    return jsonb_build_object(
      'allowed', false,
      'reason', v_max || ' device limit reached. Please sign out on your other device first.',
      'devices', v_devices, 'max', v_max);
  end if;

  update public.profiles
     set active_devices  = array_append(v_devices, p_device_id),
         device_sessions = case when v_sid is null then v_map
                                else v_map || jsonb_build_object(p_device_id, v_sid) end
   where email = v_email;

  return jsonb_build_object('allowed', true,
                            'devices', array_append(v_devices, p_device_id),
                            'max', v_max);
end;
$function$;

revoke all on function public.claim_device(text) from public, anon;
grant execute on function public.claim_device(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. release_device (sign-out) -- the 0020 body, plus forgetting the session.
--    It is deliberately not behind jwt_is_current(): a device that is being
--    signed out must still be able to free its slot.
-- ---------------------------------------------------------------------------
create or replace function public.release_device(p_device_id text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_email text := auth.jwt() ->> 'email';
begin
    if v_email is null then return; end if;
    update public.profiles
       set active_devices  = coalesce(array_remove(active_devices, p_device_id), '{}'),
           device_sessions = coalesce(device_sessions, '{}'::jsonb) - p_device_id
     where email = v_email;
end;
$function$;

grant execute on function public.release_device(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 5. admin_revoke_device -- removes the device AND ends its session.
--    p_device_id NULL removes every device of the account.
--    Returns { devices, removed, sessions_ended, unbound }.
-- ---------------------------------------------------------------------------
create or replace function public.admin_revoke_device(p_email text, p_device_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_devices text[];
  v_map     jsonb;
  v_new     text[];
  v_gone    text[];
  v_uid     uuid;
  v_sids    uuid[] := '{}';
  v_ended   int := 0;
  v_unbound int := 0;
  d         text;
  s         text;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'admin' then
    raise exception 'PIA: only an admin can revoke a device.' using errcode = '42501';
  end if;

  select coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_devices, v_map
    from public.profiles p
   where p.email = p_email
     for update;

  if not found then
    raise exception 'PIA: no profile for %', p_email using errcode = '22023';
  end if;

  if p_device_id is null then
    v_gone := v_devices;
    v_new  := '{}';
  else
    v_gone := array(select x from unnest(v_devices) x where x = p_device_id);
    v_new  := array(select x from unnest(v_devices) x where x is distinct from p_device_id);
  end if;

  -- The session behind each removed device, where one was recorded.
  foreach d in array v_gone loop
    s := v_map ->> d;
    if s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_sids := array_append(v_sids, s::uuid);
    else
      v_unbound := v_unbound + 1;
    end if;
    v_map := v_map - d;
  end loop;

  -- End them. Scoped to this account's own sessions, so a wrong id in the map
  -- can never sign anybody else out.
  select u.id into v_uid from auth.users u where lower(u.email) = lower(p_email) limit 1;

  if v_uid is not null and coalesce(array_length(v_sids, 1), 0) > 0 then
    with gone as (
      delete from auth.sessions where id = any(v_sids) and user_id = v_uid returning 1
    )
    select count(*) into v_ended from gone;

    delete from auth.refresh_tokens where session_id = any(v_sids) and user_id = v_uid::text;
  end if;

  update public.profiles
     set active_devices = v_new, device_sessions = v_map
   where email = p_email;

  return jsonb_build_object(
    'devices',        v_new,
    'removed',        coalesce(array_length(v_gone, 1), 0),
    'sessions_ended', v_ended,
    'unbound',        v_unbound);
end;
$$;

revoke all on function public.admin_revoke_device(text, text) from public, anon;
grant execute on function public.admin_revoke_device(text, text) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. The two functions that write the device list themselves keep the map in
--    step. Edited IN PLACE from their live definitions (as 0022 did), so
--    nothing else in them changes; a function that is not installed is
--    skipped.
-- ---------------------------------------------------------------------------
do $$
declare
  v_sig text;
  v_oid regprocedure;
  v_def text;
  v_new text;
begin
  foreach v_sig in array array['public.reset_my_devices(text)', 'public.claim_student_session(text)'] loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise notice 'PIA 0030: % is not installed -- skipped.', v_sig;
      continue;
    end if;

    v_def := pg_get_functiondef(v_oid);
    if position('device_sessions' in v_def) > 0 then
      raise notice 'PIA 0030: % already records its session.', v_sig;
      continue;
    end if;

    v_new := regexp_replace(v_def,
      'active_devices\s*=\s*array\[v_device\]',
      'active_devices = array[v_device], device_sessions = jsonb_build_object(v_device, v_sid::text)');

    if v_new = v_def then
      raise exception 'PIA 0030 ABORT: could not add session tracking to % (its body has changed shape).', v_sig
        using errcode = 'P0001';
    end if;

    execute v_new;
    raise notice 'PIA 0030: % now records its session.', v_sig;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- with REAL sessions, as real users, all rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_sid     uuid;
  v_uid     uuid;
  v_target  text;
  v_admin   text;
  v_student text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_res     jsonb;
  v_rows    int;
  v_left    text[];
  v_map     jsonb;
begin
  if has_function_privilege('anon', 'public.admin_revoke_device(text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.claim_device(text)', 'EXECUTE') then
    raise exception 'PIA 0030 ABORT: a device function is callable without signing in.' using errcode = 'P0001';
  end if;

  select p.email into v_admin from public.profiles p
   where lower(trim(p.role)) = 'admin' order by p.email limit 1;

  -- A real session, and the profile it belongs to.
  select s.id, s.user_id, p.email into v_sid, v_uid, v_target
    from auth.sessions s
    join auth.users u on u.id = s.user_id
    join public.profiles p on lower(p.email) = lower(u.email)
   order by s.created_at desc
   limit 1;

  if v_sid is null then
    raise notice 'PIA 0030: no live session to rehearse with -- the session tests are skipped.';
  else
    -- (a) A token is current while its session exists, and not after.
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_target, 'sub', v_uid, 'role', 'authenticated',
        'iat', v_iat, 'session_id', v_sid)::text, true);

      if not public.jwt_is_current() then
        raise exception 'PIA 0030 ABORT: a live session is refused by jwt_is_current(). Rolling back.'
          using errcode = 'P0001';
      end if;

      delete from auth.sessions where id = v_sid;

      if public.jwt_is_current() then
        raise exception 'PIA 0030 ABORT: a deleted session is still accepted. Rolling back.'
          using errcode = 'P0001';
      end if;
      raise exception 'probe done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0030 OK: a token is refused the moment its session is deleted.';
    end;

    -- (b) Revoking a device ends the session recorded for it -- and ONLY that one.
    if v_admin is null then
      raise notice 'PIA 0030: no admin profile -- the revoke test is skipped.';
    else
      begin
        update public.profiles
           set active_devices  = array['pia-0030-probe', 'pia-0030-other'],
               device_sessions = jsonb_build_object('pia-0030-probe', v_sid::text)
         where lower(email) = lower(v_target);

        perform set_config('request.jwt.claims', json_build_object(
          'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
        execute 'set local role authenticated';
        v_res := public.admin_revoke_device(v_target, 'pia-0030-probe');
        execute 'reset role';

        if (v_res ->> 'sessions_ended')::int <> 1 or (v_res ->> 'removed')::int <> 1 then
          raise exception 'PIA 0030 ABORT: revoke reported %. Rolling back.', v_res using errcode = 'P0001';
        end if;
        if exists (select 1 from auth.sessions where id = v_sid) then
          raise exception 'PIA 0030 ABORT: the revoked device''s session is still alive. Rolling back.'
            using errcode = 'P0001';
        end if;

        select p.active_devices, p.device_sessions into v_left, v_map
          from public.profiles p where lower(p.email) = lower(v_target);
        if v_left is distinct from array['pia-0030-other'] or v_map <> '{}'::jsonb then
          raise exception 'PIA 0030 ABORT: the device list after revoke is % / %. Rolling back.', v_left, v_map
            using errcode = 'P0001';
        end if;

        -- A device with no recorded session is removed and reported, not
        -- silently counted as killed.
        execute 'set local role authenticated';
        v_res := public.admin_revoke_device(v_target, 'pia-0030-other');
        execute 'reset role';
        if (v_res ->> 'sessions_ended')::int <> 0 or (v_res ->> 'unbound')::int <> 1 then
          raise exception 'PIA 0030 ABORT: an unbound device was reported as %. Rolling back.', v_res
            using errcode = 'P0001';
        end if;

        raise exception 'probe done' using errcode = 'P0002';
      exception
        when sqlstate 'P0002' then
          raise notice 'PIA 0030 OK: revoking a device ends its own session only; an unbound device is reported as unbound.';
      end;
    end if;
  end if;

  -- (c) A student cannot write the new column.
  select p.email into v_student from public.profiles p
   where lower(trim(coalesce(p.role, 'student'))) = 'student' order by p.email limit 1;

  if v_student is null then
    raise notice 'PIA 0030: no student profile -- the write-guard test is skipped.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';
      update public.profiles set device_sessions = '{"x":"y"}'::jsonb where email = v_student;
      get diagnostics v_rows = row_count;
      execute 'reset role';
      if v_rows > 0 then
        raise exception 'PIA 0030 ABORT: a student can write device_sessions. Rolling back.'
          using errcode = 'P0001';
      end if;
      raise notice 'PIA 0030: the write probe matched no row (RLS hid it), so the guard could not be exercised.';
    exception
      when insufficient_privilege then
        raise notice 'PIA 0030 OK: a student writing device_sessions is refused (42501).';
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report
select p.oid::regprocedure::text as function,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'OPEN TO ANON' else 'not anon' end as anon_access,
       case when pg_get_functiondef(p.oid) ~ 'device_sessions|auth\.sessions' then 'tracks sessions' else '-' end as session_aware
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('jwt_is_current', 'claim_device', 'release_device', 'admin_revoke_device',
                     'reset_my_devices', 'claim_student_session')
 order by 1;


-- ############################################################################
-- MIGRATION 20260929_0031_admin_boundaries_and_audit
-- ############################################################################

-- ============================================================================
-- PIA 0031 -- ADMINISTRATORS CANNOT ACT ON EACH OTHER; A SECURITY AUDIT LOG
-- ============================================================================
-- THE THREAT. One compromised administrator login could lock every other
-- administrator out: set their device limit to 1, revoke their devices,
-- demote them, change their email (and so where their password resets go),
-- or delete their accounts. Every one of those was possible, most of them
-- straight from the browser: the policy profiles_admin_all lets an admin
-- UPDATE and DELETE any profile row, and the profile write guard (0001)
-- waves admins through without looking.
--
-- THE RULE, enforced by the database:
--   A signed-in user -- through ANY path: a direct table write, a known RPC,
--   or a function created in the dashboard that this repo has never seen --
--   cannot change or delete ANOTHER administrator's profile, cannot promote
--   an existing account to administrator, and cannot change their own role.
--   An administrator can change their own max_devices, only within 2..10.
--
--   Who CAN: the project owner, from the Supabase dashboard (the SQL editor
--   or the service key). Those requests carry no signed-in user, so the rule
--   does not apply to them. That is the break-glass path, on purpose: its
--   protection is the Supabase account's own login, not this app's.
--
-- HOW:
--   1. pia_admin_boundaries -- a BEFORE trigger on profiles. Because it
--      guards the ROW, it covers every path at once. A refused change aborts
--      the whole statement, so an RPC that did other work first (deleted a
--      session, deleted answers) is rolled back with it.
--   2. pia_protect_admin_target(target, action) -- called at the top of the
--      five admin RPCs that name a target account. For admin_update_user_email
--      and admin_create_auth_user it is essential: they change the sign-in
--      account in auth.users, which the profiles trigger never sees. For the
--      other three it gives a clear message before any work is done. It is
--      inserted IN PLACE into each live definition (as 0022 did), so the
--      bodies -- several of which were created in the dashboard -- are not
--      retyped. Each function that is not installed is reported and skipped.
--   3. security_audit_log -- append-only. An AFTER trigger on profiles
--      records: accounts created (staff) and deleted (anyone), role changes,
--      device-limit changes, email changes, devices removed and sessions
--      revoked (on an administrator, or by someone other than the owner).
--      Administrators can read it; nobody can edit or delete it through the
--      API. Each row names the signed-in actor; no actor = the project owner.
--
--      REFUSED attempts cannot be kept in the table: a refusal aborts its own
--      transaction, and the log row would roll back with it. They are written
--      to the Postgres log instead (RAISE WARNING "PIA security: refused ...",
--      Supabase dashboard -> Logs -> Postgres), which is not rolled back.
--
-- EXISTING DATA. Administrator rows with max_devices below 2 are raised to 2.
--
-- SAFE TO RE-RUN. The postflight exercises every rule as a real admin under
-- RLS, against a temporary second administrator, and rolls everything back.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.pia_caller_role()') is null or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0031 ABORT (nothing changed): pia_caller_role() / jwt_is_current() are missing.'
      using errcode = 'P0001';
  end if;
  if to_regclass('public.profiles') is null then
    raise exception 'PIA 0031 ABORT (nothing changed): public.profiles is missing.' using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. The audit log
-- ---------------------------------------------------------------------------
create table if not exists public.security_audit_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  actor_email  text,                         -- null = the project owner (no signed-in user)
  actor_role   text,
  action       text not null,
  target_email text,
  detail       jsonb not null default '{}'::jsonb
);
create index if not exists security_audit_log_at_idx on public.security_audit_log (at desc);

alter table public.security_audit_log enable row level security;
revoke all on public.security_audit_log from public, anon, authenticated;
grant select on public.security_audit_log to authenticated;

drop policy if exists security_audit_log_admin_read on public.security_audit_log;
create policy security_audit_log_admin_read on public.security_audit_log
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());

comment on table public.security_audit_log is
  'Security-relevant changes to accounts (0031). Append-only: written by triggers, readable by admins.';


-- ---------------------------------------------------------------------------
-- 2. Existing data: administrators get at least two devices.
-- ---------------------------------------------------------------------------
update public.profiles
   set max_devices = 2
 where lower(trim(coalesce(role, ''))) = 'admin'
   and coalesce(max_devices, 1) < 2;


-- ---------------------------------------------------------------------------
-- 3. The boundary, on the row itself
-- ---------------------------------------------------------------------------
create or replace function public.pia_refuse(p_actor text, p_what text, p_target text)
returns void
language plpgsql
as $$
begin
  -- Survives the rollback the exception below causes: the Postgres log.
  raise warning 'PIA security: refused "%" by % on %', p_what, coalesce(p_actor, 'owner'), coalesce(p_target, '-');
  raise exception 'PIA: an administrator cannot %. Only the project owner can, from the Supabase dashboard.', p_what
    using errcode = '42501';
end;
$$;

create or replace function public.pia_admin_boundaries()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor   text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_old_adm boolean := false;
  v_new_adm boolean := false;
  v_self    boolean := false;
begin
  if tg_op <> 'INSERT' then
    v_old_adm := lower(trim(coalesce(old.role, ''))) = 'admin';
    v_self    := v_actor is not null and lower(old.email) = v_actor;
  end if;
  if tg_op <> 'DELETE' then
    v_new_adm := lower(trim(coalesce(new.role, ''))) = 'admin';
  end if;

  -- No signed-in user: the project owner (SQL editor, service key). Anything
  -- goes, except that an administrator keeps at least two devices.
  if v_actor is null then
    if tg_op <> 'DELETE' then
      if v_new_adm and coalesce(new.max_devices, 1) < 2 then new.max_devices := 2; end if;
      return new;
    end if;
    return old;
  end if;

  if tg_op = 'DELETE' then
    if v_old_adm then
      perform public.pia_refuse(v_actor, 'remove an administrator account', old.email);
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    -- "Add administrator" writes a NEW row; the limit floor applies to it.
    if v_new_adm and coalesce(new.max_devices, 1) < 2 then new.max_devices := 2; end if;
    return new;
  end if;

  -- UPDATE
  if v_old_adm and not v_self then
    if to_jsonb(new) is distinct from to_jsonb(old) then
      perform public.pia_refuse(v_actor, 'change another administrator''s account', old.email);
    end if;
    return new;
  end if;

  if v_old_adm and v_self then
    if not v_new_adm then
      perform public.pia_refuse(v_actor, 'change their own role', old.email);
    end if;
    if new.max_devices is distinct from old.max_devices
       and (new.max_devices is null or new.max_devices < 2 or new.max_devices > 10) then
      raise exception 'PIA: an administrator''s device limit must be between 2 and 10.' using errcode = '23514';
    end if;
    -- A direct write would leave the sign-in account on the old address.
    if current_user = 'authenticated' and new.email is distinct from old.email then
      perform public.pia_refuse(v_actor, 'change their own email here', old.email);
    end if;
    return new;
  end if;

  -- Not an admin row. Promotion makes a new administrator out of an existing
  -- participant or professor; new administrators come only from "Add
  -- administrator", which creates a fresh account.
  if v_new_adm then
    perform public.pia_refuse(v_actor, 'promote an existing account to administrator', old.email);
  end if;
  return new;
end;
$$;

-- Runs before the older write guard (triggers fire in name order), so an
-- admin's own refusal message is the one that comes back.
drop trigger if exists trg_admin_boundaries on public.profiles;
create trigger trg_admin_boundaries
  before insert or update or delete on public.profiles
  for each row execute function public.pia_admin_boundaries();


-- ---------------------------------------------------------------------------
-- 4. The audit trigger
-- ---------------------------------------------------------------------------
create or replace function public.pia_audit_profiles()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor  text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_arole  text;
  v_old    jsonb;
  v_new    jsonb;
  v_target text;
  v_owner  boolean;
  v_admin  boolean;
  v_gone   jsonb;
begin
  if v_actor is not null then v_arole := public.pia_caller_role(); end if;

  if tg_op = 'INSERT' then
    if lower(trim(coalesce(new.role, ''))) in ('admin', 'teacher') then
      insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
      values (v_actor, v_arole, 'account.created', new.email,
              jsonb_build_object('role', lower(trim(new.role))));
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'account.deleted', old.email,
            jsonb_build_object('role', lower(trim(coalesce(old.role, 'student')))));
    return old;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  v_target := new.email;
  v_owner := v_actor is not null and lower(old.email) = v_actor;
  v_admin := lower(trim(coalesce(old.role, ''))) = 'admin';

  if (v_old ->> 'role') is distinct from (v_new ->> 'role') then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'role.changed', v_target,
            jsonb_build_object('from', v_old ->> 'role', 'to', v_new ->> 'role'));
  end if;

  if (v_old -> 'max_devices') is distinct from (v_new -> 'max_devices') then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'device_limit.changed', v_target,
            jsonb_build_object('from', v_old -> 'max_devices', 'to', v_new -> 'max_devices'));
  end if;

  if (v_old ->> 'email') is distinct from (v_new ->> 'email') then
    insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
    values (v_actor, v_arole, 'email.changed', v_target,
            jsonb_build_object('from', v_old ->> 'email', 'to', v_new ->> 'email'));
  end if;

  -- Ordinary sign-ins and sign-outs change these on every student's own row;
  -- only an administrator's row, or someone else acting on the row, is logged.
  if v_admin or not v_owner then
    select coalesce(jsonb_agg(d), '[]'::jsonb) into v_gone
      from jsonb_array_elements_text(coalesce(v_old -> 'active_devices', '[]'::jsonb)) d
     where not (coalesce(v_new -> 'active_devices', '[]'::jsonb) ? d);
    if jsonb_array_length(v_gone) > 0 then
      insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
      values (v_actor, v_arole, 'devices.removed', v_target, jsonb_build_object('devices', v_gone));
    end if;

    if (v_old -> 'sessions_revoked_at') is distinct from (v_new -> 'sessions_revoked_at') then
      insert into public.security_audit_log (actor_email, actor_role, action, target_email, detail)
      values (v_actor, v_arole, 'sessions.revoked', v_target, '{}'::jsonb);
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_audit_profiles on public.profiles;
create trigger trg_audit_profiles
  after insert or update or delete on public.profiles
  for each row execute function public.pia_audit_profiles();


-- ---------------------------------------------------------------------------
-- 5. The same rule at the top of the admin RPCs that name a target account
-- ---------------------------------------------------------------------------
create or replace function public.pia_protect_admin_target(p_target text, p_action text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor  text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_target text := lower(trim(coalesce(p_target, '')));
begin
  if v_actor is null or v_target = '' or v_target = v_actor then
    return;   -- the owner, or one's own account (each RPC's own rules apply)
  end if;
  if exists (select 1 from public.profiles
              where lower(email) = v_target and lower(trim(coalesce(role, ''))) = 'admin') then
    perform public.pia_refuse(v_actor, p_action || ' another administrator', v_target);
  end if;
end;
$$;

revoke all on function public.pia_refuse(text, text, text)             from public, anon, authenticated;
revoke all on function public.pia_admin_boundaries()                   from public, anon, authenticated;
revoke all on function public.pia_audit_profiles()                     from public, anon, authenticated;
revoke all on function public.pia_protect_admin_target(text, text)     from public, anon, authenticated;

do $$
declare
  spec     text[];
  r        record;
  v_def    text;
  v_head   text;
  v_body   text;
  v_new    text;
  v_marker int;
  v_done   int := 0;
begin
  foreach spec slice 1 in array array[
    array['admin_delete_user',        'target_email', 'remove'],
    array['admin_revoke_sessions',    'p_email',      'sign out'],
    array['admin_revoke_device',      'p_email',      'revoke the devices of'],
    array['admin_update_user_email',  'target_email', 'change the email of'],
    array['admin_create_auth_user',   'target_email', 'reset the sign-in account of']
  ] loop
    for r in
      select p.oid, p.proname, p.proargnames, l.lanname
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        join pg_language l on l.oid = p.prolang
       where n.nspname = 'public' and p.proname = spec[1]
    loop
      if not (spec[2] = any(coalesce(r.proargnames, array[]::text[]))) then
        raise notice 'PIA 0031: %(%) has no parameter named % -- not guarded.', r.proname, r.oid::regprocedure, spec[2];
        continue;
      end if;
      if r.lanname <> 'plpgsql' then
        raise exception 'PIA 0031 ABORT: % is written in %, so the guard cannot be inserted. Rolling back.',
          r.oid::regprocedure, r.lanname using errcode = 'P0001';
      end if;

      v_def := pg_get_functiondef(r.oid);
      if position('pia_protect_admin_target' in v_def) > 0 then
        raise notice 'PIA 0031: % is already guarded.', r.oid::regprocedure;
        v_done := v_done + 1;
        continue;
      end if;

      -- The first BEGIN of the body, i.e. after the header's AS $function$.
      v_marker := position('$function$' in v_def);
      if v_marker = 0 then
        raise exception 'PIA 0031 ABORT: cannot find the body of %. Rolling back.', r.oid::regprocedure
          using errcode = 'P0001';
      end if;
      v_head := left(v_def, v_marker + length('$function$') - 1);
      v_body := substr(v_def, v_marker + length('$function$'));
      v_new  := regexp_replace(v_body, '\m(begin)\M',
                  format(E'\\1\n  perform public.pia_protect_admin_target(%s, %L);', spec[2], spec[3]), 'i');
      if v_new = v_body then
        raise exception 'PIA 0031 ABORT: no BEGIN found in %. Rolling back.', r.oid::regprocedure using errcode = 'P0001';
      end if;

      execute v_head || v_new;
      v_done := v_done + 1;
      raise notice 'PIA 0031: % now refuses to act on another administrator.', r.oid::regprocedure;
    end loop;
  end loop;

  if v_done = 0 then
    raise notice 'PIA 0031: none of the admin RPCs was found to guard.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- as a real admin, against a temporary second admin. Rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin   text;
  v_other   text := 'pia-0031-probe-admin@example.invalid';
  v_student text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_rows    int;
  v_fail    text := '';
  v_step    text;
  v_logged  int;
begin
  if has_table_privilege('authenticated', 'public.security_audit_log', 'INSERT')
     or has_table_privilege('authenticated', 'public.security_audit_log', 'UPDATE')
     or has_table_privilege('authenticated', 'public.security_audit_log', 'DELETE') then
    raise exception 'PIA 0031 ABORT: signed-in users can write the audit log.' using errcode = 'P0001';
  end if;

  select email into v_admin from public.profiles
   where lower(trim(role)) = 'admin' order by email limit 1;
  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;

  if v_admin is null then
    raise notice 'PIA 0031: no administrator to rehearse with -- skipped.';
    return;
  end if;

  begin
    -- The other administrator, created by the owner (no signed-in user).
    perform set_config('request.jwt.claims', '', true);
    insert into public.profiles (email, full_name, role, status, max_devices)
    values (v_other, 'PIA 0031 probe', 'admin', 'active', 1);
    if (select max_devices from public.profiles where email = v_other) <> 2 then
      v_fail := v_fail || 'a new admin row kept a limit below 2; ';
    end if;

    perform set_config('request.jwt.claims', json_build_object(
      'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';

    -- Each attempt on the other admin must be refused.
    foreach v_step in array array[
      format('update public.profiles set max_devices = 1 where email = %L', v_other),
      format('update public.profiles set role = %L where email = %L', 'student', v_other),
      format('update public.profiles set active_devices = %L where email = %L', '{pia-0031-probe-device}', v_other),
      format('delete from public.profiles where email = %L', v_other),
      format('select public.admin_delete_user(%L)', v_other),
      format('select public.admin_revoke_sessions(%L)', v_other),
      format('select public.admin_revoke_device(%L, null)', v_other),
      format('update public.profiles set role = %L where email = %L', 'student', v_admin),
      format('update public.profiles set max_devices = 1 where email = %L', v_admin)
    ] loop
      begin
        execute v_step;
        get diagnostics v_rows = row_count;
        -- A function that is not installed raises 42883 and lands below.
        v_fail := v_fail || 'NOT refused: ' || v_step || '; ';
      exception
        when insufficient_privilege or check_violation then null;       -- refused, as it should be
        when undefined_function then null;                              -- that RPC is not installed
      end;
    end loop;

    if v_student is not null then
      begin
        execute format('update public.profiles set role = %L where email = %L', 'admin', v_student);
        v_fail := v_fail || 'NOT refused: promoting a student to admin; ';
      exception when insufficient_privilege then null;
      end;
    end if;

    -- What an admin may still do: their own limit, within 2..10.
    update public.profiles set max_devices = 3 where email = v_admin;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then v_fail := v_fail || 'an admin could not set their own limit to 3; '; end if;

    execute 'reset role';

    select count(*) into v_logged from public.security_audit_log
     where action = 'device_limit.changed' and lower(target_email) = lower(v_admin)
       and lower(actor_email) = lower(v_admin) and at >= now();
    if v_logged < 1 then v_fail := v_fail || 'the own-limit change was not audited; '; end if;

    select count(*) into v_logged from public.security_audit_log
     where action = 'account.created' and target_email = v_other and actor_email is null;
    if v_logged < 1 then v_fail := v_fail || 'the new admin was not audited; '; end if;

    -- The owner can still do anything, including demoting that admin.
    perform set_config('request.jwt.claims', '', true);
    update public.profiles set role = 'student' where email = v_other;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then v_fail := v_fail || 'the project owner could not change an admin; '; end if;

    if v_fail <> '' then
      raise exception 'PIA 0031 ABORT: %', v_fail using errcode = 'P0001';
    end if;
    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0031 OK: another administrator cannot be changed, demoted, removed, signed out or have devices revoked; promotion and self-demotion are refused; an admin sets only their own limit (2..10); changes are audited; the project owner is unrestricted.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- Report
select p.oid::regprocedure::text as function,
       case when pg_get_functiondef(p.oid) ~ 'pia_protect_admin_target' then 'guarded' else 'NOT guarded' end as guard
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('admin_delete_user', 'admin_revoke_sessions', 'admin_revoke_device',
                     'admin_update_user_email', 'admin_create_auth_user')
 order by 1;


-- ############################################################################
-- MIGRATION 20260929_0032_admin_devices_no_limit
-- ############################################################################

-- ============================================================================
-- PIA 0032 -- NO DEVICE LIMIT FOR ADMINISTRATORS; DEAD DEVICES ARE FORGOTTEN
-- ============================================================================
-- The admin console no longer offers a "maximum devices" setting. What an
-- administrator keeps is the list of browsers signed in to their account and
-- the power to end any of them (admin_revoke_device, 0030). This migration
-- makes the database match:
--
--   1. claim_device() never refuses an ADMINISTRATOR for being "full". The
--      limit still applies to everyone else exactly as before (teachers keep
--      their slots; students use one active session since 0027).
--
--   2. claim_device() forgets devices whose login no longer exists. A device
--      id lives in localStorage, so a cleared browser or a private window
--      becomes a new "device" and the old entry stays behind for ever --
--      without a limit the list would only ever grow, and a list of dead
--      entries is no use for spotting a device you do not recognise. An
--      entry is removed only when the auth session recorded for it (0030's
--      device_sessions) is gone: that token is already refused everywhere
--      by jwt_is_current(), so nothing that works is lost. An entry with no
--      recorded session (registered before 0030) is left for the owner to
--      revoke. This applies to every role, and for teachers it also frees
--      the slots that used to trigger "device limit reached" after a lab PC
--      was closed without signing out.
--
-- profiles.max_devices is kept (teachers use it; 0031 still holds an
-- administrator's value at 2..10) -- it is simply not consulted for admins.
--
-- The body is 0030's claim_device with those two additions; nothing else in
-- it changes. The postflight rehearses both as a real admin (and a real
-- teacher, if there is one) and rolls everything back.
--
-- Requires 0030 (device_sessions, the session-aware jwt_is_current).
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles' and column_name = 'device_sessions') then
    raise exception 'PIA 0032 ABORT (nothing changed): profiles.device_sessions is missing -- run 0030 first.'
      using errcode = 'P0001';
  end if;
end;
$$;


create or replace function public.claim_device(p_device_id text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_sid     text := nullif(auth.jwt() ->> 'session_id', '');
  v_role    text;
  v_max     int;
  v_devices text[];
  v_map     jsonb;
  v_dead    text[] := '{}';
  d         text;
  s         text;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.'
      using errcode = '42501';
  end if;

  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  -- FOR UPDATE: two sign-ins racing on one account are served one after the other.
  select lower(trim(coalesce(p.role, 'student'))), coalesce(p.max_devices, 1),
         coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_role, v_max, v_devices, v_map
    from public.profiles p
   where p.email = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- 0032: forget devices whose recorded login no longer exists.
  foreach d in array v_devices loop
    s := v_map ->> d;
    if s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       and not exists (select 1 from auth.sessions x where x.id = s::uuid) then
      v_dead := array_append(v_dead, d);
    end if;
  end loop;

  if coalesce(array_length(v_dead, 1), 0) > 0 then
    v_devices := array(select x from unnest(v_devices) x where not (x = any(v_dead)));
    foreach d in array v_dead loop
      v_map := v_map - d;
    end loop;
    update public.profiles
       set active_devices = v_devices, device_sessions = v_map
     where email = v_email;
  end if;

  -- Known device: nothing to add (idempotent), but keep its session current.
  if p_device_id = any(v_devices) then
    if v_sid is not null and (v_map ->> p_device_id) is distinct from v_sid then
      update public.profiles
         set device_sessions = v_map || jsonb_build_object(p_device_id, v_sid)
       where email = v_email;
    end if;
    return jsonb_build_object('allowed', true, 'devices', v_devices, 'max', v_max);
  end if;

  -- 0032: the limit does not apply to administrators.
  if v_role <> 'admin' and coalesce(array_length(v_devices, 1), 0) >= v_max then
    return jsonb_build_object(
      'allowed', false,
      'reason', v_max || ' device limit reached. Please sign out on your other device first.',
      'devices', v_devices, 'max', v_max);
  end if;

  update public.profiles
     set active_devices  = array_append(v_devices, p_device_id),
         device_sessions = case when v_sid is null then v_map
                                else v_map || jsonb_build_object(p_device_id, v_sid) end
   where email = v_email;

  return jsonb_build_object('allowed', true,
                            'devices', array_append(v_devices, p_device_id),
                            'max', v_max);
end;
$function$;

revoke all on function public.claim_device(text) from public, anon;
grant execute on function public.claim_device(text) to authenticated;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin   text;
  v_teacher text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_res     jsonb;
  v_left    text[];
  v_fail    text := '';
begin
  select email into v_admin from public.profiles where lower(trim(role)) = 'admin' order by email limit 1;
  select email into v_teacher from public.profiles where lower(trim(role)) = 'teacher' order by email limit 1;

  if v_admin is null then
    raise notice 'PIA 0032: no administrator to rehearse with -- skipped.';
    return;
  end if;

  begin
    -- As the owner: an admin at their limit (2), holding one dead device
    -- (its recorded session does not exist) and one unbound device.
    perform set_config('request.jwt.claims', '', true);
    update public.profiles
       set max_devices = 2,
           active_devices = array['pia-0032-dead', 'pia-0032-unbound'],
           device_sessions = jsonb_build_object('pia-0032-dead', gen_random_uuid()::text)
     where email = v_admin;

    -- As that admin, from a new browser.
    perform set_config('request.jwt.claims', json_build_object(
      'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';
    v_res := public.claim_device('pia-0032-new');
    execute 'reset role';

    select active_devices into v_left from public.profiles where email = v_admin;
    if not (v_res ->> 'allowed')::boolean then
      v_fail := v_fail || 'an administrator was refused a device; ';
    end if;
    if 'pia-0032-dead' = any(v_left) then
      v_fail := v_fail || 'a device with a dead login was kept; ';
    end if;
    if not ('pia-0032-unbound' = any(v_left)) then
      v_fail := v_fail || 'a device with no recorded login was removed; ';
    end if;
    if not ('pia-0032-new' = any(v_left)) then
      v_fail := v_fail || 'the new device was not registered; ';
    end if;

    -- A teacher still has a limit.
    if v_teacher is not null then
      perform set_config('request.jwt.claims', '', true);
      update public.profiles
         set max_devices = 1, active_devices = array['pia-0032-teacher-pc'], device_sessions = '{}'::jsonb
       where email = v_teacher;

      perform set_config('request.jwt.claims', json_build_object(
        'email', v_teacher, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';
      v_res := public.claim_device('pia-0032-teacher-phone');
      execute 'reset role';
      if (v_res ->> 'allowed')::boolean then
        v_fail := v_fail || 'a teacher at their limit was given another device; ';
      end if;
    else
      raise notice 'PIA 0032: no teacher to rehearse with -- the teacher limit test is skipped.';
    end if;

    if v_fail <> '' then
      raise exception 'PIA 0032 ABORT: %', v_fail using errcode = 'P0001';
    end if;
    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0032 OK: administrators have no device limit; dead devices are forgotten, unbound ones kept; teachers keep their limit.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260929_0033_consent_assent_and_stage_overrides
-- ############################################################################

-- ============================================================================
-- PIA 0033 -- CONSENT AND ASSENT, AN UNCAPPED PRE-TEST, VISIBLE SECTION OVERRIDES
-- ============================================================================
-- Three changes behind the admin console's research workflow:
--
--   1. CONSENT AND ASSENT ARE STORED. The Register dialog has always asked
--      for "Parental consent received", but only as a gate on the button --
--      nothing was saved. profiles gains two columns:
--
--        parental_consent  boolean   null = not recorded (registered before 0033)
--        student_assent    boolean   false = not received yet, true = received
--
--      Existing rows stay NULL ("not recorded"). Every student registered
--      through the console had to tick the parental-consent box, but this
--      migration does not claim consent on anyone's behalf -- only the signed
--      forms can. Once you have checked them, the backfill is one line:
--
--        update public.profiles set parental_consent = true
--         where parental_consent is null
--           and lower(trim(coalesce(role, 'student'))) = 'student';
--
--      Only an administrator can write either column: the profile write
--      guard (0001) is a whitelist, so a student's attempt to set their own
--      is refused like any other protected column. Neither is exposed on the
--      teacher surface, which reads profiles only through its own functions.
--
--   2. THE PRE-TEST HAS NO UPPER LIMIT, AND IS NEVER REQUIRED AT REGISTRATION.
--      Registration is admin_create_auth_user (email + temporary password)
--      followed by a plain profiles insert; neither needs a score, and the
--      console no longer sends one. This section makes sure the database
--      agrees: pre_test_score is nullable, any CHECK constraint on it is
--      replaced by "not negative", and a numeric(p,s) column is widened to
--      plain numeric so a large score cannot overflow. post_test_score is not
--      touched.
--
--   3. SECTION OVERRIDES ARE RECORDED. admin_grant_stage(p_stage, p_emails,
--      p_section) moves the eligible students of a section into a closed
--      stage, one row at a time, and keeps no record that it was a section
--      grant -- so the Stage Controls card could not say which sections it
--      had opened. stage_overrides keeps that record:
--
--        * admin_grant_stage writes a row when a section grant lets at least
--          one student in (the call is unchanged; the recording is added to
--          its existing wrapper, inside the same transaction);
--        * any write of the stage's settings row -- opening or closing it for
--          everyone through admin_set_stage_open -- clears that stage's rows.
--          Closing evicts every student in the stage, so the grants are gone;
--          opening makes them moot.
--
--      Administrators can read the table; nobody can write it through the API.
--      Individually granted students are not recorded here: the console
--      counts them live from each student's current stage.
--
-- SAFE TO RE-RUN. The postflight rehearses every rule as a real administrator
-- and a real student under RLS, and rolls everything back.
--
-- Requires 0011 (the admin_grant_stage wrapper), 0022/0030 (jwt_is_current).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT -- admin_grant_stage must be the wrapper this migration expects.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count int;
  v_args  text;
  v_ret   text;
begin
  if to_regprocedure('public.pia_caller_role()') is null or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0033 ABORT (nothing changed): pia_caller_role() / jwt_is_current() are missing.'
      using errcode = 'P0001';
  end if;

  if to_regclass('public.settings') is null then
    raise exception 'PIA 0033 ABORT (nothing changed): public.settings is missing.' using errcode = 'P0001';
  end if;

  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_grant_stage';

  if v_count <> 1 then
    raise exception 'PIA 0033 ABORT (nothing changed): expected one public.admin_grant_stage, found %.', v_count
      using errcode = 'P0001';
  end if;

  select pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid)
    into v_args, v_ret
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_grant_stage';

  if v_args !~ '(^|, )p_stage text(,|$)'
     or v_args !~ '(^|, )p_emails text\[\](,|$)'
     or v_args !~ '(^|, )p_section text(,|$)'
     or array_length(string_to_array(v_args, ', '), 1) <> 3 then
    raise exception 'PIA 0033 ABORT (nothing changed): admin_grant_stage(%) is not (p_stage text, p_emails text[], p_section text).', v_args
      using errcode = 'P0001';
  end if;

  if v_ret not in ('json', 'jsonb') then
    raise exception 'PIA 0033 ABORT (nothing changed): admin_grant_stage returns %, expected json or jsonb.', v_ret
      using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Consent and assent
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists parental_consent boolean;
alter table public.profiles add column if not exists student_assent boolean;

comment on column public.profiles.parental_consent is
  'Parental consent form received (0033). null = not recorded, false = not received, true = received. Admin-written.';
comment on column public.profiles.student_assent is
  'Student assent received (0033). null = not recorded, false = not received, true = received. Admin-written.';


-- ---------------------------------------------------------------------------
-- 2. pre_test_score: optional, not negative, no upper limit
-- ---------------------------------------------------------------------------
do $$
declare
  r      record;
  v_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_type
    from pg_attribute a
   where a.attrelid = 'public.profiles'::regclass and a.attname = 'pre_test_score' and not a.attisdropped;

  if v_type is null then
    raise exception 'PIA 0033 ABORT (nothing changed): profiles.pre_test_score is missing.' using errcode = 'P0001';
  end if;

  alter table public.profiles alter column pre_test_score drop not null;

  for r in
    select c.conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.conrelid = 'public.profiles'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) ~ 'pre_test_score'
  loop
    if r.def ~ 'post_test_score' then
      raise exception 'PIA 0033 ABORT (nothing changed): constraint % also covers post_test_score (%). Split it by hand first.',
        r.conname, r.def using errcode = 'P0001';
    end if;
    execute format('alter table public.profiles drop constraint %I', r.conname);
    raise notice 'PIA 0033: dropped % -- %', r.conname, r.def;
  end loop;

  -- numeric(5,2) would still stop at 999.99; plain numeric has no ceiling.
  if v_type like 'numeric(%' then
    begin
      alter table public.profiles alter column pre_test_score type numeric;
      raise notice 'PIA 0033: pre_test_score widened from % to numeric.', v_type;
    exception when others then
      raise exception 'PIA 0033 ABORT (nothing changed): could not widen pre_test_score from % (%).', v_type, sqlerrm
        using errcode = 'P0001';
    end;
  elsif v_type not in ('numeric', 'real', 'double precision') then
    raise notice 'PIA 0033: pre_test_score is %, left as is (no upper limit to remove).', v_type;
  end if;

  if v_type !~ '^(numeric|real|double precision|integer|smallint|bigint)' then
    raise notice 'PIA 0033: pre_test_score is not a number column (%); the not-negative rule was not added.', v_type;
  elsif exists (select 1 from public.profiles where pre_test_score < 0) then
    raise notice 'PIA 0033: some pre_test_score values are negative; the not-negative rule was not added.';
  else
    alter table public.profiles
      add constraint profiles_pre_test_score_not_negative check (pre_test_score >= 0);
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. Section overrides
-- ---------------------------------------------------------------------------
create table if not exists public.stage_overrides (
  id            bigint generated always as identity primary key,
  stage         text not null check (stage in ('ocean', 'char', 'dash')),
  section       text not null,
  granted_count int  not null default 0,   -- students the last grant let in
  granted_by    text,                      -- null = the project owner
  granted_at    timestamptz not null default now(),
  unique (stage, section)
);

alter table public.stage_overrides enable row level security;
revoke all on public.stage_overrides from public, anon, authenticated;
grant select on public.stage_overrides to authenticated;

drop policy if exists stage_overrides_admin_read on public.stage_overrides;
create policy stage_overrides_admin_read on public.stage_overrides
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());

comment on table public.stage_overrides is
  'Sections opened into a closed stage by admin_grant_stage (0033). Cleared when the stage is opened or closed for everyone.';


-- Called by admin_grant_stage with its own result, which it returns unchanged.
create or replace function public.pia_record_stage_grant(
  p_stage text, p_section text, p_emails text[], p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := nullif(trim(coalesce(p_section, '')), '');
  v_granted int;
begin
  if v_section is null or p_stage is null or p_result is null then
    return p_result;
  end if;

  v_granted := case when jsonb_typeof(p_result -> 'granted') = 'array'
                    then jsonb_array_length(p_result -> 'granted') else 0 end;

  -- Nobody let in = no override to show. An earlier grant for the section,
  -- if any, is left as it was.
  if v_granted > 0 then
    insert into public.stage_overrides (stage, section, granted_count, granted_by, granted_at)
    values (p_stage, v_section, v_granted, lower(nullif(auth.jwt() ->> 'email', '')), now())
    on conflict (stage, section) do update
      set granted_count = excluded.granted_count,
          granted_by    = excluded.granted_by,
          granted_at    = excluded.granted_at;
  end if;

  return p_result;
end;
$$;

revoke all on function public.pia_record_stage_grant(text, text, text[], jsonb) from public, anon, authenticated;


-- admin_grant_stage is 0011's wrapper around admin_grant_stage__inner. Its
-- one call to the inner function becomes a call through the recorder; the
-- guard in front of it and everything else stay exactly as the database has
-- them.
do $$
declare
  v_oid     oid;
  v_ret     text;
  v_def     text;
  v_new     text;
  v_hits    int;
  v_pattern text := 'return\s+public\.admin_grant_stage__inner\s*\(([^;]*)\)\s*;';
begin
  select p.oid, pg_get_function_result(p.oid) into v_oid, v_ret
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_grant_stage';

  v_def := pg_get_functiondef(v_oid);

  if v_def ~ 'pia_record_stage_grant' then
    raise notice 'PIA 0033: admin_grant_stage already records section grants -- left as is.';
    return;
  end if;

  select count(*) into v_hits from regexp_matches(v_def, v_pattern, 'gi');
  if v_hits <> 1 then
    raise exception 'PIA 0033 ABORT (nothing changed): admin_grant_stage does not end in one "return public.admin_grant_stage__inner(...)" (found %). Send the output of: select pg_get_functiondef(''public.admin_grant_stage''::regproc);', v_hits
      using errcode = 'P0001';
  end if;

  v_new := regexp_replace(v_def, v_pattern,
    'return (public.pia_record_stage_grant(p_stage, p_section, p_emails, (public.admin_grant_stage__inner(\1))::jsonb))::'
      || v_ret || ';',
    'i');

  execute v_new;
  raise notice 'PIA 0033: admin_grant_stage now records section grants.';
end;
$$;


-- Opening or closing a stage for everyone ends its section overrides.
create or replace function public.pia_clear_stage_overrides()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.key like 'stage\_%' then
    delete from public.stage_overrides where stage = substr(new.key, 7);
  end if;
  return null;
end;
$$;

revoke all on function public.pia_clear_stage_overrides() from public, anon, authenticated;

drop trigger if exists trg_clear_stage_overrides on public.settings;
create trigger trg_clear_stage_overrides
  after insert or update on public.settings
  for each row execute function public.pia_clear_stage_overrides();


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin   text;
  v_student text;
  v_ret     text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_open    boolean;
  v_n       int;
  v_val     text;
  v_fail    text := '';
begin
  select email into v_admin from public.profiles where lower(trim(role)) = 'admin' order by email limit 1;
  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;
  select pg_get_function_result(p.oid) into v_ret
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_grant_stage';

  if v_admin is null then
    raise notice 'PIA 0033: no administrator to rehearse with -- skipped.';
    return;
  end if;

  begin
    perform set_config('request.jwt.claims', '', true);

    -- A. The recorder, fed the way the wrapper feeds it.
    execute format(
      'select (public.pia_record_stage_grant($1, $2, null, ($3::%s)::jsonb))::%s', v_ret, v_ret)
      using 'dash'::text, 'PIA-0033-probe'::text, '{"granted":["a@probe.test","b@probe.test"],"skipped":[]}'::text;
    perform public.pia_record_stage_grant('dash', 'PIA-0033-empty', null,
      '{"granted":[],"skipped":[{"email":"c@probe.test","reason":"probe"}]}'::jsonb);
    perform public.pia_record_stage_grant('char', 'PIA-0033-probe', null, '{"granted":["a@probe.test"]}'::jsonb);

    select granted_count into v_n from public.stage_overrides where stage = 'dash' and section = 'PIA-0033-probe';
    if coalesce(v_n, 0) <> 2 then
      v_fail := v_fail || 'a section grant was not recorded with its count; ';
    end if;
    if exists (select 1 from public.stage_overrides where section = 'PIA-0033-empty') then
      v_fail := v_fail || 'a grant that let nobody in was recorded; ';
    end if;

    -- B. The wrapper calls the recorder, and still runs as a whole.
    if pg_get_functiondef('public.admin_grant_stage'::regproc) !~ 'pia_record_stage_grant' then
      v_fail := v_fail || 'admin_grant_stage does not call the recorder; ';
    end if;

    perform set_config('request.jwt.claims', json_build_object(
      'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';

    begin
      perform public.admin_grant_stage('dash', null, 'PIA-0033-no-such-section');
    exception when others then
      if sqlstate in ('42883', '42804', '42P13', '22P02', '42601') or sqlerrm ~* 'pia_record_stage_grant' then
        v_fail := v_fail || 'admin_grant_stage failed through the recorder (' || sqlerrm || '); ';
      else
        raise notice 'PIA 0033: the rehearsal grant was refused by admin_grant_stage itself (%); the recorder was tested directly.', sqlerrm;
      end if;
    end;

    -- C. An administrator reads the overrides and writes consent and assent.
    --    (No pre-test here: since 0034 a score is only written through its raw
    --    score, and 0034 rehearses that itself -- so this file stays safe to
    --    re-run after 0034.)
    select count(*) into v_n from public.stage_overrides where section = 'PIA-0033-probe';
    if v_n <> 2 then
      v_fail := v_fail || 'an administrator cannot read the overrides; ';
    end if;

    if v_student is not null then
      update public.profiles
         set parental_consent = true, student_assent = false
       where email = v_student;
      get diagnostics v_n = row_count;
      if v_n <> 1 then
        v_fail := v_fail || 'an administrator could not record consent and assent; ';
      end if;
    end if;

    -- D. Closing or opening a stage for everyone clears only that stage.
    --    Called with its current value, so nothing flips.
    select coalesce(bool_or(value::text in ('true', '"true"')), false) into v_open
      from public.settings where key = 'stage_dash';
    perform public.admin_set_stage_open('dash', v_open);

    execute 'reset role';

    if exists (select 1 from public.stage_overrides where stage = 'dash') then
      v_fail := v_fail || 'admin_set_stage_open did not clear the stage''s overrides; ';
    end if;
    if not exists (select 1 from public.stage_overrides where stage = 'char' and section = 'PIA-0033-probe') then
      v_fail := v_fail || 'admin_set_stage_open cleared another stage''s overrides; ';
    end if;

    -- E. A student sees no overrides and cannot record their own assent.
    if v_student is not null then
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';

      select count(*) into v_n from public.stage_overrides;
      if v_n <> 0 then
        v_fail := v_fail || 'a student can read the overrides; ';
      end if;

      begin
        update public.profiles set student_assent = true where email = v_student;
      exception when sqlstate '42501' then
        null;   -- refused by the write guard, as it should be
      end;

      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);

      select student_assent::text into v_val from public.profiles where email = v_student;
      if v_val is distinct from 'false' then
        v_fail := v_fail || 'a student changed their own assent; ';
      end if;
    else
      raise notice 'PIA 0033: no student to rehearse with -- the student checks are skipped.';
    end if;

    if v_fail <> '' then
      raise exception 'PIA 0033 ABORT: %', v_fail using errcode = 'P0001';
    end if;
    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0033 OK: consent and assent are admin-only columns; the pre-test has no upper limit; section grants are recorded, readable by admins only, and cleared when the stage is opened or closed.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260929_0034_raw_and_transmuted_test_scores
-- ############################################################################

-- ============================================================================
-- PIA 0034 -- RAW SCORES, HIGHEST POSSIBLE SCORES, AND THE TRANSMUTED SCORE
-- ============================================================================
-- The pre-test and post-test are now entered as two numbers -- the raw score
-- and the highest possible score -- and the score the study reports is the
-- transmuted score:
--
--     transmuted = (raw / highest possible) * 50 + 50       (range 50 - 100)
--
-- profiles gains, for each test, the two numbers the admin typed:
--
--     pre_test_raw_score    pre_test_max_score
--     post_test_raw_score   post_test_max_score
--
-- and pre_test_score / post_test_score keep their names and now hold the
-- transmuted score, rounded to 2 decimals. The raw data is what the thesis
-- rests on, so the database -- not the browser -- does the arithmetic: a
-- trigger calculates the transmuted score whenever the raw score or the
-- highest possible score changes, and refuses a score written without them.
-- The admin console shows the same calculation live, but only as a preview;
-- the stored value is always the database's.
--
-- Rules, enforced by the trigger (friendly messages) and CHECK constraints
-- (the backstop):
--   * raw and highest possible are given together, or both left blank;
--   * the highest possible score is more than 0;
--   * the raw score is between 0 and the highest possible score;
--   * clearing both clears the transmuted score;
--   * the transmuted score cannot be written directly.
--
-- EXISTING SCORES. A score entered before 0034 is a single number with no
-- record of what it was out of. It is NOT converted: splitting it into raw
-- and highest possible would mean guessing the denominator, and a guessed
-- value in the thesis data is worse than a missing one. Instead:
--   * every existing score is copied, unchanged, into profiles_score_backup_0034
--     (readable only here in the SQL editor), so nothing is ever lost;
--   * the score itself stays where it is, and the console shows it as
--     "entered as a single score" until the raw scores are entered for it;
--   * the postflight reports how many there are.
-- If you know every existing score was a raw score out of 100 items, this
-- converts them (the trigger then calculates the transmuted score):
--
--   update public.profiles set pre_test_raw_score = pre_test_score, pre_test_max_score = 100
--    where pre_test_raw_score is null and pre_test_score between 0 and 100;
--   update public.profiles set post_test_raw_score = post_test_score, post_test_max_score = 100
--    where post_test_raw_score is null and post_test_score between 0 and 100;
--
-- Only an administrator can write any of these columns: the profile write
-- guard (0001) is a whitelist, and none of them is on it. None of them is
-- exposed on the teacher surface.
--
-- SAFE TO RE-RUN. The postflight rehearses every rule as a real administrator
-- under RLS and rolls everything back.
--
-- Requires 0033.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles' and column_name = 'parental_consent') then
    raise exception 'PIA 0034 ABORT (nothing changed): run 0033 first.' using errcode = 'P0001';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'profiles'
         and column_name in ('pre_test_score', 'post_test_score')) <> 2 then
    raise exception 'PIA 0034 ABORT (nothing changed): profiles.pre_test_score / post_test_score are missing.'
      using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Keep every existing score, verbatim
-- ---------------------------------------------------------------------------
create table if not exists public.profiles_score_backup_0034 (
  email           text primary key,
  pre_test_score  numeric,
  post_test_score numeric,
  backed_up_at    timestamptz not null default now()
);

alter table public.profiles_score_backup_0034 enable row level security;
revoke all on public.profiles_score_backup_0034 from public, anon, authenticated;

comment on table public.profiles_score_backup_0034 is
  'Pre/post-test scores as they were before 0034 introduced raw scores. Owner-only; never written again.';

-- A re-run keeps the first copy: by then a score may already be transmuted.
insert into public.profiles_score_backup_0034 (email, pre_test_score, post_test_score)
select p.email, p.pre_test_score::numeric, p.post_test_score::numeric
  from public.profiles p
 where p.pre_test_score is not null or p.post_test_score is not null
on conflict (email) do nothing;


-- ---------------------------------------------------------------------------
-- 2. The raw columns, and room for a score with decimals
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists pre_test_raw_score  numeric,
  add column if not exists pre_test_max_score  numeric,
  add column if not exists post_test_raw_score numeric,
  add column if not exists post_test_max_score numeric;

comment on column public.profiles.pre_test_raw_score  is 'Pre-test raw score as entered (0034).';
comment on column public.profiles.pre_test_max_score  is 'Pre-test highest possible score as entered (0034).';
comment on column public.profiles.post_test_raw_score is 'Post-test raw score as entered (0034).';
comment on column public.profiles.post_test_max_score is 'Post-test highest possible score as entered (0034).';
comment on column public.profiles.pre_test_score  is
  'Transmuted pre-test score = raw / max * 50 + 50, calculated by trg_compute_test_scores (0034). A value with no raw score was entered before 0034.';
comment on column public.profiles.post_test_score is
  'Transmuted post-test score = raw / max * 50 + 50, calculated by trg_compute_test_scores (0034). A value with no raw score was entered before 0034.';

-- A transmuted score like 66.67 must not be rounded to 67 by an integer column.
do $$
declare
  c      text;
  v_type text;
begin
  foreach c in array array['pre_test_score', 'post_test_score'] loop
    select format_type(a.atttypid, a.atttypmod) into v_type
      from pg_attribute a
     where a.attrelid = 'public.profiles'::regclass and a.attname = c and not a.attisdropped;

    if v_type ~ '^(integer|smallint|bigint|numeric\()' then
      begin
        execute format('alter table public.profiles alter column %I type numeric using %I::numeric', c, c);
        raise notice 'PIA 0034: % changed from % to numeric.', c, v_type;
      exception when others then
        raise exception 'PIA 0034 ABORT (nothing changed): could not change % from % to numeric (%).', c, v_type, sqlerrm
          using errcode = 'P0001';
      end;
    end if;
  end loop;
end;
$$;

alter table public.profiles drop constraint if exists profiles_pre_test_raw_valid;
alter table public.profiles add constraint profiles_pre_test_raw_valid check (
  (pre_test_raw_score is null) = (pre_test_max_score is null)
  and (pre_test_max_score is null
       or (pre_test_max_score > 0 and pre_test_raw_score >= 0 and pre_test_raw_score <= pre_test_max_score)));

alter table public.profiles drop constraint if exists profiles_post_test_raw_valid;
alter table public.profiles add constraint profiles_post_test_raw_valid check (
  (post_test_raw_score is null) = (post_test_max_score is null)
  and (post_test_max_score is null
       or (post_test_max_score > 0 and post_test_raw_score >= 0 and post_test_raw_score <= post_test_max_score)));


-- ---------------------------------------------------------------------------
-- 3. The calculation
-- ---------------------------------------------------------------------------
create or replace function public.pia_transmute(p_raw numeric, p_max numeric)
returns numeric
language sql
immutable
set search_path = public
as $$
  select round(p_raw / p_max * 50 + 50, 2);
$$;

-- One test's three columns, checked and settled. Returns the score to store.
create or replace function public.pia_settle_test_score(
  p_label     text,
  p_insert    boolean,
  p_raw       numeric, p_max     numeric, p_score     numeric,
  p_old_raw   numeric, p_old_max numeric, p_old_score numeric)
returns numeric
language plpgsql
set search_path = public
as $$
begin
  -- No raw data.
  if p_raw is null and p_max is null then
    -- The raw data was just cleared: the score it produced goes with it.
    if not p_insert and (p_old_raw is not null or p_old_max is not null)
       and p_score is not distinct from p_old_score then
      return null;
    end if;
    -- A new score typed on its own (an old console, or a direct write).
    if p_score is not null and (p_insert or p_score is distinct from p_old_score) then
      raise exception 'PIA: the % score is calculated from the raw score and the highest possible score -- enter both. (If the console asks for a single score, reload it.)', p_label
        using errcode = '22023';
    end if;
    -- Blank, or a score entered before 0034, kept as it was.
    return p_score;
  end if;

  if p_raw is null or p_max is null then
    raise exception 'PIA: enter both the raw score and the highest possible score for the %.', p_label
      using errcode = '22023';
  end if;
  if p_max <= 0 then
    raise exception 'PIA: the highest possible score for the % must be more than 0.', p_label
      using errcode = '22023';
  end if;
  if p_raw < 0 or p_raw > p_max then
    raise exception 'PIA: the % raw score must be between 0 and the highest possible score (%).', p_label, p_max
      using errcode = '22023';
  end if;

  -- New raw data: calculate.
  if p_insert or p_raw is distinct from p_old_raw or p_max is distinct from p_old_max then
    return public.pia_transmute(p_raw, p_max);
  end if;

  -- Raw data unchanged. The stored score is left exactly as it is -- a
  -- student's own heartbeat update must not rewrite it -- and cannot be
  -- overwritten by hand.
  if p_score is distinct from p_old_score then
    raise exception 'PIA: the % score is calculated from the raw score -- change the raw score instead.', p_label
      using errcode = '22023';
  end if;
  return p_old_score;
end;
$$;

create or replace function public.pia_compute_test_scores()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_insert boolean := tg_op = 'INSERT';
begin
  new.pre_test_score := public.pia_settle_test_score('pre-test', v_insert,
    new.pre_test_raw_score, new.pre_test_max_score, new.pre_test_score,
    case when v_insert then null else old.pre_test_raw_score end,
    case when v_insert then null else old.pre_test_max_score end,
    case when v_insert then null else old.pre_test_score end);

  new.post_test_score := public.pia_settle_test_score('post-test', v_insert,
    new.post_test_raw_score, new.post_test_max_score, new.post_test_score,
    case when v_insert then null else old.post_test_raw_score end,
    case when v_insert then null else old.post_test_max_score end,
    case when v_insert then null else old.post_test_score end);

  return new;
end;
$$;

-- pia_transmute and pia_settle_test_score keep their default EXECUTE: they
-- read no data, and the trigger runs them as whoever is writing the row (an
-- admin, a student's heartbeat, the service role).
revoke all on function public.pia_compute_test_scores() from public, anon, authenticated;

-- BEFORE triggers run in name order: after trg_admin_boundaries (0031), and
-- before trg_enforce_profile_write_scope (0001) compares old and new.
drop trigger if exists trg_compute_test_scores on public.profiles;
create trigger trg_compute_test_scores
  before insert or update on public.profiles
  for each row execute function public.pia_compute_test_scores();


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin   text;
  v_student text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_pre     numeric;
  v_post    numeric;
  v_legacy_pre  int;
  v_legacy_post int;
  v_fail    text := '';
begin
  select count(*) filter (where pre_test_score is not null and pre_test_raw_score is null),
         count(*) filter (where post_test_score is not null and post_test_raw_score is null)
    into v_legacy_pre, v_legacy_post
    from public.profiles;

  select email into v_admin from public.profiles where lower(trim(role)) = 'admin' order by email limit 1;
  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' order by email limit 1;

  if v_admin is null or v_student is null then
    raise notice 'PIA 0034: no administrator or no student to rehearse with -- skipped.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';

      -- A. Raw and highest possible in, transmuted score out.
      update public.profiles
         set pre_test_raw_score = 40, pre_test_max_score = 50,
             post_test_raw_score = 1, post_test_max_score = 3
       where email = v_student;
      select pre_test_score, post_test_score into v_pre, v_post from public.profiles where email = v_student;
      if v_pre is distinct from 90.00 then
        v_fail := v_fail || format('40/50 gave %s, expected 90; ', v_pre);
      end if;
      if v_post is distinct from 66.67 then
        v_fail := v_fail || format('1/3 gave %s, expected 66.67; ', v_post);
      end if;

      -- B. Refusals.
      begin
        update public.profiles set pre_test_raw_score = 60 where email = v_student;   -- 60 of 50
        v_fail := v_fail || 'a raw score above the highest possible score was accepted; ';
      exception when sqlstate '22023' or sqlstate '23514' then null;
      end;
      begin
        update public.profiles set pre_test_max_score = null where email = v_student;  -- raw without max
        v_fail := v_fail || 'a raw score without its highest possible score was accepted; ';
      exception when sqlstate '22023' or sqlstate '23514' then null;
      end;
      begin
        update public.profiles set pre_test_raw_score = 0, pre_test_max_score = 0 where email = v_student;
        v_fail := v_fail || 'a highest possible score of 0 was accepted; ';
      exception when sqlstate '22023' or sqlstate '23514' then null;
      end;
      begin
        update public.profiles set pre_test_score = 99 where email = v_student;        -- by hand
        v_fail := v_fail || 'a transmuted score was overwritten by hand; ';
      exception when sqlstate '22023' then null;
      end;

      -- C. An unrelated change leaves the score alone.
      update public.profiles set full_name = full_name where email = v_student;
      select pre_test_score into v_pre from public.profiles where email = v_student;
      if v_pre is distinct from 90.00 then
        v_fail := v_fail || 'an unrelated update changed the transmuted score; ';
      end if;

      -- D. Clearing the raw data clears the score.
      update public.profiles set post_test_raw_score = null, post_test_max_score = null where email = v_student;
      select post_test_score into v_post from public.profiles where email = v_student;
      if v_post is not null then
        v_fail := v_fail || 'clearing the raw score left a transmuted score behind; ';
      end if;

      -- E. A single score with no raw data is refused.
      begin
        update public.profiles set post_test_score = 77 where email = v_student;
        v_fail := v_fail || 'a single score without raw data was accepted; ';
      exception when sqlstate '22023' then null;
      end;

      execute 'reset role';

      -- F. The student cannot write their own raw score.
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_student, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';
      begin
        update public.profiles set pre_test_raw_score = 50 where email = v_student;
      exception when sqlstate '42501' then null;
      end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);

      select pre_test_score into v_pre from public.profiles where email = v_student;
      if v_pre is distinct from 90.00 then
        v_fail := v_fail || 'a student changed their own raw score; ';
      end if;

      if v_fail <> '' then
        raise exception 'PIA 0034 ABORT: %', v_fail using errcode = 'P0001';
      end if;
      raise exception 'rehearsal done' using errcode = 'P0002';
    exception
      when sqlstate 'P0002' then
        raise notice 'PIA 0034 OK: raw and highest possible scores are stored; the transmuted score is calculated by the database and cannot be written by hand.';
    end;

    perform set_config('request.jwt.claims', '', true);
  end if;

  raise notice 'PIA 0034: % pre-test and % post-test score(s) were entered as a single number before 0034. They are kept as they were (and copied to profiles_score_backup_0034) until raw scores are entered for them.',
    v_legacy_pre, v_legacy_post;
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260929_0035_stage_time_tracking
-- ############################################################################

-- ============================================================================
-- PIA 0035 -- ACTIVE TIME PER STAGE (THE HEARTBEAT)
-- ============================================================================
-- The study needs how long each student actually spent working in each stage,
-- not how long a tab happened to be open. A student page sends a ping every 30
-- seconds while its tab is visible (assets/js/function.js, startStageHeartbeat)
-- and nothing while it is hidden, offline or closed -- so time a student spends
-- elsewhere is never counted, and a lost connection simply stops the clock.
--
--   public.student_stage_time          one row per student
--       ocean_time                     seconds of active time in each stage
--       character_select_time
--       tutoring_time
--       *_locked_at                    set when the stage is completed; the
--                                      seconds above then never change again
--       heartbeat_stage                the stage of the latest ping
--       last_heartbeat_timestamp       when it arrived (server clock)
--
--   record_heartbeat(p_stage)          what the ping calls
--   finalize_stage_time(p_stage)       the final payload that locks a stage
--
-- WHY A TABLE OF ITS OWN, NOT COLUMNS ON profiles. Every write to profiles is
-- broadcast to the admin console, which reloads its whole cohort on each one;
-- forty students pinging every 30 seconds would keep it reloading all the
-- time. This table is read on demand and is not published to realtime.
--
-- THE CLOCK IS THE SERVER'S. A ping carries only a stage name. How much time
-- it is worth is worked out here from the gap since the previous ping, so a
-- student cannot send a bigger number, or pings faster than 30 seconds apart,
-- to inflate their own time:
--
--     gap since the previous ping of the SAME stage
--       under 10 s ........ ignored (a duplicate; nothing changes)
--       10 s to 45 s ...... credited: the gap itself, at most 30 s
--       over 45 s or none . the clock restarts: stamped, credited nothing
--
-- The last rule is the disconnect rule. A student who closes the laptop, loses
-- Wi-Fi or leaves the tab hidden stops pinging; when they return, the first
-- ping only restarts the clock and the away time is not counted. The most a
-- returning student can be over-credited is one 30-second interval.
--
-- ONLY A STAGE THAT IS STILL IN PROGRESS COUNTS. OCEAN stops counting once the
-- questionnaire is submitted, Character Selection once a character is chosen
-- (both read from pia_can_enter_stage, the rule the whole app already uses),
-- and any stage stops counting once it is locked.
--
-- Admins read the table (Live sessions and the export); nobody writes it
-- directly through the API. Requires 0005 (pia_can_enter_stage) and
-- 0020-0024 (pia_caller_role, jwt_is_current).
--
-- SAFE TO RE-RUN. The postflight rehearses every rule as a real student and
-- an administrator under RLS, and rolls everything back.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_problems text := '';
begin
  if to_regprocedure('public.pia_caller_role()') is null then v_problems := v_problems || 'pia_caller_role() is missing; '; end if;
  if to_regprocedure('public.jwt_is_current()') is null then v_problems := v_problems || 'jwt_is_current() is missing; '; end if;
  if to_regprocedure('public.pia_can_enter_stage(boolean, text, text, text)') is null then
    v_problems := v_problems || 'pia_can_enter_stage(boolean, text, text, text) is missing (0005); ';
  end if;
  if to_regclass('public.profiles') is null then v_problems := v_problems || 'public.profiles is missing; '; end if;

  if v_problems <> '' then
    raise exception 'PIA 0035 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------
create table if not exists public.student_stage_time (
  student_email                    text primary key
                                   references public.profiles (email) on delete cascade,
  ocean_time                       integer not null default 0 check (ocean_time >= 0),
  character_select_time            integer not null default 0 check (character_select_time >= 0),
  tutoring_time                    integer not null default 0 check (tutoring_time >= 0),
  ocean_time_locked_at             timestamptz,
  character_select_time_locked_at  timestamptz,
  tutoring_time_locked_at          timestamptz,
  heartbeat_stage                  text,
  last_heartbeat_timestamp         timestamptz
);

comment on table public.student_stage_time is
  'Active seconds per stage, credited by record_heartbeat() from the server clock and frozen by finalize_stage_time() (0035).';

alter table public.student_stage_time enable row level security;
revoke all on public.student_stage_time from public, anon, authenticated;
grant select on public.student_stage_time to authenticated;

drop policy if exists student_stage_time_admin_read on public.student_stage_time;
create policy student_stage_time_admin_read on public.student_stage_time
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());


-- ---------------------------------------------------------------------------
-- 2. record_heartbeat(p_stage)
-- ---------------------------------------------------------------------------
create or replace function public.record_heartbeat(p_stage text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_row     public.student_stage_time%rowtype;
  v_locked  timestamptz;
  v_gap     numeric;
  v_credit  integer := 0;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  -- Only students are timed; a staff ping is simply ignored.
  if public.pia_caller_role() is distinct from 'student' then
    return jsonb_build_object('counted', false, 'reason', 'not_a_student');
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard') then
    return jsonb_build_object('counted', false, 'reason', 'unknown_stage');
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    return jsonb_build_object('counted', false, 'reason', 'no_profile');
  end if;

  -- A stage the student has already finished takes no more time.
  if not public.pia_can_enter_stage(v_profile.is_ocean_done, v_profile.group_type,
                                    v_profile.selected_character, p_stage) then
    return jsonb_build_object('counted', false, 'reason', 'stage_completed');
  end if;

  insert into public.student_stage_time (student_email) values (v_profile.email)
  on conflict (student_email) do nothing;

  select * into v_row from public.student_stage_time
   where student_email = v_profile.email for update;

  v_locked := case p_stage when 'OCEAN' then v_row.ocean_time_locked_at
                           when 'Character Selection' then v_row.character_select_time_locked_at
                           else v_row.tutoring_time_locked_at end;
  if v_locked is not null then
    return jsonb_build_object('counted', false, 'reason', 'locked', 'locked', true);
  end if;

  if v_row.last_heartbeat_timestamp is not null and v_row.heartbeat_stage = p_stage then
    v_gap := extract(epoch from (now() - v_row.last_heartbeat_timestamp));
    if v_gap < 10 then
      return jsonb_build_object('counted', false, 'reason', 'too_soon');
    elsif v_gap <= 45 then
      v_credit := least(30, floor(v_gap))::integer;
    end if;
  end if;

  update public.student_stage_time set
    ocean_time            = ocean_time + case when p_stage = 'OCEAN' then v_credit else 0 end,
    character_select_time = character_select_time + case when p_stage = 'Character Selection' then v_credit else 0 end,
    tutoring_time         = tutoring_time + case when p_stage = 'Tutoring Dashboard' then v_credit else 0 end,
    heartbeat_stage       = p_stage,
    last_heartbeat_timestamp = now()
   where student_email = v_profile.email
  returning * into v_row;

  return jsonb_build_object(
    'counted', v_credit > 0,
    'credited', v_credit,
    'seconds', case p_stage when 'OCEAN' then v_row.ocean_time
                            when 'Character Selection' then v_row.character_select_time
                            else v_row.tutoring_time end);
end;
$$;

revoke all on function public.record_heartbeat(text) from public, anon;
grant execute on function public.record_heartbeat(text) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. finalize_stage_time(p_stage) -- the final payload
-- ---------------------------------------------------------------------------
-- Called once when a student completes a stage. It credits the tail since the
-- last ping (same rules as above), then stamps *_locked_at, after which the
-- seconds for that stage can never change. Refused unless the stage really is
-- complete, so a page cannot freeze its own clock early. Calling it again
-- changes nothing.
create or replace function public.finalize_stage_time(p_stage text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  v_row     public.student_stage_time%rowtype;
  v_done    boolean;
  v_gap     numeric;
  v_credit  integer := 0;
  v_locked  timestamptz;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;

  if public.pia_caller_role() is distinct from 'student' then
    return jsonb_build_object('locked', false, 'reason', 'not_a_student');
  end if;

  if p_stage is null or p_stage not in ('OCEAN', 'Character Selection', 'Tutoring Dashboard') then
    return jsonb_build_object('locked', false, 'reason', 'unknown_stage');
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    return jsonb_build_object('locked', false, 'reason', 'no_profile');
  end if;

  v_done := case p_stage
              when 'OCEAN' then coalesce(v_profile.is_ocean_done, false)
              when 'Character Selection' then v_profile.selected_character is not null
              else not coalesce(v_profile.is_in_game, false) end;
  if not v_done then
    return jsonb_build_object('locked', false, 'reason', 'stage_not_completed');
  end if;

  insert into public.student_stage_time (student_email) values (v_profile.email)
  on conflict (student_email) do nothing;

  select * into v_row from public.student_stage_time
   where student_email = v_profile.email for update;

  v_locked := case p_stage when 'OCEAN' then v_row.ocean_time_locked_at
                           when 'Character Selection' then v_row.character_select_time_locked_at
                           else v_row.tutoring_time_locked_at end;
  if v_locked is null then
    if v_row.last_heartbeat_timestamp is not null and v_row.heartbeat_stage = p_stage then
      v_gap := extract(epoch from (now() - v_row.last_heartbeat_timestamp));
      if v_gap >= 10 and v_gap <= 45 then v_credit := least(30, floor(v_gap))::integer; end if;
    end if;

    update public.student_stage_time set
      ocean_time            = ocean_time + case when p_stage = 'OCEAN' then v_credit else 0 end,
      character_select_time = character_select_time + case when p_stage = 'Character Selection' then v_credit else 0 end,
      tutoring_time         = tutoring_time + case when p_stage = 'Tutoring Dashboard' then v_credit else 0 end,
      ocean_time_locked_at  = case when p_stage = 'OCEAN' then now() else ocean_time_locked_at end,
      character_select_time_locked_at = case when p_stage = 'Character Selection' then now() else character_select_time_locked_at end,
      tutoring_time_locked_at = case when p_stage = 'Tutoring Dashboard' then now() else tutoring_time_locked_at end,
      last_heartbeat_timestamp = now()
     where student_email = v_profile.email
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'locked', true,
    'seconds', case p_stage when 'OCEAN' then v_row.ocean_time
                            when 'Character Selection' then v_row.character_select_time
                            else v_row.tutoring_time end);
end;
$$;

revoke all on function public.finalize_stage_time(text) from public, anon;
grant execute on function public.finalize_stage_time(text) to authenticated;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- rehearsed as a real student and an administrator under RLS,
-- then rolled back (P0002), so no time is left recorded.
-- ---------------------------------------------------------------------------
do $$
declare
  v_student text;
  v_admin   text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_res     jsonb;
  v_n       int;
  v_fail    text := '';
begin
  if has_function_privilege('anon', 'public.record_heartbeat(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.finalize_stage_time(text)', 'EXECUTE') then
    raise exception 'PIA 0035 ABORT: anon can call the heartbeat functions.' using errcode = 'P0001';
  end if;
  if has_table_privilege('authenticated', 'public.student_stage_time', 'INSERT')
     or has_table_privilege('authenticated', 'public.student_stage_time', 'UPDATE') then
    raise exception 'PIA 0035 ABORT: a signed-in user can write student_stage_time directly.' using errcode = 'P0001';
  end if;

  select email into v_student from public.profiles
   where lower(trim(coalesce(role, 'student'))) = 'student' and not coalesce(is_ocean_done, false)
   order by email limit 1;
  select email into v_admin from public.profiles where lower(trim(role)) = 'admin' order by email limit 1;

  if v_student is null then
    raise notice 'PIA 0035: no student who has not finished OCEAN to rehearse with -- rehearsal skipped.';
    return;
  end if;

  begin
    perform set_config('request.jwt.claims', json_build_object(
      'email', v_student, 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';

    -- A. the first ping only starts the clock
    v_res := public.record_heartbeat('OCEAN');
    if (v_res ->> 'credited')::int <> 0 then v_fail := v_fail || 'the first ping was credited; '; end if;

    -- B. a ping straight after is ignored
    v_res := public.record_heartbeat('OCEAN');
    if v_res ->> 'reason' is distinct from 'too_soon' then v_fail := v_fail || 'a duplicate ping was not ignored; '; end if;

    -- C. 30 seconds later it is worth 30; 5 minutes of silence restarts the clock
    execute 'reset role';
    update public.student_stage_time set last_heartbeat_timestamp = now() - interval '30 seconds'
     where student_email = v_student;
    execute 'set local role authenticated';
    v_res := public.record_heartbeat('OCEAN');
    if (v_res ->> 'credited')::int <> 30 or (v_res ->> 'seconds')::int <> 30 then
      v_fail := v_fail || 'a 30 s ping was not worth 30 s (' || v_res::text || '); ';
    end if;

    execute 'reset role';
    update public.student_stage_time set last_heartbeat_timestamp = now() - interval '5 minutes'
     where student_email = v_student;
    execute 'set local role authenticated';
    v_res := public.record_heartbeat('OCEAN');
    if (v_res ->> 'credited')::int <> 0 or (v_res ->> 'seconds')::int <> 30 then
      v_fail := v_fail || 'time away was counted (' || v_res::text || '); ';
    end if;

    -- D. another stage is a separate clock, and an unknown one is refused
    v_res := public.record_heartbeat('Not a stage');
    if v_res ->> 'reason' is distinct from 'unknown_stage' then v_fail := v_fail || 'an unknown stage was accepted; '; end if;

    -- E. cannot lock a stage that is not complete
    v_res := public.finalize_stage_time('OCEAN');
    if (v_res ->> 'locked')::boolean then v_fail := v_fail || 'an unfinished stage was locked; '; end if;

    -- F. a student cannot read or write the table
    select count(*) into v_n from public.student_stage_time;
    if v_n <> 0 then v_fail := v_fail || 'a student can read the table; '; end if;

    -- G. an administrator can read it
    if v_admin is not null then
      execute 'reset role';
      perform set_config('request.jwt.claims', json_build_object(
        'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
      execute 'set local role authenticated';
      select count(*) into v_n from public.student_stage_time where student_email = v_student;
      if v_n <> 1 then v_fail := v_fail || 'an administrator cannot read the table; '; end if;
    end if;

    execute 'reset role';
    if v_fail <> '' then
      raise exception 'PIA 0035 ABORT: %', v_fail using errcode = 'P0001';
    end if;
    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0035 OK: pings are credited from the server clock, away time and duplicates are not, stages are separate, and only administrators can read the times.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260929_0036_revoke_stage_by_section
-- ############################################################################

-- ============================================================================
-- PIA 0036 -- REVOKE A STAGE FOR CHOSEN SECTIONS
-- ============================================================================
-- admin_grant_stage (0011/0033) lets a section into a closed stage. Until now
-- the only way back out was admin_set_stage_open(stage, false), which closes
-- the stage for EVERY section at once. This adds the missing half:
--
--   admin_revoke_stage(p_stage, p_sections text[])
--
-- For each named section, and only those:
--   * the section's record in stage_overrides is removed, and
--   * every student of the section who is in the stage now goes back to the
--     Waiting Room -- exactly what closing the stage does for everyone.
-- Sections not named are not touched, in either table.
--
-- DATA IS NEVER TOUCHED. The only columns written are profiles.current_stage
-- and profiles.stage_started_at on the students being moved -- the same two
-- columns admin_set_stage_open writes. OCEAN answers (ocean_submissions),
-- scores, the chosen character, tutoring sessions and their results, consent,
-- and the times in student_stage_time are all left exactly as they are.
--
-- A STUDENT WHO IS MID-WAY IS NOT CUT OFF FROM THEIR OWN WORK. Nothing that
-- saves work checks whether a stage is open: submit_ocean_results and the
-- tutoring functions look only at the student and their session. So a student
-- who is part-way through the questionnaire, or a tutoring session, can still
-- finish and save it after the revoke; what they cannot do is START again.
-- Entry is decided by the stage flag or by profiles.current_stage, and this
-- function clears both routes for the section. (The student page is told to
-- let them finish and to say why; see setupStudentRealtimeStageSync.)
--
-- A stage that is open for everyone (the old global switch) cannot be revoked
-- for some sections -- there is nothing section-specific to remove. It is
-- refused with a message rather than silently doing nothing; close it for
-- everyone first (admin_set_stage_open).
--
-- Requires 0003 (pia_stage_open users), 0033 (stage_overrides) and
-- 0020-0024 (pia_caller_role, jwt_is_current).
-- SAFE TO RE-RUN. The postflight rehearses it and rolls back.
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.stage_overrides') is null then
    raise exception 'PIA 0036 ABORT (nothing changed): public.stage_overrides is missing -- apply 0033 first.' using errcode = 'P0001';
  end if;
  if to_regprocedure('public.pia_stage_open(text)') is null
     or to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0036 ABORT (nothing changed): pia_stage_open / pia_caller_role / jwt_is_current is missing.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.admin_revoke_stage(p_stage text, p_sections text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label    text;
  v_sections text[];
  v_moved    int := 0;
  v_cleared  int := 0;
begin
  if public.pia_caller_role() is distinct from 'admin' or not public.jwt_is_current() then
    raise exception 'PIA: only an administrator can revoke a stage.' using errcode = '42501';
  end if;

  if p_stage is null or p_stage not in ('ocean', 'char', 'dash') then
    raise exception 'PIA: unknown stage key: %', coalesce(p_stage, '(null)') using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct s), '{}') into v_sections
    from (select nullif(trim(x), '') as s from unnest(coalesce(p_sections, '{}')) x) t
   where s is not null;

  if coalesce(array_length(v_sections, 1), 0) = 0 then
    raise exception 'PIA: choose at least one section to revoke.' using errcode = '22023';
  end if;

  if public.pia_stage_open('stage_' || p_stage) then
    raise exception 'PIA: this stage is open for every section. Close it for everyone first; it cannot be revoked one section at a time.'
      using errcode = 'P0001';
  end if;

  v_label := case p_stage when 'ocean' then 'OCEAN'
                          when 'char'  then 'Character Selection'
                          else 'Tutoring Dashboard' end;

  with gone as (
    delete from public.stage_overrides
     where stage = p_stage and section = any (v_sections)
    returning 1)
  select count(*) into v_cleared from gone;

  with moved as (
    update public.profiles
       set current_stage = 'Waiting Room', stage_started_at = now()
     where current_stage = v_label
       and section = any (v_sections)
       and lower(trim(coalesce(role, 'student'))) = 'student'
    returning 1)
  select count(*) into v_moved from moved;

  return jsonb_build_object('stage', p_stage, 'sections', to_jsonb(v_sections),
                            'cleared', v_cleared, 'moved', v_moved);
end;
$$;

revoke all on function public.admin_revoke_stage(text, text[]) from public, anon;
grant execute on function public.admin_revoke_stage(text, text[]) to authenticated;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_admin   text;
  v_iat     bigint := extract(epoch from clock_timestamp())::bigint + 5;
  v_res     jsonb;
  v_n       int;
  v_before  bigint;
  v_fail    text := '';
begin
  if has_function_privilege('anon', 'public.admin_revoke_stage(text, text[])', 'EXECUTE') then
    raise exception 'PIA 0036 ABORT: anon can call admin_revoke_stage.' using errcode = 'P0001';
  end if;

  select email into v_admin from public.profiles where lower(trim(role)) = 'admin' order by email limit 1;
  if v_admin is null then
    raise notice 'PIA 0036: no administrator to rehearse with -- skipped.';
    return;
  end if;

  begin
    -- Two probe students in two probe sections, both inside the stage, with a
    -- recorded section grant each. The stage itself is closed.
    delete from public.settings where key = 'stage_dash';
    insert into public.settings (key, value) values ('stage_dash', to_jsonb(false));

    -- (Consent and assent recorded: 0037 refuses a student row without both.)
    insert into public.profiles (email, full_name, role, section, current_stage, is_ocean_done,
                                 parental_consent, student_assent)
    values ('probe-a@pia-0036.test', 'Probe A', 'student', 'PIA-0036-A', 'Tutoring Dashboard', true, true, true),
           ('probe-b@pia-0036.test', 'Probe B', 'student', 'PIA-0036-B', 'Tutoring Dashboard', true, true, true);
    insert into public.stage_overrides (stage, section, granted_count)
    values ('dash', 'PIA-0036-A', 1), ('dash', 'PIA-0036-B', 1);

    select count(*) into v_before from public.profiles where email like 'probe-%@pia-0036.test';

    perform set_config('request.jwt.claims', json_build_object(
      'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';

    v_res := public.admin_revoke_stage('dash', array['PIA-0036-A']);
    execute 'reset role';

    -- A. section A is out; section B is exactly as it was
    if (select current_stage from public.profiles where email = 'probe-a@pia-0036.test') <> 'Waiting Room' then
      v_fail := v_fail || 'the named section was not moved; '; end if;
    if (select current_stage from public.profiles where email = 'probe-b@pia-0036.test') <> 'Tutoring Dashboard' then
      v_fail := v_fail || 'an unnamed section was moved; '; end if;
    select count(*) into v_n from public.stage_overrides where stage = 'dash' and section = 'PIA-0036-A';
    if v_n <> 0 then v_fail := v_fail || 'the named section''s record stayed; '; end if;
    select count(*) into v_n from public.stage_overrides where stage = 'dash' and section = 'PIA-0036-B';
    if v_n <> 1 then v_fail := v_fail || 'an unnamed section''s record was removed; '; end if;

    -- B. no student row was deleted or altered beyond the stage
    select count(*) into v_n from public.profiles where email like 'probe-%@pia-0036.test';
    if v_n <> v_before then v_fail := v_fail || 'a student row disappeared; '; end if;
    if not (select is_ocean_done from public.profiles where email = 'probe-a@pia-0036.test') then
      v_fail := v_fail || 'a student''s progress flag changed; '; end if;

    -- C. refused for a non-admin, for no sections, and for a globally open stage
    perform set_config('request.jwt.claims', json_build_object(
      'email', 'probe-b@pia-0036.test', 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';
    begin
      perform public.admin_revoke_stage('dash', array['PIA-0036-B']);
      v_fail := v_fail || 'a student could revoke; ';
    exception when sqlstate '42501' then null;
    end;
    execute 'reset role';

    perform set_config('request.jwt.claims', json_build_object(
      'email', v_admin, 'role', 'authenticated', 'iat', v_iat)::text, true);
    execute 'set local role authenticated';
    begin
      perform public.admin_revoke_stage('dash', array[]::text[]);
      v_fail := v_fail || 'an empty section list was accepted; ';
    exception when sqlstate '22023' then null;
    end;
    execute 'reset role';

    update public.settings set value = to_jsonb(true) where key = 'stage_dash';
    execute 'set local role authenticated';
    begin
      perform public.admin_revoke_stage('dash', array['PIA-0036-B']);
      v_fail := v_fail || 'a globally open stage was revoked per section; ';
    exception when sqlstate 'P0001' then null;
    end;
    execute 'reset role';

    if v_fail <> '' then
      raise exception 'PIA 0036 ABORT: %', v_fail using errcode = 'P0001';
    end if;
    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      raise notice 'PIA 0036 OK: only the named sections are revoked, their students return to the Waiting Room, nothing else changes, and only administrators can do it.';
  end;

  perform set_config('request.jwt.claims', '', true);
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260929_0037_registration_rules
-- ############################################################################

-- ============================================================================
-- PIA 0037 -- REGISTRATION RULES THE DATABASE ENFORCES
-- ============================================================================
-- Two rules that used to live only in the admin console's form, and so held
-- only for as long as nobody wrote to the API by another route:
--
--   1. A STUDENT CANNOT BE REGISTERED WITHOUT BOTH PARENTAL CONSENT AND
--      STUDENT ASSENT. The Register dialog already refuses to submit; this
--      refuses the row itself. It applies to NEW student rows only -- accounts
--      registered before 0033 carry "not recorded" (null) and stay as they are.
--
--   2. A STUDENT HAS ONE DEVICE. profiles.max_devices is forced to 1 for
--      students on every insert and update, and set to 1 for the rows that
--      exist. Combined with claim_student_session (0027) -- where the newest
--      sign-in becomes the only active session and every older session and
--      refresh token is deleted -- a second device signing in takes over and
--      the first is signed out. The console no longer offers a device limit
--      for students because there is nothing to choose.
--
-- Staff (admin, teacher) are not affected by either rule.
--
-- Requires 0033 (parental_consent, student_assent).
-- SAFE TO RE-RUN. The postflight rehearses both rules and rolls back.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles' and column_name = 'parental_consent')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'profiles' and column_name = 'student_assent')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'profiles' and column_name = 'max_devices') then
    raise exception 'PIA 0037 ABORT (nothing changed): profiles.parental_consent / student_assent / max_devices is missing -- apply 0033 first.'
      using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.pia_registration_rules()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(trim(coalesce(new.role, 'student'))) = 'student' then
    if tg_op = 'INSERT'
       and (new.parental_consent is not true or new.student_assent is not true) then
      raise exception 'PIA: a student cannot be registered without both parental consent and student assent.'
        using errcode = 'P0001';
    end if;
    new.max_devices := 1;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pia_registration_rules on public.profiles;
create trigger trg_pia_registration_rules
  before insert or update on public.profiles
  for each row execute function public.pia_registration_rules();

-- Existing students: one device. (The trigger above fires on this update and
-- leaves the consent columns alone, because it is not an insert.)
update public.profiles
   set max_devices = 1
 where lower(trim(coalesce(role, 'student'))) = 'student'
   and max_devices is distinct from 1;


-- ---------------------------------------------------------------------------
-- POSTFLIGHT -- rolled back.
-- ---------------------------------------------------------------------------
do $$
declare
  v_fail text := '';
  v_dev  int;
begin
  begin
    begin
      insert into public.profiles (email, full_name, role, section, parental_consent, student_assent)
      values ('probe-none@pia-0037.test', 'Probe', 'student', 'X', true, false);
      v_fail := v_fail || 'a student with no assent was registered; ';
    exception when sqlstate 'P0001' then null;
    end;

    begin
      insert into public.profiles (email, full_name, role, section, parental_consent, student_assent)
      values ('probe-none2@pia-0037.test', 'Probe', 'student', 'X', null, null);
      v_fail := v_fail || 'a student with no consent was registered; ';
    exception when sqlstate 'P0001' then null;
    end;

    insert into public.profiles (email, full_name, role, section, parental_consent, student_assent, max_devices)
    values ('probe-ok@pia-0037.test', 'Probe', 'student', 'X', true, true, 5);
    select max_devices into v_dev from public.profiles where email = 'probe-ok@pia-0037.test';
    if v_dev is distinct from 1 then v_fail := v_fail || 'max_devices was not forced to 1 on insert (' || coalesce(v_dev::text, 'null') || '); '; end if;

    update public.profiles set max_devices = 4 where email = 'probe-ok@pia-0037.test';
    select max_devices into v_dev from public.profiles where email = 'probe-ok@pia-0037.test';
    if v_dev is distinct from 1 then v_fail := v_fail || 'max_devices was raised by an update; '; end if;

    -- staff are unaffected
    insert into public.profiles (email, full_name, role, max_devices)
    values ('probe-staff@pia-0037.test', 'Probe Teacher', 'teacher', 3);
    select max_devices into v_dev from public.profiles where email = 'probe-staff@pia-0037.test';
    if v_dev is distinct from 3 then v_fail := v_fail || 'a teacher''s device limit was changed; '; end if;

    raise exception 'rehearsal done' using errcode = 'P0002';
  exception
    when sqlstate 'P0002' then
      if v_fail <> '' then
        raise exception 'PIA 0037 ABORT: %', v_fail using errcode = 'P0001';
      end if;
      raise notice 'PIA 0037 OK: a student needs both consent and assent, students have exactly one device, staff are unaffected.';
  end;
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20260930_0038_control_ocean_only_neutral_persona
-- ############################################################################

-- ============================================================================
-- PIA 0038 -- CONTROL IS OCEAN-ONLY; NEUTRAL IS A TUTOR PERSONA, NOT A CONDITION
-- ============================================================================
-- Research policy confirmed by the project owner:
--
--   * CONTROL students take OCEAN and nothing else. They cannot enter
--     Character Selection or the Tutoring Dashboard, whatever a stage's
--     open/closed flag or a section grant says.
--   * NEUTRAL ('pia-neutral') is a tutor persona. Free Choice students may
--     pick it in Character Selection; Assigned students may be given it. It is
--     no longer a research condition, so profiles.group_type = 'neutral' must
--     not be given to anyone NEW.
--
-- WHAT THIS MIGRATION CHANGES
--   1. pia_can_enter_stage(boolean, text, text, text): a Control student is
--      refused 'Tutoring Dashboard' (Character Selection was already refused:
--      it is for the free-choice group only). Every other group is evaluated
--      exactly as in 0005. set_student_stage, the stage-time heartbeat (0035)
--      and the student route guards all read this one function.
--   2. submit_ocean_results(integer[]): redefined from 0018 with ONE change,
--      the next-stage block. A Control student is sent to 'Waiting Room'
--      instead of 'Tutoring Dashboard'. The scoring, validation, storage and
--      grants are the 0018 text unchanged.
--   3. A trigger that refuses to ASSIGN group_type 'neutral' to a new row or
--      to change an existing row TO neutral.
--
--   4. A row-level guard, trg_pia_control_stage_guard: no writer at all, a
--      SECURITY DEFINER admin RPC included, can move a Control student INTO
--      'Character Selection' or 'Tutoring Dashboard', and a Control student's
--      own browser cannot start a tutoring session (is_in_game). The body of
--      admin_grant_stage__inner is not in this repository (it was created
--      outside the migration files), so whether a section grant defers to
--      pia_can_enter_stage could not be established from source; this guard
--      makes the answer irrelevant. The write is kept at the student's
--      current stage (stage_started_at and is_in_game too) instead of
--      raising, so a section grant still completes for the section's other
--      students. Limitation: such a grant's "granted" list may still name the
--      Control student; the stage did not change.

-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
--   * It does NOT update any profile. Existing group_type = 'neutral' rows keep
--     their group, section, stage, persona and scores. They keep behaving as
--     they do today (OCEAN, then the Tutoring Dashboard; no Character
--     Selection), because the stage rule gives 'neutral' no special case. The
--     trigger lets such a row be edited for any other reason and lets an admin
--     move it OUT of neutral; it only blocks moving anyone INTO it.
--   * It does NOT move Control students who are already in the Tutoring
--     Dashboard. Review them with supabase/INSPECT_neutral_and_control.sql
--     and decide per student (docs/neutral-control-handling-plan.md).
--   * It does not touch question_bank, settings, stage_overrides or any RPC
--     other than the two named above.
--
-- Requires 0005 (pia_can_enter_stage), 0018 (submit_ocean_results), 0037.
-- SAFE TO RE-RUN. The postflight proves no profile row was changed by the
-- migration itself, rehearses the new rules on probe rows, and rolls those
-- back.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_problems text := '';
begin
  if to_regprocedure('public.pia_can_enter_stage(boolean, text, text, text)') is null then
    v_problems := v_problems || 'pia_can_enter_stage(boolean, text, text, text) is missing (0005); ';
  end if;
  if to_regprocedure('public.submit_ocean_results(integer[])') is null then
    v_problems := v_problems || 'submit_ocean_results(integer[]) is missing (0018); ';
  end if;
  if to_regprocedure('public.pia_stage_open(text)') is null then
    v_problems := v_problems || 'pia_stage_open(text) is missing (0002); ';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles' and column_name = 'group_type') then
    v_problems := v_problems || 'profiles.group_type is missing; ';
  end if;
  if v_problems <> '' then
    raise exception 'PIA 0038 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;

-- A fingerprint of the profiles table, taken before anything changes and compared
-- by the postflight. It is an ORDINARY table, not a temporary one: the Supabase SQL
-- Editor can run the pieces of a script on different connections, and a TEMP table
-- (or ON COMMIT DROP) then vanishes before the postflight reads it (42P01). It holds
-- only a row count and a hash, no emails, and nothing can read it through the API.
-- Dropped by the postflight on success; a rollback removes it with the rest, and
-- the drop-if-exists below makes a re-run after any interruption safe.
drop table if exists public.pia_0038_snapshot;
create table public.pia_0038_snapshot as
  select count(*)::bigint as n,
         coalesce(md5(string_agg(md5(row(email, group_type, section, current_stage,
                                          selected_character, is_ocean_done)::text),
                                 ',' order by email)), '') as digest
    from public.profiles;
alter table public.pia_0038_snapshot enable row level security;
revoke all on public.pia_0038_snapshot from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- PART 1 -- the stage rule. Same signature and attributes as 0005.
-- ---------------------------------------------------------------------------
create or replace function public.pia_can_enter_stage(
  p_is_ocean_done      boolean,
  p_group_type         text,
  p_selected_character text,
  p_stage              text)
returns boolean
language sql
immutable
as $$
  select case p_stage
    when 'OCEAN' then
      not coalesce(p_is_ocean_done, false)
    when 'Character Selection' then
      coalesce(p_is_ocean_done, false)
      and lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
      and p_selected_character is null
    when 'Tutoring Dashboard' then
      coalesce(p_is_ocean_done, false)
      and lower(trim(coalesce(p_group_type, ''))) <> 'control'
      and not (lower(trim(coalesce(p_group_type, ''))) in ('non-assigned', 'non_assigned')
               and p_selected_character is null)
    when 'Waiting Room' then
      true
    else false
  end;
$$;


-- ---------------------------------------------------------------------------
-- PART 2 -- submit_ocean_results: 0018 text, next-stage block changed.
-- ---------------------------------------------------------------------------
create or replace function public.submit_ocean_results(p_responses integer[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  r         integer[];
  k         record;
  v_needs_character boolean;
  v_is_control boolean;
  v_next_stage text;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  -- Once only. The admin retake action sets is_ocean_done back to false.
  if coalesce(v_profile.is_ocean_done, false) then
    raise exception 'PIA: this questionnaire has already been submitted. Ask an admin for a retake.'
      using errcode = '42501';
  end if;

  if p_responses is null or array_length(p_responses, 1) is distinct from 50 then
    raise exception 'PIA: exactly 50 responses are required (received: %).',
      coalesce(array_length(p_responses, 1), 0) using errcode = '22023';
  end if;

  -- Re-based to 1..50 in order, so r[n] is item n even if a caller crafts an
  -- array with a different lower bound.
  r := array(select x from unnest(p_responses) with ordinality as t(x, i) order by i);

  if exists (select 1 from unnest(r) v where v is null or v < 1 or v > 5) then
    raise exception 'PIA: every response must be between 1 and 5.' using errcode = '22023';
  end if;

  select * into k from public.pia_bfpt_score(r);

  -- Next stage -- decided here, never in the browser. 0038: a Control student
  -- has no stage after OCEAN, so they are parked in the Waiting Room (always
  -- permitted); the student pages show them the thank-you screen there.
  v_is_control := lower(trim(coalesce(v_profile.group_type, ''))) = 'control';
  v_needs_character :=
    lower(trim(coalesce(v_profile.group_type, ''))) in ('non-assigned', 'non_assigned')
    and v_profile.selected_character is null;

  if v_is_control then
    v_next_stage := 'Waiting Room';
  elsif v_needs_character then
    v_next_stage := case when public.pia_stage_open('stage_char')
                         then 'Character Selection' else 'Waiting Room' end;
  else
    v_next_stage := case when public.pia_stage_open('stage_dash')
                         then 'Tutoring Dashboard' else 'Waiting Room' end;
  end if;

  insert into public.ocean_submissions
         (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, scoring_key, source)
  values (v_email, r::smallint[], k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o,
          'bfpt-2026-07-22', 'questionnaire');

  -- The completion flag and the stage. Deliberately no score.
  update public.profiles set
    is_ocean_done    = true,
    current_stage    = v_next_stage,
    stage_started_at = now()
  where email = v_email;

  return jsonb_build_object('next_stage', v_next_stage);
end;
$$;

revoke all on function public.submit_ocean_results(integer[]) from public, anon;
grant execute on function public.submit_ocean_results(integer[]) to authenticated;


-- ---------------------------------------------------------------------------
-- PART 3 -- no NEW neutral assignments. Existing neutral rows are untouched.
-- ---------------------------------------------------------------------------
create or replace function public.pia_no_new_neutral_group()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(trim(coalesce(new.group_type, ''))) = 'neutral'
     and (tg_op = 'INSERT'
          or lower(trim(coalesce(old.group_type, ''))) is distinct from 'neutral') then
    raise exception 'PIA: "neutral" is a tutor persona, not a research condition. Use the assigned or free-choice group, and give the persona instead.'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pia_no_new_neutral_group on public.profiles;
create trigger trg_pia_no_new_neutral_group
  before insert or update of group_type on public.profiles
  for each row execute function public.pia_no_new_neutral_group();


-- ---------------------------------------------------------------------------
-- PART 4 -- no writer can move a Control student into a closed-to-Control stage
-- ---------------------------------------------------------------------------
create or replace function public.pia_control_stage_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(trim(coalesce(new.group_type, ''))) = 'control'
     and new.current_stage in ('Character Selection', 'Tutoring Dashboard')
     and (tg_op = 'INSERT' or new.current_stage is distinct from old.current_stage) then
    if tg_op = 'INSERT' then
      new.current_stage := 'Waiting Room';
    else
      -- Keep the student where they are. A Control student already in the
      -- dashboard before this migration is not moved by it either.
      new.current_stage    := old.current_stage;
      new.stage_started_at := old.stage_started_at;
      new.is_in_game       := old.is_in_game;
    end if;
  end if;

  -- "In a tutoring session" is written by the student's own browser
  -- (is_in_game is student-writable). A Control student has no session, so a
  -- write that would start one is dropped. A row that already says true is
  -- left as it is (not cleared by this migration).
  if lower(trim(coalesce(new.group_type, ''))) = 'control'
     and coalesce(new.is_in_game, false)
     and (tg_op = 'INSERT' or not coalesce(old.is_in_game, false)) then
    new.is_in_game := false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pia_control_stage_guard on public.profiles;
create trigger trg_pia_control_stage_guard
  before insert or update of current_stage, is_in_game, group_type on public.profiles
  for each row execute function public.pia_control_stage_guard();


-- ---------------------------------------------------------------------------
-- POSTFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_fail   text := '';
  v_n      int;
  v_legacy int;
  v_ctl    int;
  v_def    text;
  v_n0     bigint;
  v_n1     bigint;
  v_d0     text;
  v_d1     text;
begin
  -- (1) The rule, group by group (pure function, no data).
  if public.pia_can_enter_stage(true,  'control',      null,  'Tutoring Dashboard')   then v_fail := v_fail || 'control can enter the dashboard; '; end if;
  if public.pia_can_enter_stage(true,  ' Control ',    null,  'Tutoring Dashboard')   then v_fail := v_fail || 'control (padded/cased) can enter the dashboard; '; end if;
  if public.pia_can_enter_stage(true,  'control',      null,  'Character Selection')  then v_fail := v_fail || 'control can enter character selection; '; end if;
  if not public.pia_can_enter_stage(false, 'control',  null,  'OCEAN')                then v_fail := v_fail || 'control cannot take OCEAN; '; end if;
  if public.pia_can_enter_stage(true,  'control',      null,  'OCEAN')                then v_fail := v_fail || 'control can retake OCEAN without a reset; '; end if;
  if not public.pia_can_enter_stage(true, 'control',   null,  'Waiting Room')         then v_fail := v_fail || 'control cannot wait; '; end if;
  if not public.pia_can_enter_stage(true, 'assigned',  null,  'Tutoring Dashboard')   then v_fail := v_fail || 'assigned lost the dashboard; '; end if;
  if public.pia_can_enter_stage(true,  'assigned',     null,  'Character Selection')  then v_fail := v_fail || 'assigned gained character selection; '; end if;
  if not public.pia_can_enter_stage(true, 'non-assigned', null, 'Character Selection') then v_fail := v_fail || 'free choice lost character selection; '; end if;
  if public.pia_can_enter_stage(true,  'non-assigned', null,  'Tutoring Dashboard')   then v_fail := v_fail || 'free choice reached the dashboard before choosing; '; end if;
  if not public.pia_can_enter_stage(true, 'non-assigned', 'pia-neutral', 'Tutoring Dashboard') then v_fail := v_fail || 'free choice who picked pia-neutral cannot enter the dashboard; '; end if;
  if not public.pia_can_enter_stage(true, 'neutral',   null,  'Tutoring Dashboard')   then v_fail := v_fail || 'existing neutral rows lost the dashboard; '; end if;
  if public.pia_can_enter_stage(true,  'neutral',      null,  'Character Selection')  then v_fail := v_fail || 'existing neutral rows gained character selection; '; end if;

  -- (2) The new next-stage block is in place and the rest of 0018 is intact.
  select pg_get_functiondef('public.submit_ocean_results(integer[])'::regprocedure) into v_def;
  if v_def !~ 'v_is_control' or v_def !~ 'pia_bfpt_score' or v_def !~ 'ocean_submissions' then
    v_fail := v_fail || 'submit_ocean_results is not the expected text; ';
  end if;

  -- (3) Nothing was written to any profile by this migration.
  select s.n, s.digest into v_n0, v_d0 from public.pia_0038_snapshot s;
  select count(*)::bigint,
         coalesce(md5(string_agg(md5(row(email, group_type, section, current_stage,
                                          selected_character, is_ocean_done)::text),
                                 ',' order by email)), '')
    into v_n1, v_d1 from public.profiles;
  if v_n1 <> v_n0 then
    v_fail := v_fail || 'profile row count changed (' || v_n0 || ' -> ' || v_n1 || '); ';
  elsif v_d1 <> v_d0 then
    v_fail := v_fail || 'a profile row changed during the migration; ';
  end if;

  -- (4) The no-new-neutral trigger, rehearsed on probe rows and rolled back.
  begin
    begin
      begin
        insert into public.profiles (email, full_name, role, section, group_type, parental_consent, student_assent)
        values ('probe-neutral-new@pia-0038.test', 'Probe', 'student', 'X', 'neutral', true, true);
        v_fail := v_fail || 'a NEW neutral student was accepted; ';
      exception when sqlstate 'P0001' then null;
      end;

      insert into public.profiles (email, full_name, role, section, group_type, parental_consent, student_assent)
      values ('probe-assigned@pia-0038.test', 'Probe', 'student', 'X', 'assigned', true, true);

      begin
        update public.profiles set group_type = 'neutral' where email = 'probe-assigned@pia-0038.test';
        v_fail := v_fail || 'an existing student could be moved INTO neutral; ';
      exception when sqlstate 'P0001' then null;
      end;

      -- A legacy neutral row (made by switching the trigger off for the probe
      -- only) can still be edited and can leave neutral.
      alter table public.profiles disable trigger trg_pia_no_new_neutral_group;
      update public.profiles set group_type = 'neutral' where email = 'probe-assigned@pia-0038.test';
      alter table public.profiles enable trigger trg_pia_no_new_neutral_group;

      update public.profiles set section = 'Y' where email = 'probe-assigned@pia-0038.test';
      update public.profiles set group_type = 'neutral', section = 'Z' where email = 'probe-assigned@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-assigned@pia-0038.test' and group_type = 'neutral' and section = 'Z';
      if v_n <> 1 then v_fail := v_fail || 'a legacy neutral row could not be edited; '; end if;

      update public.profiles set group_type = 'assigned' where email = 'probe-assigned@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-assigned@pia-0038.test' and group_type = 'assigned';
      if v_n <> 1 then v_fail := v_fail || 'a legacy neutral row could not leave neutral; '; end if;

      -- The Control stage guard, through a plain update (no RPC needed).
      insert into public.profiles (email, full_name, role, section, group_type, current_stage, parental_consent, student_assent)
      values ('probe-control@pia-0038.test', 'Probe', 'student', 'X', 'control', 'Tutoring Dashboard', true, true);
      select count(*) into v_n from public.profiles
       where email = 'probe-control@pia-0038.test' and current_stage = 'Waiting Room';
      if v_n <> 1 then v_fail := v_fail || 'a Control student was inserted straight into the dashboard; '; end if;
      update public.profiles set current_stage = 'Tutoring Dashboard' where email = 'probe-control@pia-0038.test';
      update public.profiles set current_stage = 'Character Selection' where email = 'probe-control@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-control@pia-0038.test' and current_stage = 'Waiting Room';
      if v_n <> 1 then v_fail := v_fail || 'a Control student could be moved into the dashboard / character selection; '; end if;
      update public.profiles set current_stage = 'OCEAN' where email = 'probe-control@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-control@pia-0038.test' and current_stage = 'OCEAN';
      if v_n <> 1 then v_fail := v_fail || 'a Control student could not be moved to OCEAN; '; end if;
      -- A Control student cannot start a tutoring session; others can.
      update public.profiles set is_in_game = true where email = 'probe-control@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-control@pia-0038.test' and is_in_game = false;
      if v_n <> 1 then v_fail := v_fail || 'a Control student could start a tutoring session; '; end if;
      update public.profiles set is_in_game = true where email = 'probe-assigned@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-assigned@pia-0038.test' and is_in_game = true;
      if v_n <> 1 then v_fail := v_fail || 'the Control guard blocked an Assigned student starting a session; '; end if;
      update public.profiles set is_in_game = false where email = 'probe-assigned@pia-0038.test';
      update public.profiles set current_stage = 'Tutoring Dashboard' where email = 'probe-assigned@pia-0038.test';
      select count(*) into v_n from public.profiles
       where email = 'probe-assigned@pia-0038.test' and current_stage = 'Tutoring Dashboard';
      if v_n <> 1 then v_fail := v_fail || 'the Control guard blocked an Assigned student; '; end if;

      raise exception 'rehearsal done' using errcode = 'P0002';
    exception when sqlstate 'P0002' then null;
    end;
  end;

  -- (5) Report, never change: how many existing rows the plan has to cover.
  select count(*) into v_legacy from public.profiles where lower(trim(coalesce(group_type, ''))) = 'neutral';
  select count(*) into v_ctl from public.profiles
   where lower(trim(coalesce(group_type, ''))) = 'control'
     and (current_stage = 'Tutoring Dashboard' or coalesce(is_in_game, false));
  raise notice 'PIA 0038: % existing neutral student(s) left exactly as they were; % control student(s) currently in the Tutoring Dashboard need a decision (see the handling plan).', v_legacy, v_ctl;

  -- admin_grant_stage__inner is not in this repository; say so if it does not
  -- defer to the stage rule, because then a section grant could still move a
  -- Control student into the dashboard.
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'admin_grant_stage__inner' limit 1;
  if v_def is null then
    raise notice 'PIA 0038 REVIEW: admin_grant_stage__inner was not found; confirm how admin_grant_stage decides who is eligible.';
  elsif v_def !~ 'pia_can_enter_stage' then
    raise notice 'PIA 0038 REVIEW: admin_grant_stage__inner does not call pia_can_enter_stage; confirm a section grant cannot move a Control student into the Tutoring Dashboard.';
  end if;

  if v_fail <> '' then
    raise exception 'PIA 0038 ABORT: %', v_fail using errcode = 'P0001';
  end if;

  -- Checks passed: the fingerprint has done its job.
  drop table public.pia_0038_snapshot;
  raise notice 'PIA 0038 OK: Control is OCEAN-only; Neutral can no longer be assigned as a condition; no profile was changed.';
end;
$$;

commit;

notify pgrst, 'reload schema';


-- ############################################################################
-- MIGRATION 20261003_0039_step_based_game
-- ############################################################################

-- ============================================================================
-- PIA 0039 -- THE STEP-BY-STEP GAME, CHECKED ON THE SERVER
-- ============================================================================
-- DRAFT FOR REVIEW. NOT APPLIED. Written without a database to run it against
-- (see "What was and was not verified" at the bottom). Read it, run it on a
-- staging copy first, then apply.
--
-- WHY
--   The attached game (pia-test-main) teaches Percentages one STEP at a time:
--   Topic 1 has 2 steps (Conversion, Multiplication); Topics 2 and 3 have 3
--   (Subtraction, Division, Conversion). 0029 serves the same question bank
--   but asks only for the final answer, with two tries. This migration brings
--   the game's own rules onto the server so the browser can show the new
--   screen without ever holding an answer.
--
-- THE TIME LIMIT (the game's rule, kept; enforced here, not in the browser)
--   * app_config.time_limit is the admin's limit in MINUTES (default 10, the
--     game's own fallback of 600 s). Added below; the Admin Math Task editor
--     (deferred) is where it gets edited.
--   * ONE continuous deadline for the whole session, not one per problem. It
--     starts when the first problem is served and does not stop or reset
--     between questions or topics.
--   * When it passes, the server refuses further answers and hints
--     ('time_expired'). The browser shows the game's "Time limit reached"
--     dialog (limit, started, finished, spent).
--   * "Try again" (restart_after_expiry) is the game's Try Again: the open
--     problem is reloaded from step 1 with its error and hint counts back at
--     zero (as loadCurrentProblem does), a NEW window with a fresh deadline
--     starts, and the student's topic and topic progress are kept. Every
--     expired window is logged in game_windows.
--   * The deadline is wall-clock, so reloading the page or signing out does
--     not give more time. (The game kept its timer in the page and a reload
--     restarted everything; resume is a requirement here, so the deadline
--     lives on the server.)
--
-- THE GAME'S RULES, AS PORTED (from index.html in pia-test-main)
--   * A question has N steps. A step is solved when the student gives its
--     value. Wrong answers do not end the question: there is no try limit.
--   * Working is accepted but not final: "30 x 0.3" or "80/100" that evaluates
--     to the right value only opens a second box that asks for the value by
--     itself ("confirm" stage). Conversion steps need a decimal (Topic 1) or a
--     percentage (Topics 2-3), with or without the % sign.
--   * After two wrong answers on a step the hint button appears. Each step has
--     up to three hints (Concept, Setup, Worked calculation); each press moves
--     one tier up and the last tier repeats. The tier starts again on the next
--     step and when the confirm box opens.
--   * A question is "accurate" when it was finished with no wrong answer.
--   * Topic movement is OFFERED, never forced:
--       DOWN   after "Wrong to level down" (max_errors) questions in a row that
--              were not accurate, on Topic 2 or 3 -- checked first;
--       UP     after "Solved to level up" (min_questions) questions in this
--              topic with accuracy >= the mastery threshold, on Topic 1 or 2.
--     The student accepts or refuses. Accept: the new topic starts a fresh
--     window. Refuse after an UP offer: a fresh window on the same topic.
--     Refuse after a DOWN offer: the failure streak starts again at zero.
--     The numbers are the admin's (app_config), as in 0029.
--
-- WHAT STAYS ON THE SERVER (unchanged principle from 0029)
--   question_bank and served_questions have no student access. Every answer is
--   compared here; the browser receives right/wrong, the step the student is
--   on, and the student's OWN accepted values. A step's answer is never
--   returned, and a hint is only returned after two wrong answers.
--
-- WHO MAY ENTER (the research groups; group_type is the admin's and is never
-- read from the browser)
--   This migration does NOT redefine pia_can_enter_stage. The stage rule is
--   0038 (20260930_0038_control_ocean_only_neutral_persona.sql): Control is
--   refused the Tutoring Dashboard, free choice needs a saved tutor, and
--   assigned / legacy neutral may reach the dashboard with or without one.
--   Every game call below adds ONE condition on top of it: a saved tutor.
--     assigned / legacy neutral  the admin must have set selected_character.
--                                A missing tutor is never filled in.
--     non-assigned               the student has saved a tutor.
--     control / anything else    never (0038 for control; the group list
--                                below for unknown values) -- including a
--                                direct RPC call.
--
-- DEPARTURES FROM THE ATTACHED GAME, ON PURPOSE
--   * The game's time limit IS implemented (it was the first draft's gap).
--     See "THE TIME LIMIT" below. There is no 10-question ending any more:
--     like the game, a session continues until the student stops.
--   * No external ML call. The tutor's wording profile stays "average", the
--     game's own default. DECISION PENDING with the researcher.
--   * Questions whose steps JSON is missing or short are not served. The game
--     rebuilt steps in the browser from the question text for older rows; that
--     guesses an answer key, so it is not ported. The Admin Math Task editor
--     is where steps are authored.
--   * "^" is not accepted in working (Grade 7 arithmetic; it also keeps the
--     evaluator below trivially safe).
--   * Classification. The attached game has no smooth/struggling label. Its
--     only per-question rule is "accurate": finished with no wrong answer
--     (hints do not count against it, time is not part of it). That is the
--     rule used for both is_correct and classification ('smooth' when
--     accurate, else 'struggling'). No time or hint threshold is invented.
--
-- OLD CALLS ARE NOT CLOSED HERE. serve_next_question, check_question_answer,
-- consume_question_hint, reveal_question_solution and record_question_result
-- (0029) stay executable by signed-in users. They enforce the two-try rule,
-- so once every caller has moved they should be revoked: see
-- supabase/PROPOSED_close_old_question_rpcs.sql (not a migration; run it
-- only after the regression suites pass).
--
-- SAFE TO RE-RUN: tables/columns only if missing, functions replaced.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PREFLIGHT
-- ---------------------------------------------------------------------------
do $$
declare
  v_problems text := '';
  t          text;
begin
  foreach t in array array['served_questions', 'student_topic_progress', 'topic_changes',
                           'tutoring_attempts', 'problem_serves', 'app_config', 'profiles'] loop
    if to_regclass('public.' || t) is null then
      v_problems := v_problems || 'public.' || t || ' is missing; ';
    end if;
  end loop;
  if to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    v_problems := v_problems || 'pia_caller_role()/jwt_is_current() are missing; ';
  end if;
  if to_regprocedure('public.pia_parse_hint(text)') is null
     or to_regprocedure('public.pia_student_topic(text)') is null
     or to_regprocedure('public.pia_result_payload(uuid,text,text)') is null then
    v_problems := v_problems || '0029 helpers are missing (run 0029 first); ';
  end if;
  if to_regprocedure('public.pia_can_enter_stage(boolean, text, text, text)') is null
     or not exists (select 1 from pg_trigger where tgname = 'trg_pia_control_stage_guard') then
    v_problems := v_problems || '0038 (Control OCEAN-only) is missing -- apply it first; ';
  end if;
  if to_regprocedure('public.start_game_session()') is null then
    v_problems := v_problems || 'start_game_session() is missing; ';
  end if;
  if v_problems <> '' then
    raise exception 'PIA 0039 ABORT (nothing changed): %', v_problems using errcode = 'P0001';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 1. Tables. No grants: only the functions below touch them. The three event
--    tables are readable by admins for the analysis.
-- ---------------------------------------------------------------------------
alter table public.student_topic_progress
  add column if not exists failed_streak int not null default 0;

create table if not exists public.step_states (
  session_id    uuid        not null,
  student_email text        not null,
  problem_id    text        not null,
  step_index    int         not null default 0,           -- 0-based step being worked on
  stage         text        not null default 'work' check (stage in ('work', 'confirm')),
  work_text     text,                                      -- correct working awaiting its final value
  wrong_streak  int         not null default 0,            -- wrong answers on this step/stage
  hint_tier     int         not null default 0,            -- 0 = none yet; repeats at the last tier
  errors        int         not null default 0,            -- every wrong answer, whole question
  hints         int         not null default 0,            -- every hint pressed, whole question
  hint_unlocked boolean     not null default false,
  done_steps    jsonb       not null default '[]'::jsonb,  -- [{"text":..,"confirmed":..}]
  completed     boolean     not null default false,
  updated_at    timestamptz not null default now(),
  primary key (session_id, student_email, problem_id)
);

create table if not exists public.step_events (
  id            bigint generated always as identity primary key,
  session_id    uuid        not null,
  student_email text        not null,
  problem_id    text        not null,
  step_index    int         not null,
  stage         text        not null,
  submitted     text        not null,
  outcome       text        not null,   -- wrong | needs_final | format_error | step_done | question_done | restart
  happened_at   timestamptz not null default now()
);
create index if not exists step_events_lookup_idx on public.step_events (session_id, student_email, problem_id);

create table if not exists public.step_hints (
  id            bigint generated always as identity primary key,
  session_id    uuid        not null,
  student_email text        not null,
  problem_id    text        not null,
  step_index    int         not null,
  tier          int         not null,
  tiers_total   int         not null,
  taken_at      timestamptz not null default now()
);
create index if not exists step_hints_lookup_idx on public.step_hints (session_id, student_email, problem_id);

create table if not exists public.topic_offers (
  session_id    uuid        not null,
  student_email text        not null,
  problem_id    text        not null,
  offer         text        not null check (offer in ('up', 'down')),
  from_topic    int         not null,
  target_topic  int         not null,
  status        text        not null default 'pending' check (status in ('pending', 'accepted', 'refused')),
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz,
  primary key (session_id, student_email, problem_id)
);

alter table public.app_config
  add column if not exists time_limit int not null default 10;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_config_time_limit_check') then
    alter table public.app_config add constraint app_config_time_limit_check
      check (time_limit between 1 and 240);
  end if;
end;
$$;

alter table public.step_states add column if not exists passed boolean;
alter table public.step_states add column if not exists score  int;

-- One row per time window. The newest row is the live one; it is expired when
-- now() >= deadline_at and ended_at is null (restart_after_expiry closes it).
create table if not exists public.game_windows (
  session_id      uuid        not null,
  student_email   text        not null,
  window_no       int         not null,
  started_at      timestamptz not null default now(),
  limit_seconds   int         not null,
  deadline_at     timestamptz not null,
  ended_at        timestamptz,
  ended_reason    text,
  topic           int,
  open_problem_id text,
  errors          int,
  hints           int,
  primary key (session_id, student_email, window_no)
);

alter table public.step_states  enable row level security;
alter table public.step_events  enable row level security;
alter table public.step_hints   enable row level security;
alter table public.topic_offers enable row level security;
alter table public.game_windows enable row level security;

revoke all on public.step_states  from public, anon, authenticated;
revoke all on public.step_events  from public, anon, authenticated;
revoke all on public.step_hints   from public, anon, authenticated;
revoke all on public.topic_offers from public, anon, authenticated;
revoke all on public.game_windows from public, anon, authenticated;

drop policy if exists step_events_admin_read on public.step_events;
create policy step_events_admin_read on public.step_events
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());
drop policy if exists step_hints_admin_read on public.step_hints;
create policy step_hints_admin_read on public.step_hints
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());
drop policy if exists topic_offers_admin_read on public.topic_offers;
create policy topic_offers_admin_read on public.topic_offers
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());
grant select on public.step_events  to authenticated;
grant select on public.step_hints   to authenticated;
drop policy if exists game_windows_admin_read on public.game_windows;
create policy game_windows_admin_read on public.game_windows
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());
grant select on public.topic_offers to authenticated;
grant select on public.game_windows to authenticated;


-- ---------------------------------------------------------------------------
-- 2. Helpers (not callable from the browser)
-- ---------------------------------------------------------------------------

-- Steps per topic: Topic 1 has 2, Topics 2 and 3 have 3.
create or replace function public.pia_step_required(p_topic int)
returns int language sql immutable as $$
  select case when p_topic = 1 then 2 else 3 end;
$$;

-- The name shown on a step card. p_idx is 0-based.
create or replace function public.pia_step_label(p_topic int, p_idx int)
returns text language sql immutable as $$
  select case when p_topic = 1 then (array['Conversion', 'Multiplication'])[p_idx + 1]
              else (array['Subtraction', 'Division', 'Conversion'])[p_idx + 1] end;
$$;

-- What the confirm box must hold: a decimal (Topic 1 conversion), a
-- percentage (Topic 2-3 conversion) or a plain number.
create or replace function public.pia_step_confirm_kind(p_topic int, p_idx int)
returns text language sql immutable as $$
  select case when public.pia_step_label(p_topic, p_idx) = 'Conversion'
              then (case when p_topic = 1 then 'decimal' else 'percentage' end)
              else 'number' end;
$$;

-- A question can be served only if its first N steps all carry an answer.
create or replace function public.pia_steps_valid(p_steps jsonb, p_topic int)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  n int := public.pia_step_required(p_topic);
  i int;
begin
  if p_steps is null or jsonb_typeof(p_steps) <> 'array' or jsonb_array_length(p_steps) < n then
    return false;
  end if;
  for i in 0 .. n - 1 loop
    if nullif(trim(coalesce(p_steps -> i ->> 'answer', p_steps -> i ->> 'stepAnswer', '')), '') is null then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

-- Evaluates plain arithmetic the way the game did (math.js), or null if the
-- text is not arithmetic. DYNAMIC SQL, so the whitelist below is the safety:
-- only digits, + - * / ( ) . and whitespace ever reach EXECUTE -- no letters,
-- quotes, semicolons or "$". "--" and "/*" (SQL comment starters) are
-- refused, and 60 characters is the cap (the callers truncate to 60).
create or replace function public.pia_eval_expr(p_text text)
returns numeric
language plpgsql
volatile
set search_path = pg_catalog, public
as $$
declare
  e text := coalesce(p_text, '');
  r numeric;
begin
  e := replace(e, ',', '');
  e := regexp_replace(e, 'PHP|₱', '', 'gi');
  e := translate(e, '×·÷−', '**/-');
  e := replace(e, '%', '');
  e := regexp_replace(e, '(\d|\))\s*[xX]\s*(\d|\()', '\1*\2', 'g');
  e := btrim(e);

  if e = '' or length(e) > 60 then return null; end if;
  if e !~ '^[0-9+*/(). [:space:]-]+$' then return null; end if;
  if position('--' in e) > 0 or position('/*' in e) > 0 or position('*/' in e) > 0 then
    return null;
  end if;

  -- Every number becomes numeric first, or 80/100 would be integer division.
  e := regexp_replace(e, '(\d+\.?\d*|\.\d+)', '(\1)::numeric', 'g');

  begin
    execute 'select (' || e || ')::numeric' into r;
  exception when others then
    return null;       -- syntax error, divide by zero, overflow
  end;
  return r;
end;
$$;

-- Same value within 0.001, else a case-insensitive text match -- the game's
-- isCorrectMathValue().
create or replace function public.pia_step_matches(p_submitted text, p_key text)
returns boolean
language plpgsql
volatile
set search_path = public
as $$
declare
  u numeric := public.pia_eval_expr(p_submitted);
  k numeric := public.pia_eval_expr(p_key);
begin
  if u is not null and k is not null then
    return abs(u - k) <= 0.001;
  end if;
  return lower(trim(coalesce(p_submitted, ''))) = lower(trim(coalesce(p_key, '')));
end;
$$;

-- Did the student type working (an operation) instead of one value? The
-- game's containsMathOperation().
create or replace function public.pia_has_working(p_text text)
returns boolean
language sql
immutable
as $$
  with t as (
    select regexp_replace(translate(btrim(coalesce(p_text, '')), '×·÷−', '**/-'), '^[+-]\s*', '') as w
  )
  select w ~ '[*/^()]'
      or w ~ '\d\s*[xX]\s*(\d|\.)'
      or w ~ '(\d|\))\s*[+-]\s*(\d|\()'
  from t;
$$;

-- Is this one value in the shape the confirm box wants? A percentage may
-- carry a % sign; a decimal or plain number may not.
create or replace function public.pia_is_final_format(p_kind text, p_text text)
returns boolean
language sql
immutable
as $$
  select case when p_kind = 'percentage'
              then btrim(coalesce(p_text, '')) ~ '^[+-]?(\d+(\.\d+)?|\.\d+)\s*%?$'
              else btrim(coalesce(p_text, '')) ~ '^[+-]?(\d+(\.\d+)?|\.\d+)$' end;
$$;

-- "0.80" -> "0.8", and "20" -> "20%" for a percentage.
create or replace function public.pia_format_final(p_kind text, p_value numeric)
returns text
language sql
immutable
as $$
  select trim_scale(round(p_value, 10))::text || case when p_kind = 'percentage' then '%' else '' end;
$$;

-- The hints of one step, easiest first.
create or replace function public.pia_step_hints(p_step jsonb, p_default text)
returns text[]
language plpgsql
immutable
set search_path = public
as $$
declare
  r text[] := '{}';
  t int;
  v text;
begin
  for t in 1 .. 3 loop
    v := nullif(trim(coalesce(p_step ->> ('hint' || t), '')), '');
    if v is not null then r := r || v; end if;
  end loop;

  if cardinality(r) = 0 and jsonb_typeof(p_step -> 'hints') = 'array' then
    select coalesce(array_agg(trim(e.v) order by e.ord) filter (where nullif(trim(e.v), '') is not null), '{}')
      into r
      from jsonb_array_elements_text(p_step -> 'hints') with ordinality as e(v, ord);
  end if;

  if cardinality(r) = 0 then
    r := array[coalesce(nullif(trim(coalesce(p_default, '')), ''), 'Check your calculations carefully.')];
  end if;
  return r;
end;
$$;

-- The configured rules for one topic (defaults match 0028).
create or replace function public.pia_topic_rules(p_topic int, out mastery int, out min_q int, out max_err int)
language plpgsql
stable
set search_path = public
as $$
begin
  select coalesce(case p_topic when 1 then c.easy_mastery when 2 then c.medium_mastery else c.hard_mastery end, 80),
         coalesce(case p_topic when 1 then c.easy_min_questions when 2 then c.medium_min_questions else c.hard_min_questions end, 3),
         coalesce(case p_topic when 1 then c.easy_max_errors when 2 then c.medium_max_errors else c.hard_max_errors end, 3)
    into mastery, min_q, max_err
    from public.app_config c where c.id = 1;
  if not found then
    mastery := 80; min_q := 3; max_err := 3;
  end if;
end;
$$;

-- What the browser may know about a question's state: never a key.
create or replace function public.pia_step_state_json(sq public.served_questions, st public.step_states)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'done',           false,
    'problem_id',     sq.problem_id,
    'problem_number', sq.problem_number,
    'question',       sq.question,
    'topic',          sq.student_topic,
    'question_topic', sq.topic,
    'steps_total',    public.pia_step_required(sq.topic),
    'step_labels',    (select jsonb_agg(public.pia_step_label(sq.topic, g - 1) order by g)
                         from generate_series(1, public.pia_step_required(sq.topic)) g),
    'current_step',   st.step_index,
    'stage',          st.stage,
    'confirm_kind',   case when st.stage = 'confirm'
                           then public.pia_step_confirm_kind(sq.topic, st.step_index) end,
    'work_text',      st.work_text,
    'done_steps',     st.done_steps,
    'wrong_streak',   st.wrong_streak,
    'hint_unlocked',  st.hint_unlocked,
    'hint_tier',      st.hint_tier,
    'errors',         st.errors,
    'hints_used',     st.hints,
    'locked',         st.completed);
$$;

-- The live window of a session; opened on first use (the first problem served).
create or replace function public.pia_game_window(p_session_id uuid, p_email text)
returns public.game_windows
language plpgsql
security definer
set search_path = public
as $$
declare
  w   public.game_windows%rowtype;
  v_s int;
begin
  select * into w from public.game_windows
   where session_id = p_session_id and student_email = p_email
   order by window_no desc limit 1;
  if found then return w; end if;

  select coalesce(c.time_limit, 10) * 60 into v_s from public.app_config c where c.id = 1;
  v_s := coalesce(v_s, 600);
  insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
  values (p_session_id, p_email, 1, v_s, now() + make_interval(secs => v_s))
  returning * into w;
  return w;
end;
$$;

create or replace function public.pia_window_expired(w public.game_windows)
returns boolean language sql stable as $$
  select w.ended_at is null and now() >= w.deadline_at;
$$;

-- What the browser needs to draw the clock and the expiry dialog.
create or replace function public.pia_clock_json(w public.game_windows)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'window',            w.window_no,
    'limit_seconds',     w.limit_seconds,
    'started_at',        w.started_at,
    'finished_at',       least(now(), w.deadline_at),
    'remaining_seconds', greatest(0, ceil(extract(epoch from (w.deadline_at - now()))))::int,
    'expired',           public.pia_window_expired(w));
$$;

revoke all on function public.pia_game_window(uuid, text)               from public, anon, authenticated;
revoke all on function public.pia_window_expired(public.game_windows)   from public, anon, authenticated;
revoke all on function public.pia_clock_json(public.game_windows)       from public, anon, authenticated;

-- Signed in, current, a student, and allowed into the Tutoring Dashboard for
-- their research group. Returns the email.
create or replace function public.pia_game_email()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := auth.jwt() ->> 'email';
  p       public.profiles%rowtype;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'student' then
    raise exception 'PIA: only students take lessons.' using errcode = '42501';
  end if;

  select * into p from public.profiles where email = v_email;
  if not found
     or not public.pia_can_enter_stage(p.is_ocean_done, p.group_type, p.selected_character, 'Tutoring Dashboard')
     or lower(trim(coalesce(p.group_type, ''))) not in ('assigned', 'neutral', 'non-assigned', 'non_assigned')
     or p.selected_character is null then
    raise exception 'PIA: the tutoring game is not available to this account.' using errcode = '42501';
  end if;
  return v_email;
end;
$$;

revoke all on function public.pia_step_required(int)                              from public, anon, authenticated;
revoke all on function public.pia_step_label(int, int)                            from public, anon, authenticated;
revoke all on function public.pia_step_confirm_kind(int, int)                     from public, anon, authenticated;
revoke all on function public.pia_steps_valid(jsonb, int)                         from public, anon, authenticated;
revoke all on function public.pia_eval_expr(text)                                 from public, anon, authenticated;
revoke all on function public.pia_step_matches(text, text)                        from public, anon, authenticated;
revoke all on function public.pia_has_working(text)                               from public, anon, authenticated;
revoke all on function public.pia_is_final_format(text, text)                     from public, anon, authenticated;
revoke all on function public.pia_format_final(text, numeric)                     from public, anon, authenticated;
revoke all on function public.pia_step_hints(jsonb, text)                         from public, anon, authenticated;
revoke all on function public.pia_topic_rules(int)                                from public, anon, authenticated;
revoke all on function public.pia_step_state_json(public.served_questions, public.step_states) from public, anon, authenticated;
revoke all on function public.pia_game_email()                                    from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. The student's calls
-- ---------------------------------------------------------------------------

-- The next thing for this session: an offer still waiting for an answer, an
-- open question exactly as it was left, or a new question chosen by the
-- server (the student's topic first, then least seen, then at random).
create or replace function public.serve_next_step_question(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email    text;
  v_offer    public.topic_offers%rowtype;
  v_sq       public.served_questions%rowtype;
  v_st       public.step_states%rowtype;
  v_w        public.game_windows%rowtype;
  v_topic    int;
  v_q        record;
  v_parsed   jsonb;
  v_number   int;
  v_repeat   int;
  v_last_q   bigint;
begin
  v_email := public.pia_game_email();
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  -- The session clock starts with the first problem and never pauses.
  v_w := public.pia_game_window(p_session_id, v_email);

  select * into v_offer from public.topic_offers
   where session_id = p_session_id and student_email = v_email and status = 'pending'
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('done', false, 'clock', public.pia_clock_json(v_w),
      'pending_offer', jsonb_build_object(
        'problem_id', v_offer.problem_id, 'type', v_offer.offer,
        'from_topic', v_offer.from_topic, 'target_topic', v_offer.target_topic));
  end if;

  select sq.* into v_sq
    from public.served_questions sq
   where sq.session_id = p_session_id and sq.student_email = v_email
     and exists (select 1 from public.step_states s
                  where s.session_id = sq.session_id and s.student_email = sq.student_email
                    and s.problem_id = sq.problem_id)
     and not exists (select 1 from public.tutoring_attempts t
                      where t.session_id = sq.session_id and t.student_email = sq.student_email
                        and t.problem_id = sq.problem_id)
   order by sq.problem_number desc
   limit 1;

  if found then
    select * into v_st from public.step_states
     where session_id = v_sq.session_id and student_email = v_email and problem_id = v_sq.problem_id;
    return public.pia_step_state_json(v_sq, v_st) || jsonb_build_object('clock', public.pia_clock_json(v_w));
  end if;

  v_topic := public.pia_student_topic(v_email);

  select coalesce(max(problem_number), 0) + 1, (array_agg(question_id order by problem_number desc))[1]
    into v_number, v_last_q
    from public.served_questions where session_id = p_session_id and student_email = v_email;

  -- The game uses every question once, shuffled, before any repeats, and never
  -- shows the same one twice in a row: fewest times seen this session first.
  select q.id, q.question, q.final_answer, q.hint,
         case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end as topic
    into v_q
    from public.question_bank q
   where upper(q.difficulty) in ('EASY', 'MEDIUM', 'HARD')
     and trim(coalesce(q.question, '')) <> ''
     and public.pia_steps_valid(
           public.pia_parse_hint(q.hint) -> 'steps',
           case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end)
   order by abs((case upper(q.difficulty) when 'EASY' then 1 when 'MEDIUM' then 2 else 3 end) - v_topic),
            (select count(*) from public.served_questions s
              where s.session_id = p_session_id and s.student_email = v_email and s.question_id = q.id),
            (q.id = v_last_q),
            (select count(*) from public.served_questions s2
              where s2.student_email = v_email and s2.question_id = q.id),
            random()
   limit 1;

  if not found then
    return jsonb_build_object('done', true, 'reason', 'bank_empty', 'clock', public.pia_clock_json(v_w));
  end if;

  select count(*) into v_repeat from public.served_questions
   where session_id = p_session_id and student_email = v_email and question_id = v_q.id;

  v_parsed := public.pia_parse_hint(v_q.hint);

  insert into public.served_questions (
    session_id, student_email, problem_id, problem_number, question_id,
    topic, student_topic, question, final_answer, steps, default_hint)
  values (
    p_session_id, v_email,
    'qb-' || v_q.id || case when v_repeat > 0 then '#' || v_repeat else '' end,
    v_number, v_q.id,
    v_q.topic, v_topic, v_q.question, coalesce(v_q.final_answer, ''),
    v_parsed -> 'steps', nullif(v_parsed ->> 'defaultHint', ''))
  returning * into v_sq;

  insert into public.step_states (session_id, student_email, problem_id)
  values (p_session_id, v_email, v_sq.problem_id)
  returning * into v_st;

  -- The serve stamp that timing (and the teacher monitor) already use.
  insert into public.problem_serves (session_id, student_email, problem_id, problem_number)
  values (p_session_id, v_email, v_sq.problem_id, v_sq.problem_number)
  on conflict (session_id, problem_id) do nothing;

  return public.pia_step_state_json(v_sq, v_st) || jsonb_build_object('clock', public.pia_clock_json(v_w));
end;
$$;


-- One submission for the step the student is on. The step is the server's
-- choice, not the browser's.
create or replace function public.check_step_answer(p_session_id uuid, p_problem_id text, p_submitted text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email    text;
  v_sub      text := left(trim(coalesce(p_submitted, '')), 60);
  v_sq       public.served_questions%rowtype;
  v_st       public.step_states%rowtype;
  v_required int;
  v_step     jsonb;
  v_key      numeric;
  v_kind     text;
  v_idx      int;
  v_stage    text;
  v_num      numeric;
  v_outcome  text;
  v_text     text;
  v_confirm  text;
  v_w        public.game_windows%rowtype;
begin
  v_email := public.pia_game_email();
  if v_sub = '' then
    raise exception 'PIA: an answer is required.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  v_w := public.pia_game_window(p_session_id, v_email);

  if v_st.completed
     or exists (select 1 from public.tutoring_attempts t
                 where t.session_id = p_session_id and t.student_email = v_email and t.problem_id = p_problem_id) then
    return jsonb_build_object('outcome', 'locked', 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  -- The session time limit has passed: nothing more is checked or counted.
  if public.pia_window_expired(v_w) then
    return jsonb_build_object('outcome', 'time_expired', 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  v_required := public.pia_step_required(v_sq.topic);
  v_idx      := v_st.step_index;
  v_stage    := v_st.stage;
  v_step     := v_sq.steps -> v_idx;
  v_kind     := public.pia_step_confirm_kind(v_sq.topic, v_idx);
  v_key      := public.pia_eval_expr(coalesce(v_step ->> 'answer', v_step ->> 'stepAnswer', ''));

  if v_stage = 'work' then
    if not public.pia_step_matches(v_sub, coalesce(v_step ->> 'answer', v_step ->> 'stepAnswer', '')) then
      v_outcome := 'wrong';
    elsif not public.pia_has_working(v_sub) and public.pia_is_final_format(v_kind, v_sub) then
      v_outcome := 'step_done';
      v_num     := public.pia_eval_expr(v_sub);
      v_text    := public.pia_format_final(v_kind, v_num);
    else
      -- Right value, but working or not in the final shape: ask for the value.
      v_outcome := 'needs_final';
    end if;
  else
    if public.pia_is_final_format(v_kind, v_sub) then
      v_num := public.pia_eval_expr(v_sub);
    end if;
    if v_num is not null and v_key is not null and abs(v_num - v_key) <= 0.001 then
      v_outcome := 'step_done';
      v_text    := coalesce(v_st.work_text, public.pia_format_final(v_kind, v_num));
      v_confirm := public.pia_format_final(v_kind, v_num);
    else
      v_outcome := 'format_error';
    end if;
  end if;

  insert into public.step_events (session_id, student_email, problem_id, step_index, stage, submitted, outcome)
  values (p_session_id, v_email, p_problem_id, v_idx, v_stage, v_sub,
          case when v_outcome = 'step_done' and v_idx + 1 >= v_required then 'question_done' else v_outcome end);

  if v_outcome in ('wrong', 'format_error') then
    update public.step_states
       set errors = errors + 1,
           wrong_streak = wrong_streak + 1,
           hint_unlocked = hint_unlocked or (wrong_streak + 1 >= 2),
           updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;

  elsif v_outcome = 'needs_final' then
    update public.step_states
       set stage = 'confirm', work_text = v_sub, wrong_streak = 0, hint_tier = 0, updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;

  else  -- step_done
    update public.step_states
       set done_steps = done_steps || jsonb_build_array(
             jsonb_build_object('text', v_text, 'confirmed', v_confirm)),
           step_index = step_index + 1,
           stage = 'work', work_text = null, wrong_streak = 0, hint_tier = 0,
           completed = (step_index + 1 >= v_required),
           updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
     returning * into v_st;
    if v_st.completed then v_outcome := 'question_done'; end if;
  end if;

  return jsonb_build_object(
    'outcome',   v_outcome,
    'step_text', v_text,
    'confirmed', v_confirm,
    'state',     public.pia_step_state_json(v_sq, v_st),
    'clock',     public.pia_clock_json(v_w));
end;
$$;


-- The next hint for the current step. Only after two wrong answers.
create or replace function public.consume_step_hint(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text;
  v_sq    public.served_questions%rowtype;
  v_st    public.step_states%rowtype;
  v_list  text[];
  v_tier  int;
  v_w     public.game_windows%rowtype;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  v_w := public.pia_game_window(p_session_id, v_email);
  if v_st.completed or not v_st.hint_unlocked or public.pia_window_expired(v_w) then
    return jsonb_build_object('hint', null, 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  v_list := public.pia_step_hints(v_sq.steps -> v_st.step_index, v_sq.default_hint);
  v_tier := least(v_st.hint_tier + 1, cardinality(v_list));

  insert into public.step_hints (session_id, student_email, problem_id, step_index, tier, tiers_total)
  values (p_session_id, v_email, p_problem_id, v_st.step_index, v_tier, cardinality(v_list));

  update public.step_states
     set hint_tier = v_tier, hints = hints + 1, updated_at = now()
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   returning * into v_st;

  return jsonb_build_object(
    'hint', jsonb_build_object(
      'text', v_list[v_tier], 'tier', v_tier, 'tiers_total', cardinality(v_list),
      'step', v_st.step_index + 1),
    'state', public.pia_step_state_json(v_sq, v_st),
    'clock', public.pia_clock_json(v_w));
end;
$$;


-- Records a finished question and decides whether to OFFER a topic change.
-- Safe to call twice: the second call returns the first result.
create or replace function public.finish_step_question(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email  text;
  v_sq     public.served_questions%rowtype;
  v_st     public.step_states%rowtype;
  v_prog   public.student_topic_progress%rowtype;
  v_served timestamptz;
  v_last   timestamptz;
  v_ms     bigint;
  v_att    int;
  v_class  text;
  v_acc    boolean;
  v_topic  int;
  v_done   int;
  v_good   int;
  v_streak int;
  v_rule   record;
  v_offer  text;
  v_target int;
  v_pend   public.topic_offers%rowtype;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  if exists (select 1 from public.tutoring_attempts
              where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) then
    select * into v_pend from public.topic_offers
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id and status = 'pending';
    return public.pia_result_payload(p_session_id, v_email, p_problem_id)
           || jsonb_build_object('errors', v_st.errors,
                'offer', case when v_pend.problem_id is not null then jsonb_build_object(
                  'type', v_pend.offer, 'from_topic', v_pend.from_topic, 'target_topic', v_pend.target_topic) end);
  end if;

  if not v_st.completed then
    raise exception 'PIA: finish every step first.' using errcode = '42501';
  end if;

  select served_at into v_served from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;
  if v_served is null then
    raise exception 'PIA: this question was not served.' using errcode = '42501';
  end if;
  select max(happened_at), count(*) into v_last, v_att from public.step_events
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  v_acc   := v_st.errors = 0;
  -- The attached game's one rule: accurate = no wrong answer. Hints and
  -- time are recorded (hints_used, time_taken_ms) but do not decide it.
  v_class := case when v_acc then 'smooth' else 'struggling' end;

  -- The topic window.
  insert into public.student_topic_progress (student_email) values (v_email)
  on conflict (student_email) do nothing;
  select * into v_prog from public.student_topic_progress where student_email = v_email for update;

  v_topic := v_prog.topic;
  v_done  := v_prog.stint_answered + 1;
  v_good  := v_prog.stint_correct + case when v_acc then 1 else 0 end;
  v_streak := case when v_acc then 0 else v_prog.failed_streak + 1 end;

  select * into v_rule from public.pia_topic_rules(v_topic);

  v_offer := null;
  if v_topic > 1 and v_streak >= v_rule.max_err then
    v_offer := 'down'; v_target := v_topic - 1;
  elsif v_topic < 3 and v_done >= v_rule.min_q and v_good * 100 >= v_rule.mastery * v_done then
    v_offer := 'up';   v_target := v_topic + 1;
  end if;

  update public.student_topic_progress
     set stint_answered = v_done, stint_correct = v_good, failed_streak = v_streak, updated_at = now()
   where student_email = v_email;

  -- The game logged PASSED when errors < the topic's max errors, with a score
  -- of 100 (else 50). Kept as columns so the analysis can use them.
  update public.step_states
     set passed = (v_st.errors < v_rule.max_err), score = case when v_st.errors < v_rule.max_err then 100 else 50 end
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if v_offer is not null then
    insert into public.topic_offers (session_id, student_email, problem_id, offer, from_topic, target_topic)
    values (p_session_id, v_email, p_problem_id, v_offer, v_topic, v_target)
    on conflict do nothing;
  end if;

  -- level_before / level_after hold the TOPIC (1-3), as in 0029. A topic
  -- changes only when the student accepts an offer, so they match here.
  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, v_sq.problem_number,
    v_topic, v_topic, least(10, v_att), least(10, v_st.hints),
    v_ms, v_acc, v_class)
  on conflict (session_id, problem_number) do nothing;

  return public.pia_result_payload(p_session_id, v_email, p_problem_id)
         || jsonb_build_object('errors', v_st.errors,
              'offer', case when v_offer is not null then jsonb_build_object(
                'type', v_offer, 'from_topic', v_topic, 'target_topic', v_target) end);
end;
$$;


-- The student's answer to a topic offer.
create or replace function public.respond_topic_offer(p_session_id uuid, p_problem_id text, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text;
  v_off   public.topic_offers%rowtype;
  v_prog  public.student_topic_progress%rowtype;
  v_rule  record;
  v_to    int;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_off from public.topic_offers
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if not found then
    raise exception 'PIA: there is no offer to answer.' using errcode = '42501';
  end if;
  if v_off.status <> 'pending' then
    return jsonb_build_object('topic', public.pia_student_topic(v_email), 'status', v_off.status);
  end if;

  select * into v_prog from public.student_topic_progress where student_email = v_email for update;
  select * into v_rule from public.pia_topic_rules(v_off.from_topic);
  v_to := case when p_accept then v_off.target_topic else v_off.from_topic end;

  insert into public.topic_changes (
    student_email, session_id, problem_number, from_topic, to_topic, reason,
    stint_answered, stint_correct, stint_wrong, mastery, min_solved, max_errors)
  values (
    v_email, p_session_id,
    (select problem_number from public.served_questions
      where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id),
    v_off.from_topic, v_to,
    (case when p_accept then 'accepted_' else 'refused_' end) || v_off.offer,
    v_prog.stint_answered, v_prog.stint_correct, v_prog.failed_streak,
    v_rule.mastery, v_rule.min_q, v_rule.max_err);

  if p_accept then
    -- A new topic starts a fresh window.
    update public.student_topic_progress
       set topic = v_to, stint_answered = 0, stint_correct = 0, failed_streak = 0, updated_at = now()
     where student_email = v_email;
  elsif v_off.offer = 'up' then
    update public.student_topic_progress
       set stint_answered = 0, stint_correct = 0, failed_streak = 0, updated_at = now()
     where student_email = v_email;
  else
    update public.student_topic_progress
       set failed_streak = 0, updated_at = now()
     where student_email = v_email;
  end if;

  update public.topic_offers
     set status = case when p_accept then 'accepted' else 'refused' end, resolved_at = now()
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  return jsonb_build_object('topic', v_to, 'status', case when p_accept then 'accepted' else 'refused' end);
end;
$$;


-- The game's "Try again" after the time limit: the open problem starts again
-- from step 1 (errors and hints back at zero, as loadCurrentProblem does), a
-- new window with a fresh deadline opens, topic and topic progress are kept.
create or replace function public.restart_after_expiry(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text;
  v_w     public.game_windows%rowtype;
  v_sq    public.served_questions%rowtype;
  v_st    public.step_states%rowtype;
  v_s     int;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  v_w := public.pia_game_window(p_session_id, v_email);
  if not public.pia_window_expired(v_w) then
    return public.serve_next_step_question(p_session_id) || jsonb_build_object('restarted', false);
  end if;

  select sq.* into v_sq
    from public.served_questions sq
   where sq.session_id = p_session_id and sq.student_email = v_email
     and not exists (select 1 from public.tutoring_attempts t
                      where t.session_id = sq.session_id and t.student_email = sq.student_email
                        and t.problem_id = sq.problem_id)
   order by sq.problem_number desc limit 1;

  if found then
    select * into v_st from public.step_states
     where session_id = p_session_id and student_email = v_email and problem_id = v_sq.problem_id;
  end if;

  update public.game_windows
     set ended_at = now(), ended_reason = 'expired',
         topic = public.pia_student_topic(v_email),
         open_problem_id = v_sq.problem_id, errors = v_st.errors, hints = v_st.hints
   where session_id = p_session_id and student_email = v_email and window_no = v_w.window_no;

  select coalesce(c.time_limit, 10) * 60 into v_s from public.app_config c where c.id = 1;
  v_s := coalesce(v_s, 600);
  insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
  values (p_session_id, v_email, v_w.window_no + 1, v_s, now() + make_interval(secs => v_s));

  -- A question whose last step was already accepted keeps its result.
  if v_sq.problem_id is not null and not v_st.completed then
    update public.step_states
       set step_index = 0, stage = 'work', work_text = null, wrong_streak = 0, hint_tier = 0,
           errors = 0, hints = 0, hint_unlocked = false, done_steps = '[]'::jsonb, updated_at = now()
     where session_id = p_session_id and student_email = v_email and problem_id = v_sq.problem_id;
    update public.problem_serves set served_at = now()
     where session_id = p_session_id and problem_id = v_sq.problem_id;
    insert into public.step_events (session_id, student_email, problem_id, step_index, stage, submitted, outcome)
    values (p_session_id, v_email, v_sq.problem_id, 0, 'work', '', 'restart');
  end if;

  return public.serve_next_step_question(p_session_id) || jsonb_build_object('restarted', true);
end;
$$;


-- ---------------------------------------------------------------------------
-- 4. Resume: the same as 0029, behind the same access check.
-- ---------------------------------------------------------------------------
create or replace function public.resume_or_start_game_session()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email    text;
  v_session  uuid;
  v_answered int;
  v_correct  int;
  v_pending  text;
  v_streak   int := 0;
  r          record;
begin
  v_email := public.pia_game_email();

  select ps.session_id into v_session
    from public.problem_serves ps
   where ps.student_email = v_email and ps.problem_id like 'qb-%'
   order by ps.served_at desc
   limit 1;

  if v_session is not null then
    select count(*), coalesce(count(*) filter (where is_correct), 0)
      into v_answered, v_correct
      from public.tutoring_attempts
     where session_id = v_session and student_email = v_email and problem_id like 'qb-%';

    if true then   -- no question-count ending: the session continues until the student stops
      select sq.problem_id into v_pending
        from public.served_questions sq
       where sq.session_id = v_session and sq.student_email = v_email
         and not exists (select 1 from public.tutoring_attempts t
                          where t.session_id = sq.session_id and t.student_email = sq.student_email
                            and t.problem_id = sq.problem_id)
       order by sq.problem_number desc
       limit 1;

      -- Time away is not time on task: the open question's clock restarts.
      if v_pending is not null then
        update public.problem_serves set served_at = now()
         where session_id = v_session and problem_id = v_pending;
      end if;

      for r in select a.is_correct from public.tutoring_attempts a
                where a.session_id = v_session and a.student_email = v_email and a.problem_id like 'qb-%'
                order by a.problem_number desc loop
        exit when not r.is_correct;
        v_streak := v_streak + 1;
      end loop;

      return jsonb_build_object(
        'session_id',          v_session,
        'resumed',             true,
        'problems_answered',   v_answered,
        'correct_count',       v_correct,
        'topic',               public.pia_student_topic(v_email),
        'consecutive_correct', v_streak,
        'time_limit_seconds',  coalesce((select c.time_limit * 60 from public.app_config c where c.id = 1), 600),
        'pending_problem_id',  v_pending);
    end if;
  end if;

  return jsonb_build_object(
    'session_id',          public.start_game_session(),
    'resumed',             false,
    'problems_answered',   0,
    'correct_count',       0,
    'topic',               public.pia_student_topic(v_email),
    'consecutive_correct', 0,
    'time_limit_seconds',  coalesce((select c.time_limit * 60 from public.app_config c where c.id = 1), 600),
    'pending_problem_id',  null);
end;
$$;


-- ---------------------------------------------------------------------------
-- 5. Grants.
-- ---------------------------------------------------------------------------
revoke all on function public.serve_next_step_question(uuid)                   from public, anon;
revoke all on function public.check_step_answer(uuid, text, text)              from public, anon;
revoke all on function public.consume_step_hint(uuid, text)                    from public, anon;
revoke all on function public.finish_step_question(uuid, text)                 from public, anon;
revoke all on function public.respond_topic_offer(uuid, text, boolean)         from public, anon;
revoke all on function public.restart_after_expiry(uuid)                       from public, anon;
revoke all on function public.resume_or_start_game_session()                   from public, anon;
grant execute on function public.serve_next_step_question(uuid)                to authenticated;
grant execute on function public.check_step_answer(uuid, text, text)           to authenticated;
grant execute on function public.consume_step_hint(uuid, text)                 to authenticated;
grant execute on function public.finish_step_question(uuid, text)              to authenticated;
grant execute on function public.respond_topic_offer(uuid, text, boolean)      to authenticated;
grant execute on function public.restart_after_expiry(uuid)                   to authenticated;
grant execute on function public.resume_or_start_game_session()               to authenticated;



-- ---------------------------------------------------------------------------
-- 6. A student cannot change their tutor from the browser.
--    0001 lets a student write selected_character on their own row. That is
--    right for a free-choice student's one pick, and wrong for an assigned
--    student, whose tutor is the admin's and part of the experiment. From the
--    browser a non-admin may now set it only once, while it is empty, in the
--    free-choice group, to one of the six known tutors. Admin edits and the
--    admin "re-select" reset are untouched.
-- ---------------------------------------------------------------------------
create or replace function public.pia_guard_tutor_choice()
returns trigger
language plpgsql
security invoker              -- invoker, so current_user is the real caller (as in 0001)
set search_path = public
as $$
begin
  if current_user <> 'authenticated' then return new; end if;
  if new.selected_character is not distinct from old.selected_character then return new; end if;
  if public.pia_caller_role() = 'admin' then return new; end if;

  if old.selected_character is null
     and lower(trim(coalesce(old.group_type, ''))) in ('non-assigned', 'non_assigned')
     and new.selected_character in ('pia-open', 'pia-conscientious', 'pia-extravert',
                                    'pia-agreeable', 'pia-calm', 'pia-neutral') then
    return new;
  end if;

  raise exception 'PIA: your tutor is set for you and cannot be changed here.' using errcode = '42501';
end;
$$;

drop trigger if exists profiles_guard_tutor_choice on public.profiles;
create trigger profiles_guard_tutor_choice
  before update of selected_character on public.profiles
  for each row execute function public.pia_guard_tutor_choice();


-- ---------------------------------------------------------------------------
-- 7. SELF-TEST of the pure helpers. If any line fails, the whole migration
--    rolls back and says which. (The database calls above are NOT exercised
--    here: see the notes below.)
-- ---------------------------------------------------------------------------
do $$
begin
  assert public.pia_eval_expr('0.3 x 30') = 9,           'eval: 0.3 x 30';
  assert public.pia_eval_expr('80/100') = 0.8,           'eval: 80/100';
  assert public.pia_eval_expr('50 - 20') = 30,           'eval: 50 - 20';
  assert public.pia_eval_expr('(10+5)*2') = 30,          'eval: parentheses';
  assert public.pia_eval_expr('20%') = 20,               'eval: percent sign';
  assert public.pia_eval_expr('1,200') = 1200,           'eval: comma';
  assert public.pia_eval_expr('5--3') is null,           'eval: comment starter refused';
  assert public.pia_eval_expr('5/0') is null,            'eval: divide by zero';
  assert public.pia_eval_expr('abc') is null,            'eval: letters refused';
  assert public.pia_eval_expr('1; drop table x') is null, 'eval: semicolon refused';

  assert public.pia_step_matches('0.8', '0.80'),         'match: 0.8';
  assert public.pia_step_matches('20', '20%'),           'match: 20 vs 20%';
  assert public.pia_step_matches('30*0.3', '9'),         'match: working';
  assert not public.pia_step_matches('9.5', '9'),        'match: wrong value';

  assert public.pia_has_working('30 x 0.3'),             'working: x';
  assert public.pia_has_working('80/100'),               'working: divide';
  assert public.pia_has_working('50 - 20'),              'working: subtract';
  assert not public.pia_has_working('-5'),               'working: leading sign';
  assert not public.pia_has_working('0.8'),              'working: plain';

  assert public.pia_is_final_format('percentage', '20%'), 'format: 20%';
  assert public.pia_is_final_format('percentage', '20'),  'format: 20';
  assert not public.pia_is_final_format('decimal', '20%'), 'format: decimal with %';
  assert not public.pia_is_final_format('number', '3*4'), 'format: expression';

  assert public.pia_format_final('decimal', 0.80) = '0.8',    'format_final: decimal';
  assert public.pia_format_final('percentage', 20) = '20%',   'format_final: percent';

  assert public.pia_step_required(1) = 2 and public.pia_step_required(3) = 3, 'required';
  assert public.pia_step_label(1, 0) = 'Conversion' and public.pia_step_label(3, 2) = 'Conversion', 'labels';
  assert public.pia_step_confirm_kind(1, 0) = 'decimal'
     and public.pia_step_confirm_kind(2, 2) = 'percentage'
     and public.pia_step_confirm_kind(2, 0) = 'number', 'confirm kinds';

end;
$$;

commit;

-- ============================================================================
-- WHAT WAS AND WAS NOT VERIFIED
--   Verified: nothing against a live database -- none was available. The
--   self-test above checks the pure helpers on apply.
--   NOT verified: serve_next_step_question, check_step_answer,
--   consume_step_hint, finish_step_question, respond_topic_offer and the new
--   resume under RLS. The browser side was tested against a mock of these
--   calls only. Before applying for real, on a copy: play a lesson as a
--   student of each group and confirm (a) a control student is refused by
--   every call, (b) no response ever contains a step answer or final_answer,
--   (c) hint is null before two wrong answers, (d) the offers behave as
--   described at the top, and extend 0029's postflight to cover them.
--   Assumed from outside this repo: tutoring_attempts accepts
--   attempts_used / hints_used up to 10 and classification 'smooth' |
--   'struggling' (0029 relies on the same), and trim_scale() exists
--   (PostgreSQL 13+).
-- ============================================================================


-- ############################################################################
-- MIGRATION 20261004_0041_auto_assign_ocean_character
-- ############################################################################

-- PIA 0041: Save the Assigned group's tutor when the server records OCEAN.
-- This does not rewrite existing submissions or profiles. Apply after 0039
-- and the already deployed 0040 hint change; neither RPC is replaced here.
-- The student's RPC response still contains only next_stage, never scores.
begin;

create or replace function public.pia_choose_assigned_character(
  p_e integer, p_a integer, p_c integer, p_n integer, p_o integer)
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  v_choice text;
begin
  if num_nonnulls(p_e, p_a, p_c, p_n, p_o) <> 5
     or p_e not between 0 and 40 or p_a not between 0 and 40
     or p_c not between 0 and 40 or p_n not between 0 and 40
     or p_o not between 0 and 40 then
    raise exception 'PIA: invalid questionnaire scores.' using errcode = '22023';
  end if;

  -- The BFPT sheet's N formula runs opposite to its prose definition: a low
  -- stored N means more stress. Reverse N for character matching only. The
  -- existing pia-calm key points to the Neuroticism character in the artwork.
  select candidate.character_key into v_choice
    from (values
      ('pia-extravert',     p_e),
      ('pia-agreeable',     p_a),
      ('pia-conscientious', p_c),
      ('pia-calm',          40 - p_n),
      ('pia-open',          p_o)
    ) as candidate(character_key, score)
   where candidate.score = greatest(p_e, p_a, p_c, 40 - p_n, p_o)
   order by random()
   limit 1;

  return v_choice;
end;
$$;

revoke all on function public.pia_choose_assigned_character(integer, integer, integer, integer, integer)
  from public, anon, authenticated;

create or replace function public.pia_assign_tutor_from_ocean()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only a newly completed questionnaire for an Assigned student counts.
  -- The retake action resets is_ocean_done, so it also gets a new assignment.
  -- Existing manual choices are intentionally replaced by this result.
  if new.source = 'questionnaire' then
    update public.profiles p
       set selected_character = public.pia_choose_assigned_character(
         new.ocean_e, new.ocean_a, new.ocean_c, new.ocean_n, new.ocean_o)
     where p.email = new.email
       and lower(trim(coalesce(p.group_type, ''))) = 'assigned'
       and not coalesce(p.is_ocean_done, false);
  end if;
  return new;
end;
$$;

revoke all on function public.pia_assign_tutor_from_ocean() from public, anon, authenticated;

drop trigger if exists ocean_submission_assign_tutor on public.ocean_submissions;
create trigger ocean_submission_assign_tutor
  after insert on public.ocean_submissions
  for each row execute function public.pia_assign_tutor_from_ocean();

-- Pure-rule checks. Full submission/stage behavior is tested on a staging DB.
do $$
declare
  v_choice text;
begin
  assert public.pia_choose_assigned_character(35, 10, 9, 20, 7) = 'pia-extravert';
  assert public.pia_choose_assigned_character(9, 35, 8, 20, 6) = 'pia-agreeable';
  assert public.pia_choose_assigned_character(9, 8, 35, 20, 6) = 'pia-conscientious';
  assert public.pia_choose_assigned_character(9, 8, 7, 2, 6) = 'pia-calm';
  assert public.pia_choose_assigned_character(9, 8, 7, 20, 35) = 'pia-open';
  assert public.pia_choose_assigned_character(30, 10, 9, 40, 7) = 'pia-extravert',
    'a calm response pattern must not win the Neuroticism character';
  for v_choice in select public.pia_choose_assigned_character(30, 30, 9, 20, 7)
                    from generate_series(1, 30) loop
    assert v_choice in ('pia-extravert', 'pia-agreeable'),
      'a tie may choose only one of the highest traits';
  end loop;
end;
$$;

commit;


-- ############################################################################
-- MIGRATION 20261004_0042_admin_tutorial_report
-- ############################################################################

-- PIA 0042: Admin-only tutorial performance and time-window history.
-- 0039 keeps one resumable session_id across sign-ins. Each game_windows row
-- is one continuous timed play window, including a new row after Try again.
-- The report deliberately uses the server's attempt and event records rather
-- than browser counters. No student or teacher can call this function.
begin;

do $$
declare
  v_table text;
begin
  foreach v_table in array array['game_windows', 'tutoring_attempts', 'step_states',
                               'step_events', 'step_hints'] loop
    if to_regclass('public.' || v_table) is null then
      raise exception 'PIA 0042 requires public.% (apply 0039 first).', v_table;
    end if;
  end loop;
  if to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0042 requires the admin role/session guards.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'step_states'
                    and column_name = 'score') then
    raise exception 'PIA 0042 requires step_states.score (apply 0039 first).';
  end if;
end;
$$;

create or replace function public.pia_admin_tutorial_report(p_student_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_student_email, '')));
  v_report jsonb;
begin
  if coalesce(public.pia_caller_role(), '') <> 'admin'
     or public.jwt_is_current() is not true then
    raise exception 'PIA: admin access required.' using errcode = '42501';
  end if;
  if v_email = '' then
    raise exception 'PIA: student email required.' using errcode = '22023';
  end if;

  with windows as (
    select w.session_id, w.student_email, w.window_no, w.started_at,
           w.deadline_at, w.ended_at,
           greatest(0, floor(extract(epoch from
             least(coalesce(w.ended_at, now()), w.deadline_at) - w.started_at)))::int
             as duration_seconds
      from public.game_windows w
     where lower(w.student_email) = v_email
  ), report_rows as (
    select w.*,
           coalesce(a.completed, 0) as completed,
           coalesce(a.clean, 0) as clean,
           a.best_topic,
           coalesce(a.time_sum_ms, 0) as time_sum_ms,
           coalesce(a.timed_count, 0) as timed_count,
           coalesce(a.score_sum, 0) as score_sum,
           coalesce(e.errors, 0) as errors,
           coalesce(h.hints, 0) as hints
      from windows w
      left join lateral (
        select count(*)::int as completed,
               count(*) filter (where t.is_correct)::int as clean,
               max(t.level_before) as best_topic,
               sum(t.time_taken_ms) as time_sum_ms,
               count(t.time_taken_ms)::int as timed_count,
               sum(coalesce(st.score, 0))::int as score_sum
          from public.tutoring_attempts t
          left join public.step_states st
            on st.session_id = t.session_id and st.student_email = t.student_email
           and st.problem_id = t.problem_id
         where t.session_id = w.session_id and t.student_email = w.student_email
           and t.problem_id like 'qb-%'
           and t.created_at >= w.started_at and t.created_at < w.deadline_at
      ) a on true
      left join lateral (
        select count(*)::int as errors
          from public.step_events ev
         where ev.session_id = w.session_id and ev.student_email = w.student_email
           and ev.outcome in ('wrong', 'format_error')
           and ev.happened_at >= w.started_at and ev.happened_at < w.deadline_at
      ) e on true
      left join lateral (
        select count(*)::int as hints
          from public.step_hints sh
         where sh.session_id = w.session_id and sh.student_email = w.student_email
           and sh.taken_at >= w.started_at and sh.taken_at < w.deadline_at
      ) h on true
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'sessions', count(*)::int,
      'completed_questions', coalesce(sum(completed), 0)::int,
      'clean_questions', coalesce(sum(clean), 0)::int,
      'best_topic', max(best_topic),
      'avg_speed_seconds', case when coalesce(sum(timed_count), 0) > 0
        then round(sum(time_sum_ms)::numeric / sum(timed_count) / 1000, 1)
        else null end,
      'accuracy_percent', case when coalesce(sum(completed), 0) > 0
        then round(sum(clean)::numeric * 100 / sum(completed), 1)
        else null end,
      'score_sum', coalesce(sum(score_sum), 0)::int,
      'errors', coalesce(sum(errors), 0)::int,
      'hints', coalesce(sum(hints), 0)::int
    ),
    'history_total', count(*)::int,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'started_at', r.started_at,
        'window_no', r.window_no,
        'status', case when r.ended_at is not null or r.deadline_at <= now()
          then 'ended' else 'active' end,
        'duration_seconds', r.duration_seconds,
        'best_topic', r.best_topic,
        'completed_questions', r.completed,
        'clean_questions', r.clean,
        'score_sum', r.score_sum,
        'errors', r.errors,
        'hints', r.hints
      ) order by r.started_at desc, r.window_no desc)
        from (select * from report_rows order by started_at desc, window_no desc limit 100) r
    ), '[]'::jsonb)
  ) into v_report
    from report_rows;

  return v_report;
end;
$$;

revoke all on function public.pia_admin_tutorial_report(text) from public, anon;
grant execute on function public.pia_admin_tutorial_report(text) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261004_0043_fix_tutorial_report_timestamps
-- ############################################################################

-- PIA 0043: corrective replacement of pia_admin_tutorial_report (from 0042).
-- 0042 filtered completed questions with tutoring_attempts.created_at, but that
-- table has no timestamp column (session_id, student_email, problem_id,
-- problem_number, level_before, level_after, attempts_used, hints_used,
-- time_taken_ms, is_correct, classification). A question's completion time is
-- now the server's 'question_done' record in step_events.happened_at, written
-- in the same transaction path as the final correct step. A question counts in
-- the game window whose [started_at, deadline_at) contains that moment, the
-- same boundaries already used for errors (step_events) and hints (step_hints).
-- Admin-only access, the JSON shape and all game records are unchanged: this
-- file only replaces one function (no table, row or policy is touched).
begin;

do $$
declare
  v_col text;
begin
  foreach v_col in array array['session_id', 'student_email', 'problem_id', 'level_before',
                               'time_taken_ms', 'is_correct'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'tutoring_attempts'
                      and column_name = v_col) then
      raise exception 'PIA 0043 requires public.tutoring_attempts.%', v_col;
    end if;
  end loop;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'step_events'
                    and column_name = 'happened_at') then
    raise exception 'PIA 0043 requires public.step_events.happened_at (apply 0039 first).';
  end if;
  if to_regprocedure('public.pia_admin_tutorial_report(text)') is null then
    raise exception 'PIA 0043 replaces the function from 0042 (apply 0042 first).';
  end if;
end;
$$;

create or replace function public.pia_admin_tutorial_report(p_student_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_student_email, '')));
  v_report jsonb;
begin
  if coalesce(public.pia_caller_role(), '') <> 'admin'
     or public.jwt_is_current() is not true then
    raise exception 'PIA: admin access required.' using errcode = '42501';
  end if;
  if v_email = '' then
    raise exception 'PIA: student email required.' using errcode = '22023';
  end if;

  with windows as (
    select w.session_id, w.student_email, w.window_no, w.started_at,
           w.deadline_at, w.ended_at,
           greatest(0, floor(extract(epoch from
             least(coalesce(w.ended_at, now()), w.deadline_at) - w.started_at)))::int
             as duration_seconds
      from public.game_windows w
     where lower(w.student_email) = v_email
  ), report_rows as (
    select w.*,
           coalesce(a.completed, 0) as completed,
           coalesce(a.clean, 0) as clean,
           a.best_topic,
           coalesce(a.time_sum_ms, 0) as time_sum_ms,
           coalesce(a.timed_count, 0) as timed_count,
           coalesce(a.score_sum, 0) as score_sum,
           coalesce(e.errors, 0) as errors,
           coalesce(h.hints, 0) as hints
      from windows w
      left join lateral (
        select count(*)::int as completed,
               count(*) filter (where t.is_correct)::int as clean,
               max(t.level_before) as best_topic,
               sum(t.time_taken_ms) as time_sum_ms,
               count(t.time_taken_ms)::int as timed_count,
               sum(coalesce(st.score, 0))::int as score_sum
          from public.tutoring_attempts t
          join lateral (
            select max(ev.happened_at) as done_at
              from public.step_events ev
             where ev.session_id = t.session_id and ev.student_email = t.student_email
               and ev.problem_id = t.problem_id and ev.outcome = 'question_done'
          ) c on c.done_at is not null
          left join public.step_states st
            on st.session_id = t.session_id and st.student_email = t.student_email
           and st.problem_id = t.problem_id
         where t.session_id = w.session_id and t.student_email = w.student_email
           and t.problem_id like 'qb-%'
           and c.done_at >= w.started_at and c.done_at < w.deadline_at
      ) a on true
      left join lateral (
        select count(*)::int as errors
          from public.step_events ev
         where ev.session_id = w.session_id and ev.student_email = w.student_email
           and ev.outcome in ('wrong', 'format_error')
           and ev.happened_at >= w.started_at and ev.happened_at < w.deadline_at
      ) e on true
      left join lateral (
        select count(*)::int as hints
          from public.step_hints sh
         where sh.session_id = w.session_id and sh.student_email = w.student_email
           and sh.taken_at >= w.started_at and sh.taken_at < w.deadline_at
      ) h on true
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'sessions', count(*)::int,
      'completed_questions', coalesce(sum(completed), 0)::int,
      'clean_questions', coalesce(sum(clean), 0)::int,
      'best_topic', max(best_topic),
      'avg_speed_seconds', case when coalesce(sum(timed_count), 0) > 0
        then round(sum(time_sum_ms)::numeric / sum(timed_count) / 1000, 1)
        else null end,
      'accuracy_percent', case when coalesce(sum(completed), 0) > 0
        then round(sum(clean)::numeric * 100 / sum(completed), 1)
        else null end,
      'score_sum', coalesce(sum(score_sum), 0)::int,
      'errors', coalesce(sum(errors), 0)::int,
      'hints', coalesce(sum(hints), 0)::int
    ),
    'history_total', count(*)::int,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'started_at', r.started_at,
        'window_no', r.window_no,
        'status', case when r.ended_at is not null or r.deadline_at <= now()
          then 'ended' else 'active' end,
        'duration_seconds', r.duration_seconds,
        'best_topic', r.best_topic,
        'completed_questions', r.completed,
        'clean_questions', r.clean,
        'score_sum', r.score_sum,
        'errors', r.errors,
        'hints', r.hints
      ) order by r.started_at desc, r.window_no desc)
        from (select * from report_rows order by started_at desc, window_no desc limit 100) r
    ), '[]'::jsonb)
  ) into v_report
    from report_rows;

  return v_report;
end;
$$;

revoke all on function public.pia_admin_tutorial_report(text) from public, anon;
grant execute on function public.pia_admin_tutorial_report(text) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261004_0044_learning_features
-- ############################################################################

-- PIA 0044: the numbers the tutor's wording profile is worked out from, taken
-- from the server's OWN records. The profile itself is NOT decided here: it is
-- decided by the pia-ml-api service (its model and inference are used unchanged),
-- called by the Edge Function `learning-profile`, never by the browser.
--
-- Flow:  student's browser -> Edge Function learning-profile -> pia-ml-api
-- This function gives the Edge Function the same seven rolling numbers the
-- attached game computed in the browser (last 8 submissions): accuracy, attempts
-- per step, hint rate, response time and efficiency on correct answers, and the
-- current right/wrong streaks. The server measures them, so the browser cannot
-- shape what the model sees. They contain no name, email, student id or session
-- id. Read-only: nothing is written.
-- Differences from the browser version, because the server measures: a response
-- time is the gap since the previous recorded event or hint of the session (else
-- since the question was served), capped at 300 s; a revisited step counts once.
begin;

do $$
begin
  if to_regclass('public.step_events') is null or to_regclass('public.step_hints') is null
     or to_regclass('public.problem_serves') is null then
    raise exception 'PIA 0044 requires the 0039 game tables (apply 0039 first).';
  end if;
  if to_regprocedure('public.pia_game_email()') is null then
    raise exception 'PIA 0044 requires public.pia_game_email() (apply 0039 first).';
  end if;
end;
$$;

create or replace function public.pia_learning_features_calc(p_session_id uuid, p_email text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_n int; v_correct int; v_steps int; v_hinted int; v_streak int; v_last boolean;
  v_acc numeric; v_attempts numeric; v_hint_rate numeric; v_eff numeric; v_time numeric;
  v_cc int := 0; v_cw int := 0;
begin
  -- The last eight submissions of the session, newest first (rn = 1).
  with recent as (
    select row_number() over (order by e.id desc)::int as rn,
           e.outcome in ('needs_final', 'step_done', 'question_done') as correct,
           least(300, greatest(0, extract(epoch from (e.happened_at - coalesce(
             (select max(p.at) from (
                select pe.happened_at as at from public.step_events pe
                 where pe.session_id = e.session_id and pe.student_email = e.student_email
                   and pe.id < e.id
                 union all
                select sh.taken_at from public.step_hints sh
                 where sh.session_id = e.session_id and sh.student_email = e.student_email
                   and sh.taken_at < e.happened_at) p),
             (select ps.served_at from public.problem_serves ps
               where ps.session_id = e.session_id and ps.student_email = e.student_email
                 and ps.problem_id = e.problem_id
               order by ps.served_at desc limit 1),
             e.happened_at - interval '120 seconds')))))::numeric as rt,
           e.problem_id, e.step_index,
           (select count(*)::int from public.step_events x
             where x.session_id = e.session_id and x.student_email = e.student_email
               and x.problem_id = e.problem_id and x.step_index = e.step_index and x.id <= e.id
               and x.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done'))
             as attempt_no,
           exists (select 1 from public.step_hints h
                    where h.session_id = e.session_id and h.student_email = e.student_email
                      and h.problem_id = e.problem_id and h.step_index = e.step_index) as hinted
      from public.step_events e
     where e.session_id = p_session_id and e.student_email = p_email
       and e.outcome in ('wrong', 'format_error', 'needs_final', 'step_done', 'question_done')
     order by e.id desc
     limit 8
  ), steps as (
    select problem_id, step_index, bool_or(hinted) as hinted, max(attempt_no) as m
      from recent group by problem_id, step_index
  )
  select (select count(*) from recent),
         (select count(*) filter (where correct) from recent),
         (select correct from recent where rn = 1),
         coalesce((select min(rn) from recent
                    where correct is distinct from (select correct from recent where rn = 1)),
                  (select count(*) + 1 from recent)) - 1,
         coalesce((select avg(1.0 / (1.0 + rt / 30.0)) filter (where correct) from recent), 0),
         coalesce((select avg(rt) filter (where correct) from recent), 120),
         (select count(*) from steps),
         (select count(*) filter (where hinted) from steps),
         (select avg(m) from steps)
    into v_n, v_correct, v_last, v_streak, v_eff, v_time, v_steps, v_hinted, v_attempts;

  -- Nothing answered yet: the attached game's own starting values.
  if coalesce(v_n, 0) = 0 then
    return jsonb_build_object('events', 0, 'features', jsonb_build_object(
      'recent_accuracy', 0.5, 'average_attempts', 1, 'hint_rate', 0,
      'average_response_time', 120, 'correct_response_efficiency', 0,
      'consecutive_correct', 0, 'consecutive_wrong', 0));
  end if;

  v_acc := v_correct::numeric / v_n;
  v_attempts := greatest(1, coalesce(v_attempts, 1));
  v_hint_rate := case when v_steps > 0 then v_hinted::numeric / v_steps else 0 end;
  if v_last then v_cc := v_streak; else v_cw := v_streak; end if;

  return jsonb_build_object('events', v_n, 'features', jsonb_build_object(
    'recent_accuracy', round(v_acc, 4),
    'average_attempts', round(v_attempts, 4),
    'hint_rate', round(v_hint_rate, 4),
    'average_response_time', round(v_time, 2),
    'correct_response_efficiency', round(v_eff, 4),
    'consecutive_correct', v_cc,
    'consecutive_wrong', v_cw));
end;
$$;

-- The student's call (made by the Edge Function with the student's own token).
-- Same guard as every game call; only the caller's own records are read.
create or replace function public.get_learning_features(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := public.pia_game_email();
begin
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;
  return public.pia_learning_features_calc(p_session_id, v_email);
end;
$$;

revoke all on function public.pia_learning_features_calc(uuid, text) from public, anon, authenticated;
revoke all on function public.get_learning_features(uuid) from public, anon;
grant execute on function public.get_learning_features(uuid) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261005_0045_tutoring_closing_time
-- ############################################################################

-- PIA 0045: the tutoring closes at a time the admin sets (Philippine time in the admin
-- screen, stored as a timestamp with time zone). It replaces the per-session
-- "Game time limit (minutes)" of 0039.
--
-- RULE. app_config.game_closes_at is the one switch:
--   * NULL (never set)                  -> tutoring is open.
--   * now() >= game_closes_at           -> tutoring is CLOSED for everyone, enforced on the
--                                          server: answers and hints are refused whether the
--                                          student stays, quits, signs out or comes back.
--   * the admin sets a later time/NULL  -> it opens again; the student continues exactly
--                                          where they left off (no restart, no "try again").
-- The student sees no clock and no time at all; the page only learns "closed or not".
--
-- WHAT CHANGES. Only the window helpers and Try Again are redefined, so the big question and
-- answer functions of 0039 are untouched: they already stop on pia_window_expired().
--   pia_window_expired / pia_clock_json / pia_game_window / restart_after_expiry
-- and one new function, tutoring_status(), for the start screen. Old windows keep their
-- stored deadline but it is no longer consulted. app_config.time_limit and max_points stay
-- in the table, unused. No game record is changed or deleted.
begin;

do $$
begin
  if to_regclass('public.game_windows') is null or to_regclass('public.app_config') is null then
    raise exception 'PIA 0045 requires the 0039 game tables (apply 0039 first).';
  end if;
  if to_regprocedure('public.pia_game_email()') is null
     or to_regprocedure('public.serve_next_step_question(uuid)') is null then
    raise exception 'PIA 0045 requires the 0039 game functions (apply 0039 first).';
  end if;
end;
$$;

alter table public.app_config add column if not exists game_closes_at timestamptz;

create or replace function public.pia_tutoring_closed()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select c.game_closes_at <= now() from public.app_config c where c.id = 1), false);
$$;

-- A window is "expired" exactly when the tutoring is closed.
create or replace function public.pia_window_expired(w public.game_windows)
returns boolean language sql stable as $$
  select public.pia_tutoring_closed();
$$;

-- All the browser needs: closed or not. The numeric fields are legacy values so that a tab
-- still running the previous script keeps working until it is refreshed; nothing shows them.
create or replace function public.pia_clock_json(w public.game_windows)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'window',            w.window_no,
    'closed',            public.pia_tutoring_closed(),
    'expired',           public.pia_tutoring_closed(),
    'limit_seconds',     86400,
    'remaining_seconds', 86400);
$$;

-- The live window of a session. One window per open period: it ends when the tutoring
-- closes (ended_at = the closing time) and a new one starts if it is opened again.
create or replace function public.pia_game_window(p_session_id uuid, p_email text)
returns public.game_windows
language plpgsql
security definer
set search_path = public
as $$
declare
  w        public.game_windows%rowtype;
  v_closes timestamptz;
  v_closed boolean;
begin
  select c.game_closes_at into v_closes from public.app_config c where c.id = 1;
  v_closed := v_closes is not null and v_closes <= now();

  select * into w from public.game_windows
   where session_id = p_session_id and student_email = p_email
   order by window_no desc limit 1;

  if found then
    if w.ended_at is null and v_closed then
      update public.game_windows
         set ended_at = greatest(v_closes, w.started_at), ended_reason = 'closed'
       where session_id = w.session_id and student_email = w.student_email and window_no = w.window_no
       returning * into w;
      return w;
    end if;
    if w.ended_at is not null and not v_closed then
      insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
      values (p_session_id, p_email, w.window_no + 1, 0, 'infinity')
      returning * into w;
    end if;
    return w;
  end if;

  insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
  values (p_session_id, p_email, 1, 0, 'infinity')
  returning * into w;
  return w;
end;
$$;

-- "Try again" no longer exists as a restart. While closed it refuses; otherwise it just
-- serves the open question as it was left. Kept so an old tab does not error.
create or replace function public.restart_after_expiry(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text := public.pia_game_email();
begin
  if public.pia_tutoring_closed() then
    return jsonb_build_object('closed', true, 'restarted', false,
      'clock', jsonb_build_object('closed', true, 'expired', true, 'limit_seconds', 86400, 'remaining_seconds', 0));
  end if;
  return public.serve_next_step_question(p_session_id) || jsonb_build_object('restarted', false);
end;
$$;

-- For the start screen: closed or not, nothing else (no time).
create or replace function public.tutoring_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := public.pia_game_email();
begin
  return jsonb_build_object('closed', public.pia_tutoring_closed());
end;
$$;

revoke all on function public.pia_tutoring_closed()                         from public, anon, authenticated;
revoke all on function public.pia_window_expired(public.game_windows)       from public, anon, authenticated;
revoke all on function public.pia_clock_json(public.game_windows)           from public, anon, authenticated;
revoke all on function public.pia_game_window(uuid, text)                   from public, anon, authenticated;
revoke all on function public.restart_after_expiry(uuid)                    from public, anon;
revoke all on function public.tutoring_status()                             from public, anon;
grant execute on function public.restart_after_expiry(uuid)                 to authenticated;
grant execute on function public.tutoring_status()                          to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261005_0046_session_history
-- ############################################################################

-- PIA 0046: give a returning student back what the page used to forget on refresh:
-- the questions they have already solved (with their own working) and the last five
-- wrong entries (the error log). Until now both lived only in the browser's memory.
--
-- Read-only. Same guard as every game call; only the caller's own records of the given
-- session are read. The question's answer key is never returned: what comes back is what
-- the student typed and what the server accepted from them.
--   solved: every question of the session whose last step was accepted, in order:
--           { number, topic, question, steps: [{ title, text, confirmed }] }
--   errors: the last five wrong entries, oldest first, worded as the page words them:
--           'Step 2: Error on "x"' / 'Step 2: Final-answer error on "x"'
--   hints_total: hints taken in this session.
begin;

do $$
begin
  if to_regclass('public.served_questions') is null or to_regclass('public.step_states') is null
     or to_regclass('public.step_events') is null or to_regclass('public.step_hints') is null then
    raise exception 'PIA 0046 requires the 0039 game tables (apply 0039 first).';
  end if;
  if to_regprocedure('public.pia_game_email()') is null
     or to_regprocedure('public.pia_step_label(integer, integer)') is null then
    raise exception 'PIA 0046 requires the 0039 game functions (apply 0039 first).';
  end if;
end;
$$;

create or replace function public.get_session_history(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := public.pia_game_email();
begin
  if p_session_id is null then
    raise exception 'PIA: a session is required.' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'solved', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number',   sq.problem_number,
               'topic',    sq.topic,
               'question', sq.question,
               'steps',    (select coalesce(jsonb_agg(jsonb_build_object(
                                'title',     'Step ' || n.i || ': ' || public.pia_step_label(sq.topic, n.i - 1),
                                'text',      d.elem ->> 'text',
                                'confirmed', d.elem ->> 'confirmed') order by n.i), '[]'::jsonb)
                              from jsonb_array_elements(st.done_steps) with ordinality as d(elem, i)
                              cross join lateral (select d.i::int as i) n)) order by sq.problem_number)
        from public.served_questions sq
        join public.step_states st
          on st.session_id = sq.session_id and st.student_email = sq.student_email and st.problem_id = sq.problem_id
       where sq.session_id = p_session_id and sq.student_email = v_email and st.completed
    ), '[]'::jsonb),
    'errors', coalesce((
      select jsonb_agg(e.line order by e.id)
        from (select ev.id,
                     'Step ' || (ev.step_index + 1) || ': '
                       || case when ev.outcome = 'format_error' then 'Final-answer error on "' else 'Error on "' end
                       || ev.submitted || '"' as line
                from public.step_events ev
               where ev.session_id = p_session_id and ev.student_email = v_email
                 and ev.outcome in ('wrong', 'format_error')
               order by ev.id desc limit 5) e
    ), '[]'::jsonb),
    'hints_total', (select count(*)::int from public.step_hints h
                     where h.session_id = p_session_id and h.student_email = v_email));
end;
$$;

revoke all on function public.get_session_history(uuid) from public, anon;
grant execute on function public.get_session_history(uuid) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261005_0047_hints_never_give_the_answer
-- ############################################################################

-- PIA 0047: a hint guides; it never gives the answer.
--
-- The admin's sentence generator used to write Hint 3 as a "worked calculation" that ENDS
-- in the result ("0.4 * 350 = 140"), so the third hint handed the student the final answer
-- (and the step answers). The admin editor now writes and checks guidance-only hints; this
-- migration is the safety net for every question already in the bank: before a hint leaves
-- the server, a number that is the step's answer (or the question's final answer) and is
-- written as a result is replaced by "___":
--     "0.4 * 350 = 140"          ->  "0.4 * 350 = ___"
--     "So the answer is 140."    ->  "So the answer is ___."
--     "Multiply 0.4 by 350"      ->  unchanged (no result is shown)
--     "Find 25% of 100"          ->  unchanged (25 is a given here, not written as a result)
-- Only the hint text returned to the student changes. Nothing stored is edited or deleted;
-- consume_step_hint is otherwise exactly as in 0039.
begin;

do $$
begin
  if to_regprocedure('public.consume_step_hint(uuid, text)') is null
     or to_regprocedure('public.pia_step_hints(jsonb, text)') is null then
    raise exception 'PIA 0047 requires the 0039 game functions (apply 0039 first).';
  end if;
end;
$$;

-- p_answers: the step's answer and the question's final answer (either may be null).
create or replace function public.pia_mask_answers(p_text text, p_answers text[])
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_out   text := coalesce(p_text, '');
  v_nums  numeric[] := '{}';
  a       text;
  n       text;
  m       text[];
  v_val   numeric;
begin
  foreach a in array coalesce(p_answers, '{}') loop
    n := substring(replace(coalesce(a, ''), ',', '') from '-?\d+(?:\.\d+)?');
    if n is not null then v_nums := v_nums || n::numeric; end if;
  end loop;
  if cardinality(v_nums) = 0 then return v_out; end if;

  -- a number written as a result: after "=", "answer", "result", "equals", "gives", "get(s)"
  for m in
    select regexp_matches(p_text,
      '((?:=|\m(?:answers?|results?|equals?|gives?|gets?)\M)\s*(?:is|are|:|=)?\s*)(-?\d[\d,]*(?:\.\d+)?)(\s*%?)', 'gi')
  loop
    v_val := replace(m[2], ',', '')::numeric;
    if v_val = any (v_nums) then
      v_out := replace(v_out, m[1] || m[2] || m[3], m[1] || '___' || m[3]);
    end if;
  end loop;
  return v_out;
end;
$$;

revoke all on function public.pia_mask_answers(text, text[]) from public, anon, authenticated;

create or replace function public.consume_step_hint(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text;
  v_sq    public.served_questions%rowtype;
  v_st    public.step_states%rowtype;
  v_list  text[];
  v_tier  int;
  v_w     public.game_windows%rowtype;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   for update;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  v_w := public.pia_game_window(p_session_id, v_email);
  if v_st.completed or not v_st.hint_unlocked or public.pia_window_expired(v_w) then
    return jsonb_build_object('hint', null, 'state', public.pia_step_state_json(v_sq, v_st),
                              'clock', public.pia_clock_json(v_w));
  end if;

  v_list := public.pia_step_hints(v_sq.steps -> v_st.step_index, v_sq.default_hint);
  v_tier := least(v_st.hint_tier + 1, cardinality(v_list));

  insert into public.step_hints (session_id, student_email, problem_id, step_index, tier, tiers_total)
  values (p_session_id, v_email, p_problem_id, v_st.step_index, v_tier, cardinality(v_list));

  update public.step_states
     set hint_tier = v_tier, hints = hints + 1, updated_at = now()
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id
   returning * into v_st;

  return jsonb_build_object(
    'hint', jsonb_build_object(
      'text', public.pia_mask_answers(v_list[v_tier],
                array[v_sq.steps -> v_st.step_index ->> 'answer', v_sq.final_answer]),
      'tier', v_tier, 'tiers_total', cardinality(v_list),
      'step', v_st.step_index + 1),
    'state', public.pia_step_state_json(v_sq, v_st),
    'clock', public.pia_clock_json(v_w));
end;
$$;

revoke all on function public.consume_step_hint(uuid, text) from public, anon;
grant execute on function public.consume_step_hint(uuid, text) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261005_0048_realtime_closing
-- ############################################################################

-- PIA 0048: make the closing time live.
--   1. tutoring_status() also says how many seconds are left until the closing time (null when
--      none is set or it has passed). The page uses it only to lock at the exact moment; it is
--      never drawn, so students still see no time anywhere.
--   2. app_config and question_bank are added to the realtime publication, so an admin's save
--      reaches the other admins' screens at once. (Row changes are still filtered by the
--      existing row-level security: only admins can read these tables.)
-- Read-only function change; the publication change adds no data. Nothing is deleted.
begin;

do $$
begin
  if to_regprocedure('public.tutoring_status()') is null then
    raise exception 'PIA 0048 requires tutoring_status() (apply 0045 first).';
  end if;
end;
$$;

create or replace function public.tutoring_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email  text := public.pia_game_email();
  v_closes timestamptz;
begin
  select c.game_closes_at into v_closes from public.app_config c where c.id = 1;
  return jsonb_build_object(
    'closed', v_closes is not null and v_closes <= now(),
    'seconds_to_close',
      case when v_closes is not null and v_closes > now()
           then ceil(extract(epoch from (v_closes - now())))::int end);
end;
$$;

revoke all on function public.tutoring_status() from public, anon;
grant execute on function public.tutoring_status() to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'app_config') then
      alter publication supabase_realtime add table public.app_config;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'question_bank') then
      alter publication supabase_realtime add table public.question_bank;
    end if;
  end if;
end;
$$;

commit;


-- ############################################################################
-- MIGRATION 20261006_0049_scoring_rules
-- ############################################################################

-- PIA 0049: points that mean something, set by the admin.
--
-- BEFORE: finish_step_question wrote step_states.score = 100 (errors < the topic's max) or 50, and
-- question_bank.points (the admin's per-question value) was read by nothing in the game.
-- NOW: question_bank.points is the BASE (maximum) points of the question and the score comes from
--   raw   = base - base*wrong%*wrong_answers - base*hint%*hints_taken
--           + base*fast_bonus%   (only when the speed bonus is on, there was NO wrong answer, and
--                                 the question was finished within the fast threshold)
--   score = max(score_min, round(raw))
--   a repeat of a question already completed in this session: 0, or score*repeat% if enabled.
-- Everything is configurable in app_config (validated by CHECK constraints); the percentages are of
-- the question's own base, so they hold for 10-point and 50-point questions alike.
--
-- THE SERVER DECIDES. The score is computed in finish_step_question from the server's own records
-- (errors, hints, serve time) and saved once (idempotent: a second call returns the stored result).
-- The browser never sends or sees a score.
--
-- NOT TOUCHED: the adaptive topic rules (mastery / min questions / max errors), the PASSED flag,
-- tutoring_attempts, and the learning profile (get_learning_features): points never decide
-- Struggling / Average / Outstanding. Historical scores are never rewritten.
-- served_questions.base_points is stamped by a trigger when a question is served, so changing a
-- question's points affects only questions served afterwards.
begin;

do $$
begin
  if to_regprocedure('public.finish_step_question(uuid, text)') is null
     or to_regclass('public.step_hints') is null then
    raise exception 'PIA 0049 requires the 0039 game (apply 0039 first).';
  end if;
end;
$$;

alter table public.app_config
  add column if not exists score_wrong_pct       int     not null default 20,
  add column if not exists score_hint_pct        int     not null default 10,
  add column if not exists score_fast_bonus_pct  int     not null default 20,
  add column if not exists score_fast_seconds    int     not null default 30,
  add column if not exists score_speed_bonus     boolean not null default true,
  add column if not exists score_min             int     not null default 0,
  add column if not exists score_repeat_enabled  boolean not null default false,
  add column if not exists score_repeat_pct      int     not null default 50;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_config_score_rules_check') then
    alter table public.app_config add constraint app_config_score_rules_check check (
      score_wrong_pct between 0 and 100 and score_hint_pct between 0 and 100
      and score_fast_bonus_pct between 0 and 100 and score_fast_seconds between 1 and 3600
      and score_min between 0 and 500 and score_repeat_pct between 0 and 100);
  end if;
end;
$$;

alter table public.served_questions add column if not exists base_points int;

create or replace function public.pia_stamp_base_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.base_points is null then
    select q.points into new.base_points from public.question_bank q where q.id = new.question_id;
  end if;
  return new;
end;
$$;

drop trigger if exists served_questions_base_points on public.served_questions;
create trigger served_questions_base_points
  before insert on public.served_questions
  for each row execute function public.pia_stamp_base_points();

-- The one place the formula lives. Pure apart from reading the admin's rules.
create or replace function public.pia_compute_score(
  p_base int, p_errors int, p_hints int, p_ms bigint, p_repeat_prior int)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c        public.app_config%rowtype;
  v_base   numeric := greatest(0, coalesce(p_base, 0));
  v_raw    numeric;
  v_score  numeric;
begin
  select * into c from public.app_config where id = 1;
  if not found then
    c.score_wrong_pct := 20; c.score_hint_pct := 10; c.score_fast_bonus_pct := 20; c.score_fast_seconds := 30;
    c.score_speed_bonus := true; c.score_min := 0; c.score_repeat_enabled := false; c.score_repeat_pct := 50;
  end if;

  v_raw := v_base
         - v_base * c.score_wrong_pct / 100.0 * greatest(0, coalesce(p_errors, 0))
         - v_base * c.score_hint_pct  / 100.0 * greatest(0, coalesce(p_hints, 0));
  -- Speed only ever ADDS, and only to a question with no wrong answer. Slow answers lose nothing.
  if c.score_speed_bonus and coalesce(p_errors, 0) = 0 and p_ms is not null and p_ms >= 0
     and p_ms <= c.score_fast_seconds * 1000::bigint then
    v_raw := v_raw + v_base * c.score_fast_bonus_pct / 100.0;
  end if;
  v_score := greatest(c.score_min, round(v_raw));

  if coalesce(p_repeat_prior, 0) > 0 then
    v_score := case when c.score_repeat_enabled then greatest(0, round(v_score * c.score_repeat_pct / 100.0)) else 0 end;
  end if;
  return v_score::int;
end;
$$;

revoke all on function public.pia_stamp_base_points() from public, anon, authenticated;
revoke all on function public.pia_compute_score(int, int, int, bigint, int) from public, anon, authenticated;

create or replace function public.finish_step_question(p_session_id uuid, p_problem_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email  text;
  v_sq     public.served_questions%rowtype;
  v_st     public.step_states%rowtype;
  v_prog   public.student_topic_progress%rowtype;
  v_served timestamptz;
  v_last   timestamptz;
  v_ms     bigint;
  v_att    int;
  v_class  text;
  v_acc    boolean;
  v_topic  int;
  v_done   int;
  v_good   int;
  v_streak int;
  v_rule   record;
  v_offer  text;
  v_target int;
  v_pend   public.topic_offers%rowtype;
  v_repeat_prior int;
  v_hints_taken  int;
begin
  v_email := public.pia_game_email();
  perform pg_advisory_xact_lock(hashtext('pia-lesson:' || v_email));

  select * into v_sq from public.served_questions
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  select * into v_st from public.step_states
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  if v_sq.problem_id is null or v_st.problem_id is null then
    raise exception 'PIA: this question was not served to you.' using errcode = '42501';
  end if;

  if exists (select 1 from public.tutoring_attempts
              where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) then
    select * into v_pend from public.topic_offers
     where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id and status = 'pending';
    return public.pia_result_payload(p_session_id, v_email, p_problem_id)
           || jsonb_build_object('errors', v_st.errors,
                'offer', case when v_pend.problem_id is not null then jsonb_build_object(
                  'type', v_pend.offer, 'from_topic', v_pend.from_topic, 'target_topic', v_pend.target_topic) end);
  end if;

  if not v_st.completed then
    raise exception 'PIA: finish every step first.' using errcode = '42501';
  end if;

  select served_at into v_served from public.problem_serves
   where session_id = p_session_id and problem_id = p_problem_id;
  if v_served is null then
    raise exception 'PIA: this question was not served.' using errcode = '42501';
  end if;
  select max(happened_at), count(*) into v_last, v_att from public.step_events
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;
  v_ms := greatest(0, least(3600000,
            (extract(epoch from (coalesce(v_last, now()) - v_served)) * 1000)::bigint));

  v_acc   := v_st.errors = 0;
  -- The attached game's one rule: accurate = no wrong answer. Hints and
  -- time are recorded (hints_used, time_taken_ms) but do not decide it.
  v_class := case when v_acc then 'smooth' else 'struggling' end;

  -- The topic window.
  insert into public.student_topic_progress (student_email) values (v_email)
  on conflict (student_email) do nothing;
  select * into v_prog from public.student_topic_progress where student_email = v_email for update;

  v_topic := v_prog.topic;
  v_done  := v_prog.stint_answered + 1;
  v_good  := v_prog.stint_correct + case when v_acc then 1 else 0 end;
  v_streak := case when v_acc then 0 else v_prog.failed_streak + 1 end;

  select * into v_rule from public.pia_topic_rules(v_topic);

  v_offer := null;
  if v_topic > 1 and v_streak >= v_rule.max_err then
    v_offer := 'down'; v_target := v_topic - 1;
  elsif v_topic < 3 and v_done >= v_rule.min_q and v_good * 100 >= v_rule.mastery * v_done then
    v_offer := 'up';   v_target := v_topic + 1;
  end if;

  update public.student_topic_progress
     set stint_answered = v_done, stint_correct = v_good, failed_streak = v_streak, updated_at = now()
   where student_email = v_email;

  -- PASSED stays the game's rule (errors < the topic's max errors). The SCORE is no longer a fixed
  -- 100/50: it comes from this question's base points and the admin's scoring rules (pia_compute_score),
  -- saved once, here, by the server. A repeat of a question already completed in this session
  -- scores per the repeat rule. The hint count is the distinct hints actually taken (step, tier).
  select count(*) into v_repeat_prior
    from public.tutoring_attempts t
    join public.served_questions s
      on s.session_id = t.session_id and s.student_email = t.student_email and s.problem_id = t.problem_id
   where t.session_id = p_session_id and t.student_email = v_email and s.question_id = v_sq.question_id;
  select count(*) into v_hints_taken
    from (select distinct step_index, tier from public.step_hints
           where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id) h;

  update public.step_states
     set passed = (v_st.errors < v_rule.max_err),
         score  = coalesce(score, public.pia_compute_score(
                    coalesce(v_sq.base_points, 10), v_st.errors, v_hints_taken, v_ms, v_repeat_prior))
   where session_id = p_session_id and student_email = v_email and problem_id = p_problem_id;

  if v_offer is not null then
    insert into public.topic_offers (session_id, student_email, problem_id, offer, from_topic, target_topic)
    values (p_session_id, v_email, p_problem_id, v_offer, v_topic, v_target)
    on conflict do nothing;
  end if;

  -- level_before / level_after hold the TOPIC (1-3), as in 0029. A topic
  -- changes only when the student accepts an offer, so they match here.
  insert into public.tutoring_attempts (
    session_id, student_email, problem_id, problem_number,
    level_before, level_after, attempts_used, hints_used,
    time_taken_ms, is_correct, classification)
  values (
    p_session_id, v_email, p_problem_id, v_sq.problem_number,
    v_topic, v_topic, least(10, v_att), least(10, v_st.hints),
    v_ms, v_acc, v_class)
  on conflict (session_id, problem_number) do nothing;

  return public.pia_result_payload(p_session_id, v_email, p_problem_id)
         || jsonb_build_object('errors', v_st.errors,
              'offer', case when v_offer is not null then jsonb_build_object(
                'type', v_offer, 'from_topic', v_topic, 'target_topic', v_target) end);
end;
$$;

revoke all on function public.finish_step_question(uuid, text) from public, anon;
grant execute on function public.finish_step_question(uuid, text) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261006_0050_neutral_condition
-- ############################################################################

-- PIA 0050: "Neutral" is a research condition again, chosen by the admin when registering a student.
--
-- 0038 refused every NEW assignment to group_type 'neutral' ("a persona, not a condition"). The research now
-- wants it as a condition of its own:  Neutral = the Assigned workflow without the OCEAN-based choice.
--   OCEAN -> Tutoring Dashboard -> Game, and the tutor is ALWAYS the Neutral one (pia-neutral).
-- (Assigned: the tutor follows the highest OCEAN trait, 0041. Free choice: the student picks. Control: OCEAN only.)
--
-- WHAT THIS CHANGES
--   1. The 0038 trigger that refused new neutral rows is removed.
--   2. A row trigger makes the tutor of a neutral student pia-neutral, on insert and whenever the group or the
--      tutor is written: the OCEAN result never picks it (0041 only touches Assigned), and nobody can give a
--      neutral student another tutor. A student MOVED OUT of neutral loses the persona the group gave them, so
--      the next group's own rule applies (Assigned: after their OCEAN; Free choice: they choose).
-- WHAT IT DOES NOT CHANGE
--   Stage rules, the game, scoring, the learning profile, Control, existing rows (no profile is updated here).
--   Routing already treated 'neutral' as an experimental group: no Character Selection, then the dashboard once a
--   tutor is saved -- which the trigger now does at registration.
begin;

do $$
begin
  if to_regclass('public.profiles') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public'
                     and table_name = 'profiles' and column_name = 'selected_character') then
    raise exception 'PIA 0050 requires public.profiles.selected_character.';
  end if;
end;
$$;

drop trigger if exists trg_pia_no_new_neutral_group on public.profiles;
drop function if exists public.pia_no_new_neutral_group();

create or replace function public.pia_neutral_tutor()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if lower(trim(coalesce(new.group_type, ''))) = 'neutral' then
    new.selected_character := 'pia-neutral';
  elsif tg_op = 'UPDATE'
        and lower(trim(coalesce(old.group_type, ''))) = 'neutral'
        and lower(trim(coalesce(new.group_type, ''))) is distinct from 'neutral'
        and old.selected_character = 'pia-neutral'
        and new.selected_character is not distinct from old.selected_character then
    new.selected_character := null;
  end if;
  return new;
end;
$$;

revoke all on function public.pia_neutral_tutor() from public, anon, authenticated;

drop trigger if exists profiles_neutral_tutor on public.profiles;
create trigger profiles_neutral_tutor
  before insert or update of group_type, selected_character on public.profiles
  for each row execute function public.pia_neutral_tutor();

commit;


-- ############################################################################
-- MIGRATION 20261007_0051_close_anon_function_surface
-- ############################################################################

-- ============================================================================
-- PIA 0051 -- CLOSE THE ANONYMOUS FUNCTION SURFACE, PIN THE LAST search_path
-- ============================================================================
-- Source: the Supabase Security Advisor (linter 0011 / 0028 / 0029), 7 Oct 2026.
--
-- 1. anon_security_definer_function_executable (15 functions).
--    Postgres grants EXECUTE on every new function to PUBLIC, and `anon` inherits
--    it. Migration 0011 revoked from public/anon on the __inner functions but the
--    wrappers it created (admin_create_auth_user, admin_reset_password,
--    admin_register_teacher, admin_grant_stage, ...) kept the default grant.
--    Nothing was open: each wrapper refuses a caller whose pia_caller_role() is
--    not 'admin'. This removes the second line of defence being the ONLY line.
--
-- 2. function_search_path_mutable (14 functions).
--    0039 / 0045 / 0038 re-created pia_* helpers with CREATE OR REPLACE and no SET
--    clause, which drops the search_path 0012 had pinned.
--
-- NOT touched, on purpose:
--    * authenticated EXECUTE. The student/staff RPCs and the policy helpers
--      (is_admin, current_email, jwt_is_current, ...) must stay callable by
--      signed-in users; RLS policies run as the caller.
--    * jwt_is_current() keeps anon EXECUTE: assets/js/function.js calls it, and a
--      request made while a token is refreshing arrives as anon. Today it answers
--      "no" to anon; revoking would make that an error (read as "unknown"). That
--      is a behaviour change to decide separately, not a side effect of this one.
--    * Leaked-password protection (Auth setting, Pro plan only).
--
-- WHY THE GRANT TO authenticated IS REPEATED:
--    `revoke ... from public` also removes the implicit grant authenticated was
--    relying on for helpers that never had an explicit one. So every non-trigger
--    function that had it gets an explicit grant back, and the block checks, per function,
--    that authenticated can still execute exactly what it could before.
--
-- TRIGGER FUNCTIONS (handle_new_student_auth, profiles_guard_privileged_columns,
--    guard_session_start): Postgres checks EXECUTE only when
--    the trigger is created, never when it fires. They are revoked from everyone.
--    Chosen by return type = trigger, so a function that is not a trigger is
--    never treated as one.
--
-- ONE TRANSACTION. Any failed assertion rolls everything back. Rollback for a
-- committed run is at the bottom. No data changes.
-- ============================================================================

begin;

do $$
declare
  r            record;
  v_fail       text := '';
  v_unguarded  text := '';
  v_grants     int  := 0;
  v_triggers   int  := 0;
  v_pinned     int  := 0;
  v_had_auth   boolean;
  v_is_trigger boolean;
  v_anon_names text[] := array[
    'admin_create_auth_user','admin_delete_user','admin_grant_stage',
    'admin_register_teacher','admin_reset_password','admin_revoke_sessions',
    'current_email','current_role_name','current_user_role','current_user_section',
    'handle_new_student_auth','is_admin','is_teacher',
    'profiles_guard_privileged_columns','guard_session_start'
  ];
  v_pin_names text[] := array[
    'pia_window_expired','pia_step_required','pia_step_label','pia_clock_json',
    'pia_step_confirm_kind','pia_has_working','pia_is_final_format','pia_format_final',
    'handle_new_student_auth','pia_replay_decision_tree','pia_session_state',
    'enforce_device_limit','pia_can_enter_stage','pia_tier_label','pia_refuse'
  ];
begin
  -- ------------------------------------------------------------------------
  -- PART 1 -- anon (and the PUBLIC default) off the flagged functions.
  -- ------------------------------------------------------------------------
  for r in
    select p.oid, p.proname,
           pg_get_function_identity_arguments(p.oid) as args,
           p.prorettype = 'trigger'::regtype          as is_trigger
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname = any (v_anon_names)
  loop
    v_had_auth   := has_function_privilege('authenticated', r.oid, 'EXECUTE');
    v_is_trigger := r.is_trigger;

    execute format('revoke all on function public.%I(%s) from public, anon', r.proname, r.args);

    if v_is_trigger then
      execute format('revoke all on function public.%I(%s) from authenticated', r.proname, r.args);
      v_triggers := v_triggers + 1;
    else
      -- Never widen: only functions authenticated could already run get the grant back.
      if v_had_auth then
        execute format('grant execute on function public.%I(%s) to authenticated, service_role',
                       r.proname, r.args);
      end if;
      v_grants := v_grants + 1;
    end if;

    if has_function_privilege('anon', r.oid, 'EXECUTE') then
      v_fail := v_fail || r.proname || '(' || r.args || ') still executable by anon; ';
    end if;
    if v_is_trigger and has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      v_fail := v_fail || r.proname || ' (trigger) still executable by authenticated; ';
    end if;
    if not v_is_trigger and v_had_auth and not has_function_privilege('authenticated', r.oid, 'EXECUTE') then
      v_fail := v_fail || r.proname || '(' || r.args || ') LOST authenticated execute; ';
    end if;

    -- The admin wrappers must still carry their own role check.
    if r.proname like 'admin\_%' and r.proname not like '%\_\_inner'
       and pg_get_functiondef(r.oid) !~* '(is_admin|current_user_role|pia_caller_role)' then
      v_unguarded := v_unguarded || r.proname || ', ';
    end if;
  end loop;

  if v_unguarded <> '' then
    raise notice 'PIA 0051 REVIEW: no role check found in the body of: %  (anon is closed now; check authenticated access)', v_unguarded;
  end if;

  -- ------------------------------------------------------------------------
  -- PART 2 -- pin search_path on helpers that lost it.
  -- ------------------------------------------------------------------------
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname = any (v_pin_names)
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    execute format('alter function public.%I(%s) set search_path = public, pg_temp', r.proname, r.args);
    v_pinned := v_pinned + 1;
  end loop;

  for r in
    select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.proname = any (v_pin_names)
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
  loop
    v_fail := v_fail || r.proname || ' has no search_path; ';
  end loop;

  if v_fail <> '' then
    raise exception 'PIA 0051 ABORT (nothing changed): %', v_fail;
  end if;

  raise notice 'PIA 0051: % function(s) closed to anon and kept for authenticated, % trigger function(s) closed to everyone, % search_path(s) pinned.',
    v_grants, v_triggers, v_pinned;
end;
$$;

commit;

-- ============================================================================
-- VERIFY (read-only, run after the commit). Expect 0 rows:
--
--   select p.proname, pg_get_function_identity_arguments(p.oid)
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.prosecdef
--      and has_function_privilege('anon', p.oid, 'EXECUTE')
--      and p.proname <> 'jwt_is_current';
--
-- Then in the app: staff sign-in, a student game session, and one admin action
-- (e.g. open/close a stage). Then Advisors -> Rerun linter.
--
-- ROLLBACK of a committed run (restores the old, wider grants):
--   grant execute on function public.<name>(<args>) to public, anon;
-- for the functions listed in v_anon_names above. Not needed for search_path:
-- pinning it cannot change behaviour of these functions.
-- ============================================================================


-- ############################################################################
-- MIGRATION 20261012_0052_student_number_door
-- ############################################################################

-- ============================================================================
-- PIA 0052 -- STUDENT-NUMBER DOOR: CHECK-IN, REQUESTS THE ADMIN LETS IN
-- ============================================================================
-- Students stop signing in with an email and password. In the computer lab they
-- type their student number, confirm their name, and WAIT. An admin who can see
-- the lab ticks the students they see and lets them in; only then does the
-- student's own browser receive a session for their EXISTING account (the
-- join-with-number Edge Function). Nothing about profiles, RLS, stages or the
-- one-device rule changes.
--
-- Everything here is ADMIN-controlled. Teachers are spectators and get no
-- function that changes anything.
--
--   student_numbers   email -> 11-digit student number. A separate table, not a
--                     column on profiles, so a student's own profile policy can
--                     never reach it.
--   checkins          one OPEN row per section at most. While no check-in is open
--                     the door answers every number the same way and reads no name.
--   join_requests     one row per "let me in": section, a hash of the secret the
--                     student's browser made, waiting | let_in, delivered once.
--   join_attempts     failed tries, for rate limiting (kept one day).
--
--   admin_start_checkin(section, minutes)   5 to 120 minutes, then it closes itself
--   admin_stop_checkin(section)             the door closes; people already in go on
--   admin_checkin_overview()                sections, open check-ins, who is waiting
--   admin_let_in(ids uuid[])                lets in the ticked requests
--   admin_set_student_number(email, number)
--   admin_import_student_numbers(rows jsonb)   [{email, number}, ...]
--
-- All four tables have RLS on and NO policies: only the service role (the Edge
-- Function) and the security-definer functions below can touch them.
--
-- Requires pia_caller_role() / jwt_is_current() / current_email() (0031, 0051).
-- SAFE TO RE-RUN. No existing table or row is changed.
-- ============================================================================

begin;

do $$
begin
  if to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null
     or to_regprocedure('public.current_email()') is null then
    raise exception 'PIA 0052 ABORT (nothing changed): pia_caller_role() / jwt_is_current() / current_email() are missing -- apply 0031 first.'
      using errcode = 'P0001';
  end if;
end;
$$;

create table if not exists public.student_numbers (
  email      text primary key,
  number_key text not null unique check (number_key ~ '^[0-9]{11}$'),
  number     text not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.checkins (
  id         uuid primary key default gen_random_uuid(),
  section    text not null,
  started_at timestamptz not null default now(),
  ends_at    timestamptz not null,
  stopped_at timestamptz,
  started_by text
);
create unique index if not exists checkins_one_open_per_section
  on public.checkins (section) where stopped_at is null;

create table if not exists public.join_requests (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  section     text not null,
  secret_hash text not null,
  status      text not null default 'waiting' check (status in ('waiting', 'let_in')),
  created_at  timestamptz not null default now(),
  let_in_at   timestamptz,
  delivered   boolean not null default false
);
create index if not exists join_requests_waiting_idx on public.join_requests (status, created_at desc);

create table if not exists public.join_attempts (
  id  bigserial primary key,
  key text        not null,
  ok  boolean     not null,
  at  timestamptz not null default now()
);
create index if not exists join_attempts_key_at_idx on public.join_attempts (key, at desc);

alter table public.student_numbers enable row level security;
alter table public.checkins        enable row level security;
alter table public.join_requests   enable row level security;
alter table public.join_attempts   enable row level security;

revoke all on public.student_numbers, public.checkins, public.join_requests, public.join_attempts
  from public, anon, authenticated;
revoke all on sequence public.join_attempts_id_seq from public, anon, authenticated;


create or replace function public.pia_number_key(p_number text)
returns text
language sql
immutable
set search_path = public
as $$ select regexp_replace(coalesce(p_number, ''), '[^0-9]', '', 'g') $$;
revoke all on function public.pia_number_key(text) from public, anon;
grant execute on function public.pia_number_key(text) to authenticated, service_role;


create or replace function public.pia_require_admin()
returns void
language plpgsql
set search_path = public
as $$
begin
  if public.pia_caller_role() is distinct from 'admin' or not public.jwt_is_current() then
    raise exception 'PIA: only an administrator can do this.' using errcode = '42501';
  end if;
end;
$$;
revoke all on function public.pia_require_admin() from public, anon;
grant execute on function public.pia_require_admin() to authenticated;


create or replace function public.admin_start_checkin(p_section text, p_minutes int default 15)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := trim(p_section);
  v_id      uuid;
begin
  perform public.pia_require_admin();
  if nullif(v_section, '') is null then
    raise exception 'PIA: choose a section.' using errcode = 'P0001';
  end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 120 then
    raise exception 'PIA: check-in stays open between 5 and 120 minutes.' using errcode = 'P0001';
  end if;

  update public.checkins set stopped_at = now() where section = v_section and stopped_at is null;
  insert into public.checkins (section, ends_at, started_by)
  values (v_section, now() + make_interval(mins => p_minutes), public.current_email())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_stop_checkin(p_section text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  update public.checkins set stopped_at = now() where section = trim(p_section) and stopped_at is null;
end;
$$;

-- Lets in the ticked requests. Only a request that is still waiting, under 20
-- minutes old, for a section whose check-in is still open.
create or replace function public.admin_let_in(p_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  perform public.pia_require_admin();
  update public.join_requests r
     set status = 'let_in', let_in_at = now()
   where r.id = any (coalesce(p_ids, '{}'))
     and r.status = 'waiting'
     and r.created_at > now() - interval '20 minutes'
     and exists (select 1 from public.checkins c
                  where c.section = r.section and c.stopped_at is null and c.ends_at > now());
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.admin_set_student_number(p_email text, p_number text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := public.pia_number_key(p_number);
begin
  perform public.pia_require_admin();
  if v_key !~ '^[0-9]{11}$' then
    raise exception 'PIA: a student number has 11 digits.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where lower(email) = lower(trim(p_email))) then
    raise exception 'PIA: no student is registered with that email.' using errcode = 'P0002';
  end if;
  insert into public.student_numbers (email, number_key, number)
  values (lower(trim(p_email)), v_key, trim(p_number))
  on conflict (email) do update set number_key = excluded.number_key, number = excluded.number, updated_at = now();
end;
$$;

create or replace function public.admin_import_student_numbers(p_rows jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_count int := 0;
begin
  perform public.pia_require_admin();
  for r in select * from jsonb_to_recordset(p_rows) as x(email text, number text) loop
    perform public.admin_set_student_number(r.email, r.number);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.admin_checkin_overview()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();

  -- Housekeeping: nothing older than a day is of any use.
  delete from public.join_requests where created_at < now() - interval '1 day';
  delete from public.join_attempts where at < now() - interval '1 day';

  return jsonb_build_object(
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'section', s.section, 'students', s.n, 'without_number', s.missing) order by s.section)
        from (select trim(p.section) as section, count(*) as n,
                     count(*) filter (where sn.email is null) as missing
                from public.profiles p
                left join public.student_numbers sn on sn.email = lower(p.email)
               where lower(trim(coalesce(p.role, 'student'))) = 'student' and nullif(trim(p.section), '') is not null
               group by trim(p.section)) s), '[]'::jsonb),
    'open', coalesce((
      select jsonb_agg(jsonb_build_object('section', c.section, 'ends_at', c.ends_at) order by c.section)
        from public.checkins c where c.stopped_at is null and c.ends_at > now()), '[]'::jsonb),
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'section', w.section, 'full_name', w.full_name, 'created_at', w.created_at,
               'duplicate', w.dupes > 1) order by w.created_at)
        from (select r.id, r.section, p.full_name, r.created_at,
                     count(*) over (partition by r.email) as dupes
                from public.join_requests r
                left join public.profiles p on lower(p.email) = r.email
               where r.status = 'waiting' and r.created_at > now() - interval '20 minutes'
                 and exists (select 1 from public.checkins c
                              where c.section = r.section and c.stopped_at is null and c.ends_at > now())) w),
      '[]'::jsonb));
end;
$$;

revoke all on function public.admin_start_checkin(text, int), public.admin_stop_checkin(text),
  public.admin_let_in(uuid[]), public.admin_set_student_number(text, text),
  public.admin_import_student_numbers(jsonb), public.admin_checkin_overview() from public, anon;
grant execute on function public.admin_start_checkin(text, int), public.admin_stop_checkin(text),
  public.admin_let_in(uuid[]), public.admin_set_student_number(text, text),
  public.admin_import_student_numbers(jsonb), public.admin_checkin_overview() to authenticated;


do $$
begin
  if has_table_privilege('anon', 'public.student_numbers', 'select')
     or has_table_privilege('authenticated', 'public.student_numbers', 'select')
     or has_table_privilege('authenticated', 'public.checkins', 'select')
     or has_table_privilege('authenticated', 'public.join_requests', 'select')
     or has_table_privilege('authenticated', 'public.join_attempts', 'select') then
    raise exception 'PIA 0052 ABORT: a door table is readable by anon or authenticated.' using errcode = 'P0001';
  end if;
  raise notice 'PIA 0052 OK: student numbers, check-in and join requests are admin-only. Load the numbers with admin_import_student_numbers().';
end;
$$;

commit;

-- ROLLBACK (only if nothing depends on it):
--   drop function if exists public.admin_checkin_overview(), public.admin_import_student_numbers(jsonb),
--     public.admin_set_student_number(text, text), public.admin_let_in(uuid[]),
--     public.admin_stop_checkin(text), public.admin_start_checkin(text, int),
--     public.pia_require_admin(), public.pia_number_key(text);
--   drop table if exists public.join_attempts, public.join_requests, public.checkins, public.student_numbers;


-- ############################################################################
-- MIGRATION 20261014_0053_student_numbers_by_hand
-- ############################################################################

-- ============================================================================
-- PIA 0053 -- TYPING STUDENT NUMBERS BY HAND
-- ============================================================================
-- For the admin who adds students one at a time and has no spreadsheet:
--
--   admin_students_with_numbers(section)   the section's students with the number
--                                          each already has (empty when none), so the
--                                          admin page can show one box per student.
--   admin_set_student_number(email, number) REPLACED so that a number already given
--                                          to another student says so in plain words
--                                          instead of a database error.
--
-- Requires 0052. SAFE TO RE-RUN. No table or row is changed.
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.student_numbers') is null
     or to_regprocedure('public.pia_require_admin()') is null then
    raise exception 'PIA 0053 ABORT (nothing changed): apply 0052 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.admin_students_with_numbers(p_section text)
returns table (email text, full_name text, number text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query
    select p.email, p.full_name, sn.number
      from public.profiles p
      left join public.student_numbers sn on sn.email = lower(p.email)
     where trim(p.section) = trim(p_section)
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and p.email is not null
     order by p.full_name;
end;
$$;

create or replace function public.admin_set_student_number(p_email text, p_number text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key   text := public.pia_number_key(p_number);
  v_owner text;
begin
  perform public.pia_require_admin();
  if v_key !~ '^[0-9]{11}$' then
    raise exception 'PIA: a student number has 11 digits.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles where lower(email) = lower(trim(p_email))) then
    raise exception 'PIA: no student is registered with that email.' using errcode = 'P0002';
  end if;

  select sn.email into v_owner
    from public.student_numbers sn
   where sn.number_key = v_key and sn.email <> lower(trim(p_email));
  if v_owner is not null then
    raise exception 'PIA: that number already belongs to another student (%).', v_owner using errcode = 'P0001';
  end if;

  insert into public.student_numbers (email, number_key, number)
  values (lower(trim(p_email)), v_key, trim(p_number))
  on conflict (email) do update set number_key = excluded.number_key, number = excluded.number, updated_at = now();
end;
$$;

revoke all on function public.admin_students_with_numbers(text), public.admin_set_student_number(text, text) from public, anon;
grant execute on function public.admin_students_with_numbers(text), public.admin_set_student_number(text, text) to authenticated;

commit;

-- ROLLBACK: drop function if exists public.admin_students_with_numbers(text);
--   (admin_set_student_number keeps working; 0052's version can be restored by re-running 0052.)


-- ############################################################################
-- MIGRATION 20261018_0054_numbers_for_the_roster
-- ############################################################################

-- ============================================================================
-- PIA 0054 -- STUDENT NUMBERS FOR THE ROSTER TABLE
-- ============================================================================
-- The Students page shows one box per student for the student number. It asks for
-- the numbers of the students on the page in one call:
--
--   admin_numbers_for(emails)   email + number for each of those students that
--                               has one. Admin only.
--
-- Requires 0052. SAFE TO RE-RUN. No table or row is changed.
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.student_numbers') is null
     or to_regprocedure('public.pia_require_admin()') is null then
    raise exception 'PIA 0054 ABORT (nothing changed): apply 0052 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.admin_numbers_for(p_emails text[])
returns table (email text, number text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query
    select sn.email, sn.number
      from public.student_numbers sn
     where sn.email in (select lower(trim(e)) from unnest(coalesce(p_emails, '{}')) as e);
end;
$$;

revoke all on function public.admin_numbers_for(text[]) from public, anon;
grant execute on function public.admin_numbers_for(text[]) to authenticated;

commit;

-- ROLLBACK: drop function if exists public.admin_numbers_for(text[]);


-- ############################################################################
-- MIGRATION 20261018_0055_numbers_taken
-- ############################################################################

-- ============================================================================
-- PIA 0055 -- WHICH OF THESE STUDENT NUMBERS ARE TAKEN
-- ============================================================================
-- The Add students dialog asks, before it creates anything, whether any of the
-- numbers typed already belong to a student:
--
--   admin_numbers_taken(numbers)   one row per number that is already used:
--                                  the number, the student's name and email.
--                                  Admin only.
--
-- Requires 0052. SAFE TO RE-RUN. No table or row is changed.
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.student_numbers') is null
     or to_regprocedure('public.pia_require_admin()') is null
     or to_regprocedure('public.pia_number_key(text)') is null then
    raise exception 'PIA 0055 ABORT (nothing changed): apply 0052 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.admin_numbers_taken(p_numbers text[])
returns table (number_key text, full_name text, email text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query
    select sn.number_key, p.full_name, sn.email
      from public.student_numbers sn
      left join public.profiles p on lower(p.email) = sn.email
     where sn.number_key in (select public.pia_number_key(n) from unnest(coalesce(p_numbers, '{}')) as n);
end;
$$;

revoke all on function public.admin_numbers_taken(text[]) from public, anon;
grant execute on function public.admin_numbers_taken(text[]) to authenticated;

commit;

-- ROLLBACK: drop function if exists public.admin_numbers_taken(text[]);


-- ############################################################################
-- MIGRATION 20261019_0056_sections_view
-- ############################################################################

-- ============================================================================
-- PIA 0056 -- DATA FOR THE SECTIONS PAGE
-- ============================================================================
-- The Sections page opens with one card per section and, inside a section, shows
-- that section's attendance and its students:
--
--   admin_section_students(section)   a section's students with the student number,
--                                     condition, stage, status and whether OCEAN is
--                                     done. Admin only.
--   admin_checkin_overview()          REPLACED: the same, and each section now also
--                                     says how many of its students finished OCEAN.
--
-- Requires 0052. SAFE TO RE-RUN. No table or row is changed.
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.student_numbers') is null
     or to_regclass('public.checkins') is null
     or to_regprocedure('public.pia_require_admin()') is null then
    raise exception 'PIA 0056 ABORT (nothing changed): apply 0052 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.admin_section_students(p_section text)
returns table (email text, full_name text, number text, group_type text, current_stage text, status text, is_ocean_done boolean)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query
    select p.email, p.full_name, sn.number, p.group_type, p.current_stage, p.status,
           coalesce(p.is_ocean_done, false)
      from public.profiles p
      left join public.student_numbers sn on sn.email = lower(p.email)
     where trim(p.section) = trim(p_section)
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
       and p.email is not null
     order by lower(p.full_name);
end;
$$;

create or replace function public.admin_checkin_overview()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();

  -- Housekeeping: nothing older than a day is of any use.
  delete from public.join_requests where created_at < now() - interval '1 day';
  delete from public.join_attempts where at < now() - interval '1 day';

  return jsonb_build_object(
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'section', s.section, 'students', s.n, 'without_number', s.missing, 'ocean_done', s.ocean) order by s.section)
        from (select trim(p.section) as section, count(*) as n,
                     count(*) filter (where sn.email is null) as missing,
                     count(*) filter (where coalesce(p.is_ocean_done, false)) as ocean
                from public.profiles p
                left join public.student_numbers sn on sn.email = lower(p.email)
               where lower(trim(coalesce(p.role, 'student'))) = 'student' and nullif(trim(p.section), '') is not null
               group by trim(p.section)) s), '[]'::jsonb),
    'open', coalesce((
      select jsonb_agg(jsonb_build_object('section', c.section, 'ends_at', c.ends_at) order by c.section)
        from public.checkins c where c.stopped_at is null and c.ends_at > now()), '[]'::jsonb),
    'waiting', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'section', w.section, 'full_name', w.full_name, 'created_at', w.created_at,
               'duplicate', w.dupes > 1) order by w.created_at)
        from (select r.id, r.section, p.full_name, r.created_at,
                     count(*) over (partition by r.email) as dupes
                from public.join_requests r
                left join public.profiles p on lower(p.email) = r.email
               where r.status = 'waiting' and r.created_at > now() - interval '20 minutes'
                 and exists (select 1 from public.checkins c
                              where c.section = r.section and c.stopped_at is null and c.ends_at > now())) w),
      '[]'::jsonb));
end;
$$;

revoke all on function public.admin_section_students(text), public.admin_checkin_overview() from public, anon;
grant execute on function public.admin_section_students(text), public.admin_checkin_overview() to authenticated;

commit;

-- ROLLBACK: drop function if exists public.admin_section_students(text);
--   (re-run 0052 to restore the previous admin_checkin_overview.)


-- ############################################################################
-- MIGRATION 20261020_0057_rename_delete_section
-- ############################################################################

-- ============================================================================
-- PIA 0057 -- RENAME AND DELETE A SECTION
-- ============================================================================
--   admin_rename_section(old, new)   the new name goes everywhere the old one
--                                    was: sections, students, professors,
--                                    attendance, requests, stage overrides.
--   admin_delete_section(name)       only an EMPTY section: no student, no
--                                    professor assigned. Anything else is
--                                    refused, so nobody is ever left without
--                                    a section.
--
-- Admin only. Requires 0052. SAFE TO RE-RUN.
-- ============================================================================

begin;

do $$
begin
  if to_regprocedure('public.pia_require_admin()') is null
     or to_regclass('public.checkins') is null then
    raise exception 'PIA 0057 ABORT (nothing changed): apply 0052 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.admin_rename_section(p_old text, p_new text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old text := trim(coalesce(p_old, ''));
  v_new text := trim(coalesce(p_new, ''));
begin
  perform public.pia_require_admin();
  if v_new = '' then raise exception 'Type the new section name.' using errcode = 'P0001'; end if;
  if length(v_new) > 40 then raise exception 'Keep the name under 40 characters.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.sections where name = v_old) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  if v_new = v_old then return; end if;
  if exists (select 1 from public.sections where lower(name) = lower(v_new) and name <> v_old) then
    raise exception 'A section with that name already exists.' using errcode = 'P0001';
  end if;

  update public.sections       set name = v_new             where name = v_old;
  update public.profiles       set section = v_new          where section = v_old;
  update public.professors     set assigned_section = v_new where assigned_section = v_old;
  update public.checkins       set section = v_new          where section = v_old;
  update public.join_requests  set section = v_new          where section = v_old;
  update public.stage_overrides set section = v_new         where section = v_old;
end;
$$;

create or replace function public.admin_delete_section(p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
begin
  perform public.pia_require_admin();
  if exists (select 1 from public.profiles where section = v_name) then
    raise exception 'This section still has students. Move them first.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.professors where assigned_section = v_name) then
    raise exception 'A professor is assigned to this section.' using errcode = 'P0001';
  end if;
  delete from public.checkins        where section = v_name;
  delete from public.join_requests   where section = v_name;
  delete from public.stage_overrides where section = v_name;
  delete from public.sections        where name = v_name;
end;
$$;

revoke all on function public.admin_rename_section(text, text) from public, anon;
revoke all on function public.admin_delete_section(text) from public, anon;
grant execute on function public.admin_rename_section(text, text) to authenticated;
grant execute on function public.admin_delete_section(text) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261021_0058_roll_call
-- ############################################################################

-- ============================================================================
-- PIA 0058 -- ROLL CALL: THE ADMIN MARKS WHO IS PRESENT, THE STUDENT WALKS IN
-- ============================================================================
-- Replaces "ask to be let in, wait, get ticked" with a roll call. While an
-- attendance is open the admin marks each student present (check) or absent
-- (cross). A student marked present who types their number goes straight into
-- the game; anyone else is told to see the admin. A number gets in ONCE per
-- attendance: a second computer is refused and the row shows it, and the admin
-- can let that student back in.
--
--   attendance_marks                      one row per student per attendance
--   admin_set_attendance(section, email, present)   true / false, null clears
--   admin_attendance(section)             marks of the open attendance
--   admin_let_back_in(section, email)     lets a refused student try again
--
-- Requires 0052. SAFE TO RE-RUN. The old request tables are left alone.
-- ============================================================================

begin;

do $$
begin
  if to_regclass('public.checkins') is null
     or to_regprocedure('public.pia_require_admin()') is null then
    raise exception 'PIA 0058 ABORT (nothing changed): apply 0052 first.' using errcode = 'P0001';
  end if;
end;
$$;

create table if not exists public.attendance_marks (
  checkin_id    uuid        not null,
  email         text        not null,
  present       boolean     not null,
  entered_at    timestamptz,
  refused_count int         not null default 0,
  marked_at     timestamptz not null default now(),
  primary key (checkin_id, email)
);
alter table public.attendance_marks enable row level security;
revoke all on public.attendance_marks from public, anon, authenticated;

create or replace function public.admin_set_attendance(p_section text, p_email text, p_present boolean)
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
  select c.id into v_id from public.checkins c
   where c.section = trim(p_section) and c.stopped_at is null and c.ends_at > now();
  if v_id is null then
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

create or replace function public.admin_attendance(p_section text)
returns table (email text, present boolean, entered boolean, refused int)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query
    select m.email, m.present, (m.entered_at is not null), m.refused_count
      from public.attendance_marks m
      join public.checkins c on c.id = m.checkin_id
     where c.section = trim(p_section) and c.stopped_at is null and c.ends_at > now();
end;
$$;

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
    from public.checkins c
   where c.id = m.checkin_id and c.section = trim(p_section)
     and c.stopped_at is null and c.ends_at > now()
     and m.email = lower(trim(coalesce(p_email, '')));
end;
$$;

revoke all on function public.admin_set_attendance(text, text, boolean) from public, anon;
revoke all on function public.admin_attendance(text) from public, anon;
revoke all on function public.admin_let_back_in(text, text) from public, anon;
grant execute on function public.admin_set_attendance(text, text, boolean) to authenticated;
grant execute on function public.admin_attendance(text) to authenticated;
grant execute on function public.admin_let_back_in(text, text) to authenticated;

commit;

-- ROLLBACK: drop function if exists public.admin_set_attendance(text,text,boolean);
--   drop function if exists public.admin_attendance(text);
--   drop function if exists public.admin_let_back_in(text,text);
--   drop table if exists public.attendance_marks;


-- ############################################################################
-- MIGRATION 20261022_0059_one_professor_per_section
-- ############################################################################

-- ============================================================================
-- PIA 0059 -- ONE PROFESSOR PER SECTION, A PROFESSOR MAY HAVE SEVERAL SECTIONS
-- ============================================================================
-- Until now a professor had ONE section (professors.assigned_section) and two
-- professors could share a section. Now:
--
--   professor_sections (email, section)   section is UNIQUE: one professor per
--                                         section; an email may appear many times
--
--   admin_set_section_professor(section, email)   give a section to a professor,
--                                         or clear it (email null). Admin only.
--   admin_professor_sections()            every (professor, section) pair. Admin only.
--   teacher_my_sections()                 the caller's sections and the one in use.
--   teacher_set_section(section)          a teacher switches the section they are
--                                         looking at (only one of their own).
--
-- NOTHING ABOUT WHAT A TEACHER CAN SEE CHANGES. teacher_class_status() (0026) still
-- reads the teacher's profiles.section; switching section just moves that value
-- among the sections the admin gave them. professors.assigned_section is kept as
-- the professor's first section, so everything that reads it keeps working.
--
-- A section that already has a professor cannot be given to a second one.
--
-- 0057 is replaced here so that deleting or renaming a section also looks at
-- professor_sections.
--
-- Requires 0052 and 0057. SAFE TO RE-RUN.
-- ============================================================================

begin;

do $$
begin
  if to_regprocedure('public.pia_require_admin()') is null
     or to_regclass('public.professors') is null
     or to_regprocedure('public.admin_delete_section(text)') is null then
    raise exception 'PIA 0059 ABORT (nothing changed): apply 0052 and 0057 first.' using errcode = 'P0001';
  end if;
end;
$$;

create table if not exists public.professor_sections (
  email   text not null,
  section text not null,
  primary key (email, section),
  unique (section)
);
alter table public.professor_sections enable row level security;
revoke all on public.professor_sections from public, anon, authenticated;

-- One professor per section. Where two had the same section, the one who has a
-- teacher profile (can actually sign in) keeps it, else the first by email.
insert into public.professor_sections (email, section)
select distinct on (trim(f.assigned_section)) lower(f.email), trim(f.assigned_section)
  from public.professors f
  left join public.profiles p on lower(p.email) = lower(f.email) and lower(trim(p.role)) = 'teacher'
 where nullif(trim(f.assigned_section), '') is not null
 order by trim(f.assigned_section), (p.email is null), lower(f.email)
on conflict do nothing;

-- Keep a professor's assigned_section and the teacher profile's section in step with the table.
create or replace function public.pia_sync_professor(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_first text;
begin
  select ps.section into v_first from public.professor_sections ps where ps.email = v_email order by ps.section limit 1;
  update public.professors set assigned_section = v_first where lower(email) = v_email;
  update public.profiles p
     set section = case when exists (select 1 from public.professor_sections ps where ps.email = v_email and ps.section = p.section)
                        then p.section else v_first end
   where lower(p.email) = v_email and lower(trim(coalesce(p.role, ''))) = 'teacher';
end;
$$;
revoke all on function public.pia_sync_professor(text) from public, anon, authenticated;

do $$
declare r record;
begin
  for r in select lower(email) as email from public.professors loop
    perform public.pia_sync_professor(r.email);
  end loop;
end;
$$;

-- A professor added with a section (admin_register_teacher writes assigned_section) gets the row;
-- a section that already has someone else is refused.
create or replace function public.professors_claim_section()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := nullif(trim(coalesce(new.assigned_section, '')), '');
begin
  if v_section is null then return new; end if;
  if exists (select 1 from public.professor_sections ps where ps.section = v_section and ps.email <> lower(new.email)) then
    raise exception 'That section already has a professor.' using errcode = 'P0001';
  end if;
  insert into public.professor_sections (email, section) values (lower(new.email), v_section) on conflict do nothing;
  return new;
end;
$$;
drop trigger if exists professors_claim_section on public.professors;
create trigger professors_claim_section
  before insert or update of assigned_section on public.professors
  for each row execute function public.professors_claim_section();

create or replace function public.admin_set_section_professor(p_section text, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := trim(coalesce(p_section, ''));
  v_email   text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_old     text;
begin
  perform public.pia_require_admin();
  if not exists (select 1 from public.sections where name = v_section) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  if v_email is not null and not exists (select 1 from public.professors where lower(email) = v_email) then
    raise exception 'That professor was not found.' using errcode = 'P0001';
  end if;
  select ps.email into v_old from public.professor_sections ps where ps.section = v_section;
  delete from public.professor_sections where section = v_section;
  if v_email is not null then
    insert into public.professor_sections (email, section) values (v_email, v_section);
  end if;
  if v_old is not null then perform public.pia_sync_professor(v_old); end if;
  if v_email is not null then perform public.pia_sync_professor(v_email); end if;
end;
$$;

create or replace function public.admin_professor_sections()
returns table (email text, section text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.pia_require_admin();
  return query select ps.email, ps.section from public.professor_sections ps order by ps.section;
end;
$$;

create or replace function public.teacher_my_sections()
returns table (section text, in_use boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can do this.' using errcode = '42501';
  end if;
  return query
    select ps.section,
           coalesce(ps.section = (select p.section from public.profiles p where lower(p.email) = v_email limit 1), false)
      from public.professor_sections ps
     where ps.email = v_email
     order by ps.section;
end;
$$;

create or replace function public.teacher_set_section(p_section text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(auth.jwt() ->> 'email');
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can do this.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.professor_sections ps where ps.email = v_email and ps.section = trim(coalesce(p_section, ''))) then
    raise exception 'That is not one of your sections.' using errcode = '42501';
  end if;
  update public.profiles set section = trim(p_section)
   where lower(email) = v_email and lower(trim(coalesce(role, ''))) = 'teacher';
end;
$$;

-- Deleting and renaming a section now also look at professor_sections.
create or replace function public.admin_delete_section(p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
begin
  perform public.pia_require_admin();
  if exists (select 1 from public.profiles where section = v_name and lower(trim(coalesce(role, 'student'))) = 'student') then
    raise exception 'This section still has students. Move them first.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.professor_sections where section = v_name) then
    raise exception 'A professor is assigned to this section.' using errcode = 'P0001';
  end if;
  delete from public.checkins        where section = v_name;
  delete from public.join_requests   where section = v_name;
  delete from public.stage_overrides where section = v_name;
  delete from public.sections        where name = v_name;
end;
$$;

create or replace function public.admin_rename_section(p_old text, p_new text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old text := trim(coalesce(p_old, ''));
  v_new text := trim(coalesce(p_new, ''));
begin
  perform public.pia_require_admin();
  if v_new = '' then raise exception 'Type the new section name.' using errcode = 'P0001'; end if;
  if length(v_new) > 40 then raise exception 'Keep the name under 40 characters.' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.sections where name = v_old) then
    raise exception 'That section no longer exists.' using errcode = 'P0001';
  end if;
  if v_new = v_old then return; end if;
  if exists (select 1 from public.sections where lower(name) = lower(v_new) and name <> v_old) then
    raise exception 'A section with that name already exists.' using errcode = 'P0001';
  end if;
  update public.sections          set name = v_new             where name = v_old;
  update public.profiles          set section = v_new          where section = v_old;
  update public.professors        set assigned_section = v_new where assigned_section = v_old;
  update public.professor_sections set section = v_new         where section = v_old;
  update public.checkins          set section = v_new          where section = v_old;
  update public.join_requests     set section = v_new          where section = v_old;
  update public.stage_overrides   set section = v_new          where section = v_old;
end;
$$;

revoke all on function public.admin_set_section_professor(text, text) from public, anon;
revoke all on function public.admin_professor_sections() from public, anon;
revoke all on function public.teacher_my_sections() from public, anon;
revoke all on function public.teacher_set_section(text) from public, anon;
revoke all on function public.admin_delete_section(text) from public, anon;
revoke all on function public.admin_rename_section(text, text) from public, anon;
grant execute on function public.admin_set_section_professor(text, text) to authenticated;
grant execute on function public.admin_professor_sections() to authenticated;
grant execute on function public.teacher_my_sections() to authenticated;
grant execute on function public.teacher_set_section(text) to authenticated;
grant execute on function public.admin_delete_section(text) to authenticated;
grant execute on function public.admin_rename_section(text, text) to authenticated;

-- Postflight: one professor per section, and every pair points at a real professor.
do $$
begin
  if exists (select 1 from public.professor_sections group by section having count(*) > 1) then
    raise exception 'PIA 0059 ABORT: a section has more than one professor.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.professor_sections ps
              where not exists (select 1 from public.professors f where lower(f.email) = ps.email)) then
    raise exception 'PIA 0059 ABORT: a section points at a professor who does not exist.' using errcode = 'P0001';
  end if;
end;
$$;

commit;

-- ROLLBACK: drop trigger if exists professors_claim_section on public.professors;
--   drop function if exists public.professors_claim_section();
--   drop function if exists public.admin_set_section_professor(text,text);
--   drop function if exists public.admin_professor_sections();
--   drop function if exists public.teacher_my_sections();
--   drop function if exists public.teacher_set_section(text);
--   drop function if exists public.pia_sync_professor(text);
--   drop table if exists public.professor_sections;
--   (then re-run 0057 to restore admin_delete_section / admin_rename_section)


-- ############################################################################
-- MIGRATION 20261022_0060_tutoring_schedule_per_section
-- ############################################################################

-- PIA 0060: the Tutoring opens and closes per section, on a schedule the admin sets.
--
-- WHY. Until now two things decided whether a student could play: the stage switch of the
-- section (admin_grant_stage / admin_revoke_stage) and ONE closing time for everybody
-- (app_config.game_closes_at, 0045). The switch could say "open" while the closing time had
-- already passed, so students were locked out and the admin could not tell why. Now the
-- closing time belongs to the section, next to its switch, and may also have a start.
--
-- RULE. For a student of section S, the tutoring is CLOSED when S has a schedule row and
--   now() < opens_at   (not open yet), or
--   now() >= closes_at (closed).
-- No row, or a NULL side, means that side is not limited. Entry still needs the stage switch
-- (stage_overrides); the schedule only adds the time window. It is enforced where 0045
-- enforced it: answers and hints are refused, so it holds whether the student stays, quits
-- or comes back. Nothing needs to run at the start or end time: it is judged at each call.
--
-- STATE KEPT. Every section that had a student gets the old global closing time as its own
-- closing time, so what is closed today stays closed and what is open stays open.
-- app_config.game_closes_at stays in the table but is no longer read.
-- NO game record is changed or deleted. Nothing is applied by this file being in the repo.
begin;

do $$
begin
  if to_regprocedure('public.pia_tutoring_closed()') is null
     or to_regprocedure('public.tutoring_status()') is null
     or to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0060 ABORT (nothing changed): apply 0045/0048 (and the auth helpers) first.' using errcode = 'P0001';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The schedule, one row per section
-- ---------------------------------------------------------------------------
create table if not exists public.tutoring_schedule (
  section    text primary key,
  opens_at   timestamptz,
  closes_at  timestamptz,
  set_by     text,
  set_at     timestamptz not null default now(),
  check (opens_at is not null or closes_at is not null),
  check (opens_at is null or closes_at is null or closes_at > opens_at)
);

alter table public.tutoring_schedule enable row level security;
revoke all on public.tutoring_schedule from public, anon, authenticated;
grant select on public.tutoring_schedule to authenticated;

drop policy if exists tutoring_schedule_admin_read on public.tutoring_schedule;
create policy tutoring_schedule_admin_read on public.tutoring_schedule
  for select to authenticated
  using (public.pia_caller_role() = 'admin' and public.jwt_is_current());

comment on table public.tutoring_schedule is
  'When the Tutoring is open for a section (0060). No row = not limited by time. Replaces app_config.game_closes_at.';

-- The old global closing time becomes each section''s own, so no state changes.
insert into public.tutoring_schedule (section, opens_at, closes_at, set_by)
select s.section, null, c.game_closes_at, 'migration 0060'
  from (select distinct nullif(trim(p.section), '') as section
          from public.profiles p
         where lower(trim(coalesce(p.role, 'student'))) = 'student') s
  cross join (select game_closes_at from public.app_config where id = 1) c
 where s.section is not null and c.game_closes_at is not null
on conflict (section) do nothing;

-- ---------------------------------------------------------------------------
-- 2. The question every student function already asks, now per student
-- ---------------------------------------------------------------------------
create or replace function public.pia_tutoring_closed_for(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select (t.opens_at is not null and t.opens_at > now())
        or (t.closes_at is not null and t.closes_at <= now())
      from public.profiles p
      join public.tutoring_schedule t on t.section = nullif(trim(p.section), '')
     where lower(p.email) = lower(p_email)
     limit 1), false);
$$;

-- The caller's own section. Same name and shape as in 0045, so every function that calls it
-- (answers, hints, restart) keeps working unchanged.
create or replace function public.pia_tutoring_closed()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.pia_tutoring_closed_for(auth.jwt() ->> 'email');
$$;

create or replace function public.pia_window_expired(w public.game_windows)
returns boolean language sql stable as $$
  select public.pia_tutoring_closed_for(w.student_email);
$$;

create or replace function public.pia_clock_json(w public.game_windows)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'window',            w.window_no,
    'closed',            public.pia_tutoring_closed_for(w.student_email),
    'expired',           public.pia_tutoring_closed_for(w.student_email),
    'limit_seconds',     86400,
    'remaining_seconds', 86400);
$$;

create or replace function public.pia_game_window(p_session_id uuid, p_email text)
returns public.game_windows
language plpgsql
security definer
set search_path = public
as $$
declare
  w        public.game_windows%rowtype;
  v_closes timestamptz;
  v_closed boolean;
begin
  select t.closes_at into v_closes
    from public.profiles p
    join public.tutoring_schedule t on t.section = nullif(trim(p.section), '')
   where lower(p.email) = lower(p_email) limit 1;
  v_closed := public.pia_tutoring_closed_for(p_email);

  select * into w from public.game_windows
   where session_id = p_session_id and student_email = p_email
   order by window_no desc limit 1;

  if found then
    if w.ended_at is null and v_closed then
      update public.game_windows
         set ended_at = greatest(coalesce(v_closes, now()), w.started_at), ended_reason = 'closed'
       where session_id = w.session_id and student_email = w.student_email and window_no = w.window_no
       returning * into w;
      return w;
    end if;
    if w.ended_at is not null and not v_closed then
      insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
      values (p_session_id, p_email, w.window_no + 1, 0, 'infinity')
      returning * into w;
    end if;
    return w;
  end if;

  insert into public.game_windows (session_id, student_email, window_no, limit_seconds, deadline_at)
  values (p_session_id, p_email, 1, 0, 'infinity')
  returning * into w;
  return w;
end;
$$;

-- For the start screen: closed or not, and whether it simply has not started. The seconds are
-- only for the page to lock or unlock at the exact moment; they are never drawn.
create or replace function public.tutoring_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email text := public.pia_game_email();
  t       public.tutoring_schedule%rowtype;
begin
  select s.* into t
    from public.profiles p
    join public.tutoring_schedule s on s.section = nullif(trim(p.section), '')
   where lower(p.email) = lower(v_email) limit 1;

  return jsonb_build_object(
    'closed',            public.pia_tutoring_closed_for(v_email),
    'not_open_yet',      found and t.opens_at is not null and t.opens_at > now(),
    'seconds_to_open',   case when found and t.opens_at is not null and t.opens_at > now()
                              then ceil(extract(epoch from (t.opens_at - now())))::int end,
    'seconds_to_close',  case when found and t.closes_at is not null and t.closes_at > now()
                                   and not (t.opens_at is not null and t.opens_at > now())
                              then ceil(extract(epoch from (t.closes_at - now())))::int end);
end;
$$;

revoke all on function public.pia_tutoring_closed_for(text)             from public, anon, authenticated;
revoke all on function public.pia_tutoring_closed()                     from public, anon, authenticated;
revoke all on function public.pia_window_expired(public.game_windows)   from public, anon, authenticated;
revoke all on function public.pia_clock_json(public.game_windows)       from public, anon, authenticated;
revoke all on function public.pia_game_window(uuid, text)               from public, anon, authenticated;
revoke all on function public.tutoring_status()                         from public, anon;
grant execute on function public.tutoring_status()                      to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The admin sets or clears a section's schedule
-- ---------------------------------------------------------------------------
-- p_opens / p_closes: either may be NULL (not limited on that side). Both NULL removes the
-- schedule. A closing time that is already past is refused: it would lock the section at once.
create or replace function public.admin_set_tutoring_schedule(
  p_section text, p_opens timestamptz, p_closes timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_section text := nullif(trim(coalesce(p_section, '')), '');
begin
  if public.pia_caller_role() is distinct from 'admin' or not public.jwt_is_current() then
    raise exception 'PIA: only an administrator can set the tutoring schedule.' using errcode = '42501';
  end if;
  if v_section is null then
    raise exception 'PIA: choose a section.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where nullif(trim(section), '') = v_section) then
    raise exception 'PIA: unknown section: %', v_section using errcode = '22023';
  end if;

  if p_opens is null and p_closes is null then
    delete from public.tutoring_schedule where section = v_section;
    return jsonb_build_object('section', v_section, 'opens_at', null, 'closes_at', null);
  end if;

  if p_closes is not null and p_closes <= now() then
    raise exception 'PIA: the end must be in the future.' using errcode = '22023';
  end if;
  if p_opens is not null and p_closes is not null and p_closes <= p_opens then
    raise exception 'PIA: the end must be after the start.' using errcode = '22023';
  end if;

  insert into public.tutoring_schedule (section, opens_at, closes_at, set_by, set_at)
  values (v_section, p_opens, p_closes, lower(nullif(auth.jwt() ->> 'email', '')), now())
  on conflict (section) do update
    set opens_at = excluded.opens_at, closes_at = excluded.closes_at,
        set_by = excluded.set_by, set_at = excluded.set_at;

  return jsonb_build_object('section', v_section, 'opens_at', p_opens, 'closes_at', p_closes);
end;
$$;

revoke all on function public.admin_set_tutoring_schedule(text, timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_set_tutoring_schedule(text, timestamptz, timestamptz) to authenticated;

-- The admin screens see a change at once (row-level security still limits it to admins).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                      and schemaname = 'public' and tablename = 'tutoring_schedule') then
    alter publication supabase_realtime add table public.tutoring_schedule;
  end if;
end;
$$;

commit;


-- ############################################################################
-- MIGRATION 20261028_0061_teacher_ocean
-- ############################################################################

-- PIA 0061: a teacher takes the OCEAN questionnaire once, right after signing in.
--
-- WHY. The professor of a section is part of the study, so each teacher answers the same 50
-- statements the students do, before their dashboard opens. There is no admin switch for
-- it: it is simply open for a teacher who has not done it yet.
--
-- WHAT. One function, submit_ocean_results_teacher(integer[]):
--   * only a TEACHER can call it (anyone else is refused);
--   * once only: a teacher who already finished is refused (an admin retake that sets
--     profiles.is_ocean_done back to false lets them answer again);
--   * same validation and the same scoring sheet as the students' (public.pia_bfpt_score);
--   * the answers and scores go to ocean_submissions, which only an admin can read, so the
--     teacher never sees a score and no student sees theirs;
--   * profiles.is_ocean_done becomes true. NOTHING ELSE on the profile changes: no stage, no
--     group, no tutor. (The tutor-assignment trigger of 0041 only touches rows whose
--     group_type is 'assigned', which a teacher never has.)
--
-- submit_ocean_results (the students' function) is not touched.
-- Requires 0018 (pia_bfpt_score, ocean_submissions.scoring_key/source) and 0001 (pia_caller_role).
-- Nothing is changed in any existing row. SAFE TO RE-RUN.
begin;

do $$
begin
  if to_regprocedure('public.pia_bfpt_score(integer[])') is null
     or to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0061 ABORT (nothing changed): apply 0001, 0018 and the auth helpers first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.submit_ocean_results_teacher(p_responses integer[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.jwt() ->> 'email';
  v_profile public.profiles%rowtype;
  r         integer[];
  k         record;
begin
  if v_email is null then
    raise exception 'PIA: no authenticated session.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' or not public.jwt_is_current() then
    raise exception 'PIA: only a teacher can use this questionnaire.' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where email = v_email;
  if not found then
    raise exception 'PIA: no profile found for this session.' using errcode = '42501';
  end if;

  if coalesce(v_profile.is_ocean_done, false) then
    raise exception 'PIA: this questionnaire has already been submitted. Ask an admin for a retake.'
      using errcode = '42501';
  end if;

  if p_responses is null or array_length(p_responses, 1) is distinct from 50 then
    raise exception 'PIA: exactly 50 responses are required (received: %).',
      coalesce(array_length(p_responses, 1), 0) using errcode = '22023';
  end if;

  r := array(select x from unnest(p_responses) with ordinality as t(x, i) order by i);

  if exists (select 1 from unnest(r) v where v is null or v < 1 or v > 5) then
    raise exception 'PIA: every response must be between 1 and 5.' using errcode = '22023';
  end if;

  select * into k from public.pia_bfpt_score(r);

  insert into public.ocean_submissions
         (email, responses, ocean_e, ocean_a, ocean_c, ocean_n, ocean_o, scoring_key, source)
  values (v_email, r::smallint[], k.ocean_e, k.ocean_a, k.ocean_c, k.ocean_n, k.ocean_o,
          'bfpt-2026-07-22', 'questionnaire');

  update public.profiles set is_ocean_done = true where email = v_email;

  return jsonb_build_object('done', true);
end;
$$;

revoke all on function public.submit_ocean_results_teacher(integer[]) from public, anon;
grant execute on function public.submit_ocean_results_teacher(integer[]) to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261029_0062_close_idle_game_sessions
-- ############################################################################

-- PIA 0062: close the sessions of students who have gone quiet.
--
-- WHY. A student who closes the tab (or whose page is killed) leaves two things behind: an open
-- game window (game_windows.ended_at is null) and the "in a tutoring session" / "signed in" marks
-- on the profile. Nothing ever cleared them, so the admin showed "Active session" for children who
-- left weeks ago, and every window's Duration kept growing (one read 470 hours).
--
-- RULE. A student is QUIET when student_presence.last_seen is older than 20 minutes (or there is
-- no row). A signed-in student page reports in every 45 seconds while it is visible, and the idle
-- sign-out ends a minimised page after about 16 minutes, so 20 quiet minutes means the page is gone.
-- For every quiet student:
--   * each of their open game windows is closed at the time of their LAST ACTIVITY (the latest
--     answer, hint or step), with ended_reason = 'idle', or 'idle-long' when the window spans more
--     than 6 hours (a human should look at those);
--   * profiles.is_in_game becomes false and profiles.active_devices is emptied.
-- Nothing else is touched: no answer, score, OCEAN result or stage.
--
-- HOW OFTEN. Every 5 minutes, by pg_cron, when the extension can be enabled here. If it cannot,
-- the function still exists: schedule it from Database > Cron, or call it by hand.
--
--   select public.pia_close_idle_game_sessions(true);    -- DRY RUN: only counts, changes nothing
--   select public.pia_close_idle_game_sessions();        -- does it
--
-- NOTE. The first run also closes the three windows left open on purpose by the manual cleanup of
-- 2026-10-24 (0, 1 and about 6,658 minutes). They are tagged 'idle' / 'idle-long', so they can be
-- found again.
--
-- Requires 0039 (game_windows, step tables) and 0026 (student_presence). SAFE TO RE-RUN.
begin;

do $$
begin
  if to_regclass('public.game_windows') is null
     or to_regclass('public.student_presence') is null
     or to_regclass('public.step_events') is null then
    raise exception 'PIA 0062 ABORT (nothing changed): apply 0026 and 0039 first.' using errcode = 'P0001';
  end if;
end;
$$;

-- The open windows whose student has been quiet for 20 minutes, with their last activity.
create or replace function public.pia_idle_game_windows()
returns table (session_id uuid, student_email text, window_no int, started_at timestamptz, last_activity timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select w.session_id, w.student_email, w.window_no, w.started_at,
         greatest(w.started_at, coalesce(a.last_activity, w.started_at)) as last_activity
    from public.game_windows w
    left join lateral (
      select max(t) as last_activity
        from (
          select max(e.happened_at) as t from public.step_events e
           where e.session_id = w.session_id and e.student_email = w.student_email and e.happened_at >= w.started_at
          union all
          select max(h.taken_at) from public.step_hints h
           where h.session_id = w.session_id and h.student_email = w.student_email and h.taken_at >= w.started_at
          union all
          select max(s.updated_at) from public.step_states s
           where s.session_id = w.session_id and s.student_email = w.student_email and s.updated_at >= w.started_at
        ) x
    ) a on true
   where w.ended_at is null
     and not exists (
           select 1 from public.student_presence sp
            where lower(sp.student_email) = lower(w.student_email)
              and sp.last_seen > now() - interval '20 minutes');
$$;

create or replace function public.pia_close_idle_game_sessions(p_dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_windows  int := 0;
  v_profiles int := 0;
begin
  if p_dry_run then
    select count(*) into v_windows from public.pia_idle_game_windows();
    select count(*) into v_profiles
      from public.profiles p
     where lower(trim(coalesce(p.role, 'student'))) = 'student'
       and (p.is_in_game or coalesce(array_length(p.active_devices, 1), 0) > 0)
       and not exists (select 1 from public.student_presence sp
                        where lower(sp.student_email) = lower(p.email)
                          and sp.last_seen > now() - interval '20 minutes');
    return jsonb_build_object('dry_run', true, 'windows_would_close', v_windows, 'profiles_would_clear', v_profiles);
  end if;

  update public.game_windows w
     set ended_at     = i.last_activity,
         ended_reason = case when i.last_activity - i.started_at > interval '6 hours' then 'idle-long' else 'idle' end
    from public.pia_idle_game_windows() i
   where w.session_id = i.session_id
     and w.student_email = i.student_email
     and w.window_no = i.window_no
     and w.ended_at is null;
  get diagnostics v_windows = row_count;

  update public.profiles p
     set is_in_game = false,
         active_devices = '{}'
   where lower(trim(coalesce(p.role, 'student'))) = 'student'
     and (p.is_in_game or coalesce(array_length(p.active_devices, 1), 0) > 0)
     and not exists (select 1 from public.student_presence sp
                      where lower(sp.student_email) = lower(p.email)
                        and sp.last_seen > now() - interval '20 minutes');
  get diagnostics v_profiles = row_count;

  return jsonb_build_object('dry_run', false, 'windows_closed', v_windows, 'profiles_cleared', v_profiles);
end;
$$;

-- Only the database itself (the schedule below) and an administrator in the SQL Editor run these.
revoke all on function public.pia_idle_game_windows()                 from public, anon, authenticated;
revoke all on function public.pia_close_idle_game_sessions(boolean)   from public, anon, authenticated;

-- Every 5 minutes. Skipped with a notice (not an error) if pg_cron cannot be enabled here.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'pia-close-idle-game-sessions';
  perform cron.schedule('pia-close-idle-game-sessions', '*/5 * * * *', 'select public.pia_close_idle_game_sessions()');
exception when others then
  raise notice 'PIA 0062: the function is installed but the 5-minute schedule was NOT created (%). Schedule it in Database > Cron.', sqlerrm;
end;
$$;

commit;


-- ############################################################################
-- MIGRATION 20261025_0063_forget_deleted_student
-- ############################################################################

-- PIA 0063: a deleted student takes their student number (and door records) with them.
--
-- WHY. 0052 gave every student a number in public.student_numbers, keyed by email. Deleting a
-- participant (admin_delete_user, 0021) removes the profile, the auth user and the responses, but it
-- was written before 0052 and does not know about that table. The number stayed behind, still
-- "belonging" to an email that no longer exists, so adding the same student again failed with
-- "<email> already has this number" while the student could not be found anywhere.
--
-- WHAT.
--   1. ONE TIME: numbers that belong to no profile are removed. A copy goes to
--      student_numbers_orphans_backup_20261025 first (locked: nobody can read it through the API).
--   2. FROM NOW ON: a trigger on profiles. Whenever a profile is deleted, by any path, that
--      student's number, waiting join requests and roll-call marks are deleted with it.
-- Nothing else is touched. No other student, no answer, score or OCEAN result.
--
-- Requires 0052 (student_numbers, join_requests) and 0058 (attendance_marks). SAFE TO RE-RUN.
begin;

do $$
begin
  if to_regclass('public.student_numbers') is null
     or to_regclass('public.join_requests') is null
     or to_regclass('public.attendance_marks') is null then
    raise exception 'PIA 0063 ABORT (nothing changed): apply 0052 and 0058 first.' using errcode = 'P0001';
  end if;
end;
$$;

-- 1. The numbers that belong to nobody: backup, then delete.
drop table if exists public.student_numbers_orphans_backup_20261025;
create table public.student_numbers_orphans_backup_20261025 as
select n.*
  from public.student_numbers n
 where not exists (select 1 from public.profiles p where lower(p.email) = lower(n.email));

alter table public.student_numbers_orphans_backup_20261025 enable row level security;
revoke all on public.student_numbers_orphans_backup_20261025 from public, anon, authenticated;

do $$
declare
  v_orphans  int;
  v_profiles int;
begin
  select count(*) into v_orphans  from public.student_numbers_orphans_backup_20261025;
  select count(*) into v_profiles from public.profiles;
  -- A sane run removes a handful. Many, or an empty profiles table, means something is wrong.
  if v_profiles = 0 or v_orphans > 30 then
    raise exception 'STOP: % orphan numbers and % profiles. Nothing was changed.', v_orphans, v_profiles;
  end if;

  delete from public.student_numbers n
   using public.student_numbers_orphans_backup_20261025 b
   where n.email = b.email;
end;
$$;

-- 2. From now on.
create or replace function public.pia_forget_deleted_student()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.student_numbers   where lower(email) = lower(old.email);
  delete from public.join_requests     where lower(email) = lower(old.email);
  delete from public.attendance_marks  where lower(email) = lower(old.email);
  return old;
end;
$$;

revoke all on function public.pia_forget_deleted_student() from public, anon, authenticated;

drop trigger if exists trg_pia_forget_deleted_student on public.profiles;
create trigger trg_pia_forget_deleted_student
  after delete on public.profiles
  for each row execute function public.pia_forget_deleted_student();

commit;


-- ############################################################################
-- MIGRATION 20261029_0064_teacher_section_roster
-- ############################################################################

-- PIA 0064: the teacher sees their section's roster, read-only, and nothing sensitive.
--
-- WHY. The teacher console is being rebuilt in the homepage look as a plain roster: who is in the
-- section, who is online, where they are, and (while a roll call is open) who the admin marked
-- present. A teacher cannot read student rows directly (0026), so this one function is the only
-- door, and it returns ONLY these columns:
--
--   student_key   an opaque id (md5 of the email), never the email
--   full_name     the student's name
--   online        reported in within the last 2 minutes
--   stage         'waiting' | 'setting_up' | 'tutoring'. OCEAN and Character Selection are one label
--                 ("setting_up") because Character Selection would reveal the research group.
--   attendance    'present' | 'absent' | 'not_marked' while a roll call is open for the section,
--                 otherwise null
--
-- It returns NO student number, no email, no OCEAN result, no research group, no tutor persona,
-- no score, no answer and no lesson progress. A teacher can only call it for their own section.
-- Read-only: it changes nothing.
--
-- teacher_class_status (0026) stays as it is; the new teacher page no longer uses it.
-- Requires 0026 (student_presence), 0052 (checkins) and 0058 (attendance_marks). SAFE TO RE-RUN.
begin;

do $$
begin
  if to_regclass('public.student_presence') is null
     or to_regclass('public.checkins') is null
     or to_regclass('public.attendance_marks') is null
     or to_regprocedure('public.pia_caller_role()') is null
     or to_regprocedure('public.jwt_is_current()') is null then
    raise exception 'PIA 0064 ABORT (nothing changed): apply 0026, 0052 and 0058 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.teacher_section_roster()
returns table (
  student_key text,
  full_name   text,
  online      boolean,
  stage       text,
  attendance  text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_section text;
  v_checkin uuid;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can view a class.' using errcode = '42501';
  end if;

  -- The teacher's own section: their profile, else the faculty record the admin assigned.
  select coalesce(
           nullif(trim(p.section), ''),
           (select nullif(trim(f.assigned_section), '') from public.professors f
             where lower(f.email) = v_email limit 1))
    into v_section
    from public.profiles p
   where lower(p.email) = v_email
   limit 1;

  if v_section is null then
    return;
  end if;

  select c.id into v_checkin
    from public.checkins c
   where c.section = v_section and c.stopped_at is null and c.ends_at > now()
   order by c.started_at desc
   limit 1;

  return query
    select md5(lower(p.email)),
           coalesce(nullif(trim(p.full_name), ''), 'Unnamed student'),
           coalesce(sp.last_seen > now() - interval '2 minutes', false),
           case p.current_stage
             when 'OCEAN'               then 'setting_up'
             when 'Character Selection' then 'setting_up'
             when 'Tutoring Dashboard'  then 'tutoring'
             else 'waiting'
           end,
           case when v_checkin is null then null
                else coalesce((select case when m.present then 'present' else 'absent' end
                                 from public.attendance_marks m
                                where m.checkin_id = v_checkin and lower(m.email) = lower(p.email)),
                              'not_marked')
           end
      from public.profiles p
      left join public.student_presence sp on lower(sp.student_email) = lower(p.email)
     where p.section = v_section
       and lower(trim(coalesce(p.role, 'student'))) = 'student'
     order by p.full_name;
end;
$$;

revoke all on function public.teacher_section_roster() from public, anon;
grant execute on function public.teacher_section_roster() to authenticated;

commit;


-- ############################################################################
-- MIGRATION 20261029_0065_teacher_revoke_device
-- ############################################################################

-- PIA 0065: a teacher can end a session of their OWN account on another browser.
--
-- WHY. The teacher page now has Settings with an "Active sessions" list, like the admin's. An
-- administrator ends a device with admin_revoke_device (0030); that function is admin-only. A
-- teacher needs the same for themselves: the browsers signed in to their account, and a way to end
-- one (a lab PC left signed in is what usually fills the device slot).
--
-- WHAT. teacher_revoke_device(p_device_id):
--   * only a TEACHER can call it, and only ever on their OWN account (the email comes from the
--     signed-in token, never from the caller);
--   * removes that device from active_devices and device_sessions, and ends the login recorded
--     for it (its auth session and refresh tokens), scoped to this account's own sessions;
--   * a device id that is not in the list does nothing.
-- It cannot touch anybody else, and it does not exist for students or admins.
--
-- Requires 0030 (device_sessions, the session-aware jwt_is_current). SAFE TO RE-RUN.
begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles' and column_name = 'device_sessions')
     or to_regprocedure('public.jwt_is_current()') is null
     or to_regprocedure('public.pia_caller_role()') is null then
    raise exception 'PIA 0065 ABORT (nothing changed): apply 0030 first.' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function public.teacher_revoke_device(p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := lower(auth.jwt() ->> 'email');
  v_devices text[];
  v_map     jsonb;
  v_new     text[];
  v_sid     text;
  v_uid     uuid;
  v_ended   int := 0;
begin
  if not public.jwt_is_current() then
    raise exception 'PIA: this session was signed out. Please sign in again.' using errcode = '42501';
  end if;
  if public.pia_caller_role() is distinct from 'teacher' then
    raise exception 'PIA: only a teacher can use this.' using errcode = '42501';
  end if;
  if p_device_id is null or length(trim(p_device_id)) = 0 then
    raise exception 'PIA: a device id is required.' using errcode = '22023';
  end if;

  select coalesce(p.active_devices, '{}'), coalesce(p.device_sessions, '{}'::jsonb)
    into v_devices, v_map
    from public.profiles p
   where lower(p.email) = v_email
     for update;

  if not found then
    raise exception 'PIA: no profile for this account.' using errcode = '22023';
  end if;

  if not (p_device_id = any(v_devices)) then
    return jsonb_build_object('devices', v_devices, 'removed', 0, 'sessions_ended', 0);
  end if;

  v_new := array(select x from unnest(v_devices) x where x is distinct from p_device_id);
  v_sid := v_map ->> p_device_id;
  v_map := v_map - p_device_id;

  select u.id into v_uid from auth.users u where lower(u.email) = v_email limit 1;

  if v_uid is not null and v_sid ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    with gone as (
      delete from auth.sessions where id = v_sid::uuid and user_id = v_uid returning 1
    )
    select count(*) into v_ended from gone;

    delete from auth.refresh_tokens where session_id = v_sid::uuid and user_id = v_uid::text;
  end if;

  update public.profiles
     set active_devices = v_new, device_sessions = v_map
   where lower(email) = v_email;

  return jsonb_build_object('devices', v_new, 'removed', 1, 'sessions_ended', v_ended);
end;
$$;

revoke all on function public.teacher_revoke_device(text) from public, anon;
grant execute on function public.teacher_revoke_device(text) to authenticated;

commit;
