#!/usr/bin/env python3
"""build_pptx.py - turn an analysis JSON (see make_presentation.sh) into a .pptx file.

Usage:
    build_pptx.py analysis.json -o out.pptx [--lang uk|en] [--template base.pptx]
    build_pptx.py - -o out.pptx            (JSON on stdin)

Needs: pip install python-pptx
"""
import argparse
import json
import sys

try:
    from pptx import Presentation
    from pptx.util import Inches, Pt
except ImportError:
    sys.exit("python-pptx is not installed. Run: pip install python-pptx")

LABELS = {
    "uk": {
        "conclusion": "Короткий висновок",
        "confidence": "Рівень упевненості",
        "facts": "Факти",
        "assumptions": "Припущення",
        "interpretations": "Інтерпретація та причинно-наслідкові зв'язки",
        "alternatives": "Альтернативні погляди",
        "strength": "сила аргументів",
        "gaps": "Прогалини та обмеження даних",
        "takeaways": "Практичні висновки",
        "sources": "Джерела",
        "cont": "продовження",
    },
    "en": {
        "conclusion": "Key conclusion",
        "confidence": "Confidence level",
        "facts": "Facts",
        "assumptions": "Assumptions",
        "interpretations": "Interpretation and causal links",
        "alternatives": "Alternative views",
        "strength": "strength of evidence",
        "gaps": "Gaps and data limitations",
        "takeaways": "Practical takeaways",
        "sources": "Sources",
        "cont": "cont.",
    },
}

MAX_BULLETS = 6      # bullets per slide before the list continues on a new slide
MAX_CHARS = 230      # longest bullet; longer text is cut (full text stays in notes)


def as_list(value):
    if value is None or value == "":
        return []
    if isinstance(value, (list, tuple)):
        return [str(v).strip() for v in value if str(v).strip()]
    return [str(value).strip()]


def clip(text, limit=MAX_CHARS):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


class Deck:
    def __init__(self, template=None):
        self.prs = Presentation(template) if template else Presentation()
        self.custom = bool(template)
        if not self.custom:  # built-in template is 4:3; switch to 16:9 and lay out by hand
            self.prs.slide_width = Inches(13.333)
            self.prs.slide_height = Inches(7.5)

    def _place(self, shape, left, top, width, height):
        if not self.custom:
            shape.left, shape.top, shape.width, shape.height = (
                Inches(left), Inches(top), Inches(width), Inches(height))

    def title_slide(self, title, subtitle):
        slide = self.prs.slides.add_slide(self.prs.slide_layouts[0])
        slide.shapes.title.text = clip(title, 150)
        self._place(slide.shapes.title, 0.9, 2.1, 11.5, 1.9)
        sub = slide.placeholders[1]
        sub.text = clip(subtitle, 200)
        self._place(sub, 0.9, 4.2, 11.5, 1.4)
        return slide

    def bullets(self, title, items, notes=None):
        """Add one or more slides; long lists continue on extra slides."""
        full = [" ".join(str(i).split()) for i in items]
        chunks = [full[i:i + MAX_BULLETS] for i in range(0, len(full), MAX_BULLETS)] or [[]]
        for n, chunk in enumerate(chunks):
            slide = self.prs.slides.add_slide(self.prs.slide_layouts[1])
            slide.shapes.title.text = title if n == 0 else f"{title} ({self.cont} {n + 1})"
            self._place(slide.shapes.title, 0.6, 0.35, 12.1, 1.1)
            body = slide.placeholders[1]
            self._place(body, 0.8, 1.7, 11.7, 5.2)
            tf = body.text_frame
            tf.word_wrap = True
            shown = [clip(c) for c in chunk]
            size = 24 if sum(len(c) for c in shown) < 450 else 20
            for k, text in enumerate(shown):
                para = tf.paragraphs[0] if k == 0 else tf.add_paragraph()
                para.text = text
                for run in para.runs:
                    run.font.size = Pt(size)
            # Notes: the optional text (first slide only) plus the full text of any cut bullet.
            extra = [c for c, t in zip(chunk, shown) if c != t]
            parts = ([notes] if notes and n == 0 else []) + extra
            if parts:
                slide.notes_slide.notes_text_frame.text = "\n\n".join(parts)
        return None

    cont = "cont."


def build(data, lang, template):
    lab = LABELS["en" if lang.lower().startswith("en") else "uk"]
    deck = Deck(template)
    deck.cont = lab["cont"]

    deck.title_slide(data.get("title") or "Presentation", data.get("subtitle") or "")

    conclusion = as_list(data.get("conclusion"))
    confidence = data.get("confidence")
    if conclusion:
        deck.bullets(lab["conclusion"], conclusion,
                     notes=f"{lab['confidence']}: {confidence}" if confidence else None)

    if as_list(data.get("facts")):
        deck.bullets(lab["facts"], as_list(data["facts"]))
    if as_list(data.get("assumptions")):
        deck.bullets(lab["assumptions"], as_list(data["assumptions"]))
    if as_list(data.get("interpretations")):
        deck.bullets(lab["interpretations"], as_list(data["interpretations"]))

    views = []
    for v in data.get("alternative_views") or []:
        if isinstance(v, dict):
            pos, strength = v.get("position", ""), v.get("strength", "")
            views.append(f"{pos} ({lab['strength']}: {strength})" if strength else pos)
        else:
            views.append(str(v))
    if views:
        deck.bullets(lab["alternatives"], views)

    if as_list(data.get("gaps")):
        deck.bullets(lab["gaps"], as_list(data["gaps"]))
    if as_list(data.get("practical_takeaways")):
        deck.bullets(lab["takeaways"], as_list(data["practical_takeaways"]))

    src = []
    for s in data.get("sources") or []:
        if isinstance(s, dict):
            src.append(f"{s.get('title', '').strip()} - {s.get('url', '').strip()}".strip(" -"))
        else:
            src.append(str(s))
    if src:
        deck.bullets(lab["sources"], src)
    return deck.prs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("input", help="analysis JSON file, or - for stdin")
    ap.add_argument("-o", "--output", default="presentation.pptx")
    ap.add_argument("--lang", default="uk", help="label language: uk (default) or en")
    ap.add_argument("--template", help="existing .pptx whose layouts and theme to use")
    args = ap.parse_args()

    try:
        raw = sys.stdin.read() if args.input == "-" else open(args.input, encoding="utf-8").read()
        data = json.loads(raw)
    except (OSError, ValueError) as exc:
        sys.exit(f"Cannot read analysis JSON: {exc}")
    if not isinstance(data, dict):
        sys.exit("Analysis JSON must be an object.")

    prs = build(data, args.lang, args.template)
    prs.save(args.output)
    print(f"Saved {args.output} ({len(prs.slides)} slides)")


if __name__ == "__main__":
    main()
