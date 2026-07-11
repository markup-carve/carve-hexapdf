# Examples

Carve source (`.crv`) with the rendered PDF next to each one. Regenerate all
PDFs with:

```sh
ruby examples/generate.rb
```

| Source | PDF | Shows |
| ------ | --- | ----- |
| [`01-spec.crv`](01-spec.crv) | `01-spec.pdf` | Headings, nested / ordered / task lists, a table with a header row, definition list, block quote with attribution, fenced code, thematic break. |
| [`02-showcase.crv`](02-showcase.crv) | `02-showcase.pdf` | Every inline decoration (bold, italic, underline, strikethrough, highlight, super/subscript), an inline image, critic markup, an admonition, and a table with **row and column spans**. |
| [`03-math-diagrams.crv`](03-math-diagrams.crv) | `03-math-diagrams.pdf` | **Math and diagram fences rendered as embedded images** via `renderers:` callables (inline + display math, Mermaid, Graphviz). |

## Math and diagrams

PDF has no client-side renderer, so math and diagram fences are turned into
images by callables you pass in `renderers:`. `generate.rb` uses real renderers
when the tools are available locally - KaTeX and mermaid.js (from a sibling
`carve` checkout's `node_modules`, override with `CARVE_NODE_MODULES`) rendered
through headless Chrome at 2x scale, and the Graphviz `dot` CLI - and falls
back to drawing each construct's source into a small placeholder image (via
HexaPDF + `pdftoppm`, with a pure-Ruby fallback), so the script runs anywhere:

```ruby
Carve::Hexapdf.render(source, renderers: {
  math:     ->(tex, display) { tex_to_png(tex, display) }, # $`x` and $$`x`
  mermaid:  ->(src)          { mermaid_to_png(src) },      # ```mermaid
  graphviz: ->(src)          { dot_to_png(src) },          # ```dot / ```graphviz
  chart:    ->(src)          { chart_to_png(src) },        # ```chart / ```vega
})
```

A real deployment plugs in KaTeX / MathJax / LaTeX for math and a Mermaid /
Graphviz CLI for diagrams. Each callable returns image bytes (PNG/JPG); without
a matching callable the fence degrades to its monospace source.
