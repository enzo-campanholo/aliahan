import aliahan/date
import aliahan/model
import aliahan/store
import filepath
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/calendar
import simplifile
import wisp

pub fn handle(request: wisp.Request, priv_dir: String) -> wisp.Response {
  let request = wisp.method_override(request)

  use <- wisp.serve_static(request, under: "/static", from: priv_dir)

  case request.method, wisp.path_segments(request) {
    http.Get, [] -> index_response(priv_dir)
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
    http.Patch, ["api", "courses", course_id, "modules"] ->
      wisp.require_json(request, fn(body) {
        reorder_course_modules(course_id, body)
      })
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
  handle_schedule_query(request, fn(view, anchor, schedule_start, engine) {
    store.bootstrap_with_scheduler(view, anchor, schedule_start, engine)
    |> result.map(encode_bootstrap)
  })
}

fn handle_schedule(request: wisp.Request) -> wisp.Response {
  handle_schedule_query(request, fn(view, anchor, schedule_start, engine) {
    store.schedule_view_with_scheduler(view, anchor, schedule_start, engine)
    |> result.map(encode_schedule)
  })
}

fn handle_schedule_query(
  request: wisp.Request,
  load: fn(String, calendar.Date, Option(calendar.Date), model.SchedulerEngine) ->
    Result(json.Json, model.AppError),
) -> wisp.Response {
  case request_schedule(request) {
    Ok(#(view, anchor, schedule_start, engine)) ->
      case load(view, anchor, schedule_start, engine) {
        Ok(payload) -> json_ok(payload)
        Error(error) -> app_error(error)
      }
    Error(message) -> wisp.bad_request(message)
  }
}

fn patch_settings(body: Dynamic) -> wisp.Response {
  case decode.run(body, settings_decoder()) {
    Ok(model.SettingsPatch(include_weekends: None, deadline_slack_days: None)) ->
      wisp.bad_request(
        "Settings patch must include at least one updatable field",
      )
    Ok(settings) -> mutation_response(store.set_settings(settings))
    Error(_) -> wisp.bad_request("Invalid settings payload")
  }
}

fn create_vendor(body: Dynamic) -> wisp.Response {
  case decode.run(body, name_decoder()) {
    Ok(name) -> mutation_response(store.create_vendor(name))
    Error(_) -> wisp.bad_request("Invalid vendor payload")
  }
}

fn delete_vendor(vendor_id: String) -> wisp.Response {
  case parse_id(vendor_id) {
    Ok(vendor_id) -> mutation_response(store.delete_vendor(vendor_id))
    Error(message) -> wisp.bad_request(message)
  }
}

fn create_course(body: Dynamic) -> wisp.Response {
  case decode.run(body, new_course_decoder()) {
    Ok(input) -> mutation_response(store.create_course(input))
    Error(_) -> wisp.bad_request("Invalid course payload")
  }
}

fn update_course(course_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(course_id), decode.run(body, update_course_decoder()) {
    Ok(_),
      Ok(model.UpdateCourseInput(
        name: None,
        deadline: None,
        prerequisites: None,
      ))
    ->
      wisp.bad_request("Course patch must include at least one updatable field")
    Ok(course_id), Ok(input) ->
      mutation_response(store.update_course(course_id, input))
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid course payload")
  }
}

fn delete_course(course_id: String) -> wisp.Response {
  case parse_id(course_id) {
    Ok(course_id) -> mutation_response(store.delete_course(course_id))
    Error(message) -> wisp.bad_request(message)
  }
}

fn add_module(course_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(course_id), decode.run(body, name_decoder()) {
    Ok(course_id), Ok(name) ->
      mutation_response(store.add_module(course_id, name))
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module payload")
  }
}

fn patch_module(module_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(module_id), decode.run(body, module_patch_decoder()) {
    Ok(_), Ok(#(None, None, None)) ->
      wisp.bad_request("Module patch must include at least one updatable field")
    Ok(module_id), Ok(#(name, completed, position)) ->
      mutation_response(store.update_module(
        module_id,
        name,
        completed,
        position,
      ))
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module payload")
  }
}

fn reorder_course_modules(course_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(course_id), decode.run(body, module_reorder_decoder()) {
    Ok(course_id), Ok(module_ids) ->
      mutation_response(store.reorder_modules(course_id, module_ids))
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module reorder payload")
  }
}

fn delete_module(module_id: String) -> wisp.Response {
  case parse_id(module_id) {
    Ok(module_id) -> mutation_response(store.delete_module(module_id))
    Error(message) -> wisp.bad_request(message)
  }
}

fn mutation_response(outcome: Result(Nil, model.AppError)) -> wisp.Response {
  case outcome {
    Ok(_) -> json_ok(json.object([#("updated", json.bool(True))]))
    Error(error) -> app_error(error)
  }
}

fn request_schedule(
  request: wisp.Request,
) -> Result(
  #(String, calendar.Date, Option(calendar.Date), model.SchedulerEngine),
  String,
) {
  let query = wisp.get_query(request)
  use view <- result.try(view_query(query))
  use anchor <- result.try(date_query(
    query,
    "anchor",
    "Anchor date",
    date.today(),
  ))
  use schedule_start <- result.try(optional_date_query(
    query,
    "start",
    "Start date",
  ))
  use engine <- result.try(scheduler_query(query))
  Ok(#(view, anchor, schedule_start, engine))
}

fn scheduler_query(
  query: List(#(String, String)),
) -> Result(model.SchedulerEngine, String) {
  case list.key_find(query, "scheduler") {
    Error(_) | Ok("gleam") -> Ok(model.GleamScheduler)
    Ok("prolog") -> Ok(model.PrologScheduler)
    Ok(_) -> Error("Scheduler must be gleam or prolog")
  }
}

fn view_query(query: List(#(String, String))) -> Result(String, String) {
  case list.key_find(query, "view") {
    Error(_) | Ok("week") -> Ok("week")
    Ok("month") -> Ok("month")
    Ok(_) -> Error("View must be week or month")
  }
}

fn date_query(
  query: List(#(String, String)),
  key: String,
  label: String,
  default: calendar.Date,
) -> Result(calendar.Date, String) {
  case list.key_find(query, key) {
    Error(_) | Ok("") -> Ok(default)
    Ok(value) ->
      date.parse_iso(value)
      |> result.map_error(fn(_) { label <> " must be a YYYY-MM-DD date" })
  }
}

fn optional_date_query(
  query: List(#(String, String)),
  key: String,
  label: String,
) -> Result(Option(calendar.Date), String) {
  case list.key_find(query, key) {
    Ok("") -> Ok(None)
    Ok(value) ->
      case date.parse_iso(value) {
        Ok(parsed) -> Ok(Some(parsed))
        Error(_) -> Error(label <> " must be a YYYY-MM-DD date")
      }
    Error(_) -> Ok(None)
  }
}

fn settings_decoder() -> decode.Decoder(model.SettingsPatch) {
  {
    use include_weekends <- decode.optional_field(
      "include_weekends",
      None,
      decode.optional(decode.bool),
    )
    use deadline_slack_days <- decode.optional_field(
      "deadline_slack_days",
      None,
      decode.optional(decode.int),
    )
    decode.success(model.SettingsPatch(include_weekends:, deadline_slack_days:))
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
      None, [_, ..] -> Ok(model.ExplicitModules(modules))
      Some(_), [_, ..] | None, [] -> Error(Nil)
    }
    case date.parse_iso(deadline_text), course_modules {
      Ok(deadline), Ok(course_modules) ->
        decode.success(model.NewCourseInput(
          vendor_id: vendor_id,
          name: name,
          deadline: deadline,
          prerequisites: prerequisites,
          modules: course_modules,
        ))
      Error(_), _ ->
        decode.failure(placeholder_course_input(), expected: "YYYY-MM-DD date")
      _, Error(_) ->
        decode.failure(
          placeholder_course_input(),
          expected: "modules array or module_range object",
        )
    }
  }
}

fn placeholder_course_input() -> model.NewCourseInput {
  model.NewCourseInput(
    vendor_id: 0,
    name: "",
    deadline: date.today(),
    prerequisites: [],
    modules: model.ExplicitModules([]),
  )
}

fn update_course_decoder() -> decode.Decoder(model.UpdateCourseInput) {
  {
    use name <- decode.optional_field(
      "name",
      None,
      decode.optional(decode.string),
    )
    use deadline_text <- decode.optional_field(
      "deadline_date",
      None,
      decode.optional(decode.string),
    )
    use prerequisites <- decode.optional_field(
      "prerequisites",
      None,
      decode.optional(decode.list(of: decode.string)),
    )
    case deadline_text {
      Some(deadline_text) ->
        case date.parse_iso(deadline_text) {
          Ok(deadline) ->
            decode.success(model.UpdateCourseInput(
              name: name,
              deadline: Some(deadline),
              prerequisites: prerequisites,
            ))
          Error(_) ->
            decode.failure(
              model.UpdateCourseInput(
                name: None,
                deadline: None,
                prerequisites: None,
              ),
              expected: "YYYY-MM-DD date",
            )
        }
      None ->
        decode.success(model.UpdateCourseInput(
          name: name,
          deadline: None,
          prerequisites: prerequisites,
        ))
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

fn module_patch_decoder() -> decode.Decoder(
  #(Option(String), Option(Bool), Option(Int)),
) {
  {
    use name <- decode.optional_field(
      "name",
      None,
      decode.optional(decode.string),
    )
    use completed <- decode.optional_field(
      "completed",
      None,
      decode.optional(decode.bool),
    )
    use position <- decode.optional_field(
      "position",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(name, completed, position))
  }
}

fn module_reorder_decoder() -> decode.Decoder(List(Int)) {
  decode.field("module_ids", decode.list(of: decode.int), decode.success)
}

fn parse_id(text: String) -> Result(Int, String) {
  case int.parse(text) {
    Ok(id) if id > 0 -> Ok(id)
    _ -> Error("Invalid positive numeric id: " <> text)
  }
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
  |> wisp.set_header("cache-control", "no-store")
}

fn encode_bootstrap(data: model.BootstrapData) -> json.Json {
  json.object([
    #("today", json.string(date.to_iso(data.today))),
    #("schedule_start", json.string(date.to_iso(data.schedule_start))),
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
    #(
      "module_range",
      json.nullable(from: course.module_range, of: encode_module_range),
    ),
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
      json.nullable(from: module.scheduled_date, of: fn(value) {
        json.string(date.to_iso(value))
      }),
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

fn index_response(priv_dir: String) -> wisp.Response {
  let path = filepath.join(priv_dir, "index.html")
  case simplifile.read(path) {
    Ok(html) -> wisp.html_response(html, 200)
    Error(_) ->
      wisp.response(500)
      |> wisp.string_body("Failed to read " <> path)
  }
}
