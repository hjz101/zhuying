# Original reader test font

`../YueshanTests/Fixtures/ReaderTestFont.ttf` is a 3.9 KB TrueType font with the
unique PostScript name `YueshanReaderTest-Regular`. Its glyphs are space, A,
and digits 0–9. All outlines consist of original rectangles on a 5 × 7 grid;
no installed font or third-party font data is copied. The generated outlines
and font are dedicated to the public domain under CC0 1.0.

Regenerate from the repository root with:

```sh
python3 ios/scripts/generate_reader_test_font.py
```

The script uses only Python's standard library. It writes deterministic
TrueType tables and checks the whole-font checksum, so it requires neither
fontTools nor an installed font. Scripts and this description live outside
the test target's source tree; only the TTF is a test bundle resource.

`ReadingFontLibraryTests.testOriginalFontImportsAppliesToBodyRestoresAndRejectsDuplicateWithoutChanges`
imports the bundled resource as a regular copied file, verifies the registered
UIFont/CoreText source URL and actual glyph paths, persists the reader's font
choice, rebuilds both stores, verifies the attributed body font, and checks
that a duplicate import leaves the manifest, files, and selection unchanged.
