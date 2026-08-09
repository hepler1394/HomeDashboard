#!/usr/bin/env python3
"""Turn a markdown file into a Word .docx using only the standard library.

    python md2docx.py brief.md "My Document.docx" ["Optional Title"]

A .docx is a zip of XML parts, so no python-docx / pandoc / LibreOffice is
needed -- none of which are installed in this sandbox. Supports headings
(#/##/###), paragraphs, bullets (- or *), numbered items, **bold** and
*italic*, and collapses DeerFlow's [citation:Name](url) markup to "(Name)".

Bullets are rendered as a literal bullet glyph with a hanging indent rather
than a real numbering definition. A proper list needs a numbering.xml part and
several more cross-references; for a generated brief the visual result is the
same and there is far less to get wrong.
"""
import re
import sys
import zipfile
from xml.sax.saxutils import escape

CT = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>"""

RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""

DOC_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>"""

W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'


def runs(text):
    """Inline **bold** / *italic* -> a list of <w:r> elements."""
    out = []
    for tok in re.split(r"(\*\*[^*]+\*\*|\*[^*]+\*)", text):
        if not tok:
            continue
        props, body = "", tok
        if tok.startswith("**") and tok.endswith("**"):
            props, body = "<w:b/>", tok[2:-2]
        elif tok.startswith("*") and tok.endswith("*"):
            props, body = "<w:i/>", tok[1:-1]
        rpr = f"<w:rPr>{props}</w:rPr>" if props else ""
        out.append(f'{rpr and "<w:r>" + rpr or "<w:r>"}<w:t xml:space="preserve">{escape(body)}</w:t></w:r>')
    return "".join(out) or "<w:r><w:t/></w:r>"


def para(text, *, size=None, bold=False, before=0, after=120, indent=None, color=None):
    rpr = ""
    if size or bold or color:
        bits = ("<w:b/>" if bold else "") + (f'<w:sz w:val="{size}"/>' if size else "") + \
               (f'<w:color w:val="{color}"/>' if color else "")
        rpr = f"<w:rPr>{bits}</w:rPr>"
    ind = f'<w:ind w:left="{indent[0]}" w:hanging="{indent[1]}"/>' if indent else ""
    ppr = f'<w:pPr>{ind}<w:spacing w:before="{before}" w:after="{after}"/>{rpr}</w:pPr>'
    # Run-level formatting has to be repeated on each run; paragraph rPr alone
    # only styles the paragraph mark, not the visible text.
    body = runs(text)
    if rpr:
        body = body.replace("<w:r>", f"<w:r>{rpr}").replace(f"<w:r>{rpr}<w:rPr>", "<w:r><w:rPr>")
    return f"<w:p>{ppr}{body}</w:p>"


def normalize(line):
    line = re.sub(r"\s*\[citation:([^\]]+)\]\([^)]*\)", r" (\1)", line)
    line = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1", line)   # plain links -> text
    line = re.sub(r"\)\s+\(", "; ", line)
    line = re.sub(r"\s+([.,;])", r"\1", line)
    return re.sub(r"[ \t]{2,}", " ", line)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else None

    md = open(src, encoding="utf-8").read()
    body = []
    if title:
        body.append(para(title, size=40, bold=True, after=240))

    for rawline in md.splitlines():
        line = normalize(rawline).rstrip()
        if not line.strip():
            continue
        if m := re.match(r"^#\s+(.*)$", line):
            if title:
                continue                       # cover title already present
            body.append(para(m.group(1), size=40, bold=True, after=240))
        elif m := re.match(r"^##\s+(.*)$", line):
            body.append(para(m.group(1), size=28, bold=True, before=320, after=120))
        elif m := re.match(r"^###\s+(.*)$", line):
            body.append(para(m.group(1), size=24, bold=True, before=240, after=100))
        elif m := re.match(r"^[-*]\s+(.*)$", line):
            body.append(para("•  " + m.group(1), indent=(360, 360), after=90))
        elif m := re.match(r"^(\d+)\.\s+(.*)$", line):
            body.append(para(f"{m.group(1)}.  {m.group(2)}", indent=(360, 360), after=90))
        else:
            body.append(para(line, after=140))

    # US Letter, 1in margins.
    sect = ('<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>'
            '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>')
    document = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                f'<w:document {W}><w:body>{"".join(body)}{sect}</w:body></w:document>')

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CT)
        z.writestr("_rels/.rels", RELS)
        z.writestr("word/_rels/document.xml.rels", DOC_RELS)
        z.writestr("word/document.xml", document)

    print(f"wrote {dst} ({len(body)} paragraphs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
