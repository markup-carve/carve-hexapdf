# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "carve/hexapdf"

class IncludesTest < Minitest::Test
  def with_tree(files)
    Dir.mktmpdir do |root|
      files.each do |relative, content|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content)
      end
      yield root
    end
  end

  def strings(bytes)
    document = HexaPDF::Document.new(io: StringIO.new(bytes))
    document.pages.flat_map do |page|
      page.contents.scan(/\((?:[^()\\]|\\.)*\)/).map { |text| text[1..-2].gsub(/\\(.)/, '\1') }
    end
  end

  def test_named_input_expands_nested_paths_from_each_including_file
    with_tree(
      "book.crv" => "# Book\n\n{{ chapters/one.crv }}\n",
      "chapters/one.crv" => "## One\n\n{{ ../shared/two.crv }}\n",
      "shared/two.crv" => "Nested child.\n",
    ) do |root|
      result = Carve::Hexapdf.render_path(File.join(root, "book.crv"))

      assert_includes strings(result[:value]), "Nested child."
      assert_equal ["chapters/one.crv", "shared/two.crv"],
                   result[:dependencies].map { |dependency| dependency[:path] }
    end
  end

  def test_named_input_defaults_containment_to_its_directory
    with_tree("book/main.crv" => "{{ ../secret.crv }}\n", "secret.crv" => "SECRET\n") do |root|
      result = Carve::Hexapdf.render_path(File.join(root, "book", "main.crv"))

      refute_includes strings(result[:value]), "SECRET"
      assert_includes result[:warnings].map { |warning| warning[:rule] }, "include-unresolved"
      assert_equal "outside-root", result[:dependencies].first[:denial]
    end
  end

  def test_missing_target_stays_literal_and_is_reported
    with_tree("main.crv" => "Before {{ missing.crv }} after.\n") do |root|
      result = Carve::Hexapdf.render_path(File.join(root, "main.crv"))

      assert_includes strings(result[:value]).join, "missing.crv"
      assert_equal false, result[:dependencies].first[:resolved]
      assert_equal "not-found", result[:dependencies].first[:denial]
    end
  end

  def test_cycle_is_bounded_and_reported
    with_tree("a.crv" => "A\n\n{{ b.crv }}\n", "b.crv" => "B\n\n{{ a.crv }}\n") do |root|
      result = Carve::Hexapdf.render_path(File.join(root, "a.crv"))

      assert_includes result[:warnings].map { |warning| warning[:rule] }, "include-cycle"
      assert_kind_of String, result[:value]
      assert_equal "%PDF", result[:value][0, 4]
    end
  end

  def test_string_render_keeps_include_directives_literal
    pdf = Carve::Hexapdf.render("{{ child.crv }}")

    assert_includes strings(pdf).join, "child.crv"
  end

  def test_explicit_root_preserves_parser_options_for_parent_and_child
    with_tree("main.crv" => "{{ child.crv }}\n", "child.crv" => "# Child\n") do |root|
      result = Carve::Hexapdf.render_with_includes(
        File.binread(File.join(root, "main.crv")),
        root: root,
        source_path: File.join(root, "main.crv"),
        extensions: [],
        profile: :minimal,
      )

      assert_includes strings(result[:value]), "# Child"
    end
  end
end
