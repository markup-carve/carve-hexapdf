#!/usr/bin/env ruby
# frozen_string_literal: true

# Render every .crv in this folder to a .pdf next to it.
#
#   ruby examples/generate.rb        # from the repo root
#   ruby generate.rb                 # from within examples/
#
# The math / diagram fences in 03-math-diagrams.crv are turned into embedded
# images by the renderer callables defined below. When the real tools are
# available locally they are used:
#
#   :math     -> KaTeX (sibling carve checkout's node_modules) + headless Chrome
#   :mermaid  -> mermaid.js (same node_modules) + headless Chrome
#   :graphviz -> the dot CLI
#
# Rasters are produced at 2x scale and embedded at half size ({bytes:, width:,
# height:}) so they stay crisp in the PDF. Without the tools, each construct
# falls back to a small placeholder image drawing its source, so the script
# works on any machine.

require "json"
require "zlib"
require "stringio"
require "tempfile"

# Resolve the gem whether run from a checkout (sibling carve-rb) or installed.
sibling_rb = File.expand_path("../../carve-rb/lib", __dir__)
$LOAD_PATH.unshift sibling_rb if File.directory?(sibling_rb)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "carve/hexapdf"

DIR = __dir__

# ---- tool discovery -------------------------------------------------------

def which(cmd)
  ENV["PATH"].split(File::PATH_SEPARATOR)
             .map { |dir| File.join(dir, cmd) }
             .find { |path| File.executable?(path) }
end

CHROME = which("google-chrome") || which("chromium") || which("chromium-browser")
DOT = which("dot")
PYTHON = which("python3")

NODE_MODULES = [
  ENV["CARVE_NODE_MODULES"],
  File.expand_path("../../carve/node_modules", __dir__),
].compact.find { |dir| File.directory?(dir) }

KATEX_DIST = NODE_MODULES && File.join(NODE_MODULES, "katex", "dist")
KATEX_DIST = nil unless KATEX_DIST && File.file?(File.join(KATEX_DIST, "katex.min.js"))
MERMAID_JS = NODE_MODULES && File.join(NODE_MODULES, "mermaid", "dist", "mermaid.min.js")
MERMAID_JS = nil unless MERMAID_JS && File.file?(MERMAID_JS)

# ---- shared raster helpers ------------------------------------------------

# Whiteborder-trim a PNG in place (needs Pillow); returns true on success.
PY_TRIM = <<~PY
  import sys
  from PIL import Image, ImageChops
  path, pad = sys.argv[1], int(sys.argv[2])
  im = Image.open(path).convert("RGB")
  bg = Image.new("RGB", im.size, (255, 255, 255))
  bbox = ImageChops.difference(im, bg).getbbox()
  if bbox:
      left, top, right, bottom = bbox
      bbox = (max(0, left - pad), max(0, top - pad),
              min(im.size[0], right + pad), min(im.size[1], bottom + pad))
      im.crop(bbox).save(path)
PY

def trim_png(path, pad: 6)
  return false unless PYTHON

  system(PYTHON, "-c", PY_TRIM, path, pad.to_s, out: File::NULL, err: File::NULL)
end

def png_size(bytes)
  bytes[16, 8].unpack("N2")
end

# Wrap 2x-scale PNG bytes into the {bytes:, width:, height:} renderer result,
# capped to the printable width (A4 minus margins) so the box always fits.
MAX_WIDTH = 440.0

def hidpi(bytes)
  return nil unless bytes && bytes.start_with?("\x89PNG".b)

  width, height = png_size(bytes).map { |px| px / 2.0 }
  if width > MAX_WIDTH
    height *= MAX_WIDTH / width
    width = MAX_WIDTH
  end
  { bytes: bytes, width: width, height: height }
end

# Screenshot an HTML snippet with headless Chrome at 2x scale and trim it.
def chrome_shot(html, window: "1200,700")
  return nil unless CHROME

  html_file = Tempfile.new(["carve-example", ".html"])
  html_file.write(html)
  html_file.close
  png = html_file.path.sub(/\.html\z/, ".png")
  ok = system(CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
              "--force-device-scale-factor=2", "--window-size=#{window}",
              "--virtual-time-budget=5000", "--screenshot=#{png}",
              "file://#{html_file.path}", out: File::NULL, err: File::NULL)
  return nil unless ok && File.file?(png)

  trim_png(png)
  File.binread(png)
ensure
  File.delete(png) if png && File.exist?(png)
  html_file&.close!
end

# ---- real renderers -------------------------------------------------------

def katex_png(tex, display)
  return nil unless CHROME && KATEX_DIST

  html = <<~HTML
    <!doctype html>
    <link rel="stylesheet" href="file://#{KATEX_DIST}/katex.min.css">
    <script src="file://#{KATEX_DIST}/katex.min.js"></script>
    <body style="margin:0;background:#fff;display:inline-block;
                 font-size:#{display ? 21 : 10}px;padding:2px">
    <span id="m"></span>
    <script>
      katex.render(#{tex.to_json}, document.getElementById("m"),
                   { displayMode: #{display}, throwOnError: false });
    </script>
  HTML
  hidpi(chrome_shot(html, window: display ? "1000,400" : "800,200"))
end

def mermaid_png(src)
  return nil unless CHROME && MERMAID_JS

  html = <<~HTML
    <!doctype html>
    <body style="margin:0;background:#fff">
    <pre class="mermaid" style="margin:0">#{src.gsub("<", "&lt;")}</pre>
    <script src="file://#{MERMAID_JS}"></script>
    <script>mermaid.initialize({ startOnLoad: true, theme: "neutral" });</script>
  HTML
  hidpi(chrome_shot(html, window: "900,700"))
end

def graphviz_png(src)
  return nil unless DOT

  bytes = IO.popen([DOT, "-Tpng", "-Gdpi=144", "-Gbgcolor=white"], "r+b",
                   err: File::NULL) do |io|
    io.write(src)
    io.close_write
    io.read
  end
  hidpi(bytes)
end

# ---- placeholder fallback (self-contained) --------------------------------

# A minimal pure-Ruby solid-color PNG (used for the showcase logo and as the
# fallback when no rasterization tool is available at all).
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

# ---- renderer map ---------------------------------------------------------

RENDERERS = {
  math: lambda do |tex, display|
    katex_png(tex, display) ||
      source_png(display ? "  #{tex}  " : tex, bg: display ? "ffe" : "eef")
  end,
  mermaid: lambda do |src|
    mermaid_png(src) || source_png("[mermaid]  #{src.lines.first.to_s.strip}", bg: "efe")
  end,
  graphviz: lambda do |src|
    graphviz_png(src) || source_png("[graphviz]  #{src.lines.first.to_s.strip}", bg: "fee")
  end,
}.freeze

used = { math: CHROME && KATEX_DIST ? "KaTeX + Chrome" : "placeholder",
         mermaid: CHROME && MERMAID_JS ? "mermaid + Chrome" : "placeholder",
         graphviz: DOT ? "dot" : "placeholder" }
puts "renderers: #{used.map { |k, v| "#{k}=#{v}" }.join(', ')}"

# The showcase references logo.png; create a small one next to the .crv.
File.binwrite(File.join(DIR, "logo.png"), solid_png(46, 22, 60, 120, 220))

# Relative image paths in the documents (e.g. logo.png) resolve against the
# process working directory, so render from within the examples folder.
Dir.chdir(DIR) do
  Dir["*.crv"].sort.each do |crv|
    out = crv.sub(/\.crv\z/, ".pdf")
    pdf = Carve::Hexapdf.render(File.read(crv), renderers: RENDERERS)
    File.binwrite(out, pdf)
    puts "#{crv} -> #{out} (#{pdf.bytesize} bytes)"
  end
end
