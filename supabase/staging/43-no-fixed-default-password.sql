-- 43: No fixed default password.
--
-- When a profile was added with no sign-in account, this trigger made one with a password written in the code, so anyone
-- who knew that password and the email could sign in as that student. Now every such account gets its own random password
-- that nobody knows. The admin page already worked this way. Entry by student number and by activation link is unchanged.
-- The function also gets a fixed search_path, like the other SECURITY DEFINER functions.
--
-- Replaces ONE function (handle_new_student_auth). No table and no row changes. Accounts that already exist keep their password.
-- No Edge Function or browser change is needed.
-- Run in the Supabase SQL editor (PIA-Staging). Safe to run more than once.

create or replace function public.handle_new_student_auth() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
DECLARE
  new_user_id uuid;
  -- A new random password for every account, known to nobody. The student enters by number or activation link.
  default_pass text := encode(gen_random_bytes(24), 'hex');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = NEW.email) THEN
    new_user_id := gen_random_uuid();
    
    -- Insert sa auth.users
    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) VALUES (
      new_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', NEW.email, crypt(default_pass, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()
    );
    
    -- Insert sa auth.identities para mapayagan ang login
    INSERT INTO auth.identities (
      provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, id
    ) VALUES (
      new_user_id::text, new_user_id, format('{"sub":"%s","email":"%s"}', new_user_id::text, NEW.email)::jsonb, 'email', now(), now(), now(), gen_random_uuid()
    );
    
    -- I-sync ang ID
    UPDATE public.profiles SET id = new_user_id WHERE email = NEW.email;
  END IF;
  RETURN NEW;
END;
$$;
