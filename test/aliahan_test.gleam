import aliahan/config
import aliahan/date
import aliahan/env
import aliahan/model
import aliahan/prolog_scheduler
import aliahan/scheduler
import aliahan/store
import aliahan/web
import gleam/dynamic/decode
import gleam/http
import gleam/http/response as http_response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/string
import gleam/time/calendar
import gleeunit
import simplifile
import sqlight
import wisp/simulate

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_courses_toml_supports_generated_ranges_test() {
  let toml =
    "
  [\"Vendor\".\"Generated\"]
  module_range = { prefix = \"Module \", start = 2, end = 4 }
  deadline = 2026-04-01T23:59:59-03:00
  "

  let assert Ok([course]) = config.parse_courses_toml(toml)
  assert course.vendor_name == "Vendor"
  assert course.course_name == "Generated"
  assert course.prerequisites == []
  assert course.deadline == calendar.Date(2026, calendar.April, 1)
  assert course.modules
    == model.GeneratedRange(model.ModuleRange(
      prefix: "Module ",
      start: 2,
      end: 4,
    ))
}

pub fn parse_courses_toml_rejects_a_malformed_second_module_source_test() {
  let toml =
    "
  [\"Vendor\".\"Course\"]
  modules = [\"One\"]
  module_range = \"not a range\"
  deadline = 2026-04-01
  "

  let assert Error(model.Parse(message)) = config.parse_courses_toml(toml)
  assert message == "module_range must be a table"
}

pub fn parse_iso_requires_the_documented_shape_test() {
  assert date.parse_iso("2026-07-01")
    == Ok(calendar.Date(2026, calendar.July, 1))
  let assert Error(_) = date.parse_iso("2026-7-01")
  let assert Error(_) = date.parse_iso("26-07-01")
}

pub fn index_and_static_assets_are_served_test() {
  let index = web.handle(simulate.request(http.Get, "/"), "priv")
  assert index.status == 200
  let index_body = simulate.read_body(index)
  assert string.contains(index_body, "<title>aliahan</title>")
  assert string.contains(index_body, "setScheduler('gleam')")
  assert string.contains(index_body, "setScheduler('prolog')")

  let app_js = web.handle(simulate.request(http.Get, "/static/app.js"), "priv")
  assert app_js.status == 200

  let alpine =
    web.handle(simulate.request(http.Get, "/static/alpine.min.js"), "priv")
  assert alpine.status == 200
}

pub fn scheduler_respects_prerequisites_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)

  let intro =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Intro",
      deadline: calendar.Date(2026, calendar.March, 25),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [module(id: 11, course_id: 1, position: 1, name: "Intro 1")],
    )

  let advanced =
    course(
      id: 2,
      vendor_name: "Vendor",
      name: "Advanced",
      deadline: calendar.Date(2026, calendar.March, 25),
      prerequisite_ids: [1],
      prerequisites: ["Intro"],
      modules: [module(id: 21, course_id: 2, position: 1, name: "Advanced 1")],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([intro, advanced], settings, today)

  assert conflicts == []
  let assert [first, second] = entries
  assert first.course_name == "Intro"
  assert first.scheduled_date == today
  assert second.course_name == "Advanced"
  assert second.scheduled_date == date.day_after(today)
}

pub fn prolog_scheduler_respects_prerequisites_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)
  let intro =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Intro",
      deadline: calendar.Date(2026, calendar.March, 25),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [module(id: 11, course_id: 1, position: 1, name: "Intro 1")],
    )
  let advanced =
    course(
      id: 2,
      vendor_name: "Vendor",
      name: "Advanced",
      deadline: calendar.Date(2026, calendar.March, 25),
      prerequisite_ids: [1],
      prerequisites: ["Intro"],
      modules: [
        module(id: 21, course_id: 2, position: 1, name: "Advanced 1"),
      ],
    )

  let assert Ok(#(_, [], entries)) =
    prolog_scheduler.rebuild([intro, advanced], settings, today)
  let assert [first, second] = entries
  assert first.module_id == 11
  assert first.scheduled_date == today
  assert second.module_id == 21
  assert second.scheduled_date == date.day_after(today)
}

pub fn scheduler_skips_weekends_test() {
  let friday = calendar.Date(2026, calendar.March, 20)
  let monday = calendar.Date(2026, calendar.March, 23)
  let settings = model.Settings(include_weekends: False, deadline_slack_days: 0)
  let course =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Course",
      deadline: monday,
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "One"),
        module(id: 12, course_id: 1, position: 2, name: "Two"),
      ],
    )

  let assert Ok(#(_, [], entries)) =
    scheduler.rebuild([course], settings, friday)
  let assert [first, second] = entries
  assert first.scheduled_date == friday
  assert second.scheduled_date == monday
}

pub fn scheduler_rejects_prerequisite_cycles_test() {
  let first =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "First",
      deadline: calendar.Date(2026, calendar.March, 25),
      prerequisite_ids: [2],
      prerequisites: ["Second"],
      modules: [module(id: 11, course_id: 1, position: 1, name: "One")],
    )
  let second =
    course(
      id: 2,
      vendor_name: "Vendor",
      name: "Second",
      deadline: calendar.Date(2026, calendar.March, 25),
      prerequisite_ids: [1],
      prerequisites: ["First"],
      modules: [module(id: 21, course_id: 2, position: 1, name: "Two")],
    )

  let assert Error(model.Parse(message)) =
    scheduler.rebuild(
      [first, second],
      model.Settings(include_weekends: True, deadline_slack_days: 0),
      calendar.Date(2026, calendar.March, 20),
    )
  assert message == "Course prerequisites contain a cycle"
}

pub fn scheduler_reports_courses_with_no_available_days_test() {
  let today = calendar.Date(2026, calendar.March, 20)
  let overdue =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Overdue",
      deadline: date.day_before(today),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [module(id: 11, course_id: 1, position: 1, name: "One")],
    )

  let assert Ok(#([], [conflict], [])) =
    scheduler.rebuild(
      [overdue],
      model.Settings(include_weekends: True, deadline_slack_days: 0),
      today,
    )
  assert conflict.course_id == overdue.id
}

pub fn scheduler_overlaps_when_deadline_requires_it_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)

  let urgent =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Urgent",
      deadline: date.day_after(today),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "One"),
        module(id: 12, course_id: 1, position: 2, name: "Two"),
        module(id: 13, course_id: 1, position: 3, name: "Three"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([urgent], settings, today)

  assert conflicts == []
  assert list.any(entries, fn(entry) { entry.slot_index > 0 })
}

pub fn scheduler_spreads_required_overlaps_across_available_days_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 2)

  let packed =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Packed",
      deadline: calendar.Date(2026, calendar.March, 23),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "P1"),
        module(id: 12, course_id: 1, position: 2, name: "P2"),
        module(id: 13, course_id: 1, position: 3, name: "P3"),
        module(id: 14, course_id: 1, position: 4, name: "P4"),
        module(id: 15, course_id: 1, position: 5, name: "P5"),
        module(id: 16, course_id: 1, position: 6, name: "P6"),
        module(id: 17, course_id: 1, position: 7, name: "P7"),
        module(id: 18, course_id: 1, position: 8, name: "P8"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([packed], settings, today)

  assert conflicts == []
  // The slack window (deadline minus two days) is a hard bound: all eight
  // modules must fit on the three days up to 2026-03-21.
  let scheduled_dates = entries |> list.map(fn(entry) { entry.scheduled_date })
  assert scheduled_dates
    == [
      today,
      today,
      today,
      today,
      date.day_after(today),
      date.day_after(today),
      date.day_after(today),
      date.add_days(today, 2),
    ]
}

pub fn scheduler_keeps_later_courses_spread_when_all_days_are_occupied_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)

  let dense =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Dense",
      deadline: calendar.Date(2026, calendar.March, 23),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "D1"),
        module(id: 12, course_id: 1, position: 2, name: "D2"),
        module(id: 13, course_id: 1, position: 3, name: "D3"),
        module(id: 14, course_id: 1, position: 4, name: "D4"),
        module(id: 15, course_id: 1, position: 5, name: "D5"),
        module(id: 16, course_id: 1, position: 6, name: "D6"),
        module(id: 17, course_id: 1, position: 7, name: "D7"),
        module(id: 18, course_id: 1, position: 8, name: "D8"),
      ],
    )

  let light =
    course(
      id: 2,
      vendor_name: "Vendor",
      name: "Light",
      deadline: calendar.Date(2026, calendar.March, 23),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 21, course_id: 2, position: 1, name: "L1"),
        module(id: 22, course_id: 2, position: 2, name: "L2"),
        module(id: 23, course_id: 2, position: 3, name: "L3"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([dense, light], settings, today)

  assert conflicts == []
  let light_dates =
    entries
    |> list.filter(fn(entry) { entry.course_name == "Light" })
    |> list.map(fn(entry) { entry.scheduled_date })
  assert light_dates
    == [
      today,
      date.add_days(today, 2),
      date.add_days(today, 4),
    ]
}

pub fn scheduler_spaces_course_across_its_window_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)

  let spaced =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Spaced",
      deadline: calendar.Date(2026, calendar.April, 15),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "S1"),
        module(id: 12, course_id: 1, position: 2, name: "S2"),
        module(id: 13, course_id: 1, position: 3, name: "S3"),
        module(id: 14, course_id: 1, position: 4, name: "S4"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([spaced], settings, today)

  assert conflicts == []
  let assert [first, second, third, fourth] = entries
  assert first.scheduled_date == calendar.Date(2026, calendar.March, 19)
  assert second.scheduled_date == calendar.Date(2026, calendar.March, 28)
  assert third.scheduled_date == calendar.Date(2026, calendar.April, 6)
  assert fourth.scheduled_date == calendar.Date(2026, calendar.April, 15)
}

pub fn scheduler_fills_gaps_before_tighter_course_finishes_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)

  let tight =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Tight",
      deadline: calendar.Date(2026, calendar.March, 26),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "T1"),
        module(id: 12, course_id: 1, position: 2, name: "T2"),
        module(id: 13, course_id: 1, position: 3, name: "T3"),
        module(id: 14, course_id: 1, position: 4, name: "T4"),
      ],
    )

  let loose =
    course(
      id: 2,
      vendor_name: "Other",
      name: "Loose",
      deadline: calendar.Date(2026, calendar.April, 2),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 21, course_id: 2, position: 1, name: "L1"),
        module(id: 22, course_id: 2, position: 2, name: "L2"),
        module(id: 23, course_id: 2, position: 3, name: "L3"),
        module(id: 24, course_id: 2, position: 4, name: "L4"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([tight, loose], settings, today)

  assert conflicts == []
  let tight_entries =
    entries |> list.filter(fn(entry) { entry.course_name == "Tight" })
  let loose_entries =
    entries |> list.filter(fn(entry) { entry.course_name == "Loose" })

  let assert [_, _, _, tight_last] = tight_entries
  let assert [loose_first, ..] = loose_entries
  assert date.compare(loose_first.scheduled_date, tight_last.scheduled_date)
    == Lt
}

pub fn scheduler_prefers_finishing_before_deadline_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 1)

  let buffered =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Buffered",
      deadline: calendar.Date(2026, calendar.April, 15),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "B1"),
        module(id: 12, course_id: 1, position: 2, name: "B2"),
        module(id: 13, course_id: 1, position: 3, name: "B3"),
        module(id: 14, course_id: 1, position: 4, name: "B4"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([buffered], settings, today)

  assert conflicts == []
  let assert [_, _, _, last] = entries
  assert last.scheduled_date == calendar.Date(2026, calendar.April, 14)
}

pub fn scheduler_can_use_deadline_day_when_needed_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 5)

  let urgent =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Urgent",
      deadline: calendar.Date(2026, calendar.March, 20),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "U1"),
        module(id: 12, course_id: 1, position: 2, name: "U2"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([urgent], settings, today)

  assert conflicts == []
  let assert [first, second] = entries
  assert first.scheduled_date == today
  assert second.scheduled_date == calendar.Date(2026, calendar.March, 20)
}

pub fn scheduler_finishes_by_slack_deadline_when_stacking_is_needed_test() {
  let today = calendar.Date(2026, calendar.July, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 3)

  let tight =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Tight",
      deadline: calendar.Date(2026, calendar.July, 29),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "T1"),
        module(id: 12, course_id: 1, position: 2, name: "T2"),
        module(id: 13, course_id: 1, position: 3, name: "T3"),
        module(id: 14, course_id: 1, position: 4, name: "T4"),
        module(id: 15, course_id: 1, position: 5, name: "T5"),
        module(id: 16, course_id: 1, position: 6, name: "T6"),
        module(id: 17, course_id: 1, position: 7, name: "T7"),
        module(id: 18, course_id: 1, position: 8, name: "T8"),
        module(id: 19, course_id: 1, position: 9, name: "T9"),
        module(id: 20, course_id: 1, position: 10, name: "T10"),
        module(id: 21, course_id: 1, position: 11, name: "T11"),
        module(id: 22, course_id: 1, position: 12, name: "T12"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([tight], settings, today)

  assert conflicts == []
  assert list.length(entries) == 12
  // Twelve modules on eight allowed days: the course must still finish by
  // deadline minus slack (2026-07-26), stacking modules instead of spreading
  // up to the true deadline.
  let preferred_deadline = calendar.Date(2026, calendar.July, 26)
  assert list.all(entries, fn(entry) {
    date.compare(entry.scheduled_date, preferred_deadline) != Gt
  })
  assert list.any(entries, fn(entry) { entry.slot_index > 0 })
}

pub fn scheduler_stacks_to_meet_slack_deadline_in_a_tiny_window_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 1)

  let urgent =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Urgent",
      deadline: calendar.Date(2026, calendar.March, 20),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "U1"),
        module(id: 12, course_id: 1, position: 2, name: "U2"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([urgent], settings, today)

  assert conflicts == []
  // The slack window is a single day, so both modules stack on it rather
  // than spilling onto the true deadline day.
  let assert [first, second] = entries
  assert first.scheduled_date == today
  assert first.slot_index == 0
  assert second.scheduled_date == today
  assert second.slot_index == 1
}

pub fn scheduler_prerequisite_chain_respects_slack_deadlines_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 2)

  let base =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Base",
      deadline: calendar.Date(2026, calendar.March, 24),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "B1"),
        module(id: 12, course_id: 1, position: 2, name: "B2"),
      ],
    )

  let follow =
    course(
      id: 2,
      vendor_name: "Vendor",
      name: "Follow",
      deadline: calendar.Date(2026, calendar.March, 28),
      prerequisite_ids: [1],
      prerequisites: ["Base"],
      modules: [
        module(id: 21, course_id: 2, position: 1, name: "F1"),
        module(id: 22, course_id: 2, position: 2, name: "F2"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([base, follow], settings, today)

  assert conflicts == []
  let base_dates =
    entries
    |> list.filter(fn(entry) { entry.course_name == "Base" })
    |> list.map(fn(entry) { entry.scheduled_date })
  let follow_dates =
    entries
    |> list.filter(fn(entry) { entry.course_name == "Follow" })
    |> list.map(fn(entry) { entry.scheduled_date })
  // Base finishes by its slack deadline (3/24 - 2 = 3/22), which lets Follow
  // start the very next day and finish by its own slack deadline (3/26).
  assert base_dates
    == [
      calendar.Date(2026, calendar.March, 19),
      calendar.Date(2026, calendar.March, 22),
    ]
  assert follow_dates
    == [
      calendar.Date(2026, calendar.March, 23),
      calendar.Date(2026, calendar.March, 26),
    ]
}

pub fn scheduler_slack_larger_than_window_falls_back_to_true_deadline_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let deadline = calendar.Date(2026, calendar.March, 23)

  let make_course = fn() {
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Course",
      deadline: deadline,
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "One"),
        module(id: 12, course_id: 1, position: 2, name: "Two"),
        module(id: 13, course_id: 1, position: 3, name: "Three"),
      ],
    )
  }

  let assert Ok(#(_, slack_conflicts, slack_entries)) =
    scheduler.rebuild(
      [make_course()],
      model.Settings(include_weekends: True, deadline_slack_days: 10),
      today,
    )
  let assert Ok(#(_, zero_conflicts, zero_entries)) =
    scheduler.rebuild(
      [make_course()],
      model.Settings(include_weekends: True, deadline_slack_days: 0),
      today,
    )

  // A slack window that ends before today is empty, so scheduling falls back
  // to the true deadline with no conflict, exactly as slack 0 behaves.
  assert slack_conflicts == []
  assert zero_conflicts == []
  assert slack_entries == zero_entries
}

pub fn scheduler_compacts_large_internal_gaps_test() {
  let today = calendar.Date(2026, calendar.March, 19)
  let settings = model.Settings(include_weekends: True, deadline_slack_days: 0)

  let dense =
    course(
      id: 1,
      vendor_name: "Vendor",
      name: "Dense",
      deadline: calendar.Date(2026, calendar.March, 21),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 11, course_id: 1, position: 1, name: "D1"),
        module(id: 12, course_id: 1, position: 2, name: "D2"),
        module(id: 13, course_id: 1, position: 3, name: "D3"),
      ],
    )

  let sparse =
    course(
      id: 2,
      vendor_name: "Vendor",
      name: "Sparse",
      deadline: calendar.Date(2026, calendar.March, 26),
      prerequisite_ids: [],
      prerequisites: [],
      modules: [
        module(id: 21, course_id: 2, position: 1, name: "S1"),
        module(id: 22, course_id: 2, position: 2, name: "S2"),
      ],
    )

  let assert Ok(#(_, conflicts, entries)) =
    scheduler.rebuild([dense, sparse], settings, today)

  assert conflicts == []
  let sparse_entries =
    entries |> list.filter(fn(entry) { entry.course_name == "Sparse" })
  let assert [first_sparse, second_sparse] = sparse_entries
  assert first_sparse.scheduled_date == calendar.Date(2026, calendar.March, 23)
  assert second_sparse.scheduled_date == calendar.Date(2026, calendar.March, 26)
}

pub fn patch_module_returns_error_and_keeps_state_test() {
  with_isolated_store("patch_module_returns_error_and_keeps_state", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Atomic",
        modules: model.ExplicitModules(["First", "Second"]),
      )
    let assert [first, ..] = course.modules

    let request =
      simulate.request(http.Patch, "/api/modules/" <> int.to_string(first.id))
      |> simulate.json_body(
        json.object([
          #("name", json.string("   ")),
          #("completed", json.bool(True)),
        ]),
      )
    let response = web.handle(request, "priv")

    assert response.status == 400
    assert string.contains(
      simulate.read_body(response),
      "Module name cannot be empty",
    )

    let updated = course_named("Vendor", "Atomic")
    let assert [updated_first, ..] = updated.modules
    assert updated_first.name == "First"
    assert updated_first.completed_at == None
  })
}

pub fn schedule_queries_reject_invalid_values_test() {
  let invalid_anchor =
    web.handle(
      simulate.request(http.Get, "/api/bootstrap?anchor=2026-7-01"),
      "priv",
    )
  assert invalid_anchor.status == 400
  assert string.contains(simulate.read_body(invalid_anchor), "Anchor date")

  let invalid_view =
    web.handle(simulate.request(http.Get, "/api/bootstrap?view=agenda"), "priv")
  assert invalid_view.status == 400
  assert string.contains(simulate.read_body(invalid_view), "View must be")

  let invalid_scheduler =
    web.handle(
      simulate.request(http.Get, "/api/bootstrap?scheduler=other"),
      "priv",
    )
  assert invalid_scheduler.status == 400
  assert string.contains(
    simulate.read_body(invalid_scheduler),
    "Scheduler must be gleam or prolog",
  )

  let invalid_schedule_scheduler =
    web.handle(
      simulate.request(http.Get, "/api/schedule?scheduler=other"),
      "priv",
    )
  assert invalid_schedule_scheduler.status == 400
}

pub fn invalid_and_missing_resource_ids_return_client_errors_test() {
  with_isolated_store("missing_resource_ids", fn(_, _) {
    let assert Ok(Nil) = store.initialise()

    let invalid =
      web.handle(simulate.request(http.Delete, "/api/vendors/0"), "priv")
    assert invalid.status == 400

    let missing_vendor =
      web.handle(simulate.request(http.Delete, "/api/vendors/999"), "priv")
    assert missing_vendor.status == 404

    let missing_course =
      web.handle(simulate.request(http.Delete, "/api/courses/999"), "priv")
    assert missing_course.status == 404

    let add_to_missing_course =
      simulate.request(http.Post, "/api/courses/999/modules")
      |> simulate.json_body(json.object([#("name", json.string("Module"))]))
      |> web.handle("priv")
    assert add_to_missing_course.status == 404
  })
}

pub fn course_module_ranges_are_bounded_in_the_store_test() {
  with_isolated_store("bounded_module_ranges", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let assert Ok(Nil) = store.create_vendor("Vendor")
    let vendor = vendor_named("Vendor")

    let invalid_start =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Invalid start",
        deadline: calendar.Date(2026, calendar.December, 1),
        prerequisites: [],
        modules: model.GeneratedRange(model.ModuleRange(
          prefix: "Module ",
          start: 0,
          end: 2,
        )),
      ))
    let assert Error(model.Validation(start_message)) = invalid_start
    assert string.contains(start_message, "at least 1")

    let too_large =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Too large",
        deadline: calendar.Date(2026, calendar.December, 1),
        prerequisites: [],
        modules: model.GeneratedRange(model.ModuleRange(
          prefix: "Module ",
          start: 1,
          end: 1001,
        )),
      ))
    let assert Error(model.Validation(size_message)) = too_large
    assert string.contains(size_message, "more than 1000")
  })
}

pub fn duplicate_names_are_rejected_as_validation_errors_test() {
  with_isolated_store("duplicate_names_are_rejected", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let assert Ok(Nil) = store.create_vendor("Vendor")
    let assert Error(model.Validation(_)) = store.create_vendor("Vendor")

    let vendor = vendor_named("Vendor")
    let new_course = fn(name) {
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: name,
        deadline: calendar.Date(2026, calendar.December, 1),
        prerequisites: [],
        modules: model.ExplicitModules(["Only module"]),
      ))
    }
    let assert Ok(Nil) = new_course("Course")
    let assert Error(model.Validation(_)) = new_course("Course")
    Nil
  })
}

pub fn duplicate_prerequisite_names_are_stored_once_test() {
  with_isolated_store("duplicate_prerequisites", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let _ =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Intro",
        modules: model.ExplicitModules(["Intro module"]),
      )
    let vendor = vendor_named("Vendor")

    let assert Ok(Nil) =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Advanced",
        deadline: calendar.Date(2026, calendar.December, 1),
        prerequisites: ["Intro", " Intro ", "Intro"],
        modules: model.ExplicitModules(["Advanced module"]),
      ))

    assert course_named("Vendor", "Advanced").prerequisites == ["Intro"]
  })
}

pub fn completing_todays_module_keeps_today_blank_across_reads_and_name_patch_test() {
  with_isolated_store(
    "completing_todays_module_keeps_today_blank_across_reads_and_name_patch",
    fn(_, _) {
      let today = date.today()
      let tomorrow = date.day_after(today)
      let day_after_tomorrow = date.day_after(tomorrow)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Foundations",
          deadline: tomorrow,
          prerequisites: [],
          modules: model.ExplicitModules(["Today", "Tomorrow"]),
        ))
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Advanced",
          deadline: day_after_tomorrow,
          prerequisites: ["Foundations"],
          modules: model.ExplicitModules(["Blocked"]),
        ))

      let foundations = course_named("Vendor", "Foundations")
      let advanced = course_named("Vendor", "Advanced")
      let assert [today_module, tomorrow_module] = foundations.modules
      let assert [blocked_module] = advanced.modules
      assert today_module.scheduled_date == Some(today)
      assert tomorrow_module.scheduled_date == Some(tomorrow)
      assert blocked_module.scheduled_date == Some(day_after_tomorrow)

      let assert Ok(Nil) = store.set_module_completed(today_module.id, True)

      let first_read = bootstrap_for(today)
      assert schedule_module_names_on(first_read, today) == []
      assert schedule_module_names_on(first_read, tomorrow) == ["Tomorrow"]
      assert schedule_module_names_on(first_read, day_after_tomorrow)
        == ["Blocked"]

      let second_read = bootstrap_for(today)
      assert schedule_module_names_on(second_read, today) == []
      assert schedule_module_names_on(second_read, tomorrow) == ["Tomorrow"]

      let assert Ok(Nil) =
        store.rename_module(tomorrow_module.id, "Tomorrow renamed")
      let after_rename = bootstrap_for(today)
      assert schedule_module_names_on(after_rename, today) == []
      assert schedule_module_names_on(after_rename, tomorrow)
        == ["Tomorrow renamed"]
      assert schedule_module_names_on(after_rename, day_after_tomorrow)
        == ["Blocked"]

      let updated_foundations = course_named("Vendor", "Foundations")
      let assert [updated_today_module, updated_tomorrow_module] =
        updated_foundations.modules
      assert updated_today_module.completed_at == Some(date.to_iso(today))
      assert updated_today_module.scheduled_date == None
      assert updated_tomorrow_module.scheduled_date == Some(tomorrow)
    },
  )
}

pub fn completing_todays_prolog_module_keeps_future_schedule_test() {
  with_isolated_store("completing_todays_prolog_module", fn(_, _) {
    let today = date.today()
    let tomorrow = date.day_after(today)

    let vendor = seed_weekend_vendor()
    let assert Ok(Nil) =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Prolog completion",
        deadline: date.day_after(today),
        prerequisites: [],
        modules: model.ExplicitModules(["First", "Second"]),
      ))

    let assert Ok(before) =
      store.bootstrap_with_scheduler("week", today, None, model.PrologScheduler)
    assert schedule_module_names_on(before, today) == ["First"]
    assert schedule_module_names_on(before, tomorrow) == ["Second"]
    let saved_schedule = stored_prolog_schedule_rows()
    let course = course_named("Vendor", "Prolog completion")
    let assert [first, _] = course.modules

    let assert Ok(Nil) = store.set_module_completed(first.id, True)

    let assert Ok(after) =
      store.bootstrap_with_scheduler("week", today, None, model.PrologScheduler)
    assert schedule_module_names_on(after, today) == []
    assert schedule_module_names_on(after, tomorrow) == ["Second"]
    assert stored_prolog_schedule_rows()
      == list.filter(saved_schedule, fn(row) { row.0 != first.id })
  })
}

pub fn prolog_day_rollover_keeps_future_schedule_when_past_work_is_done_test() {
  with_isolated_store("prolog_day_rollover_keeps_future_schedule", fn(_, _) {
    let today = date.today()
    let tomorrow = date.day_after(today)
    let yesterday_iso = date.to_iso(date.day_before(today))

    let vendor = seed_weekend_vendor()
    let assert Ok(Nil) =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Prolog rollover",
        deadline: tomorrow,
        prerequisites: [],
        modules: model.ExplicitModules(["Past", "Future"]),
      ))
    let assert Ok(_) =
      store.bootstrap_with_scheduler("week", today, None, model.PrologScheduler)
    let course = course_named("Vendor", "Prolog rollover")
    let assert [past, _] = course.modules
    let assert Ok(Nil) = store.set_module_completed(past.id, True)
    let saved_schedule = stored_prolog_schedule_rows()

    let assert Ok(connection) = sqlight.open(store.database_path())
    let assert Ok(_) = sqlight.exec("
      update modules
      set completed_at = '" <> yesterday_iso <> "'
      where id = " <> int.to_string(past.id) <> ";

      update app_settings
      set prolog_schedule_generated_for = '" <> yesterday_iso <> "'
      where id = 1
      ", on: connection)
    let assert Ok(_) = sqlight.close(connection)

    let assert Ok(Nil) = store.initialise()
    let assert Ok(rolled_forward) =
      store.bootstrap_with_scheduler("week", today, None, model.PrologScheduler)
    assert schedule_module_names_on(rolled_forward, today) == []
    assert schedule_module_names_on(rolled_forward, tomorrow) == ["Future"]
    assert stored_prolog_schedule_rows() == saved_schedule
    assert stored_prolog_schedule_generated_for() == Some(date.to_iso(today))
  })
}

pub fn prolog_day_rollover_rebuilds_unfinished_past_work_test() {
  with_isolated_store("prolog_day_rollover_rebuilds_overdue", fn(_, _) {
    let today = date.today()
    let tomorrow = date.day_after(today)
    let yesterday_iso = date.to_iso(date.day_before(today))

    let vendor = seed_weekend_vendor()
    let assert Ok(Nil) =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Prolog catch up",
        deadline: tomorrow,
        prerequisites: [],
        modules: model.ExplicitModules(["Overdue", "Future"]),
      ))
    let assert Ok(_) =
      store.bootstrap_with_scheduler("week", today, None, model.PrologScheduler)
    let course = course_named("Vendor", "Prolog catch up")
    let assert [overdue, _] = course.modules

    let assert Ok(connection) = sqlight.open(store.database_path())
    let assert Ok(_) = sqlight.exec("
      update prolog_schedule_entries
      set scheduled_date = '" <> yesterday_iso <> "'
      where module_id = " <> int.to_string(overdue.id) <> ";

      update app_settings
      set prolog_schedule_generated_for = '" <> yesterday_iso <> "'
      where id = 1
      ", on: connection)
    let assert Ok(_) = sqlight.close(connection)

    let assert Ok(rebuilt) =
      store.bootstrap_with_scheduler("week", today, None, model.PrologScheduler)
    assert schedule_module_names_on(rebuilt, today) == ["Overdue"]
    assert schedule_module_names_on(rebuilt, tomorrow) == ["Future"]
  })
}

pub fn prolog_preview_reports_each_blocked_course_and_keeps_feasible_work_test() {
  with_isolated_store(
    "prolog_preview_reports_conflicts_and_keeps_feasible_work",
    fn(_, _) {
      let today = date.today()

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Elapsed",
          deadline: date.day_before(today),
          prerequisites: [],
          modules: model.ExplicitModules(["Old"]),
        ))
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Blocked",
          deadline: date.day_after(today),
          prerequisites: ["Elapsed"],
          modules: model.ExplicitModules(["Next"]),
        ))
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Transitively blocked",
          deadline: date.add_days(today, 2),
          prerequisites: ["Blocked"],
          modules: model.ExplicitModules(["Last"]),
        ))
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Feasible",
          deadline: today,
          prerequisites: [],
          modules: model.ExplicitModules(["Current"]),
        ))

      let assert Ok(preview) =
        store.bootstrap_with_scheduler(
          "week",
          today,
          None,
          model.PrologScheduler,
        )

      assert preview.conflicts
        |> list.map(fn(conflict) { conflict.course_name })
        == ["Elapsed", "Blocked", "Transitively blocked"]
      assert schedule_module_names_on(preview, today) == ["Current"]
    },
  )
}

pub fn completing_non_today_module_rebuilds_and_unblocks_future_work_test() {
  with_isolated_store(
    "completing_non_today_module_rebuilds_and_unblocks_future_work",
    fn(_, _) {
      let today = date.today()
      let tomorrow = date.day_after(today)
      let day_after_tomorrow = date.day_after(tomorrow)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Foundations",
          deadline: tomorrow,
          prerequisites: [],
          modules: model.ExplicitModules(["Today", "Tomorrow"]),
        ))
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Advanced",
          deadline: day_after_tomorrow,
          prerequisites: ["Foundations"],
          modules: model.ExplicitModules(["Blocked"]),
        ))

      let foundations = course_named("Vendor", "Foundations")
      let assert [today_module, tomorrow_module] = foundations.modules

      let assert Ok(Nil) = store.set_module_completed(today_module.id, True)
      let assert Ok(Nil) = store.set_module_completed(tomorrow_module.id, True)

      let rebuilt = bootstrap_for(today)
      assert schedule_module_names_on(rebuilt, today) == ["Blocked"]
      assert schedule_module_names_on(rebuilt, tomorrow) == []
      assert schedule_module_names_on(rebuilt, day_after_tomorrow) == []

      let updated_advanced = course_named("Vendor", "Advanced")
      let assert [blocked_module] = updated_advanced.modules
      assert blocked_module.scheduled_date == Some(today)
    },
  )
}

pub fn day_rollover_keeps_future_schedule_when_past_work_is_done_test() {
  with_isolated_store("day_rollover_keeps_future_schedule", fn(_, _) {
    let today = date.today()
    let tomorrow = date.day_after(today)

    let vendor = seed_weekend_vendor()
    let assert Ok(Nil) =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Foundations",
        deadline: tomorrow,
        prerequisites: [],
        modules: model.ExplicitModules(["Today", "Tomorrow"]),
      ))

    let foundations = course_named("Vendor", "Foundations")
    let assert [today_module, ..] = foundations.modules
    let assert Ok(Nil) = store.set_module_completed(today_module.id, True)

    let blank_today = bootstrap_for(today)
    assert schedule_module_names_on(blank_today, today) == []
    assert schedule_module_names_on(blank_today, tomorrow) == ["Tomorrow"]
    let saved_schedule = stored_schedule_rows()

    let assert Ok(connection) = sqlight.open(store.database_path())
    let stale_date = date.to_iso(date.day_before(today))
    let assert Ok(_) = sqlight.exec("
        update modules
        set completed_at = '" <> stale_date <> "'
        where id = " <> int.to_string(today_module.id) <> ";

        update app_settings
        set schedule_generated_for = '" <> stale_date <> "'
        where id = 1
        ", on: connection)
    let assert Ok(_) = sqlight.close(connection)

    let rolled_forward = bootstrap_for(today)
    assert schedule_module_names_on(rolled_forward, today) == []
    assert schedule_module_names_on(rolled_forward, tomorrow) == ["Tomorrow"]
    assert stored_schedule_rows() == saved_schedule
    assert stored_schedule_generated_for() == Some(date.to_iso(today))

    // Starting the server after the next rollover follows the same path.
    let assert Ok(connection) = sqlight.open(store.database_path())
    let assert Ok(_) = sqlight.exec("
        update app_settings
        set schedule_generated_for = '" <> stale_date <> "'
        where id = 1
        ", on: connection)
    let assert Ok(_) = sqlight.close(connection)

    let assert Ok(Nil) = store.initialise()
    assert stored_schedule_rows() == saved_schedule
    assert stored_schedule_generated_for() == Some(date.to_iso(today))
  })
}

pub fn day_rollover_rebuilds_when_past_work_is_unfinished_test() {
  with_isolated_store("day_rollover_rebuilds_overdue_work", fn(_, _) {
    let today = date.today()
    let yesterday = date.day_before(today)
    let tomorrow = date.day_after(today)

    let vendor = seed_weekend_vendor()
    let assert Ok(Nil) =
      store.create_course(model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Catch up",
        deadline: tomorrow,
        prerequisites: [],
        modules: model.ExplicitModules(["Overdue", "Tomorrow"]),
      ))

    let course = course_named("Vendor", "Catch up")
    let assert [overdue, future] = course.modules
    let assert Ok(connection) = sqlight.open(store.database_path())
    let yesterday_iso = date.to_iso(yesterday)
    let assert Ok(_) = sqlight.exec("
        update schedule_entries
        set scheduled_date = '" <> yesterday_iso <> "'
        where module_id = " <> int.to_string(overdue.id) <> ";

        update app_settings
        set schedule_generated_for = '" <> yesterday_iso <> "'
        where id = 1
        ", on: connection)
    let assert Ok(_) = sqlight.close(connection)

    let rebuilt = bootstrap_for(today)
    assert schedule_module_names_on(rebuilt, today) == ["Overdue"]
    assert schedule_module_names_on(rebuilt, tomorrow) == ["Tomorrow"]
    assert stored_schedule_rows()
      == [
        #(overdue.id, date.to_iso(today), 0),
        #(future.id, date.to_iso(tomorrow), 0),
      ]
  })
}

pub fn current_day_completion_after_rollover_keeps_future_schedule_test() {
  with_isolated_store(
    "completion_after_rollover_keeps_future_schedule",
    fn(_, _) {
      let today = date.today()
      let tomorrow = date.day_after(today)
      let yesterday_iso = date.to_iso(date.day_before(today))

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Three days",
          deadline: date.day_after(tomorrow),
          prerequisites: [],
          modules: model.ExplicitModules(["Past", "Today", "Future"]),
        ))

      let course = course_named("Vendor", "Three days")
      let assert [past, current, future] = course.modules
      let assert Ok(Nil) = store.set_module_completed(past.id, True)

      // Move the saved plan over midnight without asking the scheduler to run.
      let assert Ok(connection) = sqlight.open(store.database_path())
      let assert Ok(_) = sqlight.exec("
        update modules
        set completed_at = '" <> yesterday_iso <> "'
        where id = " <> int.to_string(past.id) <> ";

        update schedule_entries
        set scheduled_date = date(scheduled_date, '-1 day');

        update app_settings
        set schedule_generated_for = '" <> yesterday_iso <> "'
        where id = 1
        ", on: connection)
      let assert Ok(_) = sqlight.close(connection)

      let assert Ok(Nil) = store.set_module_completed(current.id, True)

      assert stored_schedule_rows() == [#(future.id, date.to_iso(tomorrow), 0)]
      assert stored_schedule_generated_for() == Some(date.to_iso(today))
    },
  )
}

pub fn cached_bootstrap_returns_conflicts_from_the_rebuild_test() {
  with_isolated_store(
    "cached_bootstrap_returns_conflicts_from_the_rebuild",
    fn(_, _) {
      let today = date.today()
      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Impossible",
          deadline: date.day_before(today),
          prerequisites: [],
          modules: model.ExplicitModules(["Late"]),
        ))

      // A missing marker is an untrusted cache, so the next bootstrap rebuilds
      // it and the one after that is served from the cache.
      let assert Ok(connection) = sqlight.open(store.database_path())
      let assert Ok(_) =
        sqlight.exec(
          "
        update app_settings
        set schedule_generated_for = null
        where id = 1
        ",
          on: connection,
        )
      let assert Ok(_) = sqlight.close(connection)

      let rebuilt = bootstrap_for(today)
      let cached = bootstrap_for(today)

      let assert [conflict] = rebuilt.conflicts
      assert conflict.vendor_name == "Vendor"
      assert conflict.course_name == "Impossible"
      assert cached.conflicts == rebuilt.conflicts
    },
  )
}

pub fn prolog_bootstrap_reuses_cached_solver_response_test() {
  with_isolated_store(
    "prolog_bootstrap_reuses_cached_solver_response",
    fn(_, _) {
      let today = date.today()
      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Cached",
          deadline: date.add_days(today, 5),
          prerequisites: [],
          modules: model.ExplicitModules(["Only"]),
        ))

      let assert Ok(first) =
        store.bootstrap_with_scheduler(
          "week",
          today,
          Some(today),
          model.PrologScheduler,
        )
      assert schedule_module_names_on(first, today) == ["Only"]

      let assert Ok(second) =
        store.bootstrap_with_scheduler(
          "week",
          today,
          Some(today),
          model.PrologScheduler,
        )
      assert second == first

      // The first call must have populated the cache. Tamper with the cached
      // response: if the next bootstrap reflects the tampered payload it was
      // served from the cache rather than from another solver run.
      let assert Ok(connection) = sqlight.open(store.database_path())
      let count_decoder = decode.field(0, decode.int, decode.success)
      let assert Ok([1]) =
        sqlight.query(
          "select count(*) from prolog_cache where id = 1",
          on: connection,
          with: [],
          expecting: count_decoder,
        )
      let assert Ok(_) =
        sqlight.exec(
          "update prolog_cache
           set response = '{\"entries\":[],\"conflicts\":[]}'",
          on: connection,
        )
      let assert Ok(_) = sqlight.close(connection)

      let assert Ok(tampered) =
        store.bootstrap_with_scheduler(
          "week",
          today,
          Some(today),
          model.PrologScheduler,
        )
      assert schedule_module_names_on(tampered, today) == []
    },
  )
}

pub fn bootstrap_can_preview_schedule_from_custom_start_without_persisting_test() {
  with_isolated_store(
    "bootstrap_can_preview_schedule_from_custom_start_without_persisting",
    fn(_, _) {
      let today = date.today()
      let simulated_start = date.day_after(today)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Preview",
          deadline: date.add_days(today, 5),
          prerequisites: [],
          modules: model.ExplicitModules(["Only"]),
        ))

      let persisted_before = course_named("Vendor", "Preview")
      let assert [persisted_module_before] = persisted_before.modules
      assert persisted_module_before.scheduled_date == Some(today)

      let assert Ok(preview) =
        store.bootstrap_with_scheduler(
          "week",
          simulated_start,
          Some(simulated_start),
          model.GleamScheduler,
        )
      assert preview.today == today
      assert preview.schedule_start == simulated_start
      let assert Ok(preview_vendor) =
        list.find(preview.vendors, fn(vendor) { vendor.name == "Vendor" })
      let assert Ok(preview_course) =
        list.find(preview_vendor.courses, fn(course) {
          course.name == "Preview"
        })
      let assert [preview_module] = preview_course.modules
      assert preview_module.scheduled_date == Some(simulated_start)
      assert schedule_module_names_on(preview, simulated_start) == ["Only"]

      let persisted_after = course_named("Vendor", "Preview")
      let assert [persisted_module_after] = persisted_after.modules
      assert persisted_module_after.scheduled_date == Some(today)
    },
  )
}

pub fn prolog_preview_does_not_replace_the_stored_gleam_schedule_test() {
  with_isolated_store(
    "prolog_preview_does_not_replace_stored_gleam_schedule",
    fn(_, _) {
      let today = date.today()
      let simulated_start = date.day_after(today)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Prolog preview",
          deadline: date.add_days(today, 5),
          prerequisites: [],
          modules: model.ExplicitModules(["Only"]),
        ))

      let assert Ok(preview) =
        store.bootstrap_with_scheduler(
          "week",
          simulated_start,
          Some(simulated_start),
          model.PrologScheduler,
        )
      assert schedule_module_names_on(preview, simulated_start) == ["Only"]

      let persisted = course_named("Vendor", "Prolog preview")
      let assert [persisted_module] = persisted.modules
      assert persisted_module.scheduled_date == Some(today)
    },
  )
}

pub fn prolog_custom_start_does_not_replace_live_prolog_schedule_test() {
  with_isolated_store(
    "prolog_custom_start_does_not_replace_live_schedule",
    fn(_, _) {
      let today = date.today()
      let simulated_start = date.day_after(today)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Stable Prolog plan",
          deadline: date.add_days(today, 5),
          prerequisites: [],
          modules: model.ExplicitModules(["First", "Second"]),
        ))

      let assert Ok(_) =
        store.bootstrap_with_scheduler(
          "week",
          today,
          None,
          model.PrologScheduler,
        )
      let saved_schedule = stored_prolog_schedule_rows()

      let assert Ok(preview) =
        store.bootstrap_with_scheduler(
          "week",
          simulated_start,
          Some(simulated_start),
          model.PrologScheduler,
        )
      assert schedule_module_names_on(preview, simulated_start) == ["First"]
      assert stored_prolog_schedule_rows() == saved_schedule
      assert stored_prolog_schedule_generated_for() == Some(date.to_iso(today))
    },
  )
}

pub fn bootstrap_start_query_returns_preview_schedule_test() {
  with_isolated_store(
    "bootstrap_start_query_returns_preview_schedule",
    fn(_, _) {
      let today = date.today()
      let simulated_start = date.day_after(today)
      let start_iso = date.to_iso(simulated_start)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Preview",
          deadline: date.add_days(today, 5),
          prerequisites: [],
          modules: model.ExplicitModules(["Only"]),
        ))

      let response =
        web.handle(
          simulate.request(
            http.Get,
            "/api/bootstrap?view=week&anchor="
              <> start_iso
              <> "&start="
              <> start_iso,
          ),
          "priv",
        )

      assert response.status == 200
      assert http_response.get_header(response, "cache-control")
        == Ok("no-store")
      let body = simulate.read_body(response)
      assert string.contains(body, "\"schedule_start\":\"" <> start_iso <> "\"")
      assert string.contains(body, "\"scheduled_date\":\"" <> start_iso <> "\"")
    },
  )
}

pub fn bootstrap_prolog_scheduler_query_returns_preview_test() {
  with_isolated_store(
    "bootstrap_prolog_scheduler_query_returns_preview",
    fn(_, _) {
      let today = date.today()
      let today_iso = date.to_iso(today)

      let vendor = seed_weekend_vendor()
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Prolog Preview",
          deadline: date.add_days(today, 5),
          prerequisites: [],
          modules: model.ExplicitModules(["Only"]),
        ))

      let response =
        web.handle(
          simulate.request(
            http.Get,
            "/api/bootstrap?view=week&anchor="
              <> today_iso
              <> "&scheduler=prolog",
          ),
          "priv",
        )

      assert response.status == 200
      let body = simulate.read_body(response)
      assert string.contains(body, "Prolog Preview")
      assert string.contains(body, "\"scheduled_date\":\"" <> today_iso <> "\"")

      let schedule_response =
        web.handle(
          simulate.request(
            http.Get,
            "/api/schedule?view=week&anchor="
              <> today_iso
              <> "&scheduler=prolog",
          ),
          "priv",
        )
      assert schedule_response.status == 200
      assert string.contains(
        simulate.read_body(schedule_response),
        "Prolog Preview",
      )
    },
  )
}

pub fn bootstrap_start_query_rejects_invalid_dates_test() {
  with_isolated_store("bootstrap_start_query_rejects_invalid_dates", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let response =
      web.handle(
        simulate.request(http.Get, "/api/bootstrap?start=not-a-date"),
        "priv",
      )

    assert response.status == 400
    assert string.contains(
      simulate.read_body(response),
      "Start date must be a YYYY-MM-DD date",
    )
  })
}

pub fn patch_settings_preserves_deadline_slack_days_when_omitted_test() {
  with_isolated_store(
    "patch_settings_preserves_deadline_slack_days_when_omitted",
    fn(_, _) {
      let assert Ok(Nil) = store.initialise()

      let baseline_request =
        simulate.request(http.Patch, "/api/settings")
        |> simulate.json_body(
          json.object([
            #("include_weekends", json.bool(False)),
            #("deadline_slack_days", json.int(3)),
          ]),
        )
      let baseline_response = web.handle(baseline_request, "priv")
      assert baseline_response.status == 200

      let request =
        simulate.request(http.Patch, "/api/settings")
        |> simulate.json_body(
          json.object([#("include_weekends", json.bool(True))]),
        )
      let response = web.handle(request, "priv")

      assert response.status == 200
      let settings = bootstrap_data().settings
      assert settings.include_weekends == True
      assert settings.deadline_slack_days == 3
    },
  )
}

pub fn patch_settings_preserves_include_weekends_when_omitted_test() {
  with_isolated_store(
    "patch_settings_preserves_include_weekends_when_omitted",
    fn(_, _) {
      let assert Ok(Nil) = store.initialise()

      let baseline_request =
        simulate.request(http.Patch, "/api/settings")
        |> simulate.json_body(
          json.object([
            #("include_weekends", json.bool(True)),
            #("deadline_slack_days", json.int(1)),
          ]),
        )
      let baseline_response = web.handle(baseline_request, "priv")
      assert baseline_response.status == 200

      let request =
        simulate.request(http.Patch, "/api/settings")
        |> simulate.json_body(
          json.object([#("deadline_slack_days", json.int(4))]),
        )
      let response = web.handle(request, "priv")

      assert response.status == 200
      let settings = bootstrap_data().settings
      assert settings.include_weekends == True
      assert settings.deadline_slack_days == 4
    },
  )
}

pub fn patch_settings_rejects_empty_payload_test() {
  with_isolated_store("patch_settings_rejects_empty_payload", fn(_, _) {
    let assert Ok(Nil) = store.initialise()

    let request =
      simulate.request(http.Patch, "/api/settings")
      |> simulate.json_body(json.object([]))
    let response = web.handle(request, "priv")

    assert response.status == 400
    assert string.contains(
      simulate.read_body(response),
      "Settings patch must include at least one updatable field",
    )
  })
}

pub fn patch_course_preserves_previous_name_when_updating_deadline_test() {
  with_isolated_store(
    "patch_course_preserves_previous_name_when_updating_deadline",
    fn(_, _) {
      let assert Ok(Nil) = store.initialise()
      let course =
        seed_course(
          vendor_name: "Vendor",
          course_name: "Original",
          modules: model.ExplicitModules(["Only module"]),
        )

      let rename_request =
        simulate.request(
          http.Patch,
          "/api/courses/" <> int.to_string(course.id),
        )
        |> simulate.json_body(json.object([#("name", json.string("Renamed"))]))
      let rename_response = web.handle(rename_request, "priv")
      assert rename_response.status == 200

      let deadline_request =
        simulate.request(
          http.Patch,
          "/api/courses/" <> int.to_string(course.id),
        )
        |> simulate.json_body(
          json.object([#("deadline_date", json.string("2026-05-15"))]),
        )
      let deadline_response = web.handle(deadline_request, "priv")
      assert deadline_response.status == 200

      let updated = course_by_id(course.id)
      assert updated.name == "Renamed"
      assert updated.deadline == calendar.Date(2026, calendar.May, 15)
      assert updated.prerequisites == []
    },
  )
}

pub fn patch_course_prerequisites_preserve_name_and_deadline_test() {
  with_isolated_store(
    "patch_course_prerequisites_preserve_name_and_deadline",
    fn(_, _) {
      let assert Ok(Nil) = store.initialise()
      let assert Ok(Nil) = store.create_vendor("Vendor")
      let vendor = vendor_named("Vendor")

      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Intro",
          deadline: calendar.Date(2026, calendar.April, 10),
          prerequisites: [],
          modules: model.ExplicitModules(["Intro 1"]),
        ))
      let assert Ok(Nil) =
        store.create_course(model.NewCourseInput(
          vendor_id: vendor.id,
          name: "Main",
          deadline: calendar.Date(2026, calendar.April, 30),
          prerequisites: [],
          modules: model.ExplicitModules(["Main 1"]),
        ))
      let course = course_named("Vendor", "Main")

      let request =
        simulate.request(
          http.Patch,
          "/api/courses/" <> int.to_string(course.id),
        )
        |> simulate.json_body(
          json.object([
            #("prerequisites", json.array(from: ["Intro"], of: json.string)),
          ]),
        )
      let response = web.handle(request, "priv")

      assert response.status == 200
      let updated = course_by_id(course.id)
      assert updated.name == "Main"
      assert updated.deadline == calendar.Date(2026, calendar.April, 30)
      assert updated.prerequisites == ["Intro"]
    },
  )
}

pub fn patch_course_rejects_empty_payload_test() {
  with_isolated_store("patch_course_rejects_empty_payload", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Validation",
        modules: model.ExplicitModules(["Only module"]),
      )

    let request =
      simulate.request(http.Patch, "/api/courses/" <> int.to_string(course.id))
      |> simulate.json_body(json.object([]))
    let response = web.handle(request, "priv")

    assert response.status == 400
    assert string.contains(
      simulate.read_body(response),
      "Course patch must include at least one updatable field",
    )
  })
}

pub fn patch_module_position_uses_api_numbering_test() {
  with_isolated_store("patch_module_position_uses_api_numbering", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Positions",
        modules: model.ExplicitModules(["One", "Two", "Three"]),
      )
    let assert [first, _, third] = course.modules

    let keep_last_request =
      simulate.request(http.Patch, "/api/modules/" <> int.to_string(third.id))
      |> simulate.json_body(
        json.object([#("position", json.int(third.position))]),
      )
    let keep_last_response = web.handle(keep_last_request, "priv")

    assert keep_last_response.status == 200
    assert module_names(course_named("Vendor", "Positions").modules)
      == [
        "One",
        "Two",
        "Three",
      ]

    let move_to_last_request =
      simulate.request(http.Patch, "/api/modules/" <> int.to_string(first.id))
      |> simulate.json_body(
        json.object([#("position", json.int(third.position))]),
      )
    let move_to_last_response = web.handle(move_to_last_request, "priv")

    assert move_to_last_response.status == 200
    assert module_names(course_named("Vendor", "Positions").modules)
      == [
        "Two",
        "Three",
        "One",
      ]
  })
}

pub fn patch_module_rejects_empty_payload_test() {
  with_isolated_store("patch_module_rejects_empty_payload", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Validation",
        modules: model.ExplicitModules(["Only module"]),
      )
    let assert [module] = course.modules

    let request =
      simulate.request(http.Patch, "/api/modules/" <> int.to_string(module.id))
      |> simulate.json_body(json.object([]))
    let response = web.handle(request, "priv")

    assert response.status == 400
    assert string.contains(
      simulate.read_body(response),
      "Module patch must include at least one updatable field",
    )
  })
}

pub fn reorder_modules_persists_requested_order_test() {
  with_isolated_store("reorder_modules_persists_requested_order", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Reorder",
        modules: model.ExplicitModules(["One", "Two", "Three"]),
      )
    let assert [one, two, three] = course.modules

    let assert Ok(Nil) =
      store.reorder_modules(course.id, [three.id, one.id, two.id])

    let reordered = course_named("Vendor", "Reorder")
    assert module_names(reordered.modules) == ["Three", "One", "Two"]
    assert module_positions(reordered.modules) == [1, 2, 3]
  })
}

pub fn set_module_position_clears_generated_range_snapshot_test() {
  with_isolated_store(
    "set_module_position_clears_generated_range_snapshot",
    fn(db_path, toml_path) {
      let assert Ok(Nil) = store.initialise()
      let course =
        seed_course(
          vendor_name: "Vendor",
          course_name: "Generated",
          modules: model.GeneratedRange(model.ModuleRange(
            prefix: "Module ",
            start: 1,
            end: 3,
          )),
        )
      let assert [_, _, third] = course.modules

      let assert Ok(Nil) = store.set_module_position(third.id, 1)

      let reordered = course_named("Vendor", "Generated")
      assert reordered.module_range == None
      assert module_names(reordered.modules)
        == ["Module 3", "Module 1", "Module 2"]
      assert module_positions(reordered.modules) == [1, 2, 3]

      let assert Ok(snapshot) = simplifile.read(toml_path)
      assert string.contains(
        snapshot,
        "modules = [ \"Module 3\", \"Module 1\", \"Module 2\" ]",
      )
      assert string.contains(snapshot, "module_range =") == False

      let _ = simplifile.delete(db_path)
      let assert Ok(Nil) = store.initialise()

      let imported = course_named("Vendor", "Generated")
      assert imported.module_range == None
      assert module_names(imported.modules)
        == ["Module 3", "Module 1", "Module 2"]
      assert module_positions(imported.modules) == [1, 2, 3]
    },
  )
}

pub fn initialise_succeeds_when_snapshot_export_path_is_invalid_test() {
  let base = "/tmp/initialise_snapshot_export_path_invalid"
  let db_path = base <> "/aliahan.sqlite3"
  let toml_path = base <> "/missing/courses.toml"

  let _ = simplifile.delete(base)
  let assert Ok(Nil) = simplifile.create_directory_all(base)

  with_store_path_env(Some(db_path), Some(toml_path), fn() {
    let assert Ok(Nil) = store.initialise()
    let data = bootstrap_data()
    assert data.vendors == []
  })

  let _ = simplifile.delete(base)
}

pub fn initialise_migrates_existing_store_for_live_prolog_schedule_test() {
  with_isolated_store("migrate_live_prolog_schedule", fn(_, _) {
    let assert Ok(connection) = sqlight.open(store.database_path())
    let assert Ok(_) =
      sqlight.exec(
        "
      create table app_settings (
        id integer primary key,
        include_weekends integer not null,
        deadline_slack_days integer not null default 0,
        schedule_generated_for text
      );

      insert into app_settings (
        id,
        include_weekends,
        deadline_slack_days,
        schedule_generated_for
      ) values (1, 1, 3, null);
      ",
        on: connection,
      )
    let assert Ok(_) = sqlight.close(connection)

    let assert Ok(Nil) = store.initialise()
    let data = bootstrap_data()
    assert data.settings.include_weekends == True
    assert data.settings.deadline_slack_days == 3

    let assert Ok(connection) = sqlight.open(store.database_path())
    let count_decoder = decode.field(0, decode.int, decode.success)
    let assert Ok([0]) =
      sqlight.query(
        "select count(*) from prolog_schedule_entries",
        on: connection,
        with: [],
        expecting: count_decoder,
      )
    let assert Ok([0]) =
      sqlight.query(
        "select count(*) from prolog_schedule_conflicts",
        on: connection,
        with: [],
        expecting: count_decoder,
      )
    let assert Ok([None]) =
      sqlight.query(
        "
        select prolog_schedule_generated_for
        from app_settings
        where id = 1
        ",
        on: connection,
        with: [],
        expecting: decode.field(
          0,
          decode.optional(decode.string),
          decode.success,
        ),
      )
    let assert Ok(_) = sqlight.close(connection)
    Nil
  })
}

pub fn mutation_succeeds_when_snapshot_export_path_is_invalid_test() {
  let base = "/tmp/mutation_snapshot_export_path_invalid"
  let db_path = base <> "/aliahan.sqlite3"
  let toml_path = base <> "/missing/courses.toml"

  let _ = simplifile.delete(base)
  let assert Ok(Nil) = simplifile.create_directory_all(base)

  with_store_path_env(Some(db_path), Some(toml_path), fn() {
    let assert Ok(Nil) = store.initialise()
    let assert Ok(Nil) = store.create_vendor("Vendor")
    let vendor = vendor_named("Vendor")
    assert vendor.name == "Vendor"
  })

  let _ = simplifile.delete(base)
}

pub fn courses_toml_path_defaults_without_overrides_test() {
  let path = with_store_path_env(None, None, fn() { store.courses_toml_path() })
  assert path == "courses.toml"
}

pub fn database_path_ignores_empty_override_test() {
  let path = with_store_path_env(Some(""), None, fn() { store.database_path() })
  assert path == "aliahan.sqlite3"
}

pub fn courses_toml_path_follows_database_override_test() {
  let path =
    with_store_path_env(Some("/tmp/aliahan-alt.sqlite3"), None, fn() {
      store.courses_toml_path()
    })

  assert path == "/tmp/aliahan-alt.courses.toml"
}

pub fn courses_toml_path_preserves_legacy_name_for_default_database_override_test() {
  let path =
    with_store_path_env(Some("aliahan.sqlite3"), None, fn() {
      store.courses_toml_path()
    })

  assert path == "courses.toml"
}

pub fn courses_toml_path_ignores_empty_override_and_uses_database_override_test() {
  let path =
    with_store_path_env(Some("/tmp/aliahan-alt.sqlite3"), Some(""), fn() {
      store.courses_toml_path()
    })

  assert path == "/tmp/aliahan-alt.courses.toml"
}

pub fn courses_toml_path_explicit_override_wins_test() {
  let path =
    with_store_path_env(
      Some("/tmp/aliahan-alt.sqlite3"),
      Some("/tmp/custom-courses.toml"),
      fn() { store.courses_toml_path() },
    )

  assert path == "/tmp/custom-courses.toml"
}

fn course(
  id id: Int,
  vendor_name vendor_name: String,
  name name: String,
  deadline deadline: calendar.Date,
  prerequisite_ids prerequisite_ids: List(Int),
  prerequisites prerequisites: List(String),
  modules modules: List(model.Module),
) -> model.Course {
  model.Course(
    id: id,
    vendor_id: 1,
    vendor_name: vendor_name,
    name: name,
    deadline: deadline,
    prerequisites: prerequisites,
    prerequisite_ids: prerequisite_ids,
    module_range: None,
    modules: modules,
  )
}

fn module(
  id id: Int,
  course_id course_id: Int,
  position position: Int,
  name name: String,
) -> model.Module {
  model.Module(
    id: id,
    course_id: course_id,
    position: position,
    name: name,
    completed_at: None,
    scheduled_date: None,
    slot_index: None,
  )
}

fn with_isolated_store(name: String, run: fn(String, String) -> Nil) -> Nil {
  let base = "/tmp/" <> name
  let db_path = base <> "/aliahan.sqlite3"
  let toml_path = base <> "/courses.toml"

  let _ = simplifile.delete(base)
  let assert Ok(Nil) = simplifile.create_directory_all(base)
  env.set(store.database_path_env_var, db_path)
  env.set(store.courses_toml_path_env_var, toml_path)

  run(db_path, toml_path)

  env.unset(store.database_path_env_var)
  env.unset(store.courses_toml_path_env_var)
  let _ = simplifile.delete(base)
  Nil
}

fn with_store_path_env(
  database_path: Option(String),
  toml_path: Option(String),
  run: fn() -> a,
) -> a {
  let previous_database_path = env.get(store.database_path_env_var)
  let previous_toml_path = env.get(store.courses_toml_path_env_var)

  set_optional_env(store.database_path_env_var, database_path)
  set_optional_env(store.courses_toml_path_env_var, toml_path)

  let result = run()

  restore_env(store.database_path_env_var, previous_database_path)
  restore_env(store.courses_toml_path_env_var, previous_toml_path)
  result
}

fn set_optional_env(name: String, value: Option(String)) -> Nil {
  case value {
    Some(path) -> env.set(name, path)
    None -> env.unset(name)
  }
}

fn restore_env(name: String, value: Result(String, Nil)) -> Nil {
  case value {
    Ok(path) -> env.set(name, path)
    Error(_) -> env.unset(name)
  }
}

/// Initialises the store with weekend scheduling enabled and a vendor named
/// "Vendor" — the shared starting point for the schedule and Prolog tests.
fn seed_weekend_vendor() -> model.Vendor {
  let assert Ok(Nil) = store.initialise()
  let assert Ok(Nil) =
    store.set_settings(model.SettingsPatch(
      include_weekends: Some(True),
      deadline_slack_days: None,
    ))
  let assert Ok(Nil) = store.create_vendor("Vendor")
  vendor_named("Vendor")
}

fn seed_course(
  vendor_name vendor_name: String,
  course_name course_name: String,
  modules modules: model.CourseModulesInput,
) -> model.Course {
  let assert Ok(Nil) = store.create_vendor(vendor_name)
  let vendor = vendor_named(vendor_name)

  let assert Ok(Nil) =
    store.create_course(model.NewCourseInput(
      vendor_id: vendor.id,
      name: course_name,
      deadline: calendar.Date(2026, calendar.April, 30),
      prerequisites: [],
      modules: modules,
    ))

  course_named(vendor_name, course_name)
}

fn bootstrap_data() -> model.BootstrapData {
  let assert Ok(data) =
    store.bootstrap_with_scheduler(
      "week",
      calendar.Date(2026, calendar.March, 19),
      None,
      model.GleamScheduler,
    )
  data
}

fn bootstrap_for(anchor: calendar.Date) -> model.BootstrapData {
  let assert Ok(data) =
    store.bootstrap_with_scheduler("month", anchor, None, model.GleamScheduler)
  data
}

fn vendor_named(vendor_name: String) -> model.Vendor {
  let data = bootstrap_data()
  let assert Ok(vendor) =
    list.find(data.vendors, fn(vendor) { vendor.name == vendor_name })
  vendor
}

fn course_named(vendor_name: String, course_name: String) -> model.Course {
  let vendor = vendor_named(vendor_name)
  let assert Ok(course) =
    list.find(vendor.courses, fn(course) { course.name == course_name })
  course
}

fn course_by_id(course_id: Int) -> model.Course {
  let data = bootstrap_data()
  let vendors = data.vendors
  let courses =
    vendors
    |> list.fold([], fn(acc, vendor) { list.append(vendor.courses, acc) })
  let assert Ok(course) =
    list.find(courses, fn(course) { course.id == course_id })
  course
}

fn module_names(modules: List(model.Module)) -> List(String) {
  modules |> list.map(fn(module) { module.name })
}

fn module_positions(modules: List(model.Module)) -> List(Int) {
  modules |> list.map(fn(module) { module.position })
}

fn schedule_module_names_on(
  data: model.BootstrapData,
  day: calendar.Date,
) -> List(String) {
  data.vendors
  |> list.flat_map(fn(vendor) { vendor.courses })
  |> list.flat_map(fn(course) { course.modules })
  |> list.filter(fn(module) {
    module.scheduled_date == Some(day) && module.completed_at == None
  })
  |> list.sort(fn(left, right) {
    int.compare(left.slot_index |> option_int, right.slot_index |> option_int)
  })
  |> list.map(fn(module) { module.name })
}

fn stored_schedule_rows() -> List(#(Int, String, Int)) {
  let assert Ok(connection) = sqlight.open(store.database_path())
  let decoder = {
    use module_id <- decode.field(0, decode.int)
    use scheduled_date <- decode.field(1, decode.string)
    use slot_index <- decode.field(2, decode.int)
    decode.success(#(module_id, scheduled_date, slot_index))
  }
  let assert Ok(rows) =
    sqlight.query(
      "
        select module_id, scheduled_date, slot_index
        from schedule_entries
        order by scheduled_date, slot_index, module_id
        ",
      on: connection,
      with: [],
      expecting: decoder,
    )
  let assert Ok(_) = sqlight.close(connection)
  rows
}

fn stored_prolog_schedule_rows() -> List(#(Int, String, Int)) {
  let assert Ok(connection) = sqlight.open(store.database_path())
  let decoder = {
    use module_id <- decode.field(0, decode.int)
    use scheduled_date <- decode.field(1, decode.string)
    use slot_index <- decode.field(2, decode.int)
    decode.success(#(module_id, scheduled_date, slot_index))
  }
  let assert Ok(rows) =
    sqlight.query(
      "
        select module_id, scheduled_date, slot_index
        from prolog_schedule_entries
        order by scheduled_date, slot_index, module_id
        ",
      on: connection,
      with: [],
      expecting: decoder,
    )
  let assert Ok(_) = sqlight.close(connection)
  rows
}

fn stored_schedule_generated_for() -> Option(String) {
  let assert Ok(connection) = sqlight.open(store.database_path())
  let decoder = decode.field(0, decode.optional(decode.string), decode.success)
  let assert Ok([generated_for]) =
    sqlight.query(
      "select schedule_generated_for from app_settings where id = 1",
      on: connection,
      with: [],
      expecting: decoder,
    )
  let assert Ok(_) = sqlight.close(connection)
  generated_for
}

fn stored_prolog_schedule_generated_for() -> Option(String) {
  let assert Ok(connection) = sqlight.open(store.database_path())
  let decoder = decode.field(0, decode.optional(decode.string), decode.success)
  let assert Ok([generated_for]) =
    sqlight.query(
      "
      select prolog_schedule_generated_for
      from app_settings
      where id = 1
      ",
      on: connection,
      with: [],
      expecting: decoder,
    )
  let assert Ok(_) = sqlight.close(connection)
  generated_for
}

fn option_int(value: Option(Int)) -> Int {
  case value {
    Some(value) -> value
    None -> 0
  }
}
