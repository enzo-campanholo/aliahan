@external(erlang, "envoy_ffi", "get")
@external(javascript, "./env_ffi.mjs", "get")
pub fn get(name: String) -> Result(String, Nil)

@external(erlang, "envoy_ffi", "set")
@external(javascript, "./env_ffi.mjs", "set")
pub fn set(name: String, value: String) -> Nil

@external(erlang, "envoy_ffi", "unset")
@external(javascript, "./env_ffi.mjs", "unset")
pub fn unset(name: String) -> Nil
