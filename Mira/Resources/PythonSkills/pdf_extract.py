#!/usr/bin/env python3
"""Extract text and metadata from a PDF.
Args JSON (stdin): {path, pages?, max_chars?}
Output JSON (stdout): {success, text, page_count, char_count, error?}
"""
import sys, json

def main():
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
    path       = args.get("path", "")
    page_nums  = args.get("pages")        # optional list of 0-based indices
    max_chars  = args.get("max_chars", 40000)

    try:
        import pdfplumber
    except ImportError:
        print(json.dumps({"success": False, "error": "pdfplumber not installed. Run: pip3 install pdfplumber"}))
        return

    try:
        with pdfplumber.open(path) as pdf:
            total = len(pdf.pages)
            targets = [pdf.pages[i] for i in page_nums if i < total] if page_nums else pdf.pages
            text = "\n\n".join(
                f"[Page {i+1}]\n{p.extract_text() or ''}"
                for i, p in enumerate(targets)
            )
            text = text[:max_chars]
            print(json.dumps({
                "success":    True,
                "text":       text,
                "page_count": total,
                "char_count": len(text),
            }))
    except Exception as e:
        # Fallback: try pymupdf (fitz)
        try:
            import fitz
            doc = fitz.open(path)
            total = doc.page_count
            targets = [doc[i] for i in page_nums if i < total] if page_nums else list(doc)
            text = "\n\n".join(
                f"[Page {i+1}]\n{p.get_text()}"
                for i, p in enumerate(targets)
            )[:max_chars]
            print(json.dumps({"success": True, "text": text, "page_count": total, "char_count": len(text)}))
        except Exception as e2:
            print(json.dumps({"success": False, "error": str(e2)}))

main()
