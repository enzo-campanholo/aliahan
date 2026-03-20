import aliahan/date
import aliahan/model as model
import aliahan/store
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as decode
import gleam/http as http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar
import wisp

pub fn handle(request: wisp.Request, priv_dir: String) -> wisp.Response {
  let request = wisp.method_override(request)

  use <- wisp.serve_static(request, under: "/static", from: priv_dir)

  case request.method, wisp.path_segments(request) {
    http.Get, [] -> wisp.html_response(index_html(), 200)
    http.Get, ["api", "bootstrap"] -> handle_bootstrap(request)
    http.Get, ["api", "schedule"] -> handle_schedule(request)
    http.Patch, ["api", "settings"] ->
      wisp.require_json(request, fn(body) { patch_settings(body) })
    http.Post, ["api", "vendors"] ->
      wisp.require_json(request, fn(body) { create_vendor(body) })
    http.Delete, ["api", "vendors", vendor_id] -> delete_vendor(vendor_id)
    http.Post, ["api", "courses"] ->
      wisp.require_json(request, fn(body) { create_course(body) })
    http.Patch, ["api", "courses", course_id] ->
      wisp.require_json(request, fn(body) { update_course(course_id, body) })
    http.Delete, ["api", "courses", course_id] -> delete_course(course_id)
    http.Post, ["api", "courses", course_id, "modules"] ->
      wisp.require_json(request, fn(body) { add_module(course_id, body) })
    http.Patch, ["api", "modules", module_id] ->
      wisp.require_json(request, fn(body) { patch_module(module_id, body) })
    http.Delete, ["api", "modules", module_id] -> delete_module(module_id)
    _, _ -> wisp.not_found()
  }
}

fn handle_bootstrap(request: wisp.Request) -> wisp.Response {
  let #(view, anchor) = request_view(request)
  case store.bootstrap(view, anchor) {
    Ok(data) -> json_ok(encode_bootstrap(data))
    Error(error) -> app_error(error)
  }
}

fn handle_schedule(request: wisp.Request) -> wisp.Response {
  let #(view, anchor) = request_view(request)
  case store.schedule_view(view, anchor) {
    Ok(schedule) -> json_ok(encode_schedule(schedule))
    Error(error) -> app_error(error)
  }
}

fn patch_settings(body: Dynamic) -> wisp.Response {
  case decode.run(body, settings_decoder()) {
    Ok(settings) ->
      case store.set_settings(settings) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(_) -> wisp.bad_request("Invalid settings payload")
  }
}

fn create_vendor(body: Dynamic) -> wisp.Response {
  case decode.run(body, name_decoder()) {
    Ok(name) ->
      case store.create_vendor(name) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(_) -> wisp.bad_request("Invalid vendor payload")
  }
}

fn delete_vendor(vendor_id: String) -> wisp.Response {
  case parse_id(vendor_id) {
    Ok(vendor_id) ->
      case store.delete_vendor(vendor_id) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message) -> wisp.bad_request(message)
  }
}

fn create_course(body: Dynamic) -> wisp.Response {
  case decode.run(body, new_course_decoder()) {
    Ok(input) ->
      case store.create_course(input) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(_) -> wisp.bad_request("Invalid course payload")
  }
}

fn update_course(course_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(course_id), decode.run(body, update_course_decoder()) {
    Ok(course_id), Ok(input) ->
      case store.update_course(course_id, input) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid course payload")
  }
}

fn delete_course(course_id: String) -> wisp.Response {
  case parse_id(course_id) {
    Ok(course_id) ->
      case store.delete_course(course_id) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message) -> wisp.bad_request(message)
  }
}

fn add_module(course_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(course_id), decode.run(body, name_decoder()) {
    Ok(course_id), Ok(name) ->
      case store.add_module(course_id, name) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module payload")
  }
}

fn patch_module(module_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(module_id), decode.run(body, module_patch_decoder()) {
    Ok(module_id), Ok(#(name, completed)) ->
      case name, completed {
        Some(name), Some(done) ->
          case store.rename_module(module_id, name) {
            Ok(_) ->
              case store.set_module_completed(module_id, done) {
                Ok(_) -> json_ok(success_json())
                Error(error) -> app_error(error)
              }
            Error(error) -> app_error(error)
          }
        Some(name), None ->
          case store.rename_module(module_id, name) {
            Ok(_) -> json_ok(success_json())
            Error(error) -> app_error(error)
          }
        None, Some(done) ->
          case store.set_module_completed(module_id, done) {
            Ok(_) -> json_ok(success_json())
            Error(error) -> app_error(error)
          }
        None, None -> wisp.bad_request("Module patch must set name or completed")
      }
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module payload")
  }
}

fn delete_module(module_id: String) -> wisp.Response {
  case parse_id(module_id) {
    Ok(module_id) ->
      case store.delete_module(module_id) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message) -> wisp.bad_request(message)
  }
}

fn request_view(request: wisp.Request) -> #(String, calendar.Date) {
  let query = wisp.get_query(request)
  let view = case list.key_find(query, "view") {
    Ok("month") -> "month"
    _ -> "week"
  }
  let anchor = case list.key_find(query, "anchor") {
    Ok(value) -> date.parse_iso(value) |> result.unwrap(date.today())
    Error(_) -> date.today()
  }
  #(view, anchor)
}

fn settings_decoder() -> decode.Decoder(model.Settings) {
  {
    use include_weekends <- decode.field("include_weekends", decode.bool)
    use deadline_slack_days <- decode.optional_field("deadline_slack_days", 0, decode.int)
    decode.success(model.Settings(include_weekends:, deadline_slack_days: deadline_slack_days))
  }
}

fn name_decoder() -> decode.Decoder(String) {
  decode.field("name", decode.string, decode.success)
}

fn new_course_decoder() -> decode.Decoder(model.NewCourseInput) {
  {
    use vendor_id <- decode.field("vendor_id", decode.int)
    use name <- decode.field("name", decode.string)
    use deadline_text <- decode.field("deadline_date", decode.string)
    use prerequisites <- decode.optional_field(
      "prerequisites",
      [],
      decode.list(of: decode.string),
    )
    use modules <- decode.optional_field(
      "modules",
      [],
      decode.list(of: decode.string),
    )
    use module_range <- decode.optional_field(
      "module_range",
      None,
      decode.optional(module_range_decoder()),
    )
    let course_modules = case module_range, modules {
      Some(range), [] -> Ok(model.GeneratedRange(range))
      None, [_, .._] -> Ok(model.ExplicitModules(modules))
      Some(_), [_, .._] ->
        Error(
          model.NewCourseInput(
            vendor_id: 0,
            name: "",
            deadline: date.today(),
            prerequisites: [],
            modules: model.ExplicitModules([]),
          ),
        )
      None, [] ->
        Error(
          model.NewCourseInput(
            vendor_id: 0,
            name: "",
            deadline: date.today(),
            prerequisites: [],
            modules: model.ExplicitModules([]),
          ),
        )
    }
    case date.parse_iso(deadline_text) {
      Ok(deadline) ->
        case course_modules {
          Ok(course_modules) ->
            decode.success(
              model.NewCourseInput(
                vendor_id: vendor_id,
                name: name,
                deadline: deadline,
                prerequisites: prerequisites,
                modules: course_modules,
              ),
            )
          Error(placeholder) -> decode.failure(
            placeholder,
            expected: "modules array or module_range object",
          )
        }
      Error(_) -> decode.failure(
        model.NewCourseInput(
          vendor_id: 0,
          name: "",
          deadline: date.today(),
          prerequisites: [],
          modules: model.ExplicitModules([]),
        ),
        expected: "YYYY-MM-DD date",
      )
    }
  }
}

fn update_course_decoder() -> decode.Decoder(model.UpdateCourseInput) {
  {
    use name <- decode.field("name", decode.string)
    use deadline_text <- decode.field("deadline_date", decode.string)
    use prerequisites <- decode.optional_field(
      "prerequisites",
      [],
      decode.list(of: decode.string),
    )
    case date.parse_iso(deadline_text) {
      Ok(deadline) ->
        decode.success(
          model.UpdateCourseInput(name:, deadline:, prerequisites: prerequisites),
        )
      Error(_) -> decode.failure(
        model.UpdateCourseInput(
          name: "",
          deadline: date.today(),
          prerequisites: [],
        ),
        expected: "YYYY-MM-DD date",
      )
    }
  }
}

fn module_range_decoder() -> decode.Decoder(model.ModuleRange) {
  {
    use prefix <- decode.field("prefix", decode.string)
    use start <- decode.field("start", decode.int)
    use finish <- decode.field("end", decode.int)
    decode.success(model.ModuleRange(prefix:, start:, end: finish))
  }
}

fn module_patch_decoder() -> decode.Decoder(#(Option(String), Option(Bool))) {
  {
    use name <- decode.optional_field("name", None, decode.optional(decode.string))
    use completed <- decode.optional_field(
      "completed",
      None,
      decode.optional(decode.bool),
    )
    decode.success(#(name, completed))
  }
}

fn parse_id(text: String) -> Result(Int, String) {
  int.parse(text)
  |> result.map_error(fn(_) { "Invalid numeric id: " <> text })
}

fn app_error(error: model.AppError) -> wisp.Response {
  let status = case error {
    model.Validation(_) | model.Parse(_) -> 400
    model.NotFound(_) -> 404
    _ -> 500
  }
  wisp.json_response(
    json.to_string(
      json.object([
        #("ok", json.bool(False)),
        #("error", json.string(model.error_message(error))),
      ]),
    ),
    status,
  )
}

fn json_ok(payload: json.Json) -> wisp.Response {
  wisp.json_response(
    json.to_string(
      json.object([
        #("ok", json.bool(True)),
        #("data", payload),
      ]),
    ),
    200,
  )
}

fn success_json() -> json.Json {
  json.object([#("updated", json.bool(True))])
}

fn encode_bootstrap(data: model.BootstrapData) -> json.Json {
  json.object([
    #("today", json.string(date.to_iso(data.today))),
    #("settings", encode_settings(data.settings)),
    #("vendors", json.array(from: data.vendors, of: encode_vendor)),
    #("conflicts", json.array(from: data.conflicts, of: encode_conflict)),
    #("schedule", encode_schedule(data.schedule)),
  ])
}

fn encode_settings(settings: model.Settings) -> json.Json {
  json.object([
    #("include_weekends", json.bool(settings.include_weekends)),
    #("deadline_slack_days", json.int(settings.deadline_slack_days)),
  ])
}

fn encode_vendor(vendor: model.Vendor) -> json.Json {
  json.object([
    #("id", json.int(vendor.id)),
    #("name", json.string(vendor.name)),
    #("courses", json.array(from: vendor.courses, of: encode_course)),
  ])
}

fn encode_course(course: model.Course) -> json.Json {
  json.object([
    #("id", json.int(course.id)),
    #("vendor_id", json.int(course.vendor_id)),
    #("vendor_name", json.string(course.vendor_name)),
    #("name", json.string(course.name)),
    #("deadline_date", json.string(date.to_iso(course.deadline))),
    #("prerequisites", json.array(from: course.prerequisites, of: json.string)),
    #("module_range", json.nullable(from: course.module_range, of: encode_module_range)),
    #("modules", json.array(from: course.modules, of: encode_module)),
  ])
}

fn encode_module_range(module_range: model.ModuleRange) -> json.Json {
  json.object([
    #("prefix", json.string(module_range.prefix)),
    #("start", json.int(module_range.start)),
    #("end", json.int(module_range.end)),
  ])
}

fn encode_module(module: model.Module) -> json.Json {
  json.object([
    #("id", json.int(module.id)),
    #("course_id", json.int(module.course_id)),
    #("position", json.int(module.position)),
    #("name", json.string(module.name)),
    #("completed_at", json.nullable(from: module.completed_at, of: json.string)),
    #(
      "scheduled_date",
      json.nullable(
        from: module.scheduled_date,
        of: fn(value) { json.string(date.to_iso(value)) },
      )
    ),
    #("slot_index", json.nullable(from: module.slot_index, of: json.int)),
  ])
}

fn encode_conflict(conflict: model.Conflict) -> json.Json {
  json.object([
    #("course_id", json.int(conflict.course_id)),
    #("vendor_name", json.string(conflict.vendor_name)),
    #("course_name", json.string(conflict.course_name)),
    #("message", json.string(conflict.message)),
  ])
}

fn encode_schedule(schedule: model.ScheduleView) -> json.Json {
  json.object([
    #("view", json.string(schedule.view)),
    #("anchor", json.string(date.to_iso(schedule.anchor))),
    #("period_start", json.string(date.to_iso(schedule.period_start))),
    #("period_end", json.string(date.to_iso(schedule.period_end))),
    #("days", json.array(from: schedule.days, of: encode_schedule_day)),
  ])
}

fn encode_schedule_day(day: model.ScheduleDay) -> json.Json {
  json.object([
    #("date", json.string(date.to_iso(day.date))),
    #("label", json.string(date.label(day.date))),
    #("entries", json.array(from: day.entries, of: encode_schedule_entry)),
  ])
}

fn encode_schedule_entry(entry: model.ScheduleEntry) -> json.Json {
  json.object([
    #("module_id", json.int(entry.module_id)),
    #("vendor_name", json.string(entry.vendor_name)),
    #("course_name", json.string(entry.course_name)),
    #("module_name", json.string(entry.module_name)),
    #("scheduled_date", json.string(date.to_iso(entry.scheduled_date))),
    #("slot_index", json.int(entry.slot_index)),
  ])
}

fn index_html() -> String {
  "<!doctype html>
<html lang=\"en\">
  <head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <title>aliahan</title>
    <style>
      body { font-family: sans-serif; margin: 1rem; }
      table { border-collapse: collapse; width: 100%; }
      th, td { border: 1px solid #000; vertical-align: top; padding: 0.5rem; }
      form { margin-bottom: 1rem; }
      input, select, textarea, button { margin: 0.2rem 0; }
      section { margin-bottom: 2rem; }
      .course-card { border: 1px solid #000; padding: 0.75rem; margin-bottom: 0.75rem; }
      .error { color: #900; }
      .done { text-decoration: line-through; }
      .grid { display: grid; gap: 1rem; }
    </style>
  </head>
  <body>
    <h1>aliahan</h1>
    <p>Local course scheduler</p>
    <div id=\"app\">Loading...</div>
    <script src=\"/static/app.js\"></script>
  </body>
</html>"
}
