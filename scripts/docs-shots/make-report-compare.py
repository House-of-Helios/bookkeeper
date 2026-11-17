#!/usr/bin/env python3
"""Draw docs/site/examples/report-input.txt beside report-sent.txt as HTML, private things
marked in the first and their stand-ins marked in the second. Both files are written by
ProblemReportTests, so the picture is made from what the code really does."""
import html, re, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
ex = root / "docs/site/examples"
before = (ex / "report-input.txt").read_text()
after = (ex / "report-sent.txt").read_text()
planted = ["0x52908400098527886E0F7030069857D2E4169EE7", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
           "/Users/jane", "192.168.1.23", "janes-macbook.local", "$4,506.20", "jane@example.com"]
def mark_before(t):
    t = html.escape(t)
    for p in planted:
        t = t.replace(html.escape(p), f'<mark class="out">{html.escape(p)}</mark>')
    return t
def mark_after(t):
    return re.sub(r"(\[(?:address|ip|host|amount|email)\]|~(?=/Library))",
                  r'<mark class="in">\1</mark>', html.escape(t))
page = f"""<!doctype html><meta charset="utf-8"><title>Report before and after</title>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500&family=Jost:wght@400;500&display=swap" rel="stylesheet">
<style>
*{{box-sizing:border-box;margin:0}}
body{{width:1400px;background:#faf6ee;color:#2b2a28;font:15px Jost,sans-serif;padding:40px 44px}}
h1{{font:500 28px Fraunces,serif;margin-bottom:22px}}
.cols{{display:grid;grid-template-columns:1fr 1fr;gap:28px}}
h2{{font:500 13px Jost;letter-spacing:.14em;text-transform:uppercase;color:#7a756c;margin-bottom:10px}}
pre{{background:#fffdf8;border:1px solid #e3ddd1;border-radius:14px;padding:18px 20px;font:12.5px/1.6 ui-monospace,Menlo,monospace;white-space:pre-wrap;word-break:break-all;min-height:520px}}
mark.out{{background:#fbd5cc;color:#9b2c14;border-radius:4px;padding:0 2px;text-decoration:line-through}}
mark.in{{background:#dcebcf;color:#2f5d1e;border-radius:4px;padding:0 2px}}
p{{margin-top:18px;color:#5d5a55}}
</style>
<h1>One report, before and after Bookkeeper cleans it</h1>
<div class="cols"><div><h2>What the app saw</h2><pre>{mark_before(before)}</pre></div>
<div><h2>What Send hands the sender, byte for byte</h2><pre>{mark_after(after)}</pre></div></div>
<p>Made by Bookkeeper's own code from <code>docs/site/examples/</code>; a test fails if this example and the code ever disagree.</p>
"""
(root / "scripts/docs-shots/report-compare.html").write_text(page)
