# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "carve/hexapdf"

# Every published inline node either reaches the page or is deliberately dropped.
#
# The renderer dispatches on `node[:type]` and falls back to
#
#   emit_children(node, ctx, out) if node[:children]
#
# so a node carrying its content in ANY other field contributes nothing at all -
# no error, no placeholder, just missing text. That is how `symbol`,
# `literal_inline`, `caption_number` and `inline_extension` were being dropped
# (carve-hexapdf#15): each keeps its content in `name`, `content` or `n`.
#
# The renderer still had a `when "emoji"` arm, and `emoji` had been renamed to
# `symbol` upstream - so the arm was dead and the new name fell to the fallback.
# Nothing failed, because the suite renders SOURCE through whatever engine is
# installed and never asserts that a given construct reached the page.
#
# This test builds one node of each type directly and renders it, so it does not
# depend on which engine version is installed or on that engine producing the
# construct. A type that stops reaching the page fails here.
class InlineVocabularyTest < Minitest::Test
  # Rendered between two markers so an empty contribution is unambiguous.
  def render_inline(node)
    tree = {
      type: "document",
      children: [{
        type: "paragraph",
        children: [{ type: "text", value: "<" }, node, { type: "text", value: ">" }],
      }],
    }
    text_of(Carve::Hexapdf.render_ast(tree))
  end

  def text_of(bytes)
    doc = HexaPDF::Document.new(io: StringIO.new(bytes))
    out = +""
    doc.pages.each do |page|
      HexaPDF::Content::Parser.parse(page.contents) do |op, operands|
        out << operands.flatten.grep(String).join if %i[Tj TJ].include?(op)
      end
    end
    out
  end

  # type => [node, the text it must contribute]
  #
  # The expectations follow the reference engine's PLAIN-TEXT target, which is
  # the closest analogue to a PDF text run: carve-js renders `:smile:` as
  # `:smile:`, `` !`raw span` `` as `raw span`, `:kbd[Ctrl]` as `Ctrl`, and the
  # caption number as the number.
  REACHES_THE_PAGE = {
    "symbol" => [{ type: "symbol", name: "smile" }, ":smile:"],
    "emoji (the old name)" => [{ type: "emoji", name: "smile" }, ":smile:"],
    "literal_inline" => [{ type: "literal_inline", content: "raw span" }, "raw span"],
    "caption_number" => [{ type: "caption_number", n: 1 }, "1"],
    "inline_extension" => [
      { type: "inline_extension", name: "kbd", content: [{ type: "text", value: "Ctrl" }] },
      "Ctrl",
    ],
    # Both halves are inline arrays (spec AST schema), and both reach the page.
    "substitution" => [
      {
        type: "substitution",
        old: [{ type: "text", value: "was" }],
        new: [{ type: "emphasis", children: [{ type: "text", value: "is" }] }],
      },
      "wasis",
    ],
    # An empty half is `[]` rather than a missing key, so the other half still
    # has to reach the page on its own.
    "substitution (empty old)" => [
      { type: "substitution", old: [], new: [{ type: "text", value: "added" }] },
      "added",
    ],
    "code (control)" => [{ type: "code", value: "x" }, "x"],
    "insert (control)" => [{ type: "insert", children: [{ type: "text", value: "ins" }] }, "ins"],
  }.freeze

  # Dropped ON PURPOSE, with the reason. A PDF has no form for raw markup, and a
  # critic comment is editorial rather than content.
  DELIBERATELY_DROPPED = {
    "raw_inline" => { type: "raw_inline", format: "html", content: "<b>x</b>" },
    "critic_comment" => { type: "critic_comment", content: "note" },
  }.freeze

  # Dropped, and SHOULD NOT BE - each needs a decision rather than an arm, so
  # they are pinned as known gaps instead of hidden. Removing an entry here is
  # what closing carve-hexapdf#15 looks like.
  #
  #   heading_ref  - carries `target` and `href` only, so printing the heading's
  #                  TEXT (what carve-js does) needs a heading index the
  #                  renderer does not build today.
  KNOWN_GAPS = {
    "heading_ref" => { type: "heading_ref", target: "h", href: "#h" },
  }.freeze

  REACHES_THE_PAGE.each do |label, (node, expected)|
    define_method("test_#{label.gsub(/\W+/, '_')}_reaches_the_page") do
      got = render_inline(node)
      assert_includes got, expected,
                      "#{label} contributed #{got.inspect}, expected it to contain #{expected.inspect}"
    end
  end

  DELIBERATELY_DROPPED.each do |label, node|
    define_method("test_#{label}_is_dropped_on_purpose") do
      assert_equal "<>", render_inline(node),
                   "#{label} started reaching the page - if that is intended, move it out of DELIBERATELY_DROPPED"
    end
  end

  KNOWN_GAPS.each do |label, node|
    define_method("test_#{label}_is_a_known_gap") do
      assert_equal "<>", render_inline(node),
                   "#{label} now reaches the page - remove it from KNOWN_GAPS"
    end
  end

  # Editorial marks whose whole point is the decoration, which text extraction
  # cannot see: `insert` and `delete` carry `children`, so their text reached
  # the page through the fallback even while the arms that style them were
  # spelled `critic_insert` and `critic_delete` and never fired (#41).
  #
  # HexaPDF draws both an underline and a strikeout as a stroked line after the
  # run, so counting `S` operators separates a styled run from a bare one.
  RULED = {
    "insert" => { type: "insert", children: [{ type: "text", value: "ins" }] },
    "delete" => { type: "delete", children: [{ type: "text", value: "del" }] },
    "substitution" => {
      type: "substitution",
      old: [{ type: "text", value: "was" }],
      new: [{ type: "text", value: "is" }],
    },
  }.freeze

  def strokes(node)
    tree = { type: "document", children: [{ type: "paragraph", children: [node] }] }
    doc = HexaPDF::Document.new(io: StringIO.new(Carve::Hexapdf.render_ast(tree)))
    count = 0
    doc.pages.each do |page|
      HexaPDF::Content::Parser.parse(page.contents) { |op, _| count += 1 if op == :S }
    end
    count
  end

  def test_plain_text_draws_no_rule
    assert_equal 0, strokes({ type: "text", value: "ins" }),
                 "the control drew a rule, so counting strokes cannot tell a styled run apart"
  end

  RULED.each do |label, node|
    define_method("test_#{label}_is_ruled") do
      assert_operator strokes(node), :>=, 1,
                      "#{label} drew no rule, so its run is indistinguishable from body text"
    end
  end

  def test_a_substitution_rules_both_halves
    assert_equal 2, strokes(RULED.fetch("substitution")),
                 "a substitution must rule the replaced half and the replacement separately"
  end

  def test_an_unhandled_type_with_children_still_emits_them
    # The fallback's good case, and the reason a type with `children` was never
    # part of this bug. Pinned so a future dispatch rewrite keeps it.
    node = { type: "no_such_inline_type", children: [{ type: "text", value: "kept" }] }
    assert_includes render_inline(node), "kept"
  end
end
