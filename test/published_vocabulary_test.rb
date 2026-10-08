# frozen_string_literal: true

require "minitest/autorun"
require "carve/hexapdf"

# EVERY NODE TYPE THE RESOLVED ENGINE PUBLISHES IS ONE THE RENDERER DISPATCHES
# ON, or is named here as deliberately unhandled.
#
# This repository has now shipped the same defect four times, and each time it
# was found by a reader noticing missing output rather than by a test:
#
#   * the arm said `critic_substitute`, the engine published `substitution`,
#     and the replaced run vanished from the page (#39);
#   * the arms said `critic_insert` / `critic_delete` against `insert` /
#     `delete`, so the decoration was lost (#41);
#   * the arm said `emoji` against `symbol` (#15);
#   * the arm said `cross_ref` against `heading_ref`, so every cross-reference
#     was dropped with nothing left behind.
#
# `inline_vocabulary_test.rb` catches one half of this: it builds a node of each
# type BY HAND, so it pins that a type the renderer claims to handle still
# reaches the page. What it cannot do is notice a type the renderer has never
# heard of, because its list is written here rather than read from the engine.
# That is the half that kept failing - every one of the four was a name nobody
# here knew the engine was using.
#
# So this reads BOTH sides and compares them: the arms out of the renderer's
# own source, and the types out of documents parsed by whichever engine is
# resolved. A rename upstream fails this test by name instead of quietly
# removing content from a PDF.
#
# It is deliberately not a list of expected types. A recorded list is the thing
# that went stale four times.
class PublishedVocabularyTest < Minitest::Test
  RENDERER = File.expand_path("../lib/carve/hexapdf/renderer.rb", __dir__)

  # Documents chosen to publish as much of the vocabulary as possible. A type no
  # source here produces is simply not checked, which is why the discriminator
  # below asserts the sample is broad rather than taking the count on trust.
  SOURCES = [
    "# Heading\n\nA *bold* and /slanted/ and `code` word.\n",
    "{#Plan}\n# Plan\n\nSee </#Plan> and </#nope>.\n",
    "A note[^a] and an inline one^[here].\n\n[^a]: body\n",
    "- a\n- b\n\n1. one\n2. two\n\n- [x] done\n",
    "> quoted\n\n```ruby\nx = 1\n```\n\n---\n",
    "| a | b |\n|---|---|\n| 1 | 2 |\n",
    "::: note\ninside\n:::\n\n![alt](x.png)\n",
    "[link](https://example.com) and <https://example.com>\n",
    "Term\n: definition\n\n~~struck~~ and ==marked== and H~2~O and x^2^\n",
    "A :smile: shortcode, an {+inserted+} and a {-deleted-} run.\n",
    "A line with a hard break\\\nand text -- with \"smart\" punctuation.\n",
    "An escaped \\*star\\* and a [span]{.cls} and !`literal`.\n",
    "%% a comment\n\nText after a comment.\n",
    "=html\n<b>raw</b>\n=\n\nText after a raw block.\n",
    "$`x^2`$ inline math and a $$\nx = 1\n$$ block.\n",
    "![pic](p.png)\n^ A caption for the figure.\n",
    "*[HTML]: HyperText Markup Language\n\nThe HTML spec.\n",
    "A @mention and a #tag in prose.\n",
  ].freeze

  # Types the renderer sees and drops on purpose. Each needs a reason, because
  # an entry here is how a real gap would be hidden.
  #
  # `document` is the tree root, which `render_ast` consumes rather than
  # dispatching on, and `pos` sub-hashes carry no `type` at all.
  INTENTIONALLY_NOT_DISPATCHED = {
    "document" => "the tree root, consumed by render_ast rather than dispatched",
    # Structural children their PARENT's arm consumes directly: the `list` arm
    # walks `list_item`, and the `table` arm walks `table_row` and `table_cell`
    # to lay out the grid. They reach the page through that walk, not through
    # the dispatcher, which is why they carry no arm of their own. Verified by
    # rendering: a table draws its cells and a list draws its items.
    "list_item" => "walked by the list arm, which needs the item's position in the list",
    "table_row" => "walked by the table arm, which lays the grid out row by row",
    "table_cell" => "walked by the table arm, together with colspan and rowspan",
  }.freeze

  def handled_types
    source = File.read(RENDERER)
    source.scan(/when\s+((?:"[a-z_]+"\s*,\s*)*"[a-z_]+")/).flatten
          .flat_map { |clause| clause.scan(/"([a-z_]+)"/).flatten }
          .uniq
  end

  def published_types(src)
    types = []
    walk = lambda do |node|
      case node
      when Hash
        types << node[:type] if node[:type]
        node.each_value { |v| walk.call(v) if v.is_a?(Array) || v.is_a?(Hash) }
      when Array
        node.each { |c| walk.call(c) }
      end
    end
    walk.call(Carve.parse(src))
    types
  end

  def test_every_published_node_type_is_dispatched_on
    arms = handled_types
    refute_empty arms, "no `when \"type\"` arms were read out of #{RENDERER}, so this test " \
                       "compared against nothing - the renderer's dispatch was probably rewritten"

    unknown = {}
    SOURCES.each do |src|
      published_types(src).uniq.each do |type|
        next if arms.include?(type)
        next if INTENTIONALLY_NOT_DISPATCHED.key?(type)

        (unknown[type] ||= []) << src
      end
    end

    assert_empty unknown.keys,
                 "the resolved carve-lang (#{Carve::VERSION}) publishes node types the renderer " \
                 "does not dispatch on, so their content reaches no page:\n" +
                 unknown.map { |type, srcs| "  #{type} - from #{srcs.first.inspect}" }.join("\n") +
                 "\n\nAdd an arm in renderer.rb, or an entry in " \
                 "INTENTIONALLY_NOT_DISPATCHED with the reason."
  end

  # THE DISCRIMINATOR. The test above passes trivially if SOURCES stop producing
  # anything: an empty sample has no unknown types in it. So the sample has to be
  # shown to be broad, and broad against something this file does not itself
  # choose - the arms the renderer actually ships.
  #
  # Not an absolute count, which would be a recorded number going stale the way
  # the four renames did. A proportion of the renderer's own dispatch.
  def test_the_sample_exercises_a_broad_share_of_the_dispatch
    arms = handled_types
    seen = SOURCES.flat_map { |src| published_types(src) }.uniq

    covered = (arms & seen).size
    share = covered.to_f / arms.size

    assert_operator share, :>, 0.4,
                     "SOURCES only reach #{covered} of the renderer's #{arms.size} dispatch arms " \
                     "(#{(share * 100).round}%), which is too narrow for the test above to mean " \
                     "much. Types reached: #{(arms & seen).sort.inspect}"
  end
end
