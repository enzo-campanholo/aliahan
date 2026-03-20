import aliahan/model.{type AppError, Parse}
import gleam/int
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp

pub fn today() -> calendar.Date {
  let #(date, _) =
    timestamp.system_time()
    |> timestamp.to_calendar(calendar.local_offset())
  date
}

pub fn compare(left: calendar.Date, right: calendar.Date) -> Order {
  case int.compare(left.year, right.year) {
    Eq ->
      case int.compare(
        calendar.month_to_int(left.month),
        calendar.month_to_int(right.month),
      ) {
        Eq -> int.compare(left.day, right.day)
        other -> other
      }
    other -> other
  }
}

pub fn min(left: calendar.Date, right: calendar.Date) -> calendar.Date {
  case compare(left, right) {
    Gt -> right
    _ -> left
  }
}

pub fn max(left: calendar.Date, right: calendar.Date) -> calendar.Date {
  case compare(left, right) {
    Lt -> right
    _ -> left
  }
}

pub fn to_iso(date: calendar.Date) -> String {
  let year = int.to_string(date.year) |> string.pad_start(4, "0")
  let month =
    date.month
    |> calendar.month_to_int
    |> int.to_string
    |> string.pad_start(2, "0")
  let day = int.to_string(date.day) |> string.pad_start(2, "0")
  year <> "-" <> month <> "-" <> day
}

pub fn parse_iso(input: String) -> Result(calendar.Date, AppError) {
  case string.split(input, on: "-") {
    [year, month, day] -> {
      use year <- result.try(parse_part(year, "Invalid year in date"))
      use month <- result.try(parse_part(month, "Invalid month in date"))
      use day <- result.try(parse_part(day, "Invalid day in date"))
      use month <- result.try(
        calendar.month_from_int(month)
        |> result.map_error(fn(_) { Parse("Invalid month in date: " <> input) }),
      )
      let date = calendar.Date(year:, month:, day:)
      case calendar.is_valid_date(date) {
        True -> Ok(date)
        False -> Error(Parse("Invalid date: " <> input))
      }
    }
    _ -> Error(Parse("Expected YYYY-MM-DD date"))
  }
}

pub fn add_days(date: calendar.Date, amount: Int) -> calendar.Date {
  let midnight = calendar.TimeOfDay(0, 0, 0, 0)
  timestamp.from_calendar(date: date, time: midnight, offset: calendar.utc_offset)
  |> timestamp.add(duration.hours(24 * amount))
  |> timestamp.to_calendar(calendar.utc_offset)
  |> first
}

pub fn day_after(date: calendar.Date) -> calendar.Date {
  add_days(date, 1)
}

pub fn day_before(date: calendar.Date) -> calendar.Date {
  add_days(date, -1)
}

pub fn days_in_month(year: Int, month: calendar.Month) -> Int {
  case month {
    calendar.January
    | calendar.March
    | calendar.May
    | calendar.July
    | calendar.August
    | calendar.October
    | calendar.December -> 31
    calendar.April | calendar.June | calendar.September | calendar.November -> 30
    calendar.February ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
  }
}

pub fn start_of_week(date: calendar.Date) -> calendar.Date {
  add_days(date, 1 - weekday_number(date))
}

pub fn end_of_week(date: calendar.Date) -> calendar.Date {
  add_days(start_of_week(date), 6)
}

pub fn start_of_month(date: calendar.Date) -> calendar.Date {
  calendar.Date(year: date.year, month: date.month, day: 1)
}

pub fn end_of_month(date: calendar.Date) -> calendar.Date {
  calendar.Date(
    year: date.year,
    month: date.month,
    day: days_in_month(date.year, date.month),
  )
}

pub fn shift_months(date: calendar.Date, amount: Int) -> calendar.Date {
  let absolute_month = calendar.month_to_int(date.month) + amount - 1
  let year_shift = floor_div(absolute_month, 12)
  let month_index = modulo(absolute_month, 12) + 1
  let assert Ok(month) = calendar.month_from_int(month_index)
  let year = date.year + year_shift
  let day = min_int(date.day, days_in_month(year, month))
  calendar.Date(year:, month:, day:)
}

pub fn weekday_number(date: calendar.Date) -> Int {
  let month = calendar.month_to_int(date.month)
  let adjusted_year = case month < 3 {
    True -> date.year - 1
    False -> date.year
  }
  let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  let month_offset = list_nth(offsets, month - 1)
  let value =
    adjusted_year
    + adjusted_year / 4
    - adjusted_year / 100
    + adjusted_year / 400
    + month_offset
    + date.day
  let sunday_based = modulo(value, 7)
  case sunday_based {
    0 -> 7
    _ -> sunday_based
  }
}

pub fn is_weekend(date: calendar.Date) -> Bool {
  let weekday = weekday_number(date)
  weekday == 6 || weekday == 7
}

pub fn rfc3339_deadline(date: calendar.Date) -> String {
  let end_of_day = calendar.TimeOfDay(23, 59, 59, 0)
  timestamp.from_calendar(
    date: date,
    time: end_of_day,
    offset: calendar.local_offset(),
  )
  |> timestamp.to_rfc3339(calendar.local_offset())
}

pub fn label(date: calendar.Date) -> String {
  let weekday = case weekday_number(date) {
    1 -> "Mon"
    2 -> "Tue"
    3 -> "Wed"
    4 -> "Thu"
    5 -> "Fri"
    6 -> "Sat"
    _ -> "Sun"
  }
  weekday <> " " <> to_iso(date)
}

fn parse_part(input: String, message: String) -> Result(Int, AppError) {
  input
  |> int.parse
  |> result.map_error(fn(_) { Parse(message) })
}

fn first(pair: #(a, b)) -> a {
  let #(value, _) = pair
  value
}

fn floor_div(left: Int, right: Int) -> Int {
  case left >= 0 {
    True -> left / right
    False -> {
      let positive = -left
      let adjusted = positive + right - 1
      let rounded = adjusted / right
      0 - rounded
    }
  }
}

fn modulo(left: Int, right: Int) -> Int {
  let result = left % right
  case result < 0 {
    True -> result + right
    False -> result
  }
}

fn min_int(left: Int, right: Int) -> Int {
  case int.compare(left, right) {
    Gt -> right
    _ -> left
  }
}

fn is_leap_year(year: Int) -> Bool {
  let divisible_by_400 = year % 400 == 0
  let divisible_by_4 = year % 4 == 0
  let divisible_by_100 = year % 100 == 0
  case divisible_by_400 {
    True -> True
    False ->
      case divisible_by_4, divisible_by_100 {
        True, False -> True
        _, _ -> False
      }
  }
}

fn list_nth(values: List(Int), index: Int) -> Int {
  case values, index {
    [value, .._], 0 -> value
    [_, ..rest], _ -> list_nth(rest, index - 1)
    [], _ -> 0
  }
}
