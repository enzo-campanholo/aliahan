import aliahan/config
import aliahan/date
import aliahan/env
import aliahan/model
import aliahan/store
import aliahan/scheduler
import aliahan/web
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Lt}
import gleam/string
import gleam/time/calendar
import gleeunit
import simplifile
import wisp/simulate

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

pub fn index_html_uses_local_alpine_bundle_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(body, "/static/alpine.min.js")
  assert string.contains(body, "cdn.jsdelivr.net") == False
  assert string.contains(body, "@alpinejs/collapse") == False
}

pub fn index_html_resets_and_hides_schedule_popovers_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "x-effect=\"$store.ui.tab === 'schedule' || resetPopover()\"",
  )
  assert string.contains(
    body,
    "x-show=\"popover.open && $store.app.view === 'month' && $store.ui.tab === 'schedule'\"",
  )
  assert string.contains(
    body,
    "x-show=\"popover.open && $store.app.view === 'week'\"",
  )
  assert string.contains(body, "@click.outside=\"resetPopover()\"") == False
  assert string.contains(body, "@click=\"resetPopover()\" aria-label=\"Close\"")
}

pub fn index_html_shows_bootstrap_error_fallback_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "x-show=\"!$store.app.loading && !$store.app.data && $store.app.error\"",
  )
  assert string.contains(body, "@click=\"$store.app.init()\">Retry</button>")
}

pub fn index_html_disables_settings_without_bootstrap_data_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(body, ":disabled=\"!$store.app.data?.settings\"")
  assert string.contains(
    body,
    "@click=\"$store.app.data?.settings && ($store.ui.settingsOpen = !$store.ui.settingsOpen)\"",
  )
  assert string.contains(
    body,
    "x-show=\"$store.ui.settingsOpen && $store.app.data?.settings\"",
  )
}

pub fn index_html_disables_add_course_without_vendors_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "@click=\"($store.app.data?.vendors || []).length > 0 && ($store.ui.modalOpen = true)\"",
  )
  assert string.contains(
    body,
    ":disabled=\"($store.app.data?.vendors || []).length === 0\"",
  )
  assert string.contains(body, "No vendors yet")
  assert string.contains(body, "class=\"btn text-sm mx-auto\" disabled>+ Add Course</button>")
}

pub fn index_html_passes_event_to_module_toggle_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(body, "@change=\"toggleModule(mod, $event)\"")
}

pub fn app_js_shares_vendor_color_revision_across_views_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "const VENDOR_COLOR_KEY = \"aliahan_vendor_colors_v2\";")
  assert string.contains(body, "const colors = Object.create(null);")
  assert string.contains(
    body,
    "return normalizeVendorColors(JSON.parse(localStorage.getItem(VENDOR_COLOR_KEY)));",
  )
  assert string.contains(body, "vendorColorRevision: 0")
  assert string.contains(
    body,
    "vendorColor(name) {\n      void Alpine.store(\"ui\").vendorColorRevision;",
  )
  assert string.contains(
    body,
    "getVendorColor(vendorName) {\n      void Alpine.store(\"ui\").vendorColorRevision;",
  )
  assert string.contains(
    body,
    "if (!Object.prototype.hasOwnProperty.call(vendorColors, vendorName)) return null;",
  )
  assert string.contains(body, "return typeof color === \"string\" ? color : null;")
  assert string.contains(body, "const explicit = getVendorColor(vendorName);")
  assert string.contains(body, "return vendorName ? vendorColorFallback(vendorName) : VENDOR_COLORS[0];")
  assert string.contains(body, "ui.vendorColorRevision += 1")
  assert string.contains(body, "vendorColors[vendorId]") == False
}

pub fn app_js_mutate_treats_refresh_separately_from_write_success_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "await api(path, options);")
  assert string.contains(body, "await this.refresh();\n        return true;")
  assert string.contains(body, "return await this.refresh();") == False
}

pub fn app_js_reverts_checkbox_after_failed_module_toggle_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "_moduleCompletionPending: Object.create(null),")
  assert string.contains(body, "isModuleCompletionSaving(moduleId) {")
  assert string.contains(body, "async toggleModule(mod, event)")
  assert string.contains(
    body,
    "if (this.isModuleCompletionSaving(mod.id)) {\n        event.target.checked = !!this._moduleCompletionPending[mod.id];\n        return;\n      }",
  )
  assert string.contains(body, "this._moduleCompletionPending[mod.id] = checked;")
  assert string.contains(body, "event.target.disabled = true;")
  assert string.contains(body, "event.target.checked = !!mod.completed_at;")
  assert string.contains(body, "delete this._moduleCompletionPending[mod.id];")
  assert string.contains(
    body,
    "if (event.target.isConnected) {\n          event.target.disabled = false;\n        }",
  )
}

pub fn app_js_reverts_controls_after_failed_settings_update_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "async toggleWeekends(event)")
  assert string.contains(body, "event.target.checked = !!settings.include_weekends;")
  assert string.contains(body, "async updateSlackDays(event)")
  assert string.contains(body, "event.target.value = String(settings.deadline_slack_days);")
}

pub fn app_js_settings_and_courses_only_patch_changed_fields_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(
    body,
    "body: JSON.stringify({\n          include_weekends: includeWeekends,\n        }),",
  )
  assert string.contains(
    body,
    "body: JSON.stringify({\n          deadline_slack_days: deadlineSlackDays,\n        }),",
  )
  assert string.contains(body, "body: JSON.stringify(changes),")
  assert string.contains(body, "deadline_slack_days: settings.deadline_slack_days") == False
  assert string.contains(body, "include_weekends: settings.include_weekends") == False
  assert string.contains(body, "name: changes.name ?? course.name") == False
}

pub fn app_js_preserves_drag_snapshot_until_reorder_finishes_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(
    body,
    "if (this._saving) {\n        event.preventDefault();\n        return;\n      }",
  )
  assert string.contains(
    body,
    "const dragSnapshot = this._dragSnapshot ? this._dragSnapshot.slice() : null;",
  )
  assert string.contains(body, "this.restoreDragSnapshot(dragSnapshot);")
  assert string.contains(
    body,
    "if (!this._saving) {\n        this._dragSnapshot = null;\n        this._dropHandled = false;\n      }",
  )
  assert string.contains(body, "restoreDragSnapshot(snapshot = this._dragSnapshot)")
}

pub fn app_js_calendar_popover_tracks_full_day_entries_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(
    body,
    "popover: { open: false, entry: null, entries: [], completing: false }",
  )
  assert string.contains(body, "selectPopoverEntry(entry) {")
  assert string.contains(body, "openPopover(entries, entry = entries?.[0]) {")
  assert string.contains(body, "entries: entries.slice(),")
}

pub fn index_html_schedule_overflow_opens_day_popover_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(body, "@click=\"openPopover(day.entries, entry)\"")
  assert string.contains(body, "@click=\"openPopover(day.entries, day.entries[3])\"")
  assert string.contains(body, "@click=\"openPopover(day.entries, day.entries[2])\"")
  assert string.contains(body, "x-show=\"popover.entries.length > 1\"")
  assert string.contains(body, "x-for=\"entry in popover.entries\"")
}

pub fn index_html_vendor_color_picker_uses_vendor_names_test() {
  let response = web.handle(simulate.request(http.Get, "/"), "priv")
  assert response.status == 200

  let body = simulate.read_body(response)
  assert string.contains(body, "getVendorColor(vendor.name)")
  assert string.contains(body, "@click=\"setVendorColor(vendor.name, c)\"")
  assert string.contains(body, "getVendorColor(vendor.id)") == False
  assert string.contains(body, "setVendorColor(vendor.id, c)") == False
}

pub fn app_js_optimistically_updates_calendar_targets_before_bootstrap_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "today() {\n      return this.data?.today || todayIso();\n    },")
  assert string.contains(body, "_bootstrapRequestId: 0")
  assert string.contains(body, "const requestId = ++this._bootstrapRequestId;")
  assert string.contains(
    body,
    "const targetAnchor = anchor || todayIso();\n      this.error = \"\";\n      this.view = view;\n      this.anchor = targetAnchor;",
  )
  assert string.contains(body, "if (requestId !== this._bootstrapRequestId) return true;")
  assert string.contains(
    body,
    "const schedule = this.data?.schedule;\n        if (schedule) {\n          this.view = schedule.view;\n          this.anchor = schedule.anchor;\n        }",
  )
  assert string.contains(body, "return dateStr === Alpine.store(\"app\").today();")
  assert string.contains(body, "anchor: app.today(),")
  assert string.contains(body, "deadline_date: Alpine.store(\"app\").today(),")
}

pub fn app_js_keeps_loading_until_latest_bootstrap_finishes_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "_loadingRequestId: 0")
  assert string.contains(
    body,
    "if (showLoading) {\n        this.loading = true;\n        this._loadingRequestId = requestId;\n      }",
  )
  assert string.contains(
    body,
    "if (showLoading && requestId === this._loadingRequestId) {\n          this.loading = false;\n          this._loadingRequestId = 0;\n        }",
  )
}

pub fn app_js_keeps_calendar_faded_until_latest_navigation_finishes_test() {
  let assert Ok(body) = simplifile.read("priv/app.js")
  assert string.contains(body, "_fadeRequestId: 0")
  assert string.contains(body, "const fadeRequestId = ++this._fadeRequestId;")
  assert string.contains(
    body,
    "try {\n        await fn();\n      } finally {\n        if (fadeRequestId === this._fadeRequestId) this._fading = false;\n      }",
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

pub fn patch_module_returns_error_and_keeps_state_test() {
  with_isolated_store("patch_module_returns_error_and_keeps_state", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Atomic",
        modules: model.ExplicitModules(["First", "Second"]),
      )
    let assert [first, .._] = course.modules

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
    let assert [updated_first, .._] = updated.modules
    assert updated_first.name == "First"
    assert updated_first.completed_at == None
  })
}

pub fn patch_settings_preserves_deadline_slack_days_when_omitted_test() {
  with_isolated_store("patch_settings_preserves_deadline_slack_days_when_omitted", fn(_, _) {
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
      |> simulate.json_body(json.object([#("include_weekends", json.bool(True))]))
    let response = web.handle(request, "priv")

    assert response.status == 200
    let settings = bootstrap_data().settings
    assert settings.include_weekends == True
    assert settings.deadline_slack_days == 3
  })
}

pub fn patch_settings_preserves_include_weekends_when_omitted_test() {
  with_isolated_store("patch_settings_preserves_include_weekends_when_omitted", fn(_, _) {
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
      |> simulate.json_body(json.object([#("deadline_slack_days", json.int(4))]))
    let response = web.handle(request, "priv")

    assert response.status == 200
    let settings = bootstrap_data().settings
    assert settings.include_weekends == True
    assert settings.deadline_slack_days == 4
  })
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
  with_isolated_store("patch_course_preserves_previous_name_when_updating_deadline", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Original",
        modules: model.ExplicitModules(["Only module"]),
      )

    let rename_request =
      simulate.request(http.Patch, "/api/courses/" <> int.to_string(course.id))
      |> simulate.json_body(json.object([#("name", json.string("Renamed"))]))
    let rename_response = web.handle(rename_request, "priv")
    assert rename_response.status == 200

    let deadline_request =
      simulate.request(http.Patch, "/api/courses/" <> int.to_string(course.id))
      |> simulate.json_body(
        json.object([#("deadline_date", json.string("2026-05-15"))]),
      )
    let deadline_response = web.handle(deadline_request, "priv")
    assert deadline_response.status == 200

    let updated = course_by_id(course.id)
    assert updated.name == "Renamed"
    assert updated.deadline == calendar.Date(2026, calendar.May, 15)
    assert updated.prerequisites == []
  })
}

pub fn patch_course_prerequisites_preserve_name_and_deadline_test() {
  with_isolated_store("patch_course_prerequisites_preserve_name_and_deadline", fn(_, _) {
    let assert Ok(Nil) = store.initialise()
    let assert Ok(Nil) = store.create_vendor("Vendor")
    let vendor = vendor_named("Vendor")

    let assert Ok(Nil) = store.create_course(
      model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Intro",
        deadline: calendar.Date(2026, calendar.April, 10),
        prerequisites: [],
        modules: model.ExplicitModules(["Intro 1"]),
      ),
    )
    let assert Ok(Nil) = store.create_course(
      model.NewCourseInput(
        vendor_id: vendor.id,
        name: "Main",
        deadline: calendar.Date(2026, calendar.April, 30),
        prerequisites: [],
        modules: model.ExplicitModules(["Main 1"]),
      ),
    )
    let course = course_named("Vendor", "Main")

    let request =
      simulate.request(http.Patch, "/api/courses/" <> int.to_string(course.id))
      |> simulate.json_body(
        json.object([
          #(
            "prerequisites",
            json.array(from: ["Intro"], of: json.string),
          ),
        ]),
      )
    let response = web.handle(request, "priv")

    assert response.status == 200
    let updated = course_by_id(course.id)
    assert updated.name == "Main"
    assert updated.deadline == calendar.Date(2026, calendar.April, 30)
    assert updated.prerequisites == ["Intro"]
  })
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
    assert module_names(course_named("Vendor", "Positions").modules) == [
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
    assert module_names(course_named("Vendor", "Positions").modules) == [
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

pub fn patch_module_rejects_unknown_only_payload_test() {
  with_isolated_store("patch_module_rejects_unknown_only_payload", fn(_, _) {
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
      |> simulate.json_body(json.object([#("unknown", json.string("value"))]))
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
  with_isolated_store("set_module_position_clears_generated_range_snapshot", fn(db_path, toml_path) {
    let assert Ok(Nil) = store.initialise()
    let course =
      seed_course(
        vendor_name: "Vendor",
        course_name: "Generated",
        modules: model.GeneratedRange(
          model.ModuleRange(prefix: "Module ", start: 1, end: 3),
        ),
      )
    let assert [_, _, third] = course.modules

    let assert Ok(Nil) = store.set_module_position(third.id, 1)

    let reordered = course_named("Vendor", "Generated")
    assert reordered.module_range == None
    assert module_names(reordered.modules) == ["Module 3", "Module 1", "Module 2"]
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
	    assert module_names(imported.modules) == ["Module 3", "Module 1", "Module 2"]
	    assert module_positions(imported.modules) == [1, 2, 3]
	  })
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

pub fn courses_toml_path_ignores_empty_override_without_database_override_test() {
  let path = with_store_path_env(None, Some(""), fn() { store.courses_toml_path() })
  assert path == "courses.toml"
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

pub fn courses_toml_path_preserves_legacy_name_for_dot_default_database_override_test() {
  let path =
    with_store_path_env(Some("./aliahan.sqlite3"), None, fn() {
      store.courses_toml_path()
    })

  assert path == "courses.toml"
}

pub fn courses_toml_path_preserves_legacy_name_for_absolute_default_database_override_test() {
  let assert Ok(current_directory) = simplifile.current_directory()
  let path =
    with_store_path_env(
      Some(current_directory <> "/aliahan.sqlite3"),
      None,
      fn() { store.courses_toml_path() },
    )

  assert path == "courses.toml"
}

pub fn courses_toml_path_ignores_empty_override_and_uses_database_override_test() {
  let path =
    with_store_path_env(Some("/tmp/aliahan-alt.sqlite3"), Some(""), fn() {
      store.courses_toml_path()
    })

  assert path == "/tmp/aliahan-alt.courses.toml"
}

pub fn courses_toml_path_ignores_empty_override_and_preserves_legacy_name_for_default_database_override_test() {
  let path =
    with_store_path_env(Some("aliahan.sqlite3"), Some(""), fn() {
      store.courses_toml_path()
    })

  assert path == "courses.toml"
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

fn with_isolated_store(
  name: String,
  run: fn(String, String) -> Nil,
) -> Nil {
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

fn seed_course(
  vendor_name vendor_name: String,
  course_name course_name: String,
  modules modules: model.CourseModulesInput,
) -> model.Course {
  let assert Ok(Nil) = store.create_vendor(vendor_name)
  let vendor = vendor_named(vendor_name)

  let assert Ok(Nil) = store.create_course(
    model.NewCourseInput(
      vendor_id: vendor.id,
      name: course_name,
      deadline: calendar.Date(2026, calendar.April, 30),
      prerequisites: [],
      modules: modules,
    ),
  )

  course_named(vendor_name, course_name)
}

fn bootstrap_data() -> model.BootstrapData {
  let assert Ok(data) =
    store.bootstrap("week", calendar.Date(2026, calendar.March, 19))
  data
}

fn vendor_named(vendor_name: String) -> model.Vendor {
  let data = bootstrap_data()
  let assert Ok(vendor) = list.find(data.vendors, fn(vendor) {
    vendor.name == vendor_name
  })
  vendor
}

fn course_named(vendor_name: String, course_name: String) -> model.Course {
  let vendor = vendor_named(vendor_name)
  let assert Ok(course) = list.find(vendor.courses, fn(course) {
    course.name == course_name
  })
  course
}

fn course_by_id(course_id: Int) -> model.Course {
  let data = bootstrap_data()
  let vendors = data.vendors
  let courses =
    vendors
    |> list.fold([], fn(acc, vendor) {
      list.append(vendor.courses, acc)
    })
  let assert Ok(course) = list.find(courses, fn(course) {
    course.id == course_id
  })
  course
}

fn module_names(modules: List(model.Module)) -> List(String) {
  modules |> list.map(fn(module) { module.name })
}

fn module_positions(modules: List(model.Module)) -> List(Int) {
  modules |> list.map(fn(module) { module.position })
}
