#!/usr/bin/env ruby
# frozen_string_literal: true

# Render every .crv in this folder to a .pdf next to it.
#
#   ruby examples/generate.rb        # from the repo root
#   ruby generate.rb                 # from within examples/
#
# The math / diagram fences in 03-math-diagrams.crv are turned into embedded
# images by the renderer callables defined below. This example renderer draws
# the construct's source into a small image so the demo is self-contained; a
# real deployment would plug in a TeX-to-PNG (KaTeX / MathJax / LaTeX) or a
# Mermaid / Graphviz renderer here instead.

require "zlib"
require "stringio"
require "tempfile"

# Resolve the gem whether run from a checkout (sibling carve-rb) or installed.
sibling_rb = File.expand_path("../../carve-rb/lib", __dir__)
$LOAD_PATH.unshift sibling_rb if File.directory?(sibling_rb)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "carve/hexapdf"

DIR = __dir__

# A minimal pure-Ruby solid-color PNG (used for the showcase logo and as the
# fallback when `pdftoppm` is unavailable).
def solid_png(width, height, red, green, blue)
  raw = (+"").b
  height.times do
    raw << 0
    width.times { raw << red << green << blue }
  end
  chunk = lambda do |type, data|
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end
  ihdr = [width, height].pack("NN") + [8, 2, 0, 0, 0].pack("C5")
  "\x89PNG\r\n\x1a\n".b +
    chunk.call("IHDR", ihdr) +
    chunk.call("IDAT", Zlib::Deflate.deflate(raw)) +
    chunk.call("IEND", "")
end

def pdftoppm?
  @pdftoppm = system("pdftoppm", "-h", out: File::NULL, err: File::NULL) if @pdftoppm.nil?
  @pdftoppm
end

# Draw a short source string into a PNG (via HexaPDF + pdftoppm). Falls back to
# a labeled solid image when pdftoppm is not installed.
def source_png(text, bg: "eef")
  return solid_png(220, 44, 210, 220, 245) unless pdftoppm?

  pdf = Tempfile.new(["carve-example", ".pdf"])
  base = pdf.path.sub(/\.pdf\z/, "")
  composer = HexaPDF::Composer.new(page_size: [0, 0, 300, 66], margin: 8)
  composer.text(text, font: "Courier", font_size: 15, text_align: :center,
                box_style: { background_color: bg, padding: 8 })
  composer.write(pdf.path)
  system("pdftoppm", "-png", "-r", "96", "-singlefile", pdf.path, base,
         out: File::NULL, err: File::NULL)
  File.binread("#{base}.png")
ensure
  if base
    png = "#{base}.png"
    File.delete(png) if File.exist?(png)
  end
  pdf&.close!
end

RENDERERS = {
  math: ->(tex, display) { source_png(display ? "  #{tex}  " : tex, bg: display ? "ffe" : "eef") },
  mermaid: ->(src) { source_png("[mermaid]  #{src.lines.first.to_s.strip}", bg: "efe") },
  graphviz: ->(src) { source_png("[graphviz]  #{src.lines.first.to_s.strip}", bg: "fee") },
}.freeze

# The showcase references logo.png; create a small one next to the .crv.
File.binwrite(File.join(DIR, "logo.png"), solid_png(46, 22, 60, 120, 220))

Dir[File.join(DIR, "*.crv")].sort.each do |crv|
  out = crv.sub(/\.crv\z/, ".pdf")
  pdf = Carve::Hexapdf.render(File.read(crv), renderers: RENDERERS)
  File.binwrite(out, pdf)
  puts "#{File.basename(crv)} -> #{File.basename(out)} (#{pdf.bytesize} bytes)"
end
