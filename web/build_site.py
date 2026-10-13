#!/usr/bin/env python3
"""Build web/index.html by splicing web/deepluau.js into web/index.template.html."""
import os
here = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(here, "index.template.html")).read()
js = open(os.path.join(here, "deepluau.js")).read()
assert "/*__DEEPLUAU_JS__*/" in tpl, "placeholder missing"
open(os.path.join(here, "index.html"), "w").write(tpl.replace("/*__DEEPLUAU_JS__*/", js))
print("wrote web/index.html")
