# carve-hexapdf

Ruby PDF renderer for Carve documents. It supports `carve-lang` 0.1.1 or later and uses the HexaPDF composition engine. See the [Carve documentation](https://markup-carve.github.io/carve/).

## Install

```sh
gem install carve-hexapdf
```

## Usage

```ruby
require "carve/hexapdf"
Carve::Hexapdf.render_file("# Hello", "hello.pdf")
```

## Documentation

- [Carve documentation](https://markup-carve.github.io/carve/)
- [Guide](docs/guide.md)
- [Documentation index](docs/README.md)
- [Contributing and development](docs/development.md)

## License

[MIT](LICENSE). HexaPDF has separate licensing terms; see the [guide](docs/guide.md#licensing).
