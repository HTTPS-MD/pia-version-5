PIA tests. None of this folder is published: config/build.sh copies only the site's own folders.

Works today
  node tests/sim/door-lockout.test.mjs             The student-number door: an outsider cannot lock out the class.
  cd ml-service && python3 -m unittest discover -s tests      The learning-profile decision tree.
  supabase/tests/eval-expr-checks.sql              57 checks of the math checker. Run it in the Supabase SQL editor;
                                                   it reads and writes nothing. "Success" means they all passed.

Browser tests (see behavior-README.txt; they need Playwright and Chrome)
  Works:          admin-behavior.cjs, cp-test.cjs, landing-behavior.cjs
  Needs updating: forms-test.cjs, auth-behavior.cjs (written for an older version of the pages, they stop on a screen that changed)
  These compare the pages before and after a change. They do not touch a real database.
  admin-behavior, forms-test, cp-test and shots must stay directly in this folder: they find the site one level up.

Not covered yet: a full class at once, and a student going through a whole problem on the real staging site.
