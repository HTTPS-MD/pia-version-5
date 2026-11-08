Behavior tests used to compare dev with the cleaned branches (same page, same steps, same results).
They need Playwright and a Chrome path:  NODE_PATH=<playwright node_modules> PIA_CHROME="<chrome binary>" node <test>.cjs
admin-behavior.cjs / forms-test.cjs / cp-test.cjs run inside a copy of the site under <copy>/tests/ and write JSON to SNAP_OUT.
landing-behavior.cjs / auth-behavior.cjs take: <site folder> <output json>.
Compare two output files; the cleaned branch should give the same JSON as dev.
