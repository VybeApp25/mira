#!/usr/bin/env python3
"""Extract text from an image using OCR (pytesseract + Pillow).
Requires tesseract binary: brew install tesseract
Args JSON (stdin): {path, lang?, psm?}
  path — absolute path to image (PNG, JPG, TIFF, BMP, PDF first-page)
  lang — tesseract language code(s), default "eng" (use "eng+fra" for multi-language)
  psm  — page segmentation mode 0-13, default 3 (fully automatic)
Output JSON (stdout): {success, text, confidence?, error?}
"""
import sys, json

def main():
    try:
        args = json.load(sys.stdin)
    except Exception:
        args = {}
    path = args.get("path", "")
    lang = args.get("lang", "eng")
    psm  = args.get("psm", 3)

    try:
        import pytesseract
        from PIL import Image
    except ImportError as ie:
        pkg = "pytesseract" if "pytesseract" in str(ie) else "Pillow"
        print(json.dumps({"success": False,
                          "error": f"{pkg} not installed. Run: pip3 install pytesseract Pillow\n"
                                   "Also ensure tesseract is installed: brew install tesseract"}))
        return

    try:
        img  = Image.open(path)
        conf = pytesseract.image_to_data(img, lang=lang,
                                         config=f"--psm {psm}",
                                         output_type=pytesseract.Output.DICT)
        text = pytesseract.image_to_string(img, lang=lang, config=f"--psm {psm}").strip()
        # Average confidence of non-empty words
        confs = [int(c) for c, t in zip(conf["conf"], conf["text"]) if t.strip() and int(c) >= 0]
        avg_conf = round(sum(confs) / len(confs)) if confs else 0
        print(json.dumps({"success": True, "text": text, "confidence": avg_conf}))
    except Exception as e:
        if "tesseract" in str(e).lower():
            print(json.dumps({"success": False,
                              "error": "tesseract not found. Install with: brew install tesseract"}))
        else:
            print(json.dumps({"success": False, "error": str(e)}))

main()
