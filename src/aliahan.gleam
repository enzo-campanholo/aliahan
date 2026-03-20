import aliahan/store
import aliahan/web
import gleam/erlang/process
import mist
import wisp
import wisp/wisp_mist

pub fn main() -> Nil {
  let assert Ok(_) = store.initialise()
  let assert Ok(priv_dir) = wisp.priv_directory("aliahan")

  let handler = fn(request) { web.handle(request, priv_dir) }

  let assert Ok(_) =
    handler
    |> wisp_mist.handler("aliahan-local-secret-key")
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
