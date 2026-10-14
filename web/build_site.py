#!/usr/bin/env python3
"""Build the self-contained page by splicing web/deepluau.js into the template.

Writes two forms of the same page:
  web/index.html   — the raw fragment used by the Claude artifact (the artifact
                     host wraps it in <!doctype>/<head>/<body> at publish time).
  index.html       — a COMPLETE standalone document at the repo root, with its own
                     doctype, charset and viewport, so GitHub Pages (deploy-from-
                     branch at root) and Vercel (zero-config) serve it directly.
Also drops a root .nojekyll so GitHub Pages serves everything verbatim.
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)

tpl = open(os.path.join(here, "index.template.html")).read()
js = open(os.path.join(here, "deepluau.js")).read()
assert "/*__DEEPLUAU_JS__*/" in tpl, "placeholder missing"
fragment = tpl.replace("/*__DEEPLUAU_JS__*/", js)

# artifact form: the fragment as-is
open(os.path.join(here, "index.html"), "w").write(fragment)

# standalone form: split head-ish content from the body at the first <header>
idx = fragment.find("<header")
assert idx != -1, "expected a <header> to split on"
head_part, body_part = fragment[:idx], fragment[idx:]
standalone = (
    "<!doctype html>\n<html lang=\"en\">\n<head>\n"
    "<meta charset=\"utf-8\">\n"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n"
    + head_part
    + "</head>\n<body>\n"
    + body_part
    + "\n</body>\n</html>\n"
)
open(os.path.join(root, "index.html"), "w").write(standalone)
open(os.path.join(root, ".nojekyll"), "w").write("")
print("wrote web/index.html (fragment) and ./index.html (standalone) + .nojekyll")
