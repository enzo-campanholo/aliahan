# aliahan

[![Package Version](https://img.shields.io/hexpm/v/aliahan)](https://hex.pm/packages/aliahan)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/aliahan/)

```sh
gleam add aliahan@1
```
```gleam
import aliahan

pub fn main() -> Nil {
  // TODO: An example of the project in use
}
```

Further documentation can be found at <https://hexdocs.pm/aliahan>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```

The checked-in `priv/app.css` keeps `gleam run` styled on a clean checkout.
If you change `priv/input.css`, regenerate the compiled stylesheet with:

```sh
pnpm run build:css
pnpm run watch:css  # Optional while iterating on styles
```

The Alpine runtime is also checked in under `priv/` so the UI works offline.
If you upgrade Alpine, refresh the vendored bundle with:

```sh
pnpm run vendor:alpine
```
