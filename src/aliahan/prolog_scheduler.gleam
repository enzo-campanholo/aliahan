import aliahan/date
import aliahan/model
import aliahan/scheduler
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/calendar

type PrologEntry {
  PrologEntry(
    course_id: Int,
    module_id: Int,
    scheduled_date: calendar.Date,
    slot_index: Int,
  )
}

type RawPrologEntry {
  RawPrologEntry(
    course_id: Int,
    module_id: Int,
    scheduled_date: String,
    slot_index: Int,
  )
}

type RawPrologConflict {
  RawPrologConflict(course_id: Int, kind: String)
}

type RawPrologResponse {
  RawPrologResponse(
    entries: List(RawPrologEntry),
    conflicts: List(RawPrologConflict),
  )
}

pub fn rebuild(
  courses: List(model.Course),
  settings: model.Settings,
  today: calendar.Date,
) -> Result(
  #(
    List(scheduler.StoredEntry),
    List(model.Conflict),
    List(model.ScheduleEntry),
  ),
  model.AppError,
) {
  let input = build_request(courses, settings, today)
  use output <- result.try(run_solver(input))
  parse_output(output, courses)
}

/// Builds the JSON request sent to the Prolog solver. The string is stable
/// for identical inputs, so it doubles as a cache key: any change to the
/// courses, settings, or date produces a different request.
pub fn build_request(
  courses: List(model.Course),
  settings: model.Settings,
  today: calendar.Date,
) -> String {
  encode_request(courses, settings, today) |> json.to_string
}

/// Runs the Prolog solver with a request built by `build_request`, returning
/// its raw JSON output.
pub fn run_solver(input: String) -> Result(String, model.AppError) {
  run(input)
  |> result.map_error(fn(message) {
    model.IOError("Prolog scheduler failed: " <> message)
  })
}

/// Parses raw solver output into schedule entries and conflicts. Vendor,
/// course, and module names are derived from the courses passed in, not from
/// the output, so replaying a cached response reflects current names.
pub fn parse_output(
  output: String,
  courses: List(model.Course),
) -> Result(
  #(
    List(scheduler.StoredEntry),
    List(model.Conflict),
    List(model.ScheduleEntry),
  ),
  model.AppError,
) {
  use response <- result.try(
    json.parse(output, response_decoder())
    |> result.map_error(fn(_) {
      invalid_response("an invalid response", output)
    }),
  )
  use entries <- result.try(response.entries |> list.try_map(parse_entry))
  use schedule_entries <- result.try(
    entries |> list.try_map(build_schedule_entry(_, courses)),
  )
  use conflicts <- result.try(
    response.conflicts |> list.try_map(build_conflict(_, courses)),
  )
  let stored_entries =
    entries
    |> list.map(fn(entry) {
      scheduler.StoredEntry(
        module_id: entry.module_id,
        scheduled_date: entry.scheduled_date,
        slot_index: entry.slot_index,
      )
    })
  Ok(#(stored_entries, conflicts, schedule_entries))
}

fn encode_request(
  courses: List(model.Course),
  settings: model.Settings,
  today: calendar.Date,
) -> json.Json {
  json.object([
    #("today", json.string(date.to_iso(today))),
    #("include_weekends", json.bool(settings.include_weekends)),
    #("deadline_slack_days", json.int(settings.deadline_slack_days)),
    #("courses", json.array(courses, encode_course)),
  ])
}

fn encode_course(course: model.Course) -> json.Json {
  let remaining_module_ids =
    course.modules
    |> list.filter(fn(module) { module.completed_at == None })
    |> list.map(fn(module) { module.id })
  json.object([
    #("id", json.int(course.id)),
    #("deadline", json.string(date.to_iso(course.deadline))),
    #("prerequisite_ids", json.array(course.prerequisite_ids, json.int)),
    #("module_ids", json.array(remaining_module_ids, json.int)),
  ])
}

fn response_decoder() -> decode.Decoder(RawPrologResponse) {
  {
    use entries <- decode.field("entries", decode.list(of: entry_decoder()))
    use conflicts <- decode.field(
      "conflicts",
      decode.list(of: conflict_decoder()),
    )
    decode.success(RawPrologResponse(entries:, conflicts:))
  }
}

fn entry_decoder() -> decode.Decoder(RawPrologEntry) {
  {
    use course_id <- decode.field("course_id", decode.int)
    use module_id <- decode.field("module_id", decode.int)
    use scheduled_date_text <- decode.field("scheduled_date", decode.string)
    use slot_index <- decode.field("slot_index", decode.int)
    decode.success(RawPrologEntry(
      course_id:,
      module_id:,
      scheduled_date: scheduled_date_text,
      slot_index:,
    ))
  }
}

fn conflict_decoder() -> decode.Decoder(RawPrologConflict) {
  {
    use course_id <- decode.field("course_id", decode.int)
    use kind <- decode.field("kind", decode.string)
    decode.success(RawPrologConflict(course_id:, kind:))
  }
}

fn parse_entry(entry: RawPrologEntry) -> Result(PrologEntry, model.AppError) {
  use scheduled_date <- result.try(
    date.parse_iso(entry.scheduled_date)
    |> result.map_error(fn(_) {
      model.IOError("Prolog scheduler returned an invalid scheduled date")
    }),
  )
  Ok(PrologEntry(
    course_id: entry.course_id,
    module_id: entry.module_id,
    scheduled_date:,
    slot_index: entry.slot_index,
  ))
}

fn build_schedule_entry(
  entry: PrologEntry,
  courses: List(model.Course),
) -> Result(model.ScheduleEntry, model.AppError) {
  use course <- result.try(find_course(courses, entry.course_id))
  use module <- result.try(
    course.modules
    |> list.find(fn(module) { module.id == entry.module_id })
    |> result.map_error(fn(_) {
      model.IOError("Prolog scheduler returned an unknown module id")
    }),
  )
  Ok(model.ScheduleEntry(
    module_id: module.id,
    vendor_name: course.vendor_name,
    course_name: course.name,
    module_name: module.name,
    scheduled_date: entry.scheduled_date,
    slot_index: entry.slot_index,
  ))
}

fn build_conflict(
  conflict: RawPrologConflict,
  courses: List(model.Course),
) -> Result(model.Conflict, model.AppError) {
  use course <- result.try(find_course(courses, conflict.course_id))
  use message <- result.try(case conflict.kind {
    "impossible" ->
      Ok(
        "This course cannot be scheduled before its deadline with the current prerequisites and completed work.",
      )
    "blocked" ->
      Ok(
        "This course is blocked because one of its prerequisites could not finish before the deadline.",
      )
    _ ->
      Error(model.IOError("Prolog scheduler returned an unknown conflict kind"))
  })
  Ok(model.Conflict(
    course_id: course.id,
    vendor_name: course.vendor_name,
    course_name: course.name,
    message:,
  ))
}

fn find_course(
  courses: List(model.Course),
  course_id: Int,
) -> Result(model.Course, model.AppError) {
  courses
  |> list.find(fn(course) { course.id == course_id })
  |> result.map_error(fn(_) {
    model.IOError("Prolog scheduler returned an unknown course id")
  })
}

fn invalid_response(reason: String, output: String) -> model.AppError {
  let snippet = output |> string.trim |> string.slice(at_index: 0, length: 200)
  let detail = case snippet {
    "" -> "no output"
    text -> text
  }
  model.IOError("Prolog scheduler returned " <> reason <> ": " <> detail)
}

@external(erlang, "aliahan_prolog_ffi", "run")
fn run(input: String) -> Result(String, String)
