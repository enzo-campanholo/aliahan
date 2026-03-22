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
    http.Patch, ["api", "courses", course_id, "modules"] ->
      wisp.require_json(request, fn(body) { reorder_course_modules(course_id, body) })
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
    Ok(model.SettingsPatch(include_weekends: None, deadline_slack_days: None)) ->
      wisp.bad_request("Settings patch must include at least one updatable field")
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
    Ok(_), Ok(model.UpdateCourseInput(name: None, deadline: None, prerequisites: None)) ->
      wisp.bad_request("Course patch must include at least one updatable field")
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
    Ok(_), Ok(#(None, None, None)) ->
      wisp.bad_request("Module patch must include at least one updatable field")
    Ok(module_id), Ok(#(name, completed, position)) ->
      case store.update_module(module_id, name, completed, position) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module payload")
  }
}

fn reorder_course_modules(course_id: String, body: Dynamic) -> wisp.Response {
  case parse_id(course_id), decode.run(body, module_reorder_decoder()) {
    Ok(course_id), Ok(module_ids) ->
      case store.reorder_modules(course_id, module_ids) {
        Ok(_) -> json_ok(success_json())
        Error(error) -> app_error(error)
      }
    Error(message), _ -> wisp.bad_request(message)
    _, Error(_) -> wisp.bad_request("Invalid module reorder payload")
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
    use name <- decode.optional_field("name", None, decode.optional(decode.string))
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
            decode.success(
              model.UpdateCourseInput(
                name: name,
                deadline: Some(deadline),
                prerequisites: prerequisites,
              ),
            )
          Error(_) -> decode.failure(
            model.UpdateCourseInput(
              name: None,
              deadline: None,
              prerequisites: None,
            ),
            expected: "YYYY-MM-DD date",
          )
        }
      None ->
        decode.success(
          model.UpdateCourseInput(
            name: name,
            deadline: None,
            prerequisites: prerequisites,
          ),
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

fn module_patch_decoder() -> decode.Decoder(#(Option(String), Option(Bool), Option(Int))) {
  {
    use name <- decode.optional_field("name", None, decode.optional(decode.string))
    use completed <- decode.optional_field(
      "completed",
      None,
      decode.optional(decode.bool),
    )
    use position <- decode.optional_field("position", None, decode.optional(decode.int))
    decode.success(#(name, completed, position))
  }
}

fn module_reorder_decoder() -> decode.Decoder(List(Int)) {
  decode.field("module_ids", decode.list(of: decode.int), decode.success)
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
<html lang=\"en\" class=\"antialiased\">
  <head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <title>aliahan</title>
    <link rel=\"preconnect\" href=\"https://fonts.googleapis.com\">
    <link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin>
    <link href=\"https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,200..800&family=DM+Sans:ital,opsz,wght@0,9..40,100..1000;1,9..40,100..1000&display=swap\" rel=\"stylesheet\">
    <link rel=\"stylesheet\" href=\"/static/app.css\">
    <script defer src=\"/static/alpine.min.js\"></script>
  </head>
  <body x-data x-init=\"$store.app.init()\">

    <!-- Toast notifications -->
    <div class=\"fixed top-4 right-4 z-50 flex flex-col gap-2\" style=\"pointer-events:none\">
      <template x-for=\"toast in $store.ui.toasts\" :key=\"toast.id\">
        <div
          x-show=\"toast.visible\"
          x-transition:enter=\"transition-[transform,opacity] duration-300 ease-out\"
          x-transition:enter-start=\"translate-x-full opacity-0\"
          x-transition:enter-end=\"translate-x-0 opacity-100\"
          x-transition:leave=\"transition-[transform,opacity] duration-200 ease-in\"
          x-transition:leave-start=\"translate-x-0 opacity-100\"
          x-transition:leave-end=\"translate-x-full opacity-0\"
          class=\"card px-4 py-3 font-heading font-bold text-sm min-w-[240px]\"
          style=\"pointer-events:auto\"
          :class=\"toast.type === 'error' ? 'bg-pink' : toast.type === 'success' ? 'bg-lime' : 'bg-yellow'\"
          x-text=\"toast.message\"
        ></div>
      </template>
    </div>

    <!-- Confirm dialog overlay -->
    <template x-if=\"$store.ui.confirmDialog\">
      <div class=\"fixed inset-0 z-40 flex items-center justify-center\" x-data=\"confirmDialog\">
        <div class=\"absolute inset-0 bg-ink/30\" @click=\"cancel()\"></div>
        <div
          class=\"card relative z-10 bg-surface p-6 max-w-sm w-full mx-4\"
          x-transition:enter=\"transition-[transform,opacity] duration-200 ease-out\"
          x-transition:enter-start=\"translate-y-6 opacity-0\"
          x-transition:enter-end=\"translate-y-0 opacity-100\"
        >
          <h3 class=\"text-lg mb-3\" x-text=\"$store.ui.confirmDialog.message\"></h3>
          <div class=\"flex gap-3\">
            <button class=\"btn btn-ghost flex-1\" @click=\"cancel()\">Cancel</button>
            <button class=\"btn btn-pink flex-1\" @click=\"confirm()\">Delete</button>
          </div>
        </div>
      </div>
    </template>

    <!-- Course creation modal -->
    <template x-if=\"$store.ui.modalOpen\">
      <div class=\"fixed inset-0 z-40 flex items-center justify-center\" x-data=\"courseModal\">
        <div class=\"absolute inset-0 bg-ink/30\" @click=\"close()\"></div>
        <div
          class=\"card relative z-10 bg-surface p-6 max-w-lg w-full mx-4 max-h-[90vh] overflow-y-auto\"
          x-transition:enter=\"transition-[transform,opacity] duration-300 ease-out\"
          x-transition:enter-start=\"translate-y-6 opacity-0\"
          x-transition:enter-end=\"translate-y-0 opacity-100\"
          @click.outside=\"close()\"
        >
          <h3 class=\"text-xl mb-4\">New Course</h3>
          <form @submit.prevent=\"submit()\" class=\"flex flex-col gap-3\">
            <div>
              <label class=\"block text-sm font-bold font-heading mb-1\">Vendor</label>
              <select x-model=\"form.vendor_id\" class=\"input-brutal\">
                <template x-for=\"v in $store.app.data?.vendors || []\" :key=\"v.id\">
                  <option :value=\"v.id\" x-text=\"v.name\"></option>
                </template>
              </select>
            </div>
            <div>
              <label class=\"block text-sm font-bold font-heading mb-1\">Course name</label>
              <input x-model=\"form.name\" class=\"input-brutal\" placeholder=\"e.g. Cloud Foundations\" required>
            </div>
            <div>
              <label class=\"block text-sm font-bold font-heading mb-1\">Deadline</label>
              <input type=\"date\" x-model=\"form.deadline_date\" class=\"input-brutal\" required>
            </div>
            <div>
              <label class=\"block text-sm font-bold font-heading mb-1\">Prerequisites (comma separated)</label>
              <input x-model=\"form.prerequisites\" class=\"input-brutal\" placeholder=\"Course A, Course B\">
            </div>
            <div>
              <label class=\"block text-sm font-bold font-heading mb-1\">Module mode</label>
              <div class=\"flex gap-2\">
                <button type=\"button\" class=\"btn text-xs flex-1\" :class=\"form.mode === 'explicit' ? 'btn-yellow' : ''\" @click=\"form.mode = 'explicit'\">Explicit list</button>
                <button type=\"button\" class=\"btn text-xs flex-1\" :class=\"form.mode === 'range' ? 'btn-yellow' : ''\" @click=\"form.mode = 'range'\">Generated range</button>
              </div>
            </div>
            <template x-if=\"form.mode === 'explicit'\">
              <div>
                <label class=\"block text-sm font-bold font-heading mb-1\">Modules (one per line)</label>
                <textarea x-model=\"form.modules\" class=\"input-brutal\" rows=\"4\" placeholder=\"Module 1&#10;Module 2&#10;Module 3\"></textarea>
              </div>
            </template>
            <template x-if=\"form.mode === 'range'\">
              <div class=\"flex flex-col gap-3\">
                <div>
                  <label class=\"block text-sm font-bold font-heading mb-1\">Prefix</label>
                  <input x-model=\"form.range_prefix\" class=\"input-brutal\" value=\"Module \">
                </div>
                <div class=\"flex gap-3\">
                  <div class=\"flex-1\">
                    <label class=\"block text-sm font-bold font-heading mb-1\">Start</label>
                    <input type=\"number\" x-model.number=\"form.range_start\" class=\"input-brutal\" min=\"1\">
                  </div>
                  <div class=\"flex-1\">
                    <label class=\"block text-sm font-bold font-heading mb-1\">End</label>
                    <input type=\"number\" x-model.number=\"form.range_end\" class=\"input-brutal\" min=\"1\">
                  </div>
                </div>
              </div>
            </template>
            <div class=\"flex gap-3 mt-2\">
              <button type=\"button\" class=\"btn btn-ghost flex-1\" @click=\"close()\">Cancel</button>
              <button type=\"submit\" class=\"btn btn-yellow flex-1\" :disabled=\"submitting\">
                <span x-show=\"!submitting\">Create Course</span>
                <span x-show=\"submitting\">Creating...</span>
              </button>
            </div>
          </form>
        </div>
      </div>
    </template>

    <!-- Header bar -->
    <header class=\"sticky top-0 z-30 bg-yellow border-b-3 border-ink stagger-in\" style=\"animation-delay:0ms\">
      <div class=\"mx-auto px-6 py-3 flex items-center gap-5\">
        <h1 class=\"text-3xl tracking-tight mr-2\">aliahan</h1>

        <!-- Tab switcher -->
        <div class=\"flex border-3 border-ink\">
          <button
            class=\"px-5 py-2 font-heading font-bold text-base cursor-pointer transition-[background-color,color] duration-100\"
            :class=\"$store.ui.tab === 'schedule' ? 'bg-ink text-surface' : 'bg-surface text-ink'\"
            @click=\"$store.ui.tab = 'schedule'\"
          >Schedule</button>
          <button
            class=\"px-5 py-2 font-heading font-bold text-base border-l-3 border-ink cursor-pointer transition-[background-color,color] duration-100\"
            :class=\"$store.ui.tab === 'manage' ? 'bg-ink text-surface' : 'bg-surface text-ink'\"
            @click=\"$store.ui.tab = 'manage'\"
          >Manage</button>
        </div>

        <div class=\"flex-1\"></div>

        <!-- Conflicts badge -->
        <div class=\"relative\" x-show=\"($store.app.data?.conflicts || []).length > 0\">
          <button
            class=\"btn btn-icon p-2\"
            @click=\"$store.ui.conflictsOpen = !$store.ui.conflictsOpen\"
          >
            <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z\"/><line x1=\"12\" y1=\"9\" x2=\"12\" y2=\"13\"/><line x1=\"12\" y1=\"17\" x2=\"12.01\" y2=\"17\"/></svg>
            <span class=\"absolute -top-1 -right-1 bg-pink text-surface text-xs font-bold font-heading w-5 h-5 flex items-center justify-center border-2 border-ink\" x-text=\"($store.app.data?.conflicts || []).length\"></span>
          </button>
          <div
            x-show=\"$store.ui.conflictsOpen\"
            @click.outside=\"$store.ui.conflictsOpen = false\"
            x-transition:enter=\"transition-[transform,opacity] duration-200 ease-out\"
            x-transition:enter-start=\"-translate-y-2 opacity-0\"
            x-transition:enter-end=\"translate-y-0 opacity-100\"
            class=\"absolute right-0 top-full mt-2 w-80 card bg-surface p-4 z-50\"
          >
            <h4 class=\"text-sm font-heading font-bold mb-2\">Schedule Conflicts</h4>
            <ul class=\"flex flex-col gap-2\">
              <template x-for=\"c in $store.app.data?.conflicts || []\" :key=\"c.course_id\">
                <li class=\"text-sm border-l-4 border-pink pl-3 py-1\">
                  <span class=\"font-bold\" x-text=\"c.vendor_name + ' / ' + c.course_name\"></span>
                  <span class=\"block text-sm\" x-text=\"c.message\"></span>
                </li>
              </template>
            </ul>
          </div>
        </div>

        <!-- Settings popover -->
        <div class=\"relative\">
          <button
            class=\"btn btn-icon p-2\"
            :class=\"!$store.app.data?.settings ? 'opacity-50 cursor-not-allowed' : ''\"
            :disabled=\"!$store.app.data?.settings\"
            @click=\"$store.app.data?.settings && ($store.ui.settingsOpen = !$store.ui.settingsOpen)\"
          >
            <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z\"/></svg>
          </button>
          <div
            x-show=\"$store.ui.settingsOpen && $store.app.data?.settings\"
            @click.outside=\"$store.ui.settingsOpen = false\"
            x-transition:enter=\"transition-[transform,opacity] duration-200 ease-out\"
            x-transition:enter-start=\"-translate-y-2 opacity-0\"
            x-transition:enter-end=\"translate-y-0 opacity-100\"
            class=\"absolute right-0 top-full mt-2 w-72 card bg-surface p-4 z-50\"
            x-data=\"settingsPanel\"
          >
            <h4 class=\"text-sm font-heading font-bold mb-3\">Settings</h4>
            <div class=\"flex flex-col gap-3\">
              <label class=\"flex items-center gap-3 cursor-pointer\">
                <div class=\"relative w-11 h-7 border-3 border-ink bg-surface peer-checked:bg-yellow\">
                  <input type=\"checkbox\" class=\"sr-only peer\" :checked=\"$store.app.data?.settings?.include_weekends\" :disabled=\"!$store.app.data?.settings\" @change=\"toggleWeekends($event)\">
                  <div class=\"absolute inset-0 peer-checked:bg-yellow transition-[background-color] duration-150\"></div>
                  <div class=\"absolute top-[3px] left-[3px] w-[14px] h-[14px] bg-ink transition-[transform] duration-150 peer-checked:translate-x-[16px]\"></div>
                </div>
                <span class=\"text-sm font-bold font-heading\">Include weekends</span>
              </label>
              <div>
                <label class=\"block text-sm font-bold font-heading mb-1\">Deadline slack days</label>
                <input
                  type=\"number\"
                  class=\"input-brutal w-20 tabular-nums\"
                  min=\"0\"
                  :disabled=\"!$store.app.data?.settings\"
                  :value=\"$store.app.data?.settings?.deadline_slack_days || 0\"
                  @change=\"updateSlackDays($event)\"
                >
              </div>
            </div>
          </div>
        </div>
      </div>
    </header>

    <!-- Main content -->
    <main class=\"px-6 py-4\">

      <!-- Loading state -->
      <div x-show=\"$store.app.loading && !$store.app.data\" class=\"flex items-center justify-center py-20\">
        <div class=\"card bg-yellow px-6 py-4 font-heading font-bold\">Loading schedule...</div>
      </div>

      <!-- Persistent bootstrap error state -->
      <div
        x-show=\"!$store.app.loading && !$store.app.data && $store.app.error\"
        class=\"max-w-2xl mx-auto py-16\"
      >
        <div class=\"card bg-pink p-6\">
          <h2 class=\"text-xl mb-2\">Unable to load schedule</h2>
          <p class=\"text-sm mb-4\" x-text=\"$store.app.error\"></p>
          <button class=\"btn bg-surface\" @click=\"$store.app.init()\">Retry</button>
        </div>
      </div>

      <!-- Schedule tab -->
      <div
        x-show=\"$store.ui.tab === 'schedule' && $store.app.data\"
        x-data=\"calendarGrid\"
        x-effect=\"$store.ui.tab === 'schedule' || resetPopover()\"
        class=\"stagger-in\"
        style=\"animation-delay:100ms\"
      >

        <!-- Calendar toolbar -->
        <div class=\"flex items-center gap-4 mb-4 shrink-0\">
          <div class=\"flex border-3 border-ink\">
            <button
              class=\"px-4 py-1.5 font-heading font-bold text-sm cursor-pointer transition-[background-color,color] duration-100\"
              :class=\"$store.app.view === 'week' ? 'bg-ink text-surface' : 'bg-surface text-ink'\"
              @click=\"setView('week')\"
            >Week</button>
            <button
              class=\"px-4 py-1.5 font-heading font-bold text-sm border-l-3 border-ink cursor-pointer transition-[background-color,color] duration-100\"
              :class=\"$store.app.view === 'month' ? 'bg-ink text-surface' : 'bg-surface text-ink'\"
              @click=\"setView('month')\"
            >Month</button>
          </div>

          <button class=\"btn p-2\" @click=\"prev()\" aria-label=\"Previous\">
            <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"15 18 9 12 15 6\"/></svg>
          </button>
          <h2 class=\"text-xl tabular-nums w-[280px] text-center\" x-text=\"periodLabel\"></h2>
          <button class=\"btn p-2\" @click=\"next()\" aria-label=\"Next\">
            <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"9 18 15 12 9 6\"/></svg>
          </button>
          <button class=\"btn btn-yellow text-sm\" @click=\"goToday()\">Today</button>
        </div>

        <!-- Calendar content (fades via _fading) -->
        <div class=\"transition-[opacity,transform] duration-120 ease-out\" :class=\"_fading ? 'opacity-0 translate-y-1' : 'opacity-100 translate-y-0'\">

          <!-- Week view -->
          <template x-if=\"$store.app.view === 'week'\">
            <div class=\"grid grid-cols-7 border-3 border-ink\" style=\"min-height: calc(40vh - 40px)\">
              <template x-for=\"(day, i) in schedule?.days || []\" :key=\"day.date\">
                <div class=\"border-r-3 border-ink last:border-r-0 flex flex-col\" :class=\"isToday(day.date) ? 'bg-yellow/10' : 'bg-surface'\">
                  <div class=\"px-3 py-2 border-b-3 border-ink text-center\" :class=\"isToday(day.date) ? 'bg-yellow' : 'bg-surface'\">
                    <div class=\"font-heading font-bold text-sm uppercase\" x-text=\"dayLabel(day.date)\"></div>
                    <div class=\"font-heading font-bold text-2xl tabular-nums\" x-text=\"dayNum(day.date)\"></div>
                  </div>
                  <div class=\"p-2 flex flex-col gap-2 min-h-[200px] flex-1\">
                    <template x-for=\"entry in day.entries.slice(0, 3)\" :key=\"entry.module_id\">
                      <div
                        class=\"border-3 border-ink bg-surface p-2.5 cursor-pointer transition-[transform,box-shadow] duration-150 hover:shadow-[2px_2px_0px_#1A1A1A] hover:translate-x-[-1px] hover:translate-y-[-1px]\"
                        @click=\"openPopover(day.entries, entry)\"
                        :title=\"entry.vendor_name + ' / ' + entry.course_name + ' — ' + entry.module_name\"
                      >
                        <div class=\"flex items-center gap-2 mb-1\">
                          <div class=\"w-3 h-3 border-2 border-ink shrink-0\" :style=\"'background:' + vendorColor(entry.vendor_name)\"></div>
                          <span class=\"text-xs font-heading font-bold truncate opacity-60\" x-text=\"entry.vendor_name\"></span>
                        </div>
                        <div class=\"font-bold font-heading text-sm leading-snug truncate\" x-text=\"entry.module_name\"></div>
                        <div class=\"text-xs truncate opacity-50 mt-0.5\" x-text=\"entry.course_name\"></div>
                      </div>
                    </template>
                    <button
                      type=\"button\"
                      x-show=\"day.entries.length > 3\"
                      class=\"text-xs font-bold font-heading text-center opacity-60 py-1 cursor-pointer hover:underline decoration-2 decoration-ink/30 underline-offset-2\"
                      @click=\"openPopover(day.entries, day.entries[3])\"
                      x-text=\"'+' + (day.entries.length - 3) + ' more'\"
                    ></button>
                  </div>
                </div>
              </template>
            </div>
          </template>

          <!-- Month view -->
          <template x-if=\"$store.app.view === 'month'\">
            <div class=\"grid grid-cols-7 border-3 border-ink\" style=\"grid-template-rows: auto repeat(var(--month-rows, 5), 1fr); min-height: calc(100vh - 180px)\">
              <template x-for=\"label in ['Mon','Tue','Wed','Thu','Fri','Sat','Sun']\" :key=\"label\">
                <div class=\"px-3 py-2 bg-ink text-surface text-center font-heading font-bold text-xs uppercase border-r border-ink/20 last:border-r-0\" x-text=\"label\"></div>
              </template>
              <template x-for=\"(day, i) in schedule?.days || []\" :key=\"day.date\">
                <div class=\"border-t-3 border-ink flex flex-col overflow-hidden\" :class=\"[isToday(day.date) ? 'bg-yellow/10' : 'bg-surface', (i + 1) % 7 !== 0 ? 'border-r-3' : '']\">
                  <div :class=\"isCurrentMonth(day.date) ? '' : 'opacity-40'\">
                    <div class=\"px-2 py-1 text-right\">
                      <span class=\"text-sm font-heading font-bold tabular-nums\" x-text=\"dayNum(day.date)\"></span>
                    </div>
                    <div class=\"px-1.5 pb-1.5 flex flex-col gap-1\">
                      <template x-for=\"(entry, ei) in day.entries.slice(0, 2)\" :key=\"entry.module_id\">
                        <div
                          class=\"flex items-stretch text-xs leading-snug border-3 border-ink bg-surface cursor-pointer transition-[transform,box-shadow] duration-150 hover:shadow-[2px_2px_0px_#1A1A1A] hover:translate-x-[-1px] hover:translate-y-[-1px]\"
                          @click=\"openPopover(day.entries, entry)\"
                          :title=\"entry.vendor_name + ' / ' + entry.course_name + ' — ' + entry.module_name\"
                        >
                          <div class=\"w-1 shrink-0\" :style=\"'background:' + vendorColor(entry.vendor_name)\"></div>
                          <div class=\"truncate px-2 py-1\">
                            <div class=\"truncate font-medium\" x-text=\"entry.module_name\"></div>
                            <div class=\"truncate opacity-50\" x-text=\"entry.course_name\"></div>
                          </div>
                        </div>
                      </template>
                      <button
                        type=\"button\"
                        x-show=\"day.entries.length > 2\"
                        class=\"text-xs font-bold font-heading text-center opacity-60 cursor-pointer hover:underline decoration-2 decoration-ink/30 underline-offset-2\"
                        @click=\"openPopover(day.entries, day.entries[2])\"
                        x-text=\"'+' + (day.entries.length - 2) + ' more'\"
                      ></button>
                    </div>
                  </div>
                </div>
              </template>
            </div>
          </template>

        </div>

        <!-- Week view: detail strip below calendar -->
        <div
          x-show=\"popover.open && $store.app.view === 'week'\"
          x-transition:enter=\"transition-[transform,opacity] duration-150 ease-out\"
          x-transition:enter-start=\"-translate-y-2 opacity-0\"
          x-transition:enter-end=\"translate-y-0 opacity-100\"
          x-transition:leave=\"transition-[opacity] duration-100 ease-in\"
          x-transition:leave-start=\"opacity-100\"
          x-transition:leave-end=\"opacity-0\"
          class=\"mt-[-3px] border-3 border-ink bg-surface relative z-10\"
        >
          <div class=\"px-5 py-4 flex flex-col gap-4\">
            <div x-show=\"popover.entries.length > 1\" class=\"flex flex-col gap-2\">
              <div class=\"text-xs font-heading font-bold uppercase opacity-60\">All entries</div>
              <div class=\"flex flex-col gap-2\">
                <template x-for=\"entry in popover.entries\" :key=\"entry.module_id\">
                  <button
                    type=\"button\"
                    class=\"border-3 border-ink p-2.5 text-left cursor-pointer transition-[transform,box-shadow] duration-150 hover:shadow-[2px_2px_0px_#1A1A1A] hover:translate-x-[-1px] hover:translate-y-[-1px]\"
                    :class=\"popover.entry?.module_id === entry.module_id ? 'bg-yellow' : 'bg-surface'\"
                    :disabled=\"popover.completing\"
                    @click=\"selectPopoverEntry(entry)\"
                  >
                    <div class=\"flex items-center gap-2 mb-1\">
                      <div class=\"w-3 h-3 border-2 border-ink shrink-0\" :style=\"'background:' + vendorColor(entry.vendor_name)\"></div>
                      <span class=\"text-xs font-heading font-bold truncate opacity-60\" x-text=\"entry.vendor_name\"></span>
                    </div>
                    <div class=\"font-bold font-heading text-sm leading-snug truncate\" x-text=\"entry.module_name\"></div>
                    <div class=\"text-xs truncate opacity-50 mt-0.5\" x-text=\"entry.course_name\"></div>
                  </button>
                </template>
              </div>
            </div>
            <div class=\"flex items-center justify-between gap-4\">
              <div class=\"flex items-center gap-3 min-w-0\">
                <div class=\"w-4 h-4 border-2 border-ink shrink-0\" :style=\"'background:' + vendorColor(popover.entry?.vendor_name || '')\"></div>
                <div class=\"min-w-0\">
                  <div class=\"font-heading font-bold text-base truncate\" x-text=\"popover.entry?.module_name\"></div>
                  <div class=\"text-sm opacity-60 truncate\" x-text=\"popover.entry?.vendor_name + ' / ' + popover.entry?.course_name\"></div>
                </div>
              </div>
              <button class=\"btn btn-ghost p-1.5\" @click=\"resetPopover()\" aria-label=\"Close\">
                <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\"><line x1=\"18\" y1=\"6\" x2=\"6\" y2=\"18\"/><line x1=\"6\" y1=\"6\" x2=\"18\" y2=\"18\"/></svg>
              </button>
            </div>
            <div class=\"flex\">
              <button
                class=\"btn btn-lime text-sm\"
                @click=\"markDone(popover.entry?.module_id)\"
                :disabled=\"popover.completing\"
              >
                <span x-show=\"!popover.completing\">Mark done</span>
                <span x-show=\"popover.completing\" class=\"flex items-center gap-2\">
                  <svg class=\"animate-spin\" xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\"><path d=\"M21 12a9 9 0 11-6.219-8.56\"/></svg>
                  Done!
                </span>
              </button>
            </div>
          </div>
        </div>

        <!-- Month view: centered dialog overlay -->
        <template x-teleport=\"body\">
          <div
            x-show=\"popover.open && $store.app.view === 'month' && $store.ui.tab === 'schedule'\"
            class=\"fixed inset-0 z-50 flex items-center justify-center\"
            @keydown.escape.window=\"resetPopover()\"
          >
            <!-- Backdrop -->
            <div
              class=\"absolute inset-0 bg-ink/20\"
              x-show=\"popover.open && $store.app.view === 'month' && $store.ui.tab === 'schedule'\"
              x-transition:enter=\"transition-[opacity] duration-150 ease-out\"
              x-transition:enter-start=\"opacity-0\"
              x-transition:enter-end=\"opacity-100\"
              x-transition:leave=\"transition-[opacity] duration-100 ease-in\"
              x-transition:leave-start=\"opacity-100\"
              x-transition:leave-end=\"opacity-0\"
              @click=\"resetPopover()\"
            ></div>
            <!-- Card -->
            <div
              x-show=\"popover.open && $store.app.view === 'month' && $store.ui.tab === 'schedule'\"
              x-transition:enter=\"transition-[transform,opacity] duration-150 ease-out\"
              x-transition:enter-start=\"translate-y-3 opacity-0\"
              x-transition:enter-end=\"translate-y-0 opacity-100\"
              x-transition:leave=\"transition-[transform,opacity] duration-100 ease-in\"
              x-transition:leave-start=\"translate-y-0 opacity-100\"
              x-transition:leave-end=\"translate-y-3 opacity-0\"
              class=\"relative card bg-surface p-6 w-80\"
            >
              <button class=\"absolute top-3 right-3 btn btn-ghost p-1.5\" @click=\"resetPopover()\" aria-label=\"Close\">
                <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\"><line x1=\"18\" y1=\"6\" x2=\"6\" y2=\"18\"/><line x1=\"6\" y1=\"6\" x2=\"18\" y2=\"18\"/></svg>
              </button>
              <div x-show=\"popover.entries.length > 1\" class=\"flex flex-col gap-2 mb-5 pr-8\">
                <div class=\"text-xs font-heading font-bold uppercase opacity-60\">All entries</div>
                <div class=\"flex flex-col gap-2\">
                  <template x-for=\"entry in popover.entries\" :key=\"entry.module_id\">
                    <button
                      type=\"button\"
                      class=\"border-3 border-ink p-2 text-left cursor-pointer transition-[transform,box-shadow] duration-150 hover:shadow-[2px_2px_0px_#1A1A1A] hover:translate-x-[-1px] hover:translate-y-[-1px]\"
                      :class=\"popover.entry?.module_id === entry.module_id ? 'bg-yellow' : 'bg-surface'\"
                      :disabled=\"popover.completing\"
                      @click=\"selectPopoverEntry(entry)\"
                    >
                      <div class=\"flex items-center gap-2 mb-1\">
                        <div class=\"w-3 h-3 border-2 border-ink shrink-0\" :style=\"'background:' + vendorColor(entry.vendor_name)\"></div>
                        <span class=\"text-xs font-heading font-bold truncate opacity-60\" x-text=\"entry.vendor_name\"></span>
                      </div>
                      <div class=\"font-bold font-heading text-sm leading-snug truncate\" x-text=\"entry.module_name\"></div>
                      <div class=\"text-xs truncate opacity-50 mt-0.5\" x-text=\"entry.course_name\"></div>
                    </button>
                  </template>
                </div>
              </div>
              <div class=\"flex items-start gap-3 mb-5 pr-8\">
                <div class=\"w-5 h-5 mt-0.5 border-2 border-ink shrink-0\" :style=\"'background:' + vendorColor(popover.entry?.vendor_name || '')\"></div>
                <div>
                  <div class=\"font-heading font-bold text-lg\" x-text=\"popover.entry?.module_name\"></div>
                  <div class=\"text-sm opacity-60 mt-1\" x-text=\"popover.entry?.vendor_name + ' / ' + popover.entry?.course_name\"></div>
                </div>
              </div>
              <button
                class=\"btn btn-lime w-full text-sm\"
                @click=\"markDone(popover.entry?.module_id)\"
                :disabled=\"popover.completing\"
              >
                <span x-show=\"!popover.completing\">Mark done</span>
                <span x-show=\"popover.completing\" class=\"flex items-center gap-2\">
                  <svg class=\"animate-spin\" xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\"><path d=\"M21 12a9 9 0 11-6.219-8.56\"/></svg>
                  Done!
                </span>
              </button>
            </div>
          </div>
        </template>
      </div>

      <!-- Manage tab -->
      <div x-show=\"$store.ui.tab === 'manage' && $store.app.data\" x-data=\"manageTab\" class=\"stagger-in\" style=\"animation-delay:100ms\">

        <!-- Actions bar -->
        <div class=\"flex flex-wrap gap-4 mb-8\">
          <div x-data=\"vendorForm\" class=\"flex gap-3\">
            <input
              x-model=\"vendorName\"
              class=\"input-brutal w-56 text-base\"
              placeholder=\"Vendor name\"
              @keydown.enter=\"create()\"
            >
            <button class=\"btn btn-yellow text-sm\" @click=\"create()\" :disabled=\"!vendorName.trim()\">+ Add Vendor</button>
          </div>
          <button
            class=\"btn text-sm\"
            @click=\"($store.app.data?.vendors || []).length > 0 && ($store.ui.modalOpen = true)\"
            :disabled=\"($store.app.data?.vendors || []).length === 0\"
          >
            + Add Course
          </button>
        </div>

        <!-- Vendor accordions -->
        <div class=\"flex flex-col gap-4\">
          <template x-for=\"vendor in $store.app.data?.vendors || []\" :key=\"vendor.id\">
            <div class=\"card\">
              <!-- Vendor header -->
              <div class=\"flex items-center bg-surface\">
                <button
                  class=\"flex-1 flex items-center justify-between p-5 hover:bg-yellow/10 transition-[background-color] duration-150 cursor-pointer text-left\"
                  @click=\"toggleVendor(vendor.id)\"
                >
                  <div class=\"flex items-center gap-3\">
                    <div class=\"w-5 h-5 border-3 border-ink shrink-0\" :style=\"'background:' + getVendorColor(vendor.name)\"></div>
                    <h3 class=\"text-xl\" x-text=\"vendor.name\"></h3>
                  </div>
                  <div class=\"flex items-center gap-3\">
                    <span class=\"text-sm font-heading tabular-nums\" x-text=\"vendor.courses.length + ' course' + (vendor.courses.length !== 1 ? 's' : '')\"></span>
                    <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"
                      class=\"transition-[transform] duration-200\"
                      :class=\"isVendorExpanded(vendor.id) ? 'rotate-90' : ''\"
                    ><polyline points=\"9 18 15 12 9 6\"/></svg>
                  </div>
                </button>
                <!-- Color picker + delete -->
                <div class=\"flex items-center gap-3 px-4 border-l-3 border-ink self-stretch\">
                  <div class=\"flex gap-1.5 items-center\">
                    <template x-for=\"c in vendorPalette\" :key=\"c\">
                      <button
                        class=\"w-6 h-6 border-3 cursor-pointer transition-[transform,border-color] duration-150 hover:scale-110\"
                        :class=\"getVendorColor(vendor.name) === c ? 'border-ink scale-110' : 'border-ink/30'\"
                        :style=\"'background:' + c\"
                        @click=\"setVendorColor(vendor.name, c)\"
                      ></button>
                    </template>
                  </div>
                  <button class=\"btn btn-pink p-1.5 text-xs shrink-0\" @click=\"deleteVendor(vendor.id, vendor.name)\" title=\"Delete vendor\">
                    <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"3 6 5 6 21 6\"/><path d=\"M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2\"/></svg>
                  </button>
                </div>
              </div>

              <!-- Vendor content (courses) -->
              <div
                x-show=\"isVendorExpanded(vendor.id)\"
                x-transition:enter=\"transition-[opacity,transform] duration-200 ease-out\"
                x-transition:enter-start=\"opacity-0 -translate-y-1\"
                x-transition:enter-end=\"opacity-100 translate-y-0\"
                x-transition:leave=\"transition-[opacity,transform] duration-150 ease-in\"
                x-transition:leave-start=\"opacity-100 translate-y-0\"
                x-transition:leave-end=\"opacity-0 -translate-y-1\"
              >
                <div class=\"border-t-3 border-ink\">
                  <!-- Empty vendor -->
                  <div x-show=\"vendor.courses.length === 0\" class=\"p-5\">
                    <p class=\"text-sm\">No courses yet.</p>
                  </div>

                  <!-- Course cards -->
                  <template x-for=\"(course, ci) in vendor.courses\" :key=\"course.id\">
                    <div :class=\"ci > 0 ? 'border-t-3 border-ink' : ''\" class=\"p-5\" x-data=\"courseCard(course, vendor)\">
                      <div class=\"flex items-center justify-between gap-3 mb-4\">
                        <!-- Course name (inline edit) -->
                        <div class=\"flex-1 min-w-0\">
                          <template x-if=\"!editing.name\">
                            <h4 class=\"text-lg cursor-pointer hover:underline decoration-2 decoration-ink/30 underline-offset-2 truncate\" @click=\"editing.name = true\" x-text=\"course.name\" :title=\"course.name\"></h4>
                          </template>
                          <template x-if=\"editing.name\">
                            <input
                              class=\"input-brutal text-lg font-heading font-bold\"
                              :value=\"course.name\"
                              @blur=\"saveName($event.target.value)\"
                              @keydown.enter=\"$event.target.blur()\"
                              @keydown.escape=\"editing.name = false\"
                              x-init=\"$nextTick(() => $el.focus())\"
                            >
                          </template>
                        </div>
                        <!-- Delete course -->
                        <button class=\"btn btn-pink p-1.5 shrink-0\" @click=\"deleteCourse()\" title=\"Delete course\">
                          <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"3 6 5 6 21 6\"/><path d=\"M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2\"/></svg>
                        </button>
                      </div>

                      <!-- Course meta -->
                      <div class=\"flex flex-wrap items-center gap-4 mb-4 text-sm\">
                        <div class=\"flex items-center gap-1.5 font-heading font-bold\">
                          <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\"><rect x=\"3\" y=\"4\" width=\"18\" height=\"18\" rx=\"0\"/><line x1=\"16\" y1=\"2\" x2=\"16\" y2=\"6\"/><line x1=\"8\" y1=\"2\" x2=\"8\" y2=\"6\"/><line x1=\"3\" y1=\"10\" x2=\"21\" y2=\"10\"/></svg>
                          <template x-if=\"!editing.deadline\">
                            <span class=\"cursor-pointer hover:underline decoration-2 decoration-ink/30 underline-offset-2 tabular-nums\" @click=\"editing.deadline = true\" x-text=\"formatDate(course.deadline_date)\"></span>
                          </template>
                          <template x-if=\"editing.deadline\">
                            <input
                              type=\"date\"
                              class=\"input-brutal text-sm py-0 px-1 w-auto\"
                              :value=\"course.deadline_date\"
                              @blur=\"saveDeadline($event.target.value)\"
                              @keydown.enter=\"$event.target.blur()\"
                              @keydown.escape=\"editing.deadline = false\"
                              x-init=\"$nextTick(() => $el.focus())\"
                            >
                          </template>
                        </div>
                        <div class=\"flex items-center gap-1.5 flex-wrap\">
                          <span class=\"font-heading font-bold\">Prereqs:</span>
                          <template x-if=\"!editing.prerequisites\">
                            <div class=\"flex items-center gap-1.5 flex-wrap\">
                              <template x-if=\"course.prerequisites.length > 0\">
                                <div class=\"flex items-center gap-1.5 flex-wrap\">
                                  <template x-for=\"prereq in course.prerequisites\" :key=\"prereq\">
                                    <span class=\"bg-ink text-surface px-2 py-0.5 text-xs font-bold font-heading\" x-text=\"prereq\"></span>
                                  </template>
                                </div>
                              </template>
                              <template x-if=\"course.prerequisites.length === 0\">
                                <span class=\"text-xs font-heading font-bold opacity-50\">No prerequisites</span>
                              </template>
                              <button class=\"text-xs font-bold font-heading ml-2 opacity-70 hover:opacity-100 cursor-pointer transition-opacity duration-150 underline decoration-2 decoration-ink/40 underline-offset-2\" @click=\"startPrerequisitesEdit()\">Edit</button>
                            </div>
                          </template>
                          <template x-if=\"editing.prerequisites\">
                            <input
                              class=\"input-brutal text-sm min-w-64\"
                              :value=\"prerequisiteDraft\"
                              @input=\"prerequisiteDraft = $event.target.value\"
                              @blur=\"savePrerequisites($event.target.value)\"
                              @keydown.enter.prevent=\"$event.target.blur()\"
                              @keydown.escape.prevent=\"cancelPrerequisitesEdit()\"
                              x-init=\"$nextTick(() => { $el.focus(); $el.select(); })\"
                            >
                          </template>
                        </div>
                      </div>

                      <!-- Progress bar -->
                      <div class=\"mb-4\">
                        <div class=\"flex items-center justify-between text-sm font-heading font-bold mb-1.5\">
                          <span>Progress</span>
                          <span class=\"tabular-nums\" x-text=\"completedCount + '/' + course.modules.length\"></span>
                        </div>
                        <div class=\"h-4 bg-surface border-3 border-ink\">
                          <div class=\"h-full bg-lime transition-[width] duration-300 ease-out\" :style=\"'width:' + progressPct + '%'\"></div>
                        </div>
                      </div>

                      <!-- Module list (drag-reorderable) -->
                      <div class=\"flex flex-col gap-1.5\" x-ref=\"moduleList\">
                        <template x-for=\"(mod, mi) in course.modules\" :key=\"mod.id\">
                          <div
                            class=\"flex items-center gap-3 group text-base py-2 px-3 -mx-3 border-3 border-transparent hover:border-ink/10 transition-[background-color,border-color] duration-150 select-none\"
                            :class=\"mod.completed_at ? 'line-through opacity-60' : ''\"
                            :draggable=\"editingModuleId !== mod.id\"
                            @dragstart=\"dragStart($event, mi)\"
                            @dragover.prevent=\"dragOver($event, mi)\"
                            @drop.prevent=\"drop($event)\"
                            @dragend=\"dragEnd()\"
                          >
                            <!-- Drag handle -->
                            <div
                              class=\"transition-[opacity] duration-150 shrink-0\"
                              :class=\"editingModuleId === mod.id ? 'cursor-default opacity-20' : 'cursor-grab opacity-30 group-hover:opacity-70'\"
                              title=\"Drag to reorder\"
                            >
                              <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"14\" height=\"14\" viewBox=\"0 0 24 24\" fill=\"currentColor\"><circle cx=\"9\" cy=\"6\" r=\"1.5\"/><circle cx=\"15\" cy=\"6\" r=\"1.5\"/><circle cx=\"9\" cy=\"12\" r=\"1.5\"/><circle cx=\"15\" cy=\"12\" r=\"1.5\"/><circle cx=\"9\" cy=\"18\" r=\"1.5\"/><circle cx=\"15\" cy=\"18\" r=\"1.5\"/></svg>
                            </div>
                            <!-- Checkbox -->
                            <label class=\"relative cursor-pointer shrink-0\">
                              <input
                                type=\"checkbox\"
                                class=\"sr-only peer\"
                                :checked=\"!!mod.completed_at\"
                                @change=\"toggleModule(mod, $event)\"
                              >
                              <div class=\"w-6 h-6 border-3 border-ink bg-surface peer-checked:bg-lime flex items-center justify-center transition-[background-color] duration-150\">
                                <svg x-show=\"mod.completed_at\" xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><polyline points=\"20 6 9 17 4 12\"/></svg>
                              </div>
                              <div class=\"absolute inset-0 -m-2\"></div>
                            </label>
                            <!-- Module name -->
                            <template x-if=\"editingModuleId !== mod.id\">
                              <button
                                type=\"button\"
                                class=\"flex-1 truncate text-left hover:underline decoration-2 decoration-ink/30 underline-offset-2\"
                                :title=\"mod.name\"
                                @click.stop=\"startModuleRename(mod)\"
                                x-text=\"mod.name\"
                              ></button>
                            </template>
                            <template x-if=\"editingModuleId === mod.id\">
                              <input
                                class=\"input-brutal flex-1 text-base py-1\"
                                :value=\"moduleNameDraft\"
                                @input=\"moduleNameDraft = $event.target.value\"
                                @blur=\"saveModuleName(mod)\"
                                @keydown.enter.prevent=\"$event.target.blur()\"
                                @keydown.escape.prevent=\"cancelModuleRename()\"
                                @mousedown.stop
                                @click.stop
                                x-init=\"$nextTick(() => { $el.focus(); $el.select(); })\"
                              >
                            </template>
                            <!-- Scheduled date tag -->
                            <span x-show=\"mod.scheduled_date && !mod.completed_at\" class=\"text-xs font-heading font-bold bg-ink/10 border-2 border-ink px-2 py-0.5 tabular-nums shrink-0\" x-text=\"mod.scheduled_date\"></span>
                            <!-- Delete module -->
                            <button class=\"opacity-0 group-hover:opacity-100 transition-[opacity] duration-150 btn p-1\" @click=\"deleteModule(mod)\" title=\"Delete module\">
                              <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"18\" y1=\"6\" x2=\"6\" y2=\"18\"/><line x1=\"6\" y1=\"6\" x2=\"18\" y2=\"18\"/></svg>
                            </button>
                          </div>
                        </template>
                      </div>

                      <!-- Add module -->
                      <div class=\"mt-3 flex gap-3\">
                        <input
                          class=\"input-brutal flex-1 text-base\"
                          placeholder=\"New module name\"
                          x-model=\"newModuleName\"
                          @keydown.enter=\"addModule()\"
                        >
                        <button class=\"btn text-sm\" @click=\"addModule()\" :disabled=\"!newModuleName.trim()\">+ Add</button>
                      </div>
                    </div>
                  </template>
                </div>
              </div>
            </div>
          </template>
        </div>

        <!-- Empty state -->
        <div x-show=\"($store.app.data?.vendors || []).length === 0\" class=\"card bg-surface p-8 text-center\">
          <h3 class=\"text-xl mb-2\">No vendors yet</h3>
          <p class=\"text-sm mb-4\">Add a vendor to get started with scheduling your courses.</p>
          <button class=\"btn text-sm mx-auto\" disabled>+ Add Course</button>
        </div>
      </div>

    </main>

    <script src=\"/static/app.js\"></script>
  </body>
</html>"
}
