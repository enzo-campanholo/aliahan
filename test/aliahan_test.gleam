import aliahan/config
import aliahan/date
import aliahan/model
import aliahan/scheduler
import gleam/list
import gleam/option.{None}
import gleam/order.{Lt}
import gleam/time/calendar
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_courses_toml_supports_generated_ranges_test() {
  let toml = "
  [\"Vendor\".\"Generated\"]
  module_range = { prefix = \"Module \", start = 2, end = 4 }
  deadline = 2026-04-01T23:59:59-03:00
  "

  let assert Ok([course]) = config.parse_courses_toml(toml)
  assert course.vendor_name == "Vendor"
  assert course.course_name == "Generated"
  assert course.prerequisites == []
  assert course.deadline == calendar.Date(2026, calendar.April, 1)
  assert course.modules == model.GeneratedRange(
    model.ModuleRange(prefix: "Module ", start: 2, end: 4),
  )
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
  let assert [loose_first, .._] = loose_entries
  assert date.compare(loose_first.scheduled_date, tight_last.scheduled_date) == Lt
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
  let assert [first, second] = entries
  assert first.scheduled_date == today
  assert second.scheduled_date == calendar.Date(2026, calendar.March, 20)
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
