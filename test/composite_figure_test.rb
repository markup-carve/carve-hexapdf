# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# A composite figure renders as one grouped float (carve-hexapdf#18).
#
# PART 9 section 4c: a bare `::: figure` opener is ONE figure of ordered
# panels. The AST node is `figure_group` - `children`, an optional group
# `caption`, `attrs`, `pos`, and deliberately no `target`, no title, no label -
# and it is discriminated by its TYPE, never by probing for the field that is
# not there. Its `figure` and `table` children are the panels, in source order;
# every other child is plain group content preserved IN PLACE between them.
#
# The engine this gem consumes (carve-lang, over carve-rs) does not parse the
# construct yet, so these tests drive the renderer through its public
# `render_ast` entry point with the AST the wire format pins
# (`resources/ast-schema.json` in the spec repo). That is the same contract
# `Carve.parse` will hand over once carve-rs ships section 4c.
class CompositeFigureTest < Minitest::Test
  def doc(*children)
    { type: "document", children: children }
  end

  def text(value)
    { type: "text", value: value }
  end

  # A panel: a captioned image, which is what section 4b's generic captioned
  # wrapper builds from `![alt](src)` plus a `^ ` line. The src does not exist,
  # so the image degrades to its alt text - visible in the content stream,
  # which is what these assertions read.
  def panel(alt, caption, id: nil)
    node = {
      type: "figure",
      target: { type: "image", src: "/no-such-#{alt}.png", alt: alt },
      caption: [text(caption)],
    }
    node[:attrs] = { id: id } if id
    node
  end

  def group(*children, caption: nil, classes: nil)
    node = { type: "figure_group", children: children }
    node[:caption] = [text(caption)] if caption
    node[:attrs] = { classes: classes } if classes
    node
  end

  def pages(bytes)
    HexaPDF::Document.new(io: StringIO.new(bytes)).pages
  end

  # The literal strings a page's content stream draws, in drawing order. A
  # content stream escapes `(` and `)` inside a literal string, so the drawn
  # text is the unescaped form.
  def strings_per_page(bytes)
    pages(bytes).map { |page| literal_strings(page.contents) }
  end

  def literal_strings(content)
    content.scan(/\((?:[^()\\]|\\.)*\)/).map { |s| s[1..-2].gsub(/\\(.)/, '\1') }
  end

  def strings(bytes)
    strings_per_page(bytes).flatten
  end

  # A tall filler that leaves only a sliver of the first page free, so anything
  # that follows either fits in the remainder or moves to the next page.
  def filler(paragraphs)
    (1..paragraphs).map { |i| { type: "paragraph", children: [text("Filler paragraph #{i}.")] } }
  end

  # ---- content ---------------------------------------------------------

  def test_every_panel_and_both_caption_kinds_reach_the_page
    out = strings(Carve::Hexapdf.render_ast(doc(
      group(panel("one", "(a) One"), panel("two", "(b) Two"), caption: "Figure 1: Group caption")
    )))
    assert_includes out, "(a) One"
    assert_includes out, "(b) Two"
    assert_includes out, "Figure 1: Group caption"
  end

  def test_a_group_without_a_caption_still_renders_its_panels
    out = strings(Carve::Hexapdf.render_ast(doc(group(panel("one", "(a) One")))))
    assert_includes out, "(a) One"
  end

  # Section 4c: non-panel children are plain group content, PRESERVED IN PLACE.
  # No renderer may drop them or re-attach them elsewhere, so this asserts the
  # order and not merely the presence.
  def test_stray_content_is_preserved_between_the_panels_in_source_order
    note = { type: "paragraph", children: [text("Both panels were shot the same day.")] }
    out = strings(Carve::Hexapdf.render_ast(doc(
      group(panel("one", "(a) One"), note, panel("two", "(b) Two"), caption: "Figure 1: Grouped")
    )))
    order = ["(a) One", "Both panels were shot the same day.", "(b) Two", "Figure 1: Grouped"]
    assert_equal order, out.select { |s| order.include?(s) }
  end

  # A table child is a panel too, and keeps its own caption.
  def test_a_table_panel_renders_with_its_own_caption
    table = {
      type: "table",
      caption: [text("Table caption")],
      rows: [
        { cells: [{ header: true, children: [text("H")] }] },
        { cells: [{ children: [text("cell")] }] },
      ],
    }
    out = strings(Carve::Hexapdf.render_ast(doc(group(table, caption: "Figure 1: With a table"))))
    assert_includes out, "cell"
    assert_includes out, "Table caption"
    assert_includes out, "Figure 1: With a table"
  end

  # ---- the group is one float -----------------------------------------

  # The point of the construct on a paged target: the group caption numbers the
  # panels, so it may not be stranded on the page after them, and a panel
  # caption may not be stranded from its host.
  def test_the_whole_group_lands_on_one_page
    bytes = Carve::Hexapdf.render_ast(doc(
      *filler(42),
      group(panel("one", "(a) One"), panel("two", "(b) Two"), caption: "Figure 1: Group caption")
    ))
    per_page = strings_per_page(bytes)
    assert_operator per_page.length, :>=, 2, "the filler did not push the group off the first page"
    holders = per_page.each_index.select do |i|
      per_page[i].any? { |s| ["(a) One", "(b) Two", "Figure 1: Group caption"].include?(s) }
    end
    assert_equal 1, holders.length, "the group was split across pages: #{per_page.inspect}"
  end

  # A group taller than a page CANNOT be kept together. HexaPDF raises "Box
  # didn't fit multiple times" on a non-splitable box that big, which would
  # lose the whole document over one oversized figure, so the group splits
  # instead - and its panels stay in source order across the break.
  def test_a_group_taller_than_a_page_splits_instead_of_failing_the_render
    panels = (1..40).map { |i| panel("p#{i}", "(#{i}) Panel #{i}") }
    bytes = Carve::Hexapdf.render_ast(doc(group(*panels, caption: "Figure 1: Too tall")))
    per_page = strings_per_page(bytes)
    assert_operator per_page.length, :>=, 2, "the group was expected to need more than one page"
    seen = per_page.flatten.select { |s| s.start_with?("(") && s.include?(") Panel ") }
    assert_equal panels.map { |p| p[:caption][0][:value] }, seen
    assert_includes per_page.flatten, "Figure 1: Too tall"
  end

  # ---- layout hints ----------------------------------------------------

  # `.columns-2` is honored when the page is wide enough: the two panels sit
  # side by side instead of stacked. The hint changes layout, never content.
  def test_a_columns_hint_lays_the_panels_out_side_by_side
    body = [panel("one", "(a) One"), panel("two", "(b) Two")]
    stacked = Carve::Hexapdf.render_ast(doc(group(*body)))
    columned = Carve::Hexapdf.render_ast(doc(group(*body, classes: ["columns-2"])))
    # Side by side, the two panel captions share a baseline; stacked they do
    # not. The content stream's text-positioning operators say which.
    assert_operator panel_baselines(stacked).uniq.length, :>, 1
    assert_equal 1, panel_baselines(columned).uniq.length,
                 "the panels are not on one row: #{panel_baselines(columned).inspect}"
    assert_equal strings(stacked).sort, strings(columned).sort,
                 "the hint changed the content, not only the layout"
  end

  # A hint the page cannot pay for is ignored, and ignoring it costs no
  # content: every panel is still drawn.
  def test_a_columns_hint_too_wide_for_the_page_stacks_without_losing_a_panel
    ast = doc(group(panel("one", "(a) One"), panel("two", "(b) Two"),
                    caption: "Figure 1: Narrow", classes: ["columns-8"]))
    out = strings(Carve::Hexapdf.render_ast(ast, page_size: :A7))
    assert_includes out, "(a) One"
    assert_includes out, "(b) Two"
    assert_includes out, "Figure 1: Narrow"
  end

  def test_the_column_gap_and_minimum_width_are_style_keys
    ast = doc(group(panel("one", "(a) One"), panel("two", "(b) Two"), classes: ["columns-2"]))
    wide = Carve::Hexapdf.render_ast(ast)
    # A minimum column width the page cannot satisfy turns the hint off.
    narrow = Carve::Hexapdf.render_ast(ast, styles: { "figure.group" => { min_column_width: 400 } })
    assert_equal 1, panel_baselines(wide).uniq.length
    assert_operator panel_baselines(narrow).uniq.length, :>, 1
  end

  # ---- the control: a titled or labelled opener is NOT this production --

  # Section 4c is explicit: `::: figure "T"` and `::: figure [g]` do NOT match
  # `figure_group_open`. They stay a generic Tier-2 container - an `admonition`
  # of kind `figure`, title preserved - and must keep rendering as one. The
  # observable difference is where the authored text sits: an admonition draws
  # its TITLE before the body, a group draws its CAPTION after the panels.
  def test_a_titled_figure_container_is_not_a_group
    out = strings(Carve::Hexapdf.render_ast(doc(
      { type: "admonition", kind: "figure", title: [text("A titled figure div")],
        children: [panel("one", "(a) One")] }
    )))
    order = ["A titled figure div", "(a) One"]
    assert_equal order, out.select { |s| order.include?(s) },
                 "the container's title rendered as a group caption would"
  end

  def test_a_group_caption_follows_its_panels
    out = strings(Carve::Hexapdf.render_ast(doc(
      group(panel("one", "(a) One"), caption: "Figure 1: Group caption")
    )))
    order = ["(a) One", "Figure 1: Group caption"]
    assert_equal order, out.select { |s| order.include?(s) }
  end

  private

  # The y coordinate of each panel caption's text object, one per panel, in
  # drawing order. Text is positioned with `x y Td` inside a `BT`/`ET` pair.
  def panel_baselines(bytes)
    content = pages(bytes).map(&:contents).join("\n")
    content.scan(/BT.*?ET/m).filter_map do |block|
      next unless (literal_strings(block) & ["(a) One", "(b) Two"]).any?

      block[/([-\d.]+)\s+([-\d.]+)\s+Td/, 2]&.to_f
    end
  end
end
