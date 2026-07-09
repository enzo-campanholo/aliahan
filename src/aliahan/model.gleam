import gleam/option.{type Option}
import gleam/time/calendar

pub type AppError {
  Validation(message: String)
  NotFound(message: String)
  IOError(message: String)
  Database(message: String)
  Parse(message: String)
  Unexpected(message: String)
}

pub fn error_message(error: AppError) -> String {
  case error {
    Validation(message)
    | NotFound(message)
    | IOError(message)
    | Database(message)
    | Parse(message)
    | Unexpected(message) -> message
  }
}

pub type ModuleRange {
  ModuleRange(prefix: String, start: Int, end: Int)
}

pub type CourseModulesInput {
  ExplicitModules(List(String))
  GeneratedRange(ModuleRange)
}

pub type NewCourseInput {
  NewCourseInput(
    vendor_id: Int,
    name: String,
    deadline: calendar.Date,
    prerequisites: List(String),
    modules: CourseModulesInput,
  )
}

pub type UpdateCourseInput {
  UpdateCourseInput(
    name: Option(String),
    deadline: Option(calendar.Date),
    prerequisites: Option(List(String)),
  )
}

pub type SettingsPatch {
  SettingsPatch(
    include_weekends: Option(Bool),
    deadline_slack_days: Option(Int),
  )
}

pub type Settings {
  Settings(include_weekends: Bool, deadline_slack_days: Int)
}

pub type Module {
  Module(
    id: Int,
    course_id: Int,
    position: Int,
    name: String,
    completed_at: Option(String),
    scheduled_date: Option(calendar.Date),
    slot_index: Option(Int),
  )
}

pub type Course {
  Course(
    id: Int,
    vendor_id: Int,
    vendor_name: String,
    name: String,
    deadline: calendar.Date,
    prerequisites: List(String),
    prerequisite_ids: List(Int),
    module_range: Option(ModuleRange),
    modules: List(Module),
  )
}

pub type Vendor {
  Vendor(id: Int, name: String, courses: List(Course))
}

pub type Conflict {
  Conflict(
    course_id: Int,
    vendor_name: String,
    course_name: String,
    message: String,
  )
}

pub type ScheduleEntry {
  ScheduleEntry(
    module_id: Int,
    vendor_name: String,
    course_name: String,
    module_name: String,
    scheduled_date: calendar.Date,
    slot_index: Int,
  )
}

pub type ScheduleDay {
  ScheduleDay(date: calendar.Date, entries: List(ScheduleEntry))
}

pub type ScheduleView {
  ScheduleView(
    view: String,
    anchor: calendar.Date,
    period_start: calendar.Date,
    period_end: calendar.Date,
    days: List(ScheduleDay),
  )
}

pub type BootstrapData {
  BootstrapData(
    today: calendar.Date,
    schedule_start: calendar.Date,
    settings: Settings,
    vendors: List(Vendor),
    conflicts: List(Conflict),
    schedule: ScheduleView,
  )
}
