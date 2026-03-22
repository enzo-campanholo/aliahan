import aliahan/config
import aliahan/date
import aliahan/env
import aliahan/model.{
  type AppError,
  type BootstrapData,
  BootstrapData,
  type Conflict,
  type Course,
  Course,
  type CourseModulesInput,
  ExplicitModules,
  GeneratedRange,
  type Module,
  Module,
  type ModuleRange,
  ModuleRange,
  type NewCourseInput,
  ScheduleDay,
  type ScheduleEntry,
  type ScheduleView,
  ScheduleView,
  type SettingsPatch,
  type Settings,
  Settings,
  type UpdateCourseInput,
  type Vendor,
  Vendor,
  Database,
  IOError,
  NotFound,
  Validation,
}
import aliahan/scheduler
import filepath
import gleam/dict
import gleam/dynamic/decode as decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Eq, Gt}
import gleam/result
import gleam/string
import gleam/time/calendar
import simplifile
import sqlight

pub const database_path_env_var = "ALIAHAN_DATABASE_PATH"
pub const courses_toml_path_env_var = "ALIAHAN_COURSES_TOML_PATH"
const default_database_path = "aliahan.sqlite3"
const default_courses_toml_path = "courses.toml"

pub fn database_path() -> String {
  path_from_env(database_path_env_var, default_database_path)
}

pub fn courses_toml_path() -> String {
  case non_empty_env(courses_toml_path_env_var) {
    Ok(path) -> path
    Error(_) ->
      case non_empty_env(database_path_env_var) {
        Ok(path) ->
          case default_database_path_equivalent(path) {
            True -> default_courses_toml_path
            False -> derive_courses_toml_path(path)
          }
        Error(_) -> default_courses_toml_path
      }
  }
}

pub fn initialise() -> Result(Nil, AppError) {
  use _ <- result.try(with_db(fn(connection) {
    use _ <- result.try(prepare_schema(connection))

    let is_empty = has_courses(connection) |> result.unwrap(False) |> bool_not

    use _ <- result.try(
      case is_empty {
        True ->
          case simplifile.is_file(courses_toml_path()) {
            Ok(True) -> transactional(connection, import_from_toml)
            _ -> transactional(connection, refresh_schedule_in_transaction)
          }
        False -> transactional(connection, refresh_schedule_in_transaction)
      },
    )

    Ok(Nil)
  }))

  let _ = export_snapshot()
  Ok(Nil)
}

pub fn bootstrap(
  view: String,
  anchor: calendar.Date,
) -> Result(BootstrapData, AppError) {
  with_db(fn(connection) {
    use _ <- result.try(prepare_schema(connection))
    use #(conflicts, schedule_entries) <- result.try(
      transactional(connection, refresh_schedule_in_transaction),
    )
    use settings <- result.try(load_settings(connection))
    use vendors <- result.try(load_vendors(connection))
    let today = date.today()
    let schedule = build_schedule_view(schedule_entries, view, anchor)
    Ok(
      BootstrapData(
        today: today,
        settings: settings,
        vendors: vendors,
        conflicts: conflicts,
        schedule: schedule,
      ),
    )
  })
}

pub fn schedule_view(
  view: String,
  anchor: calendar.Date,
) -> Result(ScheduleView, AppError) {
  with_db(fn(connection) {
    use _ <- result.try(prepare_schema(connection))
    use #(_, schedule_entries) <- result.try(
      transactional(connection, refresh_schedule_in_transaction),
    )
    Ok(build_schedule_view(schedule_entries, view, anchor))
  })
}

pub fn set_settings(patch: SettingsPatch) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use current <- result.try(load_settings(connection))
    let settings = merge_settings(current, patch)
    case settings.deadline_slack_days < 0 {
      True -> Error(Validation("Deadline slack days cannot be negative"))
      False ->
        exec_with_args(
          "
          update app_settings
          set include_weekends = ?, deadline_slack_days = ?
          where id = 1
          ",
          [
            sqlight.bool(settings.include_weekends),
            sqlight.int(settings.deadline_slack_days),
          ],
          connection,
        )
    }
  })
}

pub fn create_vendor(name: String) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    let name = validate_name(name, "Vendor name") |> result.unwrap("")
    use _ <- result.try(validate_name(name, "Vendor name"))
    exec_with_args(
      "insert into vendors (name) values (?)",
      [sqlight.text(name)],
      connection,
    )
  })
}

pub fn delete_vendor(vendor_id: Int) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use _ <- result.try(exec_with_args(
      "delete from modules where course_id in (select id from courses where vendor_id = ?)",
      [sqlight.int(vendor_id)],
      connection,
    ))
    use _ <- result.try(exec_with_args(
      "delete from courses where vendor_id = ?",
      [sqlight.int(vendor_id)],
      connection,
    ))
    exec_with_args(
      "delete from vendors where id = ?",
      [sqlight.int(vendor_id)],
      connection,
    )
  })
}

pub fn create_course(input: NewCourseInput) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use name <- result.try(validate_name(input.name, "Course name"))
    use _ <- result.try(ensure_vendor_exists(connection, input.vendor_id))
    let deadline = date.to_iso(input.deadline)
    let module_range = module_range_from_input(input.modules)
    let generated_modules = expand_modules(input.modules)
    use _ <- result.try(validate_modules(generated_modules))

    use course_id <- result.try(
      insert_course_row(connection, input.vendor_id, name, deadline, module_range),
    )
    use prerequisite_ids <- result.try(
      resolve_prerequisites(connection, input.vendor_id, input.prerequisites),
    )
    use _ <- result.try(insert_prerequisites(connection, course_id, prerequisite_ids))
    insert_modules(connection, course_id, generated_modules)
  })
}

pub fn update_course(course_id: Int, input: UpdateCourseInput) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use #(vendor_id, current_name, current_deadline, current_prerequisites) <- result.try(
      load_course_update_state(connection, course_id),
    )
    let next_name = case input.name {
      Some(name) -> name
      None -> current_name
    }
    let next_deadline = case input.deadline {
      Some(deadline) -> deadline
      None -> current_deadline
    }
    let next_prerequisites = case input.prerequisites {
      Some(prerequisites) -> prerequisites
      None -> current_prerequisites
    }
    use name <- result.try(validate_name(next_name, "Course name"))
    let deadline = date.to_iso(next_deadline)
    use prerequisite_ids <- result.try(
      resolve_prerequisites(connection, vendor_id, next_prerequisites),
    )
    use _ <- result.try(
      exec_with_args(
        "
        update courses
        set name = ?, deadline_date = ?
        where id = ?
        ",
        [sqlight.text(name), sqlight.text(deadline), sqlight.int(course_id)],
        connection,
      ),
    )
    use _ <- result.try(
      exec_with_args(
        "delete from course_prerequisites where course_id = ?",
        [sqlight.int(course_id)],
        connection,
      ),
    )
    insert_prerequisites(connection, course_id, prerequisite_ids)
  })
}

pub fn delete_course(course_id: Int) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    exec_with_args(
      "delete from courses where id = ?",
      [sqlight.int(course_id)],
      connection,
    )
  })
}

pub fn add_module(course_id: Int, name: String) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use name <- result.try(validate_name(name, "Module name"))
    let next_position =
      query_one(
        "select coalesce(max(position), 0) + 1 from modules where course_id = ?",
        [sqlight.int(course_id)],
        int_decoder(),
        connection,
      )
      |> result.unwrap(1)

    use _ <- result.try(
      exec_with_args(
        "
        insert into modules (course_id, position, name, completed_at)
        values (?, ?, ?, null)
        ",
        [
          sqlight.int(course_id),
          sqlight.int(next_position),
          sqlight.text(name),
        ],
        connection,
      ),
    )
    clear_course_range(connection, course_id)
  })
}

pub fn rename_module(module_id: Int, name: String) -> Result(Nil, AppError) {
  update_module(module_id, Some(name), None, None)
}

pub fn set_module_completed(module_id: Int, done: Bool) -> Result(Nil, AppError) {
  update_module(module_id, None, Some(done), None)
}

pub fn set_module_position(module_id: Int, position: Int) -> Result(Nil, AppError) {
  update_module(module_id, None, None, Some(position))
}

pub fn update_module(
  module_id: Int,
  name: Option(String),
  completed: Option(Bool),
  position: Option(Int),
) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use course_id <- result.try(module_course_id(connection, module_id))
    use validated_name <- result.try(validate_optional_name(name, "Module name"))
    use order_changed <- result.try(
      case position {
        Some(next_position) -> {
          use ordered_module_ids <- result.try(
            moved_module_ids(connection, course_id, module_id, next_position),
          )
          apply_module_order(connection, course_id, ordered_module_ids)
        }
        None -> Ok(False)
      },
    )
    use _ <- result.try(
      case validated_name {
        Some(name) ->
          exec_with_args(
            "update modules set name = ? where id = ?",
            [sqlight.text(name), sqlight.int(module_id)],
            connection,
          )
        None -> Ok(Nil)
      },
    )
    use _ <- result.try(
      case completed {
        Some(done) ->
          exec_with_args(
            "update modules set completed_at = ? where id = ?",
            [
              sqlight.nullable(sqlight.text, completed_at_value(done)),
              sqlight.int(module_id),
            ],
            connection,
          )
        None -> Ok(Nil)
      },
    )
    case validated_name, order_changed {
      Some(_), _ -> clear_course_range(connection, course_id)
      None, True -> clear_course_range(connection, course_id)
      None, False -> Ok(Nil)
    }
  })
}

pub fn reorder_modules(course_id: Int, module_ids: List(Int)) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use _ <- result.try(course_vendor_id(connection, course_id))
    use changed <- result.try(apply_module_order(connection, course_id, module_ids))
    case changed {
      True -> clear_course_range(connection, course_id)
      False -> Ok(Nil)
    }
  })
}

pub fn delete_module(module_id: Int) -> Result(Nil, AppError) {
  apply_mutation(fn(connection) {
    use course_id <- result.try(module_course_id(connection, module_id))
    use _ <- result.try(
      exec_with_args(
        "delete from modules where id = ?",
        [sqlight.int(module_id)],
        connection,
      ),
    )
    use _ <- result.try(resequence_modules(connection, course_id))
    clear_course_range(connection, course_id)
  })
}

fn apply_mutation(
  mutation: fn(sqlight.Connection) -> Result(Nil, AppError),
) -> Result(Nil, AppError) {
  use _ <- result.try(with_db(fn(connection) {
    use _ <- result.try(prepare_schema(connection))
    use _ <- result.try(
      transactional(connection, fn(tx) {
        use _ <- result.try(mutation(tx))
        use _ <- result.try(refresh_schedule_in_transaction(tx))
        Ok(Nil)
      }),
    )
    Ok(Nil)
  }))
  let _ = export_snapshot()
  Ok(Nil)
}

fn with_db(action: fn(sqlight.Connection) -> Result(a, AppError)) -> Result(a, AppError) {
  use connection <- result.try(
    sqlight.open(database_path())
    |> result.map_error(sql_error),
  )
  let outcome = action(connection)
  let close_result = sqlight.close(connection) |> result.map_error(sql_error)
  case outcome {
    Ok(value) ->
      case close_result {
        Ok(_) -> Ok(value)
        Error(error) -> Error(error)
      }
    Error(error) -> {
      let _ = close_result
      Error(error)
    }
  }
}

fn prepare_schema(connection: sqlight.Connection) -> Result(Nil, AppError) {
  use _ <- result.try(exec(connection, "pragma foreign_keys = on"))
  use _ <- result.try(exec(connection, schema_sql))
  use _ <- result.try(ensure_app_settings_column(connection))
  exec(
    connection,
    "
    insert or ignore into app_settings (id, include_weekends, deadline_slack_days)
    values (1, 0, 0)
    ",
  )
}

fn transactional(
  connection: sqlight.Connection,
  action: fn(sqlight.Connection) -> Result(a, AppError),
) -> Result(a, AppError) {
  use _ <- result.try(exec(connection, "begin immediate transaction"))
  case action(connection) {
    Ok(value) ->
      case exec(connection, "commit") {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = exec(connection, "rollback")
          Error(error)
        }
      }
    Error(error) -> {
      let _ = exec(connection, "rollback")
      Error(error)
    }
  }
}

fn import_from_toml(connection: sqlight.Connection) -> Result(#(List(Conflict), List(ScheduleEntry)), AppError) {
  use contents <- result.try(
    simplifile.read(courses_toml_path())
    |> result.map_error(file_error),
  )
  use imported <- result.try(config.parse_courses_toml(contents))
  use _ <- result.try(
    list.try_fold(imported, dict.new(), fn(vendor_ids, imported_course) {
      let vendor_name = imported_course.vendor_name |> string.trim
      let existing_vendor_id = dict.get(vendor_ids, vendor_name)
      let vendor_id_result = case existing_vendor_id {
        Ok(vendor_id) -> Ok(vendor_id)
        Error(_) -> ensure_vendor_id(connection, vendor_name)
      }
      use vendor_id <- result.try(vendor_id_result)

      let module_range = module_range_from_input(imported_course.modules)
      let modules = expand_modules(imported_course.modules)
      use _ <- result.try(validate_modules(modules))
      use course_id <- result.try(
        insert_course_row(
          connection,
          vendor_id,
          imported_course.course_name |> string.trim,
          date.to_iso(imported_course.deadline),
          module_range,
        ),
      )
      use _ <- result.try(insert_modules(connection, course_id, modules))
      Ok(dict.insert(vendor_ids, vendor_name, vendor_id))
    }),
  )

  use courses <- result.try(load_courses(connection))
  use _ <- result.try(
    list.try_fold(imported, Nil, fn(_, imported_course) {
      use vendor_id <- result.try(find_vendor_id(connection, imported_course.vendor_name))
      use course_id <- result.try(
        find_course_id(connection, vendor_id, imported_course.course_name),
      )
      use prerequisite_ids <- result.try(
        resolve_prerequisites(connection, vendor_id, imported_course.prerequisites),
      )
      insert_prerequisites(connection, course_id, prerequisite_ids)
    }),
  )

  let _ = courses
  refresh_schedule_in_transaction(connection)
}

fn refresh_schedule_in_transaction(
  connection: sqlight.Connection,
) -> Result(#(List(Conflict), List(ScheduleEntry)), AppError) {
  use settings <- result.try(load_settings(connection))
  use courses <- result.try(load_courses(connection))
  use #(stored_entries, conflicts, schedule_entries) <- result.try(
    scheduler.rebuild(courses, settings, date.today()),
  )
  use _ <- result.try(exec(connection, "delete from schedule_entries"))
  use _ <- result.try(
    list.try_fold(stored_entries, Nil, fn(_, entry) {
      exec_with_args(
        "
        insert into schedule_entries (module_id, scheduled_date, slot_index)
        values (?, ?, ?)
        ",
        [
          sqlight.int(entry.module_id),
          sqlight.text(date.to_iso(entry.scheduled_date)),
          sqlight.int(entry.slot_index),
        ],
        connection,
      )
    }),
  )
  Ok(#(conflicts, schedule_entries))
}

fn export_snapshot() -> Result(Nil, AppError) {
  with_db(fn(connection) {
    use vendors <- result.try(load_vendors(connection))
    let contents = config.export_courses_toml(vendors)
    simplifile.write(to: courses_toml_path(), contents: contents)
    |> result.map_error(file_error)
  })
}

fn has_courses(connection: sqlight.Connection) -> Result(Bool, AppError) {
  query_one("select count(*) from courses", [], int_decoder(), connection)
  |> result.map(fn(count) { count > 0 })
}

fn load_settings(connection: sqlight.Connection) -> Result(Settings, AppError) {
  query_one(
    "select include_weekends, deadline_slack_days from app_settings where id = 1",
    [],
    settings_row_decoder(),
    connection,
  )
  |> result.map(fn(row) {
    Settings(include_weekends: row.0, deadline_slack_days: row.1)
  })
}

fn merge_settings(current: Settings, patch: SettingsPatch) -> Settings {
  let include_weekends = case patch.include_weekends {
    Some(include_weekends) -> include_weekends
    None -> current.include_weekends
  }
  let deadline_slack_days = case patch.deadline_slack_days {
    Some(deadline_slack_days) -> deadline_slack_days
    None -> current.deadline_slack_days
  }
  Settings(include_weekends:, deadline_slack_days:)
}

fn load_course_update_state(
  connection: sqlight.Connection,
  course_id: Int,
) -> Result(#(Int, String, calendar.Date, List(String)), AppError) {
  use #(vendor_id, name, deadline_text) <- result.try(
    query_one(
      "select vendor_id, name, deadline_date from courses where id = ?",
      [sqlight.int(course_id)],
      course_update_row_decoder(),
      connection,
    ),
  )
  use deadline <- result.try(date.parse_iso(deadline_text))
  use prerequisites <- result.try(load_course_prerequisite_names(connection, course_id))
  Ok(#(vendor_id, name, deadline, prerequisites))
}

fn load_course_prerequisite_names(
  connection: sqlight.Connection,
  course_id: Int,
) -> Result(List(String), AppError) {
  query(
    "
    select prereq.name
    from course_prerequisites cp
    join courses prereq on prereq.id = cp.prerequisite_course_id
    where cp.course_id = ?
    order by prereq.name
    ",
    [sqlight.int(course_id)],
    string_decoder(),
    connection,
  )
}

fn load_vendors(connection: sqlight.Connection) -> Result(List(Vendor), AppError) {
  use vendor_rows <- result.try(
    query(
      "select id, name from vendors order by name",
      [],
      pair_int_string_decoder(),
      connection,
    ),
  )
  use course_rows <- result.try(
    query(
      "
      select
        c.id,
        c.vendor_id,
        v.name,
        c.name,
        c.deadline_date,
        c.module_range_prefix,
        c.module_range_start,
        c.module_range_end
      from courses c
      join vendors v on v.id = c.vendor_id
      order by v.name, c.name
      ",
      [],
      course_row_decoder(),
      connection,
    ),
  )
  use prerequisite_rows <- result.try(
    query(
      "
      select cp.course_id, cp.prerequisite_course_id, prereq.name
      from course_prerequisites cp
      join courses prereq on prereq.id = cp.prerequisite_course_id
      order by cp.course_id, prereq.name
      ",
      [],
      prerequisite_row_decoder(),
      connection,
    ),
  )
  use module_rows <- result.try(
    query(
      "
      select
        m.id,
        m.course_id,
        m.position,
        m.name,
        m.completed_at,
        se.scheduled_date,
        se.slot_index
      from modules m
      left join schedule_entries se on se.module_id = m.id
      order by m.course_id, m.position
      ",
      [],
      module_row_decoder(),
      connection,
    ),
  )

  let prerequisite_ids =
    prerequisite_rows
    |> list.fold(dict.new(), fn(acc, row) {
      let existing = dict.get(acc, row.0) |> result.unwrap([])
      dict.insert(acc, row.0, [row.1, ..existing])
    })
  let prerequisite_names =
    prerequisite_rows
    |> list.fold(dict.new(), fn(acc, row) {
      let existing = dict.get(acc, row.0) |> result.unwrap([])
      dict.insert(acc, row.0, [row.2, ..existing])
    })
  let modules =
    module_rows
    |> list.fold(dict.new(), fn(acc, row) {
      let existing = dict.get(acc, row.1) |> result.unwrap([])
      dict.insert(acc, row.1, [module_from_row(row), ..existing])
    })

  vendor_rows
  |> list.try_map(fn(row) {
    let courses =
      course_rows
      |> list.filter(fn(course) { course.1 == row.0 })
      |> list.try_map(fn(course_row) {
        use deadline <- result.try(date.parse_iso(course_row.4))
        let prerequisite_id_list =
          prerequisite_ids |> dict.get(course_row.0) |> result.unwrap([]) |> list.reverse
        let prerequisite_name_list =
          prerequisite_names
          |> dict.get(course_row.0)
          |> result.unwrap([])
          |> list.reverse
        let course_modules =
          modules |> dict.get(course_row.0) |> result.unwrap([]) |> list.reverse
        Ok(
          Course(
            id: course_row.0,
            vendor_id: course_row.1,
            vendor_name: course_row.2,
            name: course_row.3,
            deadline: deadline,
            prerequisites: prerequisite_name_list,
            prerequisite_ids: prerequisite_id_list,
            module_range: module_range_from_row(course_row),
            modules: course_modules,
          ),
        )
      })

    result.map(courses, fn(courses) { Vendor(id: row.0, name: row.1, courses:) })
  })
}

fn load_courses(connection: sqlight.Connection) -> Result(List(Course), AppError) {
  use vendors <- result.try(load_vendors(connection))
  Ok(
    vendors
    |> list.fold([], fn(acc, vendor) {
      list.append(vendor.courses, acc)
    })
    |> list.reverse
  )
}

fn build_schedule_view(
  entries: List(ScheduleEntry),
  view: String,
  anchor: calendar.Date,
) -> ScheduleView {
  let #(period_start, period_end) = case view {
    "month" -> {
      let month_start = date.start_of_month(anchor)
      let month_end = date.end_of_month(anchor)
      #(date.start_of_week(month_start), date.end_of_week(month_end))
    }
    _ -> #(date.start_of_week(anchor), date.end_of_week(anchor))
  }

  let days =
    days_in_period(period_start, period_end)
    |> list.map(fn(day) {
      let day_entries =
        entries
        |> list.filter(fn(entry) { date.compare(entry.scheduled_date, day) == Eq })
        |> list.sort(fn(left, right) { int.compare(left.slot_index, right.slot_index) })
      ScheduleDay(date: day, entries: day_entries)
    })

  ScheduleView(view:, anchor:, period_start:, period_end:, days:)
}

fn days_in_period(start: calendar.Date, finish: calendar.Date) -> List(calendar.Date) {
  case date.compare(start, finish) {
    Gt -> []
    _ -> [start, ..days_in_period(date.day_after(start), finish)]
  }
}

fn insert_course_row(
  connection: sqlight.Connection,
  vendor_id: Int,
  name: String,
  deadline: String,
  module_range: Option(ModuleRange),
) -> Result(Int, AppError) {
  use _ <- result.try(
    exec_with_args(
      "
      insert into courses (
        vendor_id,
        name,
        deadline_date,
        module_range_prefix,
        module_range_start,
        module_range_end
      ) values (?, ?, ?, ?, ?, ?)
      ",
      [
        sqlight.int(vendor_id),
        sqlight.text(name),
        sqlight.text(deadline),
        sqlight.nullable(sqlight.text, option_map(module_range, fn(range) { range.prefix })),
        sqlight.nullable(sqlight.int, option_map(module_range, fn(range) { range.start })),
        sqlight.nullable(sqlight.int, option_map(module_range, fn(range) { range.end })),
      ],
      connection,
    ),
  )
  query_one("select last_insert_rowid()", [], int_decoder(), connection)
}

fn ensure_vendor_id(connection: sqlight.Connection, name: String) -> Result(Int, AppError) {
  case find_vendor_id(connection, name) {
    Ok(vendor_id) -> Ok(vendor_id)
    Error(_) -> {
      use _ <- result.try(
        exec_with_args(
          "insert into vendors (name) values (?)",
          [sqlight.text(name)],
          connection,
        ),
      )
      query_one("select last_insert_rowid()", [], int_decoder(), connection)
    }
  }
}

fn find_vendor_id(connection: sqlight.Connection, name: String) -> Result(Int, AppError) {
  query_one(
    "select id from vendors where name = ?",
    [sqlight.text(name)],
    int_decoder(),
    connection,
  )
}

fn find_course_id(
  connection: sqlight.Connection,
  vendor_id: Int,
  name: String,
) -> Result(Int, AppError) {
  query_one(
    "select id from courses where vendor_id = ? and name = ?",
    [sqlight.int(vendor_id), sqlight.text(name)],
    int_decoder(),
    connection,
  )
}

fn ensure_vendor_exists(
  connection: sqlight.Connection,
  vendor_id: Int,
) -> Result(Nil, AppError) {
  case query_one(
    "select count(*) from vendors where id = ?",
    [sqlight.int(vendor_id)],
    int_decoder(),
    connection,
  ) {
    Ok(1) -> Ok(Nil)
    Ok(_) -> Error(NotFound("Vendor not found"))
    Error(error) -> Error(error)
  }
}

fn course_vendor_id(
  connection: sqlight.Connection,
  course_id: Int,
) -> Result(Int, AppError) {
  query_one(
    "select vendor_id from courses where id = ?",
    [sqlight.int(course_id)],
    int_decoder(),
    connection,
  )
}

fn module_course_id(
  connection: sqlight.Connection,
  module_id: Int,
) -> Result(Int, AppError) {
  query_one(
    "select course_id from modules where id = ?",
    [sqlight.int(module_id)],
    int_decoder(),
    connection,
  )
}

fn course_module_ids(
  connection: sqlight.Connection,
  course_id: Int,
) -> Result(List(Int), AppError) {
  query(
    "select id from modules where course_id = ? order by position, id",
    [sqlight.int(course_id)],
    int_decoder(),
    connection,
  )
}

fn moved_module_ids(
  connection: sqlight.Connection,
  course_id: Int,
  module_id: Int,
  position: Int,
) -> Result(List(Int), AppError) {
  use module_ids <- result.try(course_module_ids(connection, course_id))
  let module_count = list.length(module_ids)

  case position < 1 || position > module_count {
    True -> Error(Validation("Module position is out of range"))
    False -> {
      let remaining = remove_first(module_ids, module_id)
      Ok(insert_at(remaining, position - 1, module_id))
    }
  }
}

fn apply_module_order(
  connection: sqlight.Connection,
  course_id: Int,
  ordered_module_ids: List(Int),
) -> Result(Bool, AppError) {
  use current_module_ids <- result.try(course_module_ids(connection, course_id))
  use _ <- result.try(validate_module_order(current_module_ids, ordered_module_ids))

  case ordered_module_ids == current_module_ids {
    True -> Ok(False)
    False -> {
      use _ <- result.try(
        ordered_module_ids
        |> list.index_map(fn(module_id, index) { #(0 - index - 1, module_id) })
        |> apply_position_updates(connection),
      )
      use _ <- result.try(
        ordered_module_ids
        |> list.index_map(fn(module_id, index) { #(index + 1, module_id) })
        |> apply_position_updates(connection),
      )
      Ok(True)
    }
  }
}

fn validate_module_order(
  current_module_ids: List(Int),
  ordered_module_ids: List(Int),
) -> Result(Nil, AppError) {
  let invalid_message = "Module order must include every module exactly once"

  case list.length(current_module_ids) == list.length(ordered_module_ids) {
    False -> Error(Validation(invalid_message))
    True -> {
      let remaining =
        current_module_ids
        |> list.fold(dict.new(), fn(acc, module_id) {
          dict.insert(acc, module_id, True)
        })

      use remaining <- result.try(
        ordered_module_ids
        |> list.try_fold(remaining, fn(acc, module_id) {
          case dict.has_key(acc, module_id) {
            True -> Ok(dict.delete(acc, module_id))
            False -> Error(Validation(invalid_message))
          }
        }),
      )

      case dict.size(remaining) == 0 {
        True -> Ok(Nil)
        False -> Error(Validation(invalid_message))
      }
    }
  }
}

fn resolve_prerequisites(
  connection: sqlight.Connection,
  vendor_id: Int,
  names: List(String),
) -> Result(List(Int), AppError) {
  names
  |> list.map(string.trim)
  |> list.filter(fn(name) { name != "" })
  |> list.try_map(fn(name) { find_course_id(connection, vendor_id, name) })
}

fn insert_prerequisites(
  connection: sqlight.Connection,
  course_id: Int,
  prerequisite_ids: List(Int),
) -> Result(Nil, AppError) {
  list.try_fold(prerequisite_ids, Nil, fn(_, prerequisite_id) {
    exec_with_args(
      "
      insert into course_prerequisites (course_id, prerequisite_course_id)
      values (?, ?)
      ",
      [sqlight.int(course_id), sqlight.int(prerequisite_id)],
      connection,
    )
  })
}

fn insert_modules(
  connection: sqlight.Connection,
  course_id: Int,
  modules: List(String),
) -> Result(Nil, AppError) {
  modules
  |> list.index_map(fn(name, index) {
    #(index + 1, name)
  })
  |> list.try_fold(Nil, fn(_, item) {
    let #(position, name) = item
    exec_with_args(
      "
      insert into modules (course_id, position, name, completed_at)
      values (?, ?, ?, null)
      ",
      [sqlight.int(course_id), sqlight.int(position), sqlight.text(name)],
      connection,
    )
  })
}

fn resequence_modules(
  connection: sqlight.Connection,
  course_id: Int,
) -> Result(Nil, AppError) {
  use module_ids <- result.try(course_module_ids(connection, course_id))
  module_ids
  |> list.index_map(fn(module_id, index) { #(index + 1, module_id) })
  |> apply_position_updates(connection)
}

fn apply_position_updates(
  updates: List(#(Int, Int)),
  connection: sqlight.Connection,
) -> Result(Nil, AppError) {
  updates
  |> list.try_fold(Nil, fn(_, item) {
    let #(position, module_id) = item
    exec_with_args(
      "update modules set position = ? where id = ?",
      [sqlight.int(position), sqlight.int(module_id)],
      connection,
    )
  })
}

fn clear_course_range(
  connection: sqlight.Connection,
  course_id: Int,
) -> Result(Nil, AppError) {
  exec_with_args(
    "
    update courses
    set module_range_prefix = null, module_range_start = null, module_range_end = null
    where id = ?
    ",
    [sqlight.int(course_id)],
    connection,
  )
}

fn expand_modules(input: CourseModulesInput) -> List(String) {
  case input {
    ExplicitModules(modules) ->
      modules
      |> list.map(string.trim)
      |> list.filter(fn(name) { name != "" })
    GeneratedRange(range) ->
      range_inclusive(range.start, range.end)
      |> list.map(fn(number) { range.prefix <> int.to_string(number) })
  }
}

fn module_range_from_input(input: CourseModulesInput) -> Option(ModuleRange) {
  case input {
    GeneratedRange(range) -> Some(range)
    ExplicitModules(_) -> None
  }
}

fn validate_optional_name(
  name: Option(String),
  label: String,
) -> Result(Option(String), AppError) {
  case name {
    Some(name) -> validate_name(name, label) |> result.map(Some)
    None -> Ok(None)
  }
}

fn validate_name(name: String, label: String) -> Result(String, AppError) {
  let trimmed = string.trim(name)
  case trimmed == "" {
    True -> Error(Validation(label <> " cannot be empty"))
    False -> Ok(trimmed)
  }
}

fn validate_modules(modules: List(String)) -> Result(Nil, AppError) {
  case modules == [] {
    True -> Error(Validation("A course must contain at least one module"))
    False -> Ok(Nil)
  }
}

fn module_from_row(
  row: #(Int, Int, Int, String, Option(String), Option(String), Option(Int)),
) -> Module {
  Module(
    id: row.0,
    course_id: row.1,
    position: row.2,
    name: row.3,
    completed_at: row.4,
    scheduled_date: option_then(row.5, date.parse_iso),
    slot_index: row.6,
  )
}

fn module_range_from_row(
  row: #(Int, Int, String, String, String, Option(String), Option(Int), Option(Int)),
) -> Option(ModuleRange) {
  case row.5, row.6, row.7 {
    Some(prefix), Some(start), Some(finish) ->
      Some(ModuleRange(prefix:, start:, end: finish))
    _, _, _ -> None
  }
}

fn option_then(value: Option(a), fun: fn(a) -> Result(b, AppError)) -> Option(b) {
  case value {
    Some(value) ->
      case fun(value) {
        Ok(parsed) -> Some(parsed)
        Error(_) -> None
      }
    None -> None
  }
}

fn range_inclusive(start: Int, finish: Int) -> List(Int) {
  case start > finish {
    True -> []
    False ->
      int.range(
        from: start,
        to: finish + 1,
        with: [],
        run: fn(acc, number) { [number, ..acc] },
      )
      |> list.reverse
  }
}

fn completed_at_value(done: Bool) -> Option(String) {
  case done {
    True -> Some(date.to_iso(date.today()))
    False -> None
  }
}

fn remove_first(items: List(Int), item: Int) -> List(Int) {
  case items {
    [] -> []
    [head, ..tail] if head == item -> tail
    [head, ..tail] -> [head, ..remove_first(tail, item)]
  }
}

fn insert_at(items: List(Int), index: Int, item: Int) -> List(Int) {
  case items, index <= 0 {
    _, True -> [item, ..items]
    [], False -> [item]
    [head, ..tail], False -> [head, ..insert_at(tail, index - 1, item)]
  }
}

fn exec(connection: sqlight.Connection, sql: String) -> Result(Nil, AppError) {
  sqlight.exec(sql, on: connection) |> result.map_error(sql_error)
}

fn exec_with_args(
  sql: String,
  arguments: List(sqlight.Value),
  connection: sqlight.Connection,
) -> Result(Nil, AppError) {
  sqlight.query(sql, on: connection, with: arguments, expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(sql_error)
}

fn query(
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
  connection: sqlight.Connection,
) -> Result(List(a), AppError) {
  sqlight.query(sql, on: connection, with: arguments, expecting: decoder)
  |> result.map_error(sql_error)
}

fn query_one(
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
  connection: sqlight.Connection,
) -> Result(a, AppError) {
  use rows <- result.try(query(sql, arguments, decoder, connection))
  case rows {
    [row, .._] -> Ok(row)
    [] -> Error(NotFound("Expected a row but query returned none"))
  }
}

fn course_row_decoder() -> decode.Decoder(#(Int, Int, String, String, String, Option(String), Option(Int), Option(Int))) {
  {
    use id <- decode.field(0, decode.int)
    use vendor_id <- decode.field(1, decode.int)
    use vendor_name <- decode.field(2, decode.string)
    use name <- decode.field(3, decode.string)
    use deadline <- decode.field(4, decode.string)
    use module_range_prefix <- decode.field(5, decode.optional(decode.string))
    use module_range_start <- decode.field(6, decode.optional(decode.int))
    use module_range_end <- decode.field(7, decode.optional(decode.int))
    decode.success(#(
      id,
      vendor_id,
      vendor_name,
      name,
      deadline,
      module_range_prefix,
      module_range_start,
      module_range_end,
    ))
  }
}

fn course_update_row_decoder() -> decode.Decoder(#(Int, String, String)) {
  {
    use vendor_id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    use deadline <- decode.field(2, decode.string)
    decode.success(#(vendor_id, name, deadline))
  }
}

fn prerequisite_row_decoder() -> decode.Decoder(#(Int, Int, String)) {
  {
    use course_id <- decode.field(0, decode.int)
    use prerequisite_id <- decode.field(1, decode.int)
    use prerequisite_name <- decode.field(2, decode.string)
    decode.success(#(course_id, prerequisite_id, prerequisite_name))
  }
}

fn module_row_decoder() -> decode.Decoder(#(Int, Int, Int, String, Option(String), Option(String), Option(Int))) {
  {
    use id <- decode.field(0, decode.int)
    use course_id <- decode.field(1, decode.int)
    use position <- decode.field(2, decode.int)
    use name <- decode.field(3, decode.string)
    use completed_at <- decode.field(4, decode.optional(decode.string))
    use scheduled_date <- decode.field(5, decode.optional(decode.string))
    use slot_index <- decode.field(6, decode.optional(decode.int))
    decode.success(#(id, course_id, position, name, completed_at, scheduled_date, slot_index))
  }
}

fn pair_int_string_decoder() -> decode.Decoder(#(Int, String)) {
  {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(#(id, name))
  }
}

fn int_decoder() -> decode.Decoder(Int) {
  decode.field(0, decode.int, decode.success)
}

fn string_decoder() -> decode.Decoder(String) {
  decode.field(0, decode.string, decode.success)
}

fn settings_row_decoder() -> decode.Decoder(#(Bool, Int)) {
  {
    use include_weekends <- decode.field(0, sqlight.decode_bool())
    use deadline_slack_days <- decode.field(1, decode.int)
    decode.success(#(include_weekends, deadline_slack_days))
  }
}

fn ensure_app_settings_column(connection: sqlight.Connection) -> Result(Nil, AppError) {
  case sqlight.exec(
    "
    alter table app_settings
    add column deadline_slack_days integer not null default 0
    ",
    on: connection,
  ) {
    Ok(_) -> Ok(Nil)
    Error(error) ->
      case string.contains(error.message, "duplicate column name") {
        True -> Ok(Nil)
        False -> Error(sql_error(error))
      }
  }
}

fn sql_error(error: sqlight.Error) -> AppError {
  Database("SQLite error: " <> error.message)
}

fn file_error(error: simplifile.FileError) -> AppError {
  IOError("File error: " <> string.inspect(error))
}

fn bool_not(value: Bool) -> Bool {
  case value {
    True -> False
    False -> True
  }
}

fn path_from_env(name: String, fallback: String) -> String {
  non_empty_env(name) |> result.unwrap(fallback)
}

fn non_empty_env(name: String) -> Result(String, Nil) {
  case env.get(name) {
    Ok("") -> Error(Nil)
    result -> result
  }
}

fn default_database_path_equivalent(path: String) -> Bool {
  let current_directory = simplifile.current_directory() |> result.unwrap(".")
  let default_absolute = filepath.join(current_directory, default_database_path)

  case filepath.is_absolute(path) {
    True -> path == default_absolute
    False ->
      case string.starts_with(path, "./") {
        True -> string.drop_start(path, 2) == default_database_path
        False -> path == default_database_path
      }
  }
}

fn derive_courses_toml_path(database_path: String) -> String {
  let directory = filepath.directory_name(database_path)
  let stem =
    database_path
    |> filepath.strip_extension
    |> filepath.base_name

  filepath.join(directory, stem <> ".courses.toml")
}

fn option_map(value: Option(a), fun: fn(a) -> b) -> Option(b) {
  case value {
    Some(value) -> Some(fun(value))
    None -> None
  }
}

const schema_sql = "
create table if not exists vendors (
  id integer primary key autoincrement,
  name text not null unique
);

create table if not exists courses (
  id integer primary key autoincrement,
  vendor_id integer not null references vendors(id) on delete cascade,
  name text not null,
  deadline_date text not null,
  module_range_prefix text,
  module_range_start integer,
  module_range_end integer,
  unique(vendor_id, name)
);

create table if not exists course_prerequisites (
  course_id integer not null references courses(id) on delete cascade,
  prerequisite_course_id integer not null references courses(id) on delete cascade,
  primary key (course_id, prerequisite_course_id)
);

create table if not exists modules (
  id integer primary key autoincrement,
  course_id integer not null references courses(id) on delete cascade,
  position integer not null,
  name text not null,
  completed_at text,
  unique(course_id, position)
);

create table if not exists schedule_entries (
  module_id integer primary key references modules(id) on delete cascade,
  scheduled_date text not null,
  slot_index integer not null
);

create table if not exists app_settings (
  id integer primary key,
  include_weekends integer not null,
  deadline_slack_days integer not null default 0
);
"
