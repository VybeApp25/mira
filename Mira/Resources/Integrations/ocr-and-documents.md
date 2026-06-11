# OCR & Documents
tools: run_python_skill (pdf_extract, ocr_image, docx_rw, pptx_rw)

## When to use
User says: read this PDF, extract text, scan this image, what does this document say, OCR, convert to text.

## By file type

### PDF — text extraction
`run_python_skill(skill:"pdf_extract", args:{path:"<abs_path>", max_chars?:40000})`
Returns: `{success, text, page_count, truncated}`

### Image — OCR (PNG, JPG, TIFF)
`run_python_skill(skill:"ocr_image", args:{path:"<abs_path>", lang?:"eng"})`
Returns: `{success, text, confidence}`
Lang codes: `"eng"`, `"fra"`, `"deu"`, `"spa"`, `"eng+fra"` (combined).
Requires: `brew install tesseract` (report if missing).
Report confidence to user if < 70.

### DOCX — read
`run_python_skill(skill:"docx_rw", args:{op:"read", path:"<abs_path>"})`

### PPTX — read (see powerpoint.md for full ops)
`run_python_skill(skill:"pptx_rw", args:{op:"read", path:"<abs_path>"})`

## Decision tree
1. DOCX → `docx_rw` op:"read"
2. PPTX → `pptx_rw` op:"read"
3. Text-based PDF → `pdf_extract` (fast, no OCR needed)
4. Scanned image / photo of document → `ocr_image` (needs tesseract)

## Canonical patterns

### "What does this PDF say?"
`pdf_extract` → summarize content.

### "Read the text in this image"
`ocr_image` → return extracted text, note confidence.

### "Extract the text from this Word doc"
`docx_rw` op:"read".

## Constraints
- pdf_extract uses pdfplumber (auto-installed). Works on text PDFs; not scanned.
- ocr_image requires tesseract system install. If missing: "Install with `brew install tesseract`."
- Paths support `~` expansion.
