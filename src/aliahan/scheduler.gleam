import aliahan/date
import aliahan/model as model
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result
import gleam/string
import gleam/time/calendar

type PlannedCourse {
  PlannedCourse(
    course: model.Course,
    effective_deadline: calendar.Date,
    remaining: List(model.Module),
  )
}

type CandidateCourse {
  CandidateCourse(
    plan: PlannedCourse,
    earliest_start: calendar.Date,
    allowed_days: List(calendar.Date),
    preferred_day_count: Int,
    slack: Int,
  )
}

pub type StoredEntry {
  StoredEntry(module_id: Int, scheduled_date: calendar.Date, slot_index: Int)
}

type Placement {
  Placement(module_id: Int, scheduled_date: calendar.Date)
}

type CourseContext {
  CourseContext(
    course: model.Course,
    effective_deadline: calendar.Date,
    preferred_deadline: calendar.Date,
    module_ids: List(Int),
  )
}

type ModuleContext {
  ModuleContext(
    module_id: Int,
    course_id: Int,
    vendor_name: String,
    course_name: String,
    module_name: String,
    position: Int,
  )
}

type ScheduleContext {
  ScheduleContext(
    course_contexts: List(CourseContext),
    courses_by_id: dict.Dict(Int, CourseContext),
    module_contexts_by_id: dict.Dict(Int, ModuleContext),
    dependents: dict.Dict(Int, List(Int)),
    settings: model.Settings,
    today: calendar.Date,
  )
}

type Gap {
  Gap(left_date: calendar.Date, right_date: calendar.Date, gap_size: Int)
}

type CandidateMove {
  CandidateMove(module_id: Int, target_date: calendar.Date)
}

type ScheduleScore {
  ScheduleScore(
    idle_overflow: Int,
    activity_penalty: Int,
    preferred_overflow: Int,
  )
}

type ScoredMove {
  ScoredMove(move: CandidateMove, score: ScheduleScore)
}

const max_idle_gap = 2

pub fn validate_no_cycles(
  courses: List(model.Course),
) -> Result(Nil, model.AppError) {
  let active_ids = unfinished_course_ids(courses)
  list.try_fold(active_ids, dict.new(), fn(states, course_id) {
    visit(course_id, courses, states)
  })
  |> result.map(fn(_) { Nil })
}

pub fn rebuild(
  courses: List(model.Course),
  settings: model.Settings,
  today: calendar.Date,
) -> Result(
  #(List(StoredEntry), List(model.Conflict), List(model.ScheduleEntry)),
  model.AppError,
) {
  case validate_no_cycles(courses) {
    Error(error) -> Error(error)
    Ok(_) -> {
      use effective_deadlines <- result.try(
        compute_effective_deadlines(
          courses |> list.filter(fn(course) { remaining_modules(course) != [] }),
        ),
      )

      let completed_ids = completed_course_ids(courses)
      let active_courses =
        courses
        |> list.filter(fn(course) { remaining_modules(course) != [] })
        |> list.map(fn(course) {
          let assert Ok(effective_deadline) =
            dict.get(effective_deadlines, course.id)
          PlannedCourse(
            course: course,
            effective_deadline: effective_deadline,
            remaining: remaining_modules(course),
          )
        })

      let finished_dates =
        completed_ids
        |> list.fold(dict.new(), fn(acc, course_id) {
          dict.insert(acc, course_id, date.day_before(today))
        })

      let #(stored_entries, conflicts, _) =
        schedule_courses(
          active_courses,
          settings,
          today,
          finished_dates,
          dict.new(),
          [],
          [],
          [],
        )

      let normalized_entries =
        stored_entries
        |> sort_stored_entries
        |> normalize_schedule(active_courses, settings, today)
      let schedule_entries =
        build_schedule_entries(active_courses, settings, today, normalized_entries)

      Ok(#(
        normalized_entries,
        conflicts,
        schedule_entries |> sort_schedule_entries,
      ))
    }
  }
}

fn schedule_courses(
  planned: List(PlannedCourse),
  settings: model.Settings,
  today: calendar.Date,
  finished_dates: dict.Dict(Int, calendar.Date),
  occupancy: dict.Dict(String, Int),
  stored_entries: List(StoredEntry),
  schedule_entries: List(model.ScheduleEntry),
  conflicts: List(model.Conflict),
) -> #(List(StoredEntry), List(model.Conflict), List(model.ScheduleEntry)) {
  case planned {
    [] -> #(stored_entries, conflicts, schedule_entries)

    _ -> {
      let #(ready, blocked) = split_ready(planned, finished_dates)
      let candidates =
        ready
        |> list.map(fn(plan) {
          build_candidate(plan, finished_dates, settings, today)
        })
      let #(impossible, schedulable) = split_impossible(candidates)
      let conflicts =
        impossible
        |> list.map(fn(candidate) { impossible_conflict(candidate.plan.course) })
        |> list.reverse
        |> list.append(conflicts)

      case schedulable |> list.sort(compare_candidate) {
        [] -> {
          let blocked_conflicts =
            blocked
            |> list.map(fn(plan) { blocked_conflict(plan.course) })
            |> list.reverse
            |> list.append(conflicts)
          #(stored_entries, blocked_conflicts, schedule_entries)
        }

        [selected, ..remaining_candidates] -> {
          let #(next_occupancy, next_stored, next_schedule_entries, finish_date) =
            place_course(
              selected,
              occupancy,
              stored_entries,
              schedule_entries,
            )

          let next_finished = dict.insert(finished_dates, selected.plan.course.id, finish_date)
          let next_planned =
            remaining_candidates
            |> list.map(fn(candidate) { candidate.plan })
            |> list.append(blocked)

          schedule_courses(
            next_planned,
            settings,
            today,
            next_finished,
            next_occupancy,
            next_stored,
            next_schedule_entries,
            conflicts,
          )
        }
      }
    }
  }
}

fn normalize_schedule(
  stored_entries: List(StoredEntry),
  planned: List(PlannedCourse),
  settings: model.Settings,
  today: calendar.Date,
) -> List(StoredEntry) {
  let context = build_schedule_context(planned, settings, today, stored_entries)
  let placements = placements_from_entries(stored_entries)
  let normalized = normalize_loop(context, placements)
  build_stored_entries(context.module_contexts_by_id, normalized)
}

fn build_schedule_entries(
  planned: List(PlannedCourse),
  settings: model.Settings,
  today: calendar.Date,
  stored_entries: List(StoredEntry),
) -> List(model.ScheduleEntry) {
  let context = build_schedule_context(planned, settings, today, stored_entries)
  stored_entries
  |> list.map(fn(entry) {
    let assert Ok(module_context) =
      dict.get(context.module_contexts_by_id, entry.module_id)
    model.ScheduleEntry(
      module_id: entry.module_id,
      vendor_name: module_context.vendor_name,
      course_name: module_context.course_name,
      module_name: module_context.module_name,
      scheduled_date: entry.scheduled_date,
      slot_index: entry.slot_index,
    )
  })
}

fn build_schedule_context(
  planned: List(PlannedCourse),
  settings: model.Settings,
  today: calendar.Date,
  stored_entries: List(StoredEntry),
) -> ScheduleContext {
  let scheduled_module_ids =
    stored_entries |> list.map(fn(entry) { entry.module_id })
  let course_contexts =
    planned
    |> list.fold([], fn(acc, plan) {
      let scheduled_modules =
        plan.remaining
        |> list.filter(fn(module) { list.contains(scheduled_module_ids, module.id) })
      case scheduled_modules {
        [] -> acc
        _ -> [
          CourseContext(
            course: plan.course,
            effective_deadline: plan.effective_deadline,
            preferred_deadline:
              preferred_deadline(plan.effective_deadline, settings.deadline_slack_days),
            module_ids: scheduled_modules |> list.map(fn(module) { module.id }),
          ),
          ..acc
        ]
      }
    })
    |> list.reverse
  let courses_by_id =
    course_contexts
    |> list.fold(dict.new(), fn(acc, course_context) {
      dict.insert(acc, course_context.course.id, course_context)
    })
  let module_contexts_by_id =
    course_contexts
    |> list.fold(dict.new(), fn(acc, course_context) {
      course_context.module_ids
      |> list.fold(acc, fn(inner, module_id) {
        let assert Ok(module) =
          list.find(course_context.course.modules, fn(module) { module.id == module_id })
        dict.insert(
          inner,
          module_id,
          ModuleContext(
            module_id: module.id,
            course_id: course_context.course.id,
            vendor_name: course_context.course.vendor_name,
            course_name: course_context.course.name,
            module_name: module.name,
            position: module.position,
          ),
        )
      })
    })
  ScheduleContext(
    course_contexts: course_contexts,
    courses_by_id: courses_by_id,
    module_contexts_by_id: module_contexts_by_id,
    dependents: build_dependents(course_contexts |> list.map(fn(context) { context.course })),
    settings: settings,
    today: today,
  )
}

fn placements_from_entries(entries: List(StoredEntry)) -> List(Placement) {
  entries
  |> list.map(fn(entry) {
    Placement(module_id: entry.module_id, scheduled_date: entry.scheduled_date)
  })
}

fn normalize_loop(
  context: ScheduleContext,
  placements: List(Placement),
) -> List(Placement) {
  let current_score = schedule_score(context, placements)
  case best_improving_move(context, placements, current_score) {
    Some(scored_move) ->
      normalize_loop(context, apply_move(placements, scored_move.move))
    None -> placements
  }
}

fn best_improving_move(
  context: ScheduleContext,
  placements: List(Placement),
  current_score: ScheduleScore,
) -> Option(ScoredMove) {
  oversized_gaps(context.settings, placements)
  |> list.fold(None, fn(best, gap) {
    candidate_moves_for_gap(context, placements, gap)
    |> list.fold(best, fn(inner_best, move) {
      let next_placements = apply_move(placements, move)
      let score = schedule_score(context, next_placements)
      case compare_schedule_score(score, current_score) {
        Lt -> choose_better_move(inner_best, ScoredMove(move:, score:))
        _ -> inner_best
      }
    })
  })
}

fn choose_better_move(
  best: Option(ScoredMove),
  candidate: ScoredMove,
) -> Option(ScoredMove) {
  case best {
    None -> Some(candidate)
    Some(current) ->
      case compare_scored_move(candidate, current) {
        Lt -> Some(candidate)
        _ -> best
      }
  }
}

fn compare_scored_move(left: ScoredMove, right: ScoredMove) -> Order {
  case compare_schedule_score(left.score, right.score) {
    Eq ->
      case date.compare(left.move.target_date, right.move.target_date) {
        Eq -> int.compare(left.move.module_id, right.move.module_id)
        other -> other
      }
    other -> other
  }
}

fn compare_schedule_score(left: ScheduleScore, right: ScheduleScore) -> Order {
  case int.compare(left.idle_overflow, right.idle_overflow) {
    Eq ->
      case int.compare(left.activity_penalty, right.activity_penalty) {
        Eq -> int.compare(left.preferred_overflow, right.preferred_overflow)
        other -> other
      }
    other -> other
  }
}

fn candidate_moves_for_gap(
  context: ScheduleContext,
  placements: List(Placement),
  gap: Gap,
) -> List(CandidateMove) {
  let active_dates = unique_active_dates(placements)
  let left_target =
    next_allowed_day(date.day_after(gap.left_date), context.settings)
  let right_target =
    previous_allowed_day(date.day_before(gap.right_date), context.settings)
  let left_modules =
    modules_on_day(placements, gap.left_date, context.module_contexts_by_id)
  let right_modules =
    modules_on_day(placements, gap.right_date, context.module_contexts_by_id)
  let left_moves =
    case
      run_length_ending_at_date(active_dates, gap.left_date, context.settings) > 1
      || list.length(left_modules) > 1
    {
      True ->
        left_modules
        |> list.fold([], fn(acc, module_id) {
          let move = CandidateMove(module_id:, target_date: left_target)
          case legal_move(context, placements, move) {
            True -> [move, ..acc]
            False -> acc
          }
        })
        |> list.reverse
      False -> []
    }
  let right_moves =
    case
      run_length_starting_at_date(active_dates, gap.right_date, context.settings) > 1
      || list.length(right_modules) > 1
    {
      True ->
        right_modules
        |> list.fold([], fn(acc, module_id) {
          let move = CandidateMove(module_id:, target_date: right_target)
          case legal_move(context, placements, move) {
            True -> [move, ..acc]
            False -> acc
          }
        })
        |> list.reverse
      False -> []
    }
  list.append(left_moves, right_moves)
}

fn legal_move(
  context: ScheduleContext,
  placements: List(Placement),
  move: CandidateMove,
) -> Bool {
  case
    dict.get(context.module_contexts_by_id, move.module_id),
    day_is_idle(placements, move.target_date)
  {
    Ok(module_context), True -> {
      let assert Ok(course_context) =
        dict.get(context.courses_by_id, module_context.course_id)
      case
        should_skip_day(context.settings, move.target_date)
        || date.compare(move.target_date, context.today) == Lt
        || date.compare(move.target_date, course_context.effective_deadline) == Gt
      {
        True -> False

        False -> {
          let previous_date =
            previous_module_date(course_context.module_ids, move.module_id, placements)
          let next_date =
            next_module_date(course_context.module_ids, move.module_id, placements)
          let earliest_start =
            earliest_start_from_placements(
              course_context.course.prerequisite_ids,
              context,
              placements,
            )
          case
            previous_blocks_move(previous_date, move.target_date)
            || next_blocks_move(next_date, move.target_date)
            || first_module_too_early(
              course_context.module_ids,
              move.module_id,
              move.target_date,
              earliest_start,
            )
          {
            True -> False

            False -> {
              let next_placements = apply_move(placements, move)
              dependents_still_start_after_finish(
                course_context,
                context,
                next_placements,
              )
            }
          }
        }
      }
    }
    _, _ -> False
  }
}

fn previous_blocks_move(
  previous_date: Option(calendar.Date),
  target_date: calendar.Date,
) -> Bool {
  case previous_date {
    Some(previous_date) -> date.compare(previous_date, target_date) == Gt
    None -> False
  }
}

fn next_blocks_move(
  next_date: Option(calendar.Date),
  target_date: calendar.Date,
) -> Bool {
  case next_date {
    Some(next_date) -> date.compare(target_date, next_date) == Gt
    None -> False
  }
}

fn first_module_too_early(
  module_ids: List(Int),
  module_id: Int,
  target_date: calendar.Date,
  earliest_start: calendar.Date,
) -> Bool {
  case module_ids {
    [first_id, .._] ->
      case first_id == module_id {
        True -> date.compare(target_date, earliest_start) == Lt
        False -> False
      }
    [] -> False
  }
}

fn dependents_still_start_after_finish(
  course_context: CourseContext,
  context: ScheduleContext,
  placements: List(Placement),
) -> Bool {
  let finish_date = course_finish_date(course_context, placements)
  dict.get(context.dependents, course_context.course.id)
  |> result.unwrap([])
  |> list.all(fn(dependent_id) {
    case dict.get(context.courses_by_id, dependent_id) {
      Ok(dependent_context) ->
        date.compare(finish_date, course_start_date(dependent_context, placements)) == Lt
      Error(_) -> True
    }
  })
}

fn earliest_start_from_placements(
  prerequisite_ids: List(Int),
  context: ScheduleContext,
  placements: List(Placement),
) -> calendar.Date {
  let latest_finish =
    prerequisite_ids
    |> list.fold(date.day_before(context.today), fn(acc, prerequisite_id) {
      case dict.get(context.courses_by_id, prerequisite_id) {
        Ok(prerequisite_context) ->
          date.max(acc, course_finish_date(prerequisite_context, placements))
        Error(_) -> acc
      }
    })
  let earliest =
    case date.compare(latest_finish, date.day_before(context.today)) {
      Eq -> context.today
      _ -> date.day_after(latest_finish)
    }
  next_allowed_day(earliest, context.settings)
}

fn apply_move(
  placements: List(Placement),
  move: CandidateMove,
) -> List(Placement) {
  placements
  |> list.map(fn(placement) {
    case placement.module_id == move.module_id {
      True -> Placement(module_id: placement.module_id, scheduled_date: move.target_date)
      False -> placement
    }
  })
}

fn schedule_score(
  context: ScheduleContext,
  placements: List(Placement),
) -> ScheduleScore {
  ScheduleScore(
    idle_overflow: idle_overflow(context, placements),
    activity_penalty: activity_penalty(context.settings, placements),
    preferred_overflow: preferred_overflow(context, placements),
  )
}

fn idle_overflow(
  context: ScheduleContext,
  placements: List(Placement),
) -> Int {
  oversized_gaps(context.settings, placements)
  |> list.fold(leading_idle_overflow(context, placements), fn(total, gap) {
    total + { gap.gap_size - max_idle_gap }
  })
}

fn activity_penalty(
  settings: model.Settings,
  placements: List(Placement),
) -> Int {
  unique_active_dates(placements)
  |> activity_penalty_from_dates(settings, 0, 0)
}

fn activity_penalty_from_dates(
  dates: List(calendar.Date),
  settings: model.Settings,
  current_run: Int,
  penalty: Int,
) -> Int {
  case dates {
    [] -> penalty + { current_run * current_run }
    [_day] -> penalty + { current_run + 1 } * { current_run + 1 }
    [left, right, ..rest] -> {
      let next_run =
        case idle_gap_size(left, right, settings) == 0 {
          True -> current_run + 1
          False -> 0
        }
      let next_penalty =
        case idle_gap_size(left, right, settings) == 0 {
          True -> penalty
          False -> penalty + { current_run + 1 } * { current_run + 1 }
        }
      activity_penalty_from_dates([right, ..rest], settings, next_run, next_penalty)
    }
  }
}

fn leading_idle_overflow(
  context: ScheduleContext,
  placements: List(Placement),
) -> Int {
  case unique_active_dates(placements) {
    [first_active, .._] -> {
      let start = next_allowed_day(context.today, context.settings)
      let size =
        case date.compare(start, first_active) {
          Lt ->
            days_in_window(start, date.day_before(first_active), context.settings)
            |> list.length
          _ -> 0
        }
      case size > max_idle_gap {
        True -> size - max_idle_gap
        False -> 0
      }
    }
    [] -> 0
  }
}

fn run_length_ending_at_date(
  dates: List(calendar.Date),
  target: calendar.Date,
  settings: model.Settings,
) -> Int {
  run_length_ending_at_date_loop(dates, target, settings, None, 0)
}

fn run_length_ending_at_date_loop(
  dates: List(calendar.Date),
  target: calendar.Date,
  settings: model.Settings,
  previous_date: Option(calendar.Date),
  current_run: Int,
) -> Int {
  case dates {
    [] -> 0
    [day, ..rest] -> {
      let next_run =
        case previous_date {
          Some(previous_day) ->
            case idle_gap_size(previous_day, day, settings) == 0 {
              True -> current_run + 1
              False -> 1
            }
          None -> 1
        }
      case date.compare(day, target) {
        Eq -> next_run
        _ ->
          run_length_ending_at_date_loop(
            rest,
            target,
            settings,
            Some(day),
            next_run,
          )
      }
    }
  }
}

fn run_length_starting_at_date(
  dates: List(calendar.Date),
  target: calendar.Date,
  settings: model.Settings,
) -> Int {
  case dates {
    [] -> 0
    [day, next_day, ..rest] ->
      case date.compare(day, target) {
        Eq ->
          case idle_gap_size(day, next_day, settings) == 0 {
            True ->
              1 + run_length_starting_at_date([next_day, ..rest], next_day, settings)
            False -> 1
          }
        _ -> run_length_starting_at_date([next_day, ..rest], target, settings)
      }
    [day] ->
      case date.compare(day, target) {
        Eq -> 1
        _ -> 0
      }
  }
}

fn preferred_overflow(
  context: ScheduleContext,
  placements: List(Placement),
) -> Int {
  context.course_contexts
  |> list.fold(0, fn(total, course_context) {
    let finish_date = course_finish_date(course_context, placements)
    case date.compare(finish_date, course_context.preferred_deadline) {
      Gt ->
        total
        + {
          days_in_window(
            date.day_after(course_context.preferred_deadline),
            finish_date,
            context.settings,
          )
          |> list.length
        }
      _ -> total
    }
  })
}

fn oversized_gaps(
  settings: model.Settings,
  placements: List(Placement),
) -> List(Gap) {
  gaps_from_dates(settings, unique_active_dates(placements), [])
}

fn gaps_from_dates(
  settings: model.Settings,
  dates: List(calendar.Date),
  acc: List(Gap),
) -> List(Gap) {
  case dates {
    [left, right, ..rest] -> {
      let size = idle_gap_size(left, right, settings)
      case size > max_idle_gap {
        True ->
          gaps_from_dates(
            settings,
            [right, ..rest],
            [Gap(left_date: left, right_date: right, gap_size: size), ..acc],
          )
        False -> gaps_from_dates(settings, [right, ..rest], acc)
      }
    }
    _ -> list.reverse(acc)
  }
}

fn idle_gap_size(
  left: calendar.Date,
  right: calendar.Date,
  settings: model.Settings,
) -> Int {
  days_in_window(date.day_after(left), date.day_before(right), settings)
  |> list.length
}

fn unique_active_dates(placements: List(Placement)) -> List(calendar.Date) {
  placements
  |> list.map(fn(placement) { placement.scheduled_date })
  |> list.sort(date.compare)
  |> unique_sorted_dates([])
}

fn unique_sorted_dates(
  dates: List(calendar.Date),
  acc: List(calendar.Date),
) -> List(calendar.Date) {
  case dates, acc {
    [], _ -> list.reverse(acc)
    [date, ..rest], [] -> unique_sorted_dates(rest, [date])
    [date, ..rest], [last, .._] ->
      case date.compare(date, last) {
        Eq -> unique_sorted_dates(rest, acc)
        _ -> unique_sorted_dates(rest, [date, ..acc])
      }
  }
}

fn modules_on_day(
  placements: List(Placement),
  scheduled_date: calendar.Date,
  module_contexts_by_id: dict.Dict(Int, ModuleContext),
) -> List(Int) {
  placements
  |> list.filter(fn(placement) { date.compare(placement.scheduled_date, scheduled_date) == Eq })
  |> list.sort(fn(left, right) {
    compare_module_order(
      left.module_id,
      right.module_id,
      module_contexts_by_id,
    )
  })
  |> list.map(fn(placement) { placement.module_id })
}

fn day_is_idle(
  placements: List(Placement),
  scheduled_date: calendar.Date,
) -> Bool {
  case
    placements
    |> list.any(fn(placement) { date.compare(placement.scheduled_date, scheduled_date) == Eq })
  {
    True -> False
    False -> True
  }
}

fn compare_module_order(
  left_id: Int,
  right_id: Int,
  module_contexts_by_id: dict.Dict(Int, ModuleContext),
) -> Order {
  let assert Ok(left) = dict.get(module_contexts_by_id, left_id)
  let assert Ok(right) = dict.get(module_contexts_by_id, right_id)
  case string.compare(left.vendor_name, right.vendor_name) {
    Eq ->
      case string.compare(left.course_name, right.course_name) {
        Eq ->
          case int.compare(left.position, right.position) {
            Eq -> int.compare(left.module_id, right.module_id)
            other -> other
          }
        other -> other
      }
    other -> other
  }
}

fn previous_module_date(
  module_ids: List(Int),
  module_id: Int,
  placements: List(Placement),
) -> Option(calendar.Date) {
  previous_module_date_loop(module_ids, module_id, placements, None)
}

fn previous_module_date_loop(
  module_ids: List(Int),
  module_id: Int,
  placements: List(Placement),
  previous_date: Option(calendar.Date),
) -> Option(calendar.Date) {
  case module_ids {
    [] -> previous_date
    [current_id, ..rest] ->
      case current_id == module_id {
        True -> previous_date
        False ->
          previous_module_date_loop(
            rest,
            module_id,
            placements,
            Some(scheduled_date_for_module(placements, current_id)),
          )
      }
  }
}

fn next_module_date(
  module_ids: List(Int),
  module_id: Int,
  placements: List(Placement),
) -> Option(calendar.Date) {
  case module_ids {
    [] -> None
    [current_id, next_id, .._] ->
      case current_id == module_id {
        True -> Some(scheduled_date_for_module(placements, next_id))
        False ->
          case module_ids {
            [_, ..rest] -> next_module_date(rest, module_id, placements)
            [] -> None
          }
      }
    [_] -> None
  }
}

fn scheduled_date_for_module(
  placements: List(Placement),
  module_id: Int,
) -> calendar.Date {
  let assert Ok(placement) =
    list.find(placements, fn(placement) { placement.module_id == module_id })
  placement.scheduled_date
}

fn course_start_date(
  course_context: CourseContext,
  placements: List(Placement),
) -> calendar.Date {
  case course_context.module_ids {
    [first_id, .._] -> scheduled_date_for_module(placements, first_id)
    [] -> panic as "Scheduled course is missing modules"
  }
}

fn course_finish_date(
  course_context: CourseContext,
  placements: List(Placement),
) -> calendar.Date {
  last_module_date(course_context.module_ids, placements)
}

fn last_module_date(
  module_ids: List(Int),
  placements: List(Placement),
) -> calendar.Date {
  case module_ids {
    [module_id] -> scheduled_date_for_module(placements, module_id)
    [_, ..rest] -> last_module_date(rest, placements)
    [] -> panic as "Scheduled course is missing modules"
  }
}

fn previous_allowed_day(
  day: calendar.Date,
  settings: model.Settings,
) -> calendar.Date {
  case should_skip_day(settings, day) {
    True -> previous_allowed_day(date.day_before(day), settings)
    False -> day
  }
}

fn build_stored_entries(
  module_contexts_by_id: dict.Dict(Int, ModuleContext),
  placements: List(Placement),
) -> List(StoredEntry) {
  placements
  |> list.sort(fn(left, right) {
    compare_placement(left, right, module_contexts_by_id)
  })
  |> assign_slots(None, 0, [])
}

fn assign_slots(
  placements: List(Placement),
  current_day: Option(calendar.Date),
  next_slot_index: Int,
  acc: List(StoredEntry),
) -> List(StoredEntry) {
  case placements {
    [] -> list.reverse(acc)
    [placement, ..rest] ->
      case current_day {
        Some(day) ->
          case date.compare(day, placement.scheduled_date) {
            Eq ->
              assign_slots(
                rest,
                current_day,
                next_slot_index + 1,
                [
                  StoredEntry(
                    module_id: placement.module_id,
                    scheduled_date: placement.scheduled_date,
                    slot_index: next_slot_index,
                  ),
                  ..acc
                ],
              )
            _ ->
              assign_slots(
                rest,
                Some(placement.scheduled_date),
                1,
                [
                  StoredEntry(
                    module_id: placement.module_id,
                    scheduled_date: placement.scheduled_date,
                    slot_index: 0,
                  ),
                  ..acc
                ],
              )
          }

        None ->
          assign_slots(
            rest,
            Some(placement.scheduled_date),
            1,
            [
              StoredEntry(
                module_id: placement.module_id,
                scheduled_date: placement.scheduled_date,
                slot_index: 0,
              ),
              ..acc
            ],
          )
      }
  }
}

fn compare_placement(
  left: Placement,
  right: Placement,
  module_contexts_by_id: dict.Dict(Int, ModuleContext),
) -> Order {
  case date.compare(left.scheduled_date, right.scheduled_date) {
    Eq ->
      compare_module_order(
        left.module_id,
        right.module_id,
        module_contexts_by_id,
      )
    other -> other
  }
}

fn split_ready(
  planned: List(PlannedCourse),
  finished_dates: dict.Dict(Int, calendar.Date),
) -> #(List(PlannedCourse), List(PlannedCourse)) {
  planned
  |> list.fold(#([], []), fn(acc, plan) {
    let #(ready, blocked) = acc
    case prerequisites_scheduled(plan.course.prerequisite_ids, finished_dates) {
      True -> #([plan, ..ready], blocked)
      False -> #(ready, [plan, ..blocked])
    }
  })
  |> reverse_both
}

fn build_candidate(
  plan: PlannedCourse,
  finished_dates: dict.Dict(Int, calendar.Date),
  settings: model.Settings,
  today: calendar.Date,
) -> CandidateCourse {
  let earliest_start =
    earliest_start_date(
      plan.course.prerequisite_ids,
      finished_dates,
      settings,
      today,
    )
  let allowed_days = days_in_window(earliest_start, plan.effective_deadline, settings)
  let preferred_deadline =
    preferred_deadline(plan.effective_deadline, settings.deadline_slack_days)
  let preferred_day_count =
    days_in_window(earliest_start, preferred_deadline, settings) |> list.length
  let slack = preferred_day_count - list.length(plan.remaining)
  CandidateCourse(plan:, earliest_start:, allowed_days:, preferred_day_count:, slack:)
}

fn split_impossible(
  candidates: List(CandidateCourse),
) -> #(List(CandidateCourse), List(CandidateCourse)) {
  candidates
  |> list.fold(#([], []), fn(acc, candidate) {
    let #(impossible, schedulable) = acc
    case candidate.allowed_days {
      [] -> #([candidate, ..impossible], schedulable)
      _ -> #(impossible, [candidate, ..schedulable])
    }
  })
  |> reverse_both
}

fn place_course(
  candidate: CandidateCourse,
  occupancy: dict.Dict(String, Int),
  stored_entries: List(StoredEntry),
  schedule_entries: List(model.ScheduleEntry),
) -> #(
  dict.Dict(String, Int),
  List(StoredEntry),
  List(model.ScheduleEntry),
  calendar.Date,
) {
  place_modules(
    candidate.plan.course,
    candidate.plan.remaining,
    candidate.allowed_days,
    candidate.preferred_day_count,
    list.length(candidate.allowed_days),
    list.length(candidate.plan.remaining),
    0,
    0,
    occupancy,
    stored_entries,
    schedule_entries,
    candidate.earliest_start,
  )
}

fn place_modules(
  course: model.Course,
  modules: List(model.Module),
  allowed_days: List(calendar.Date),
  preferred_day_count: Int,
  day_count: Int,
  module_count: Int,
  module_index: Int,
  min_index: Int,
  occupancy: dict.Dict(String, Int),
  stored_entries: List(StoredEntry),
  schedule_entries: List(model.ScheduleEntry),
  last_assigned_day: calendar.Date,
) -> #(
  dict.Dict(String, Int),
  List(StoredEntry),
  List(model.ScheduleEntry),
  calendar.Date,
) {
  case modules {
    [] -> #(occupancy, stored_entries, schedule_entries, last_assigned_day)

    [module, ..rest] -> {
      let target_day_count = effective_target_day_count(preferred_day_count, day_count)
      let target_index =
        target_day_index(module_index, module_count, target_day_count)
        |> max_int(min_index)
      let chosen_index =
        choose_day_index(
          allowed_days,
          occupancy,
          preferred_day_count,
          target_index,
          min_index,
        )
      let assigned_day = date_for_index(allowed_days, chosen_index)
      let slot_index = slot_count(occupancy, assigned_day)
      let occupancy = occupy_day(occupancy, assigned_day)
      let stored_entry =
        StoredEntry(
          module_id: module.id,
          scheduled_date: assigned_day,
          slot_index: slot_index,
        )
      let schedule_entry =
        model.ScheduleEntry(
          module_id: module.id,
          vendor_name: course.vendor_name,
          course_name: course.name,
          module_name: module.name,
          scheduled_date: assigned_day,
          slot_index: slot_index,
        )

      place_modules(
        course,
        rest,
        allowed_days,
        preferred_day_count,
        day_count,
        module_count,
        module_index + 1,
        chosen_index,
        occupancy,
        [stored_entry, ..stored_entries],
        [schedule_entry, ..schedule_entries],
        assigned_day,
      )
    }
  }
}

fn choose_day_index(
  allowed_days: List(calendar.Date),
  occupancy: dict.Dict(String, Int),
  preferred_day_count: Int,
  target_index: Int,
  min_index: Int,
) -> Int {
  let max_index = list.length(allowed_days) - 1
  let candidate_indices = index_range(min_index, max_index)
  let free_indices =
    candidate_indices
    |> list.filter(fn(index) {
      slot_count(occupancy, date_for_index(allowed_days, index)) == 0
    })

  case free_indices {
    [first, ..rest] ->
      choose_best_free_index(
        rest,
        first,
        target_index,
        preferred_day_count,
      )
    [] ->
      choose_best_overlap_index(
        candidate_indices,
        target_index,
        preferred_day_count,
        allowed_days,
        occupancy,
      )
  }
}

fn choose_best_free_index(
  indices: List(Int),
  best: Int,
  target_index: Int,
  preferred_day_count: Int,
) -> Int {
  case indices {
    [] -> best
    [index, ..rest] ->
      case better_free_index(index, best, target_index, preferred_day_count) {
        True -> choose_best_free_index(rest, index, target_index, preferred_day_count)
        False -> choose_best_free_index(rest, best, target_index, preferred_day_count)
      }
  }
}

fn choose_best_overlap_index(
  indices: List(Int),
  target_index: Int,
  preferred_day_count: Int,
  allowed_days: List(calendar.Date),
  occupancy: dict.Dict(String, Int),
) -> Int {
  let assert [first, ..rest] = indices
  choose_best_overlap_index_loop(
    rest,
    first,
    target_index,
    preferred_day_count,
    allowed_days,
    occupancy,
  )
}

fn choose_best_overlap_index_loop(
  indices: List(Int),
  best: Int,
  target_index: Int,
  preferred_day_count: Int,
  allowed_days: List(calendar.Date),
  occupancy: dict.Dict(String, Int),
) -> Int {
  case indices {
    [] -> best
    [index, ..rest] ->
      case better_overlap_index(
        index,
        best,
        target_index,
        preferred_day_count,
        allowed_days,
        occupancy,
      ) {
        True ->
          choose_best_overlap_index_loop(
            rest,
            index,
            target_index,
            preferred_day_count,
            allowed_days,
            occupancy,
          )

        False ->
          choose_best_overlap_index_loop(
            rest,
            best,
            target_index,
            preferred_day_count,
            allowed_days,
            occupancy,
          )
      }
  }
}

fn better_free_index(
  left: Int,
  right: Int,
  target_index: Int,
  preferred_day_count: Int,
) -> Bool {
  case int.compare(preferred_penalty(left, preferred_day_count), preferred_penalty(right, preferred_day_count)) {
    Lt -> True
    Gt -> False
    Eq -> compare_distance_then_left(left, right, target_index)
  }
}

fn compare_distance_then_left(left: Int, right: Int, target_index: Int) -> Bool {
  let left_distance = abs_int(left - target_index)
  let right_distance = abs_int(right - target_index)

  case int.compare(left_distance, right_distance) {
    Lt -> True
    Gt -> False
    Eq -> left < right
  }
}

fn better_overlap_index(
  left: Int,
  right: Int,
  target_index: Int,
  preferred_day_count: Int,
  allowed_days: List(calendar.Date),
  occupancy: dict.Dict(String, Int),
) -> Bool {
  let left_slots = slot_count(occupancy, date_for_index(allowed_days, left))
  let right_slots = slot_count(occupancy, date_for_index(allowed_days, right))

  case int.compare(left_slots, right_slots) {
    Lt -> True
    Gt -> False

    Eq ->
      case int.compare(
        preferred_penalty(left, preferred_day_count),
        preferred_penalty(right, preferred_day_count),
      ) {
        Lt -> True
        Gt -> False
        Eq -> compare_distance_then_left(left, right, target_index)
      }
  }
}

fn target_day_index(module_index: Int, module_count: Int, day_count: Int) -> Int {
  case module_count <= 1 || day_count <= 1 {
    True -> 0
    False -> { module_index * { day_count - 1 } } / { module_count - 1 }
  }
}

fn effective_target_day_count(preferred_day_count: Int, hard_day_count: Int) -> Int {
  case preferred_day_count > 0 {
    True -> preferred_day_count
    False -> hard_day_count
  }
}

fn compare_candidate(left: CandidateCourse, right: CandidateCourse) -> Order {
  case int.compare(left.slack, right.slack) {
    Eq ->
      case compare_density(left, right) {
        Eq ->
          case date.compare(left.plan.effective_deadline, right.plan.effective_deadline) {
            Eq -> string.compare(left.plan.course.name, right.plan.course.name)
            other -> other
          }

        other -> other
      }

    other -> other
  }
}

fn compare_density(left: CandidateCourse, right: CandidateCourse) -> Order {
  let left_days =
    effective_target_day_count(left.preferred_day_count, list.length(left.allowed_days))
  let right_days =
    effective_target_day_count(right.preferred_day_count, list.length(right.allowed_days))
  let left_modules = list.length(left.plan.remaining)
  let right_modules = list.length(right.plan.remaining)

  case left_days <= 0, right_days <= 0 {
    True, True -> Eq
    True, False -> Lt
    False, True -> Gt

    False, False -> {
      let left_score = left_modules * right_days
      let right_score = right_modules * left_days
      int.compare(right_score, left_score)
    }
  }
}

fn prerequisites_scheduled(
  prerequisite_ids: List(Int),
  finished_dates: dict.Dict(Int, calendar.Date),
) -> Bool {
  prerequisite_ids
  |> list.all(fn(prerequisite_id) {
    case dict.get(finished_dates, prerequisite_id) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}

fn earliest_start_date(
  prerequisite_ids: List(Int),
  finished_dates: dict.Dict(Int, calendar.Date),
  settings: model.Settings,
  today: calendar.Date,
) -> calendar.Date {
  let latest_finish =
    prerequisite_ids
    |> list.fold(date.day_before(today), fn(acc, prerequisite_id) {
      case dict.get(finished_dates, prerequisite_id) {
        Ok(finish_date) -> date.max(acc, finish_date)
        Error(_) -> acc
      }
    })

  let earliest =
    case date.compare(latest_finish, date.day_before(today)) {
      Eq -> today
      _ -> date.day_after(latest_finish)
    }

  next_allowed_day(earliest, settings)
}

fn preferred_deadline(
  effective_deadline: calendar.Date,
  deadline_slack_days: Int,
) -> calendar.Date {
  case deadline_slack_days <= 0 {
    True -> effective_deadline
    False -> date.add_days(effective_deadline, 0 - deadline_slack_days)
  }
}

fn next_allowed_day(day: calendar.Date, settings: model.Settings) -> calendar.Date {
  case should_skip_day(settings, day) {
    True -> next_allowed_day(date.day_after(day), settings)
    False -> day
  }
}

fn days_in_window(
  start: calendar.Date,
  finish: calendar.Date,
  settings: model.Settings,
) -> List(calendar.Date) {
  case date.compare(start, finish) {
    Gt -> []

    _ -> {
      let rest = days_in_window(date.day_after(start), finish, settings)
      case should_skip_day(settings, start) {
        True -> rest
        False -> [start, ..rest]
      }
    }
  }
}

fn slot_count(
  occupancy: dict.Dict(String, Int),
  scheduled_date: calendar.Date,
) -> Int {
  dict.get(occupancy, date.to_iso(scheduled_date)) |> result.unwrap(0)
}

fn occupy_day(
  occupancy: dict.Dict(String, Int),
  scheduled_date: calendar.Date,
) -> dict.Dict(String, Int) {
  let key = date.to_iso(scheduled_date)
  let next_count = dict.get(occupancy, key) |> result.unwrap(0) |> int.add(1)
  dict.insert(occupancy, key, next_count)
}

fn compute_effective_deadlines(
  active_courses: List(model.Course),
) -> Result(dict.Dict(Int, calendar.Date), model.AppError) {
  let dependents = build_dependents(active_courses)
  list.try_fold(active_courses, dict.new(), fn(cache, course) {
    ensure_effective_deadline(course.id, active_courses, dependents, cache)
  })
}

fn ensure_effective_deadline(
  course_id: Int,
  courses: List(model.Course),
  dependents: dict.Dict(Int, List(Int)),
  cache: dict.Dict(Int, calendar.Date),
) -> Result(dict.Dict(Int, calendar.Date), model.AppError) {
  effective_deadline(course_id, courses, dependents, cache, [])
}

fn effective_deadline(
  course_id: Int,
  courses: List(model.Course),
  dependents: dict.Dict(Int, List(Int)),
  cache: dict.Dict(Int, calendar.Date),
  stack: List(Int),
) -> Result(dict.Dict(Int, calendar.Date), model.AppError) {
  case dict.get(cache, course_id) {
    Ok(_) -> Ok(cache)

    Error(_) ->
      case list.contains(stack, course_id) {
        True -> Error(model.Parse("Course prerequisites contain a cycle"))

        False -> {
          use course <- result.try(find_course(courses, course_id))
          let dependent_ids = dict.get(dependents, course_id) |> result.unwrap([])
          use next_cache <- result.try(
            list.try_fold(dependent_ids, cache, fn(inner_cache, dependent_id) {
              effective_deadline(
                dependent_id,
                courses,
                dependents,
                inner_cache,
                [course_id, ..stack],
              )
            }),
          )
          let deadline =
            dependent_ids
            |> list.fold(course.deadline, fn(acc, dependent_id) {
              case dict.get(next_cache, dependent_id) {
                Ok(dependent_deadline) ->
                  date.min(acc, date.day_before(dependent_deadline))

                Error(_) -> acc
              }
            })
          Ok(dict.insert(next_cache, course_id, deadline))
        }
      }
  }
}

fn visit(
  course_id: Int,
  courses: List(model.Course),
  states: dict.Dict(Int, String),
) -> Result(dict.Dict(Int, String), model.AppError) {
  case dict.get(states, course_id) {
    Ok("done") -> Ok(states)
    Ok("visiting") -> Error(model.Parse("Course prerequisites contain a cycle"))

    _ -> {
      use course <- result.try(find_course(courses, course_id))
      let states = dict.insert(states, course_id, "visiting")
      use states <- result.try(
        list.try_fold(course.prerequisite_ids, states, fn(next_states, prerequisite_id) {
          visit(prerequisite_id, courses, next_states)
        }),
      )
      Ok(dict.insert(states, course_id, "done"))
    }
  }
}

fn build_dependents(courses: List(model.Course)) -> dict.Dict(Int, List(Int)) {
  courses
  |> list.fold(dict.new(), fn(acc, course) {
    course.prerequisite_ids
    |> list.fold(acc, fn(inner, prerequisite_id) {
      let existing = dict.get(inner, prerequisite_id) |> result.unwrap([])
      dict.insert(inner, prerequisite_id, [course.id, ..existing])
    })
  })
}

fn unfinished_course_ids(courses: List(model.Course)) -> List(Int) {
  courses
  |> list.filter(fn(course) { remaining_modules(course) != [] })
  |> list.map(fn(course) { course.id })
}

fn completed_course_ids(courses: List(model.Course)) -> List(Int) {
  courses
  |> list.filter(fn(course) { remaining_modules(course) == [] })
  |> list.map(fn(course) { course.id })
}

fn remaining_modules(course: model.Course) -> List(model.Module) {
  course.modules
  |> list.filter(fn(module) { module.completed_at == None })
}

fn impossible_conflict(course: model.Course) -> model.Conflict {
  model.Conflict(
    course_id: course.id,
    vendor_name: course.vendor_name,
    course_name: course.name,
    message:
      "This course cannot be scheduled before its deadline with the current prerequisites and completed work.",
  )
}

fn blocked_conflict(course: model.Course) -> model.Conflict {
  model.Conflict(
    course_id: course.id,
    vendor_name: course.vendor_name,
    course_name: course.name,
    message:
      "This course is blocked because one of its prerequisites could not finish before the deadline.",
  )
}

fn should_skip_day(settings: model.Settings, current_day: calendar.Date) -> Bool {
  case settings.include_weekends, date.is_weekend(current_day) {
    False, True -> True
    _, _ -> False
  }
}

fn sort_stored_entries(entries: List(StoredEntry)) -> List(StoredEntry) {
  entries
  |> list.sort(fn(left, right) {
    compare_schedule_position(
      left.scheduled_date,
      left.slot_index,
      left.module_id,
      right.scheduled_date,
      right.slot_index,
      right.module_id,
    )
  })
}

fn preferred_penalty(index: Int, preferred_day_count: Int) -> Int {
  case preferred_day_count > 0 && index >= preferred_day_count {
    True -> 1
    False -> 0
  }
}

fn sort_schedule_entries(
  entries: List(model.ScheduleEntry),
) -> List(model.ScheduleEntry) {
  entries
  |> list.sort(fn(left, right) {
    compare_schedule_position(
      left.scheduled_date,
      left.slot_index,
      left.module_id,
      right.scheduled_date,
      right.slot_index,
      right.module_id,
    )
  })
}

fn compare_schedule_position(
  left_date: calendar.Date,
  left_slot: Int,
  left_id: Int,
  right_date: calendar.Date,
  right_slot: Int,
  right_id: Int,
) -> Order {
  case date.compare(left_date, right_date) {
    Eq ->
      case int.compare(left_slot, right_slot) {
        Eq -> int.compare(left_id, right_id)
        other -> other
      }

    other -> other
  }
}

fn find_course(
  courses: List(model.Course),
  course_id: Int,
) -> Result(model.Course, model.AppError) {
  courses
  |> list.find(fn(course) { course.id == course_id })
  |> result.map_error(fn(_) { model.Parse("Unknown course id in prerequisite graph") })
}

fn index_range(start: Int, finish: Int) -> List(Int) {
  case start > finish {
    True -> []
    False -> [start, ..index_range(start + 1, finish)]
  }
}

fn date_for_index(days: List(calendar.Date), index: Int) -> calendar.Date {
  case days, index {
    [day, .._], 0 -> day
    [_, ..rest], _ -> date_for_index(rest, index - 1)
    [], _ -> panic as "Invalid schedule day index"
  }
}

fn abs_int(value: Int) -> Int {
  case value < 0 {
    True -> 0 - value
    False -> value
  }
}

fn max_int(left: Int, right: Int) -> Int {
  case int.compare(left, right) {
    Lt -> right
    _ -> left
  }
}

fn reverse_both(
  input: #(List(a), List(b)),
) -> #(List(a), List(b)) {
  let #(left, right) = input
  #(list.reverse(left), list.reverse(right))
}
