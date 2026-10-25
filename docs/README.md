# PIA — Personal Instructing Agent

A web-based math tutoring system for Grade 7. Students learn percentages with one of six
tutor personas matched to their personality (Big Five / OCEAN). Teachers and administrators
manage sections, attendance and results.

## Architecture

| Part | Folder | Technology | Hosting |
|---|---|---|---|
| Web app (landing, student, teacher, admin) | `index.html`, `admin/`, `student/`, `teacher/`, `assets/`, `styles/` | HTML, CSS, vanilla JavaScript | Cloudflare Pages |
| Database, auth, row-level security | `supabase/database-history.sql` | PostgreSQL (SQL) on Supabase | Supabase |
| Server functions (2) | `supabase/functions/` | JavaScript | Supabase Edge Functions |
| Learning-profile model | `ml-service/` | Python | Cloudflare Workers |

Languages used: Python, HTML, CSS, JavaScript (and SQL for the database). Supabase is the
backend service; the project has no build step for the web app.

The browser talks only to Supabase (REST, Auth, Realtime, Edge Functions). Edge Function
`learning-profile` calls the ML Worker with a secret token; the browser never does.

## How it works

### Who uses it

| Who | What they do |
|---|---|
| Admin | Creates sections and students, calls the roll, opens or closes each stage, manages the math question bank. |
| Teacher | Sees a read-only list of their own section (online, stage, attendance). |
| Student | Enters with a student number and works through the stages. |

### 1. How a student gets in

Students have no password. The admin controls who may enter.

```
Admin opens attendance and marks each student present or absent
        |
Student types the 11-digit student number on the first page
        |
join-with-number checks, in order:
   attendance is open for the section  ->  the number exists
   ->  the name is confirmed  ->  the student is marked present
   ->  the number has not been used yet today
        |
A one-time sign-in token is given  ->  the student is signed in  ->  Waiting room
```

If a classmate types someone else's number first, the real student is told it is
already in use, and the admin sees it on that row and can let them back in.
After 5 wrong tries for one number, 60 from one computer address, or 200 in total
within 10 minutes, the door pauses for a few minutes.

### 2. What the student does

```
Waiting room -> OCEAN personality test -> Choose a tutor -> Tutoring dashboard -> Done
```

The admin opens or closes each stage for a whole section with the switch beside
the stage tab. A student who opens a page for a stage that is not open to them is sent back to the page they belong on.

Students belong to a group, shown in the admin table:

| Group | Meaning |
|---|---|
| Assigned | The tutor is matched to the student's OCEAN result. |
| Free choice | The student picks the tutor. |
| Neutral | A neutral tutor. |
| Control | Traditional lesson, no tutor. |

### 3. The tutor and the math questions

Each question is solved in steps. A step has hints, and a hint never gives the
final answer. The six tutors have their own pictures and wording. The admin
manages the question bank in the **Math Task** tab (finding a percentage,
percentage increase, percentage decrease).

### 4. The learning profile

```
Student's browser  ->  learning-profile function  ->  ML service
   (session id only)     reads 7 numbers from the        returns a profile
                         database as that student         and a confidence
```

After at least two answers, the page asks for a profile. The seven numbers are
recent accuracy, average attempts, hint use, response time, efficiency, and the
current streaks of right and wrong answers. No name, email or id is sent to the ML
service. The answer is one of `struggling`, `average` or `outstanding`. If
anything fails, the page keeps its current wording.

### Where to look in the code

| Part | Files |
|---|---|
| First page and sign-in | `index.html`, `assets/js/landing/` |
| Student stages | `student/html/`, `student/js/` |
| Shared session, guards and helpers | `assets/js/shared/function.js` |
| Admin console | `admin/html/`, `admin/js/` |
| Teacher page | `teacher/html/`, `teacher/js/` |
| Student entry rules | `supabase/functions/join-with-number/` |
| Learning profile | `supabase/functions/learning-profile/`, `ml-service/` |
| Colors and fonts | `styles/global.css` |

## Folder structure

```
.
├── index.html              landing page and student-number sign-in
├── admin/                  admin console   (html/, js/)
├── teacher/                teacher pages   (html/, js/)
├── student/                student journey (html/, js/)
├── assets/
│   ├── js/
│   │   ├── shared/     scripts used by many pages (session, guards, theme, fonts)
│   │   ├── landing/    landing page only (sign-in, navbar, tutor picker, effects)
│   │   ├── sign-up/    set-password page
│   │   └── vendor/     third-party libraries
│   ├── images/
│   │   ├── backgrounds/  classroom, wallpaper, hero art
│   │   ├── landing/      landing page art and partner logos
│   │   ├── tutors/ personas/ heads/ cast/   the six tutors
│   │   └── logo.svg, logo-320.webp, logo-640.webp
│   ├── video/          how-to video
│   └── html/           sign-up and 404 pages
├── styles/
│   ├── global.css      shared tokens and base styles
│   └── admin/ student/ teacher/ landing/ auth/   one folder per area
├── supabase/
│   ├── database-history.sql  every database change, in order (read-only reference)
│   └── functions/          Edge Functions
├── ml-service/             ML Worker (see its README)
├── build.sh                runs config/build.sh (the command Cloudflare already uses)
├── config/                 build.sh, _headers (security headers) and robots.txt
└── docs/README.md          this file
```

## Build and deploy

```sh
sh build.sh        # writes dist/
```

Cloudflare Pages: build command `sh build.sh` (unchanged; it calls `config/build.sh`), output directory `dist`. Only the site files end up
in `dist/`; `supabase/` and `ml-service/` are never published.

## Run locally

```sh
sh build.sh && python3 -m http.server 8000 -d dist
```

Open http://localhost:8000. Sign-in needs the Supabase project the site is configured for.

## Database

`supabase/database-history.sql` lists every database change in the order it was applied,
by number (`0063` is dated before `0061`). It extends a base schema that was created before
migrations were used, so it cannot rebuild the database from nothing; take a
`pg_dump --schema-only` of the live database for that.

## Security notes

- Content-Security-Policy is `script-src 'self'`: there are no inline scripts.
- Access control is enforced in the database (row-level security), not in the browser.
- Staff pages are marked `noindex`.
