"use strict";

const state = {
  view: "week",
  anchor: null,
  data: null,
  error: "",
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "content-type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    throw new Error(payload.error || "Request failed");
  }
  return payload.data;
}

async function loadBootstrap() {
  const params = new URLSearchParams({ view: state.view, anchor: state.anchor || todayIso() });
  state.data = await api(`/api/bootstrap?${params.toString()}`, { method: "GET" });
  state.anchor = state.data.schedule.anchor;
}

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

function splitCsv(value) {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function splitLines(value) {
  return value
    .split("\n")
    .map((item) => item.trim())
    .filter(Boolean);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function shiftAnchor(anchor, view, delta) {
  const date = new Date(`${anchor}T00:00:00`);
  if (view === "month") {
    date.setMonth(date.getMonth() + delta);
  } else {
    date.setDate(date.getDate() + (delta * 7));
  }
  return date.toISOString().slice(0, 10);
}

function monthPrefix(anchor) {
  return anchor.slice(0, 7);
}

function renderCalendar(schedule) {
  const days = schedule.days;
  if (schedule.view === "month") {
    const rows = [];
    for (let i = 0; i < days.length; i += 7) {
      rows.push(days.slice(i, i + 7));
    }
    return `
      <table>
        <thead>
          <tr>${["Mon","Tue","Wed","Thu","Fri","Sat","Sun"].map((label) => `<th>${label}</th>`).join("")}</tr>
        </thead>
        <tbody>
          ${rows.map((row) => `<tr>${row.map((day) => renderDayCell(day, monthPrefix(schedule.anchor))).join("")}</tr>`).join("")}
        </tbody>
      </table>
    `;
  }

  return `
    <table>
      <thead>
        <tr>${days.map((day) => `<th>${escapeHtml(day.label)}</th>`).join("")}</tr>
      </thead>
      <tbody>
        <tr>${days.map((day) => renderDayCell(day, null)).join("")}</tr>
      </tbody>
    </table>
  `;
}

function renderDayCell(day, activeMonth) {
  const muted = activeMonth && !day.date.startsWith(activeMonth) ? " style=\"opacity:0.6\"" : "";
  return `
    <td${muted}>
      <div>${escapeHtml(day.date)}</div>
      <ul>
        ${day.entries.map((entry) => `
          <li>
            <div>${escapeHtml(entry.vendor_name)} / ${escapeHtml(entry.course_name)}</div>
            <div>${escapeHtml(entry.module_name)}</div>
            <button data-action="toggle-complete" data-module-id="${entry.module_id}" data-completed="true">Mark done</button>
          </li>
        `).join("")}
      </ul>
    </td>
  `;
}

function renderCourseCard(vendor, course) {
  const prerequisites = course.prerequisites.join(", ");
  return `
    <div class="course-card">
      <h4>${escapeHtml(course.name)}</h4>
      <div>Vendor: ${escapeHtml(vendor.name)}</div>
      <form data-action="update-course" data-course-id="${course.id}">
        <div><label>Name <input name="name" value="${escapeHtml(course.name)}"></label></div>
        <div><label>Deadline <input type="date" name="deadline_date" value="${escapeHtml(course.deadline_date)}"></label></div>
        <div><label>Prerequisites <input name="prerequisites" value="${escapeHtml(prerequisites)}"></label></div>
        <button type="submit">Save course</button>
        <button type="button" data-action="delete-course" data-course-id="${course.id}">Delete course</button>
      </form>
      <ul>
        ${course.modules.map((module) => `
          <li class="${module.completed_at ? "done" : ""}">
            <form data-action="update-module" data-module-id="${module.id}">
              <input name="name" value="${escapeHtml(module.name)}">
              <span>Position ${module.position}</span>
              <span>${module.completed_at ? `Completed ${escapeHtml(module.completed_at)}` : (module.scheduled_date ? `Scheduled ${escapeHtml(module.scheduled_date)}` : "Unscheduled")}</span>
              <button type="submit">Save</button>
              <button type="button" data-action="toggle-complete" data-module-id="${module.id}" data-completed="${module.completed_at ? "false" : "true"}">
                ${module.completed_at ? "Mark undone" : "Mark done"}
              </button>
              <button type="button" data-action="delete-module" data-module-id="${module.id}">Delete</button>
            </form>
          </li>
        `).join("")}
      </ul>
      <form data-action="add-module" data-course-id="${course.id}">
        <input name="name" placeholder="New module name">
        <button type="submit">Add module</button>
      </form>
    </div>
  `;
}

function renderApp() {
  const root = document.getElementById("app");
  if (!state.data) {
    root.innerHTML = "<p>Loading...</p>";
    return;
  }

  const { settings, vendors, conflicts, schedule, today } = state.data;
  root.innerHTML = `
    <section>
      <div class="error">${escapeHtml(state.error || "")}</div>
      <div>
        <button data-action="prev-period">Previous</button>
        <button data-action="next-period">Next</button>
        <button data-action="go-today">Today</button>
        <button data-action="toggle-view">${schedule.view === "week" ? "Month view" : "Week view"}</button>
      </div>
      <div>Today: ${escapeHtml(today)}</div>
      <label>
        <input type="checkbox" id="include-weekends" ${settings.include_weekends ? "checked" : ""}>
        Include weekends
      </label>
      <label>
        Deadline slack days
        <input
          type="number"
          id="deadline-slack-days"
          min="0"
          value="${settings.deadline_slack_days}"
        >
      </label>
      <div>${renderCalendar(schedule)}</div>
    </section>

    <section>
      <h2>Conflicts</h2>
      <ul>
        ${conflicts.map((conflict) => `<li>${escapeHtml(conflict.vendor_name)} / ${escapeHtml(conflict.course_name)}: ${escapeHtml(conflict.message)}</li>`).join("") || "<li>None</li>"}
      </ul>
    </section>

    <section>
      <h2>Vendors</h2>
      <form data-action="create-vendor">
        <input name="name" placeholder="Vendor name">
        <button type="submit">Add vendor</button>
      </form>

      <form data-action="create-course">
        <div>
          <label>Vendor
            <select name="vendor_id">
              ${vendors.map((vendor) => `<option value="${vendor.id}">${escapeHtml(vendor.name)}</option>`).join("")}
            </select>
          </label>
        </div>
        <div><label>Course name <input name="name"></label></div>
        <div><label>Deadline <input type="date" name="deadline_date" value="${escapeHtml(today)}"></label></div>
        <div><label>Prerequisites <input name="prerequisites" placeholder="Comma separated"></label></div>
        <div>
          <label>Module mode
            <select name="mode">
              <option value="explicit">Explicit list</option>
              <option value="range">Generated range</option>
            </select>
          </label>
        </div>
        <div><label>Modules <textarea name="modules" rows="4" cols="40" placeholder="One module per line"></textarea></label></div>
        <div><label>Range prefix <input name="range_prefix" value="Module "></label></div>
        <div><label>Range start <input type="number" name="range_start" value="1"></label></div>
        <div><label>Range end <input type="number" name="range_end" value="5"></label></div>
        <button type="submit">Add course</button>
      </form>

      ${vendors.map((vendor) => `
        <section>
          <h3>${escapeHtml(vendor.name)}</h3>
          ${vendor.courses.length === 0 ? `<button data-action="delete-vendor" data-vendor-id="${vendor.id}">Delete empty vendor</button>` : ""}
          ${vendor.courses.map((course) => renderCourseCard(vendor, course)).join("")}
        </section>
      `).join("")}
    </section>
  `;
}

async function refresh() {
  state.error = "";
  try {
    await loadBootstrap();
  } catch (error) {
    state.error = error.message;
  }
  renderApp();
}

async function mutate(path, options) {
  state.error = "";
  try {
    await api(path, options);
    await loadBootstrap();
  } catch (error) {
    state.error = error.message;
  }
  renderApp();
}

document.addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  const action = form.dataset.action;
  const data = new FormData(form);

  if (action === "create-vendor") {
    await mutate("/api/vendors", {
      method: "POST",
      body: JSON.stringify({ name: data.get("name") }),
    });
  }

  if (action === "create-course") {
    const mode = data.get("mode");
    const payload = {
      vendor_id: Number(data.get("vendor_id")),
      name: data.get("name"),
      deadline_date: data.get("deadline_date"),
      prerequisites: splitCsv(data.get("prerequisites") || ""),
    };
    if (mode === "range") {
      payload.module_range = {
        prefix: data.get("range_prefix"),
        start: Number(data.get("range_start")),
        end: Number(data.get("range_end")),
      };
    } else {
      payload.modules = splitLines(data.get("modules") || "");
    }
    await mutate("/api/courses", {
      method: "POST",
      body: JSON.stringify(payload),
    });
  }

  if (action === "update-course") {
    await mutate(`/api/courses/${form.dataset.courseId}`, {
      method: "PATCH",
      body: JSON.stringify({
        name: data.get("name"),
        deadline_date: data.get("deadline_date"),
        prerequisites: splitCsv(data.get("prerequisites") || ""),
      }),
    });
  }

  if (action === "add-module") {
    await mutate(`/api/courses/${form.dataset.courseId}/modules`, {
      method: "POST",
      body: JSON.stringify({ name: data.get("name") }),
    });
  }

  if (action === "update-module") {
    await mutate(`/api/modules/${form.dataset.moduleId}`, {
      method: "PATCH",
      body: JSON.stringify({ name: data.get("name") }),
    });
  }
});

document.addEventListener("click", async (event) => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  const action = button.dataset.action;

  if (action === "prev-period") {
    state.anchor = shiftAnchor(state.anchor || todayIso(), state.view, -1);
    await refresh();
  }
  if (action === "next-period") {
    state.anchor = shiftAnchor(state.anchor || todayIso(), state.view, 1);
    await refresh();
  }
  if (action === "go-today") {
    state.anchor = todayIso();
    await refresh();
  }
  if (action === "toggle-view") {
    state.view = state.view === "week" ? "month" : "week";
    await refresh();
  }
  if (action === "delete-course") {
    await mutate(`/api/courses/${button.dataset.courseId}`, { method: "DELETE" });
  }
  if (action === "delete-vendor") {
    await mutate(`/api/vendors/${button.dataset.vendorId}`, { method: "DELETE" });
  }
  if (action === "toggle-complete") {
    await mutate(`/api/modules/${button.dataset.moduleId}`, {
      method: "PATCH",
      body: JSON.stringify({ completed: button.dataset.completed === "true" }),
    });
  }
  if (action === "delete-module") {
    await mutate(`/api/modules/${button.dataset.moduleId}`, { method: "DELETE" });
  }
});

document.addEventListener("change", async (event) => {
  const element = event.target;
  if (element.id === "include-weekends" || element.id === "deadline-slack-days") {
    const includeWeekends = document.getElementById("include-weekends");
    const deadlineSlackDays = document.getElementById("deadline-slack-days");
    await mutate("/api/settings", {
      method: "PATCH",
      body: JSON.stringify({
        include_weekends: includeWeekends.checked,
        deadline_slack_days: Math.max(0, Number(deadlineSlackDays.value) || 0),
      }),
    });
  }
});

refresh();
