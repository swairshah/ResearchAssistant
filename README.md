# ResearchReader

Minimal native macOS paper reader:

- projects in a sidebar
- paper list per project
- local PDF storage in app support
- automatic metadata lookup from PDF text via DOI or arXiv ID
- built-in PDF viewer

The app keeps its data in:

`~/Library/Application Support/ResearchReader`

## Run

```bash
swift run
```

## Notes

- Metadata detection is intentionally simple: it scans the first few PDF pages for a DOI or arXiv identifier.
- If auto-detection misses, select a paper and paste a DOI or arXiv ID into the override field.
- Imported PDFs are copied into app storage so projects stay stable even if the originals move.
