# Staging setup: your steps (Part 1)

Goal: a separate test copy of the system. The real database and the real website are never touched.

## Safety rules
1. The real Supabase project is `hvfqqdtemayhhfavmfbs`. If you ever see this in a command you are about to run to CHANGE something, stop.
2. Never send me: the database password, the `secret` / `service_role` key, or any token.
3. You may send me: the staging Project URL, the staging `publishable` (anon) key, the GitHub repo link.

## Step 1: new GitHub repository (3 minutes)
1. Go to github.com and sign in.
2. Click `+` (top right), then `New repository`.
3. Repository name: `pia-version-5`.
4. Choose `Private`.
5. Leave everything else empty (no README, no .gitignore, no license).
6. Click `Create repository`.
7. Copy the repository link (looks like `https://github.com/<you>/pia-version-5`). Send it to me.

## Step 2: new Supabase project (5 minutes)
1. Go to supabase.com/dashboard and sign in.
2. Click `New project`.
3. Name: `PIA-Staging`.
4. Database password: click `Generate`, then SAVE it in your password manager. Do not send it to me.
5. Region: pick the same region as the real project (real project: Project Settings, General, Region).
6. Plan: Free.
7. Click `Create new project` and wait about 2 minutes.
8. When it is ready, open Project Settings, API (or API Keys).
9. Copy two things and send them to me:
   - Project URL (`https://xxxxxxxx.supabase.co`). It must NOT contain `hvfqqdtemayhhfavmfbs`.
   - The `publishable` key (also called `anon`/`public`). Do NOT copy the `secret` or `service_role` key.

## Step 3: copy the structure of the real database (10 minutes)
This only READS the real database. It copies the table structure, not the students' data.

1. Open the Terminal tab in VS Code.
2. In the real Supabase dashboard open `Connect` and copy the `Session pooler` connection string. Replace `[YOUR-PASSWORD]` with the real database password.
3. Run this (it asks you to paste the string; you will not see it while pasting; press Enter):

```bash
read -s "URL?Paste connection string: "; pg_dump --schema-only --no-owner --schema=public "$URL" > ~/Desktop/pia-schema.sql; unset URL; ls -la ~/Desktop/pia-schema.sql
```

4. The file `pia-schema.sql` should be larger than 50 KB. Tell me when it is on your Desktop.
5. Do NOT run this against the staging project, and do NOT run `supabase link` or `supabase db push` yet.

## What to send me (no passwords)
- GitHub repository link
- Staging Project URL
- Staging publishable key
- A message that `pia-schema.sql` is on the Desktop

## What I will do after that (Part 2)
1. Check the schema file, then prepare copy-and-paste SQL for the staging database (structure, a few settings, fake test data).
2. Point `Version05` to the staging Supabase and add a red STAGING banner.
3. Give you the exact steps to deploy the two functions to staging only, to create the new Cloudflare project, and to run the test checklist.
