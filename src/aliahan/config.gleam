import aliahan/date
import aliahan/model
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import tom

pub type ImportedCourse {
  ImportedCourse(
    vendor_name: String,
    course_name: String,
    deadline: calendar.Date,
    prerequisites: List(String),
    modules: model.CourseModulesInput,
  )
}

pub fn parse_courses_toml(
  contents: String,
) -> Result(List(ImportedCourse), model.AppError) {
  use parsed <- result.try(
    tom.parse(contents)
    |> result.map_error(fn(error) {
      model.Parse("Could not parse courses.toml: " <> string.inspect(error))
    }),
  )

  parsed
  |> dict.to_list
  |> list.try_fold([], fn(acc, vendor_entry) {
    let #(vendor_name, value) = vendor_entry
    use courses <- result.try(parse_vendor(vendor_name, value))
    Ok(list.reverse(courses) |> list.append(acc))
  })
  |> result.map(list.reverse)
}

pub fn export_courses_toml(vendors: List(model.Vendor)) -> String {
  vendors
  |> sort_vendors
  |> list.fold([], fn(acc, vendor) {
    vendor.courses
    |> sort_courses
    |> list.fold(acc, fn(inner, course) {
      [course_to_toml(vendor.name, course), ..inner]
    })
  })
  |> list.reverse
  |> string.join(with: "\n\n")
  |> append_trailing_newline
}

fn parse_vendor(
  vendor_name: String,
  value: tom.Toml,
) -> Result(List(ImportedCourse), model.AppError) {
  case value {
    tom.Table(courses) | tom.InlineTable(courses) ->
      courses
      |> dict.to_list
      |> list.try_fold([], fn(acc, course_entry) {
        let #(course_name, course_value) = course_entry
        use course <- result.try(parse_course(
          vendor_name,
          course_name,
          course_value,
        ))
        Ok([course, ..acc])
      })
    other ->
      Error(model.Parse(
        "Expected vendor table for "
        <> vendor_name
        <> ", got "
        <> string.inspect(other),
      ))
  }
}

fn parse_course(
  vendor_name: String,
  course_name: String,
  value: tom.Toml,
) -> Result(ImportedCourse, model.AppError) {
  let table = case value {
    tom.Table(table) | tom.InlineTable(table) -> Ok(table)
    other ->
      Error(model.Parse(
        "Expected course table for "
        <> vendor_name
        <> " / "
        <> course_name
        <> ", got "
        <> string.inspect(other),
      ))
  }

  use table <- result.try(table)
  use deadline <- result.try(parse_deadline(table, vendor_name, course_name))
  use prerequisites <- result.try(
    parse_string_array(table, "prerequisites", []),
  )
  use modules <- result.try(parse_modules(table, vendor_name, course_name))

  Ok(ImportedCourse(
    vendor_name: vendor_name,
    course_name: course_name,
    deadline: deadline,
    prerequisites: prerequisites,
    modules: modules,
  ))
}

fn parse_deadline(
  table: dict.Dict(String, tom.Toml),
  vendor_name: String,
  course_name: String,
) -> Result(calendar.Date, model.AppError) {
  case tom.get(table, ["deadline"]) {
    Ok(tom.Date(date)) -> Ok(date)
    Ok(tom.DateTime(date:, ..)) -> Ok(date)
    Ok(other) ->
      Error(model.Parse(
        "Deadline for "
        <> vendor_name
        <> " / "
        <> course_name
        <> " must be a TOML date or datetime, got "
        <> string.inspect(other),
      ))
    Error(_) ->
      Error(model.Parse(
        "Missing deadline for " <> vendor_name <> " / " <> course_name,
      ))
  }
}

fn parse_modules(
  table: dict.Dict(String, tom.Toml),
  vendor_name: String,
  course_name: String,
) -> Result(model.CourseModulesInput, model.AppError) {
  use modules <- result.try(optional_string_array(table, "modules"))
  use module_range <- result.try(optional_module_range(table))

  case modules, module_range {
    Some(modules), None -> Ok(model.ExplicitModules(modules))
    None, Some(module_range) -> Ok(model.GeneratedRange(module_range))
    Some(_), Some(_) ->
      Error(model.Parse(
        "Course "
        <> vendor_name
        <> " / "
        <> course_name
        <> " cannot define both modules and module_range",
      ))
    None, None ->
      Error(model.Parse(
        "Course "
        <> vendor_name
        <> " / "
        <> course_name
        <> " must define either modules or module_range",
      ))
  }
}

fn optional_string_array(
  table: dict.Dict(String, tom.Toml),
  key: String,
) -> Result(Option(List(String)), model.AppError) {
  case tom.get_array(table, [key]) {
    Ok(items) ->
      items
      |> list.try_map(fn(item) {
        case item {
          tom.String(value) -> Ok(value)
          _ -> Error(model.Parse(key <> " must contain only strings"))
        }
      })
      |> result.map(Some)
    Error(tom.NotFound(_)) -> Ok(None)
    Error(_) -> Error(model.Parse(key <> " must be an array"))
  }
}

fn parse_string_array(
  table: dict.Dict(String, tom.Toml),
  key: String,
  default: List(String),
) -> Result(List(String), model.AppError) {
  case tom.get_array(table, [key]) {
    Ok(items) ->
      items
      |> list.try_map(fn(item) {
        case item {
          tom.String(value) -> Ok(value)
          _ -> Error(model.Parse(key <> " must contain only strings"))
        }
      })
    Error(tom.NotFound(_)) -> Ok(default)
    Error(_) -> Error(model.Parse(key <> " must be an array"))
  }
}

fn optional_module_range(
  table: dict.Dict(String, tom.Toml),
) -> Result(Option(model.ModuleRange), model.AppError) {
  let range_table = case tom.get_table(table, ["module_range"]) {
    Ok(range_table) -> Ok(Some(range_table))
    Error(tom.NotFound(_)) -> Ok(None)
    Error(_) -> Error(model.Parse("module_range must be a table"))
  }
  use range_table <- result.try(range_table)
  case range_table {
    None -> Ok(None)
    Some(range_table) -> parse_module_range(range_table) |> result.map(Some)
  }
}

fn parse_module_range(
  range_table: dict.Dict(String, tom.Toml),
) -> Result(model.ModuleRange, model.AppError) {
  use prefix <- result.try(
    tom.get_string(range_table, ["prefix"])
    |> result.map_error(fn(_) {
      model.Parse("module_range.prefix must be a string")
    }),
  )
  use start <- result.try(
    tom.get_int(range_table, ["start"])
    |> result.map_error(fn(_) {
      model.Parse("module_range.start must be an integer")
    }),
  )
  use finish <- result.try(
    tom.get_int(range_table, ["end"])
    |> result.map_error(fn(_) {
      model.Parse("module_range.end must be an integer")
    }),
  )
  Ok(model.ModuleRange(prefix:, start:, end: finish))
}

fn course_to_toml(vendor_name: String, course: model.Course) -> String {
  let header =
    "[" <> toml_string(vendor_name) <> "." <> toml_string(course.name) <> "]"

  let prerequisites = case course.prerequisites {
    [] -> []
    prerequisites -> [
      "prerequisites = " <> toml_string_array(prerequisites),
    ]
  }

  let modules = case course.module_range {
    Some(range) -> [
      "module_range = { prefix = "
      <> toml_string(range.prefix)
      <> ", start = "
      <> int.to_string(range.start)
      <> ", end = "
      <> int.to_string(range.end)
      <> " }",
    ]
    None -> [
      "modules = "
      <> toml_string_array(
        course.modules |> list.map(fn(module) { module.name }),
      ),
    ]
  }

  let deadline = "deadline = " <> date.rfc3339_deadline(course.deadline)

  [header, ..prerequisites]
  |> list.append(modules)
  |> list.append([deadline])
  |> string.join(with: "\n")
}

fn toml_string_array(values: List(String)) -> String {
  let rendered =
    values
    |> list.map(toml_string)
    |> string.join(with: ", ")
  "[ " <> rendered <> " ]"
}

fn toml_string(value: String) -> String {
  let escaped =
    value
    |> string.replace(each: "\\", with: "\\\\")
    |> string.replace(each: "\"", with: "\\\"")
  "\"" <> escaped <> "\""
}

fn sort_vendors(vendors: List(model.Vendor)) -> List(model.Vendor) {
  list.sort(vendors, by: fn(left, right) {
    string.compare(left.name, right.name)
  })
}

fn sort_courses(courses: List(model.Course)) -> List(model.Course) {
  list.sort(courses, by: fn(left, right) {
    string.compare(left.name, right.name)
  })
}

fn append_trailing_newline(contents: String) -> String {
  case contents == "" {
    True -> contents
    False -> contents <> "\n"
  }
}
