"use strict";

// ── API Layer ──────────────────────────────────────────

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

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

function shiftAnchor(anchor, view, delta) {
  const d = new Date(`${anchor}T00:00:00`);
  if (view === "month") {
    d.setMonth(d.getMonth() + delta);
  } else {
    d.setDate(d.getDate() + delta * 7);
  }
  return d.toISOString().slice(0, 10);
}

// Vendor color palette and persistence
const VENDOR_COLORS = ["#FF6B9D", "#4ECDC4", "#FF8A5C", "#FFE500", "#BFFF00", "#C4A1FF", "#FF4444", "#44BBFF"];
const VENDOR_COLOR_KEY = "aliahan_vendor_colors_v2";
const vendorColors = loadVendorColors();

function normalizeVendorColors(value) {
  const colors = Object.create(null);
  if (!value || typeof value !== "object" || Array.isArray(value)) return colors;
  for (const [vendorName, color] of Object.entries(value)) {
    if (typeof color === "string") colors[vendorName] = color;
  }
  return colors;
}

function loadVendorColors() {
  try {
    return normalizeVendorColors(JSON.parse(localStorage.getItem(VENDOR_COLOR_KEY)));
  } catch {
    return Object.create(null);
  }
}

function saveVendorColors(map) {
  try {
    localStorage.setItem(VENDOR_COLOR_KEY, JSON.stringify(map));
    return true;
  } catch {
    return false;
  }
}

function getVendorColor(vendorName) {
  if (!Object.prototype.hasOwnProperty.call(vendorColors, vendorName)) return null;
  const color = vendorColors[vendorName];
  return typeof color === "string" ? color : null;
}

function setVendorColor(vendorName, color) {
  vendorColors[vendorName] = color;
  saveVendorColors(vendorColors);
  if (typeof Alpine !== "undefined") {
    const ui = Alpine.store("ui");
    if (ui) ui.vendorColorRevision += 1;
  }
}

// Fallback: deterministic color from name (used when no explicit color set)
function vendorColorFallback(name) {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = ((hash << 5) - hash + name.charCodeAt(i)) | 0;
  }
  return VENDOR_COLORS[Math.abs(hash) % VENDOR_COLORS.length];
}

// Resolve vendor color: explicit pick (by name) > fallback hash
function resolveVendorColor(vendorName) {
  const explicit = getVendorColor(vendorName);
  if (explicit) return explicit;
  return vendorColorFallback(vendorName);
}

// ── Toast helper ───────────────────────────────────────

let toastId = 0;
function showToast(message, type = "info") {
  const id = ++toastId;
  const toast = { id, message, type, visible: true };
  Alpine.store("ui").toasts.push(toast);
  setTimeout(() => {
    toast.visible = false;
    setTimeout(() => {
      const toasts = Alpine.store("ui").toasts;
      const idx = toasts.findIndex((t) => t.id === id);
      if (idx !== -1) toasts.splice(idx, 1);
    }, 300);
  }, 3000);
}

// ── Confirm dialog helper ──────────────────────────────

function requestConfirm(message) {
  return new Promise((resolve) => {
    Alpine.store("ui").confirmDialog = { message, resolve };
  });
}

// ── Alpine Stores ──────────────────────────────────────

document.addEventListener("alpine:init", () => {
  // App data store
  Alpine.store("app", {
    data: null,
    view: "week",
    anchor: null,
    loading: false,
    error: "",
    _bootstrapRequestId: 0,
    _loadingRequestId: 0,

    today() {
      return this.data?.today || todayIso();
    },

    async loadBootstrap({ showLoading = false, view = this.view, anchor = this.anchor || todayIso() } = {}) {
      const requestId = ++this._bootstrapRequestId;
      const targetAnchor = anchor || todayIso();
      this.error = "";
      this.view = view;
      this.anchor = targetAnchor;
      if (showLoading) {
        this.loading = true;
        this._loadingRequestId = requestId;
      }
      try {
        const params = new URLSearchParams({
          view,
          anchor: targetAnchor,
        });
        const data = await api(`/api/bootstrap?${params}`);
        if (requestId !== this._bootstrapRequestId) return true;
        this.data = data;
        this.view = data.schedule.view;
        this.anchor = data.schedule.anchor;
        this.error = "";
        return true;
      } catch (e) {
        if (requestId !== this._bootstrapRequestId) return true;
        const schedule = this.data?.schedule;
        if (schedule) {
          this.view = schedule.view;
          this.anchor = schedule.anchor;
        }
        this.error = e.message;
        showToast(e.message, "error");
        return false;
      } finally {
        if (showLoading && requestId === this._loadingRequestId) {
          this.loading = false;
          this._loadingRequestId = 0;
        }
      }
    },

    async init() {
      return await this.loadBootstrap({
        showLoading: true,
        view: this.view,
        anchor: this.anchor || todayIso(),
      });
    },

    async refresh() {
      return await this.loadBootstrap({
        view: this.view,
        anchor: this.anchor || todayIso(),
      });
    },

    async mutate(path, options) {
      this.error = "";
      try {
        await api(path, options);
        await this.refresh();
        return true;
      } catch (e) {
        this.error = e.message;
        showToast(e.message, "error");
        return false;
      }
    },
  });

  // UI state store
  Alpine.store("ui", {
    tab: "schedule",
    settingsOpen: false,
    conflictsOpen: false,
    expandedVendors: [],
    vendorColorRevision: 0,
    modalOpen: false,
    courseVendorId: null,
    confirmDialog: null,
    toasts: [],
  });

  // ── Components ─────────────────────────────────────

  // Calendar grid
  Alpine.data("calendarGrid", () => ({
    popover: { open: false, entry: null, entries: [], completing: false },
    _fading: false,
    _fadeRequestId: 0,

    get schedule() {
      const s = Alpine.store("app").data?.schedule;
      // Set --month-rows CSS variable for month grid
      if (s?.days && Alpine.store("app").view === "month") {
        const rows = Math.ceil(s.days.length / 7);
        document.documentElement.style.setProperty("--month-rows", String(rows));
      }
      return s;
    },

    get periodLabel() {
      const s = this.schedule;
      if (!s) return "";
      if (Alpine.store("app").view === "month") {
        const d = new Date(`${s.anchor}T00:00:00`);
        return d.toLocaleDateString("en-US", { month: "long", year: "numeric" });
      }
      const start = new Date(`${s.period_start}T00:00:00`);
      const end = new Date(`${s.period_end}T00:00:00`);
      const opts = { month: "short", day: "numeric" };
      const yearOpts = { month: "short", day: "numeric", year: "numeric" };
      if (start.getFullYear() !== end.getFullYear()) {
        return start.toLocaleDateString("en-US", yearOpts) + " — " + end.toLocaleDateString("en-US", yearOpts);
      }
      return start.toLocaleDateString("en-US", opts) + " — " + end.toLocaleDateString("en-US", yearOpts);
    },

    // Fade out, run action while invisible, fade back in
    async _withFade(fn) {
      const fadeRequestId = ++this._fadeRequestId;
      this._fading = true;
      await new Promise((r) => setTimeout(r, 140));
      try {
        await fn();
      } finally {
        if (fadeRequestId === this._fadeRequestId) this._fading = false;
      }
    },

    dayLabel(dateStr) {
      const d = new Date(`${dateStr}T00:00:00`);
      return d.toLocaleDateString("en-US", { weekday: "short" });
    },

    dayNum(dateStr) {
      return parseInt(dateStr.split("-")[2], 10);
    },

    isToday(dateStr) {
      return dateStr === Alpine.store("app").today();
    },

    isCurrentMonth(dateStr) {
      const anchor = this.schedule?.anchor;
      if (!anchor) return true;
      return dateStr.slice(0, 7) === anchor.slice(0, 7);
    },

    vendorColor(name) {
      void Alpine.store("ui").vendorColorRevision;
      return resolveVendorColor(name);
    },

    resetPopover() {
      this.popover = { open: false, entry: null, entries: [], completing: false };
    },

    selectPopoverEntry(entry) {
      if (!entry || this.popover.completing) return;
      this.popover.entry = entry;
    },

    setView(view) {
      this.resetPopover();
      this._withFade(async () => {
        const app = Alpine.store("app");
        await app.loadBootstrap({
          view,
          anchor: app.anchor || todayIso(),
        });
      });
    },

    prev() {
      this.resetPopover();
      this._withFade(async () => {
        const app = Alpine.store("app");
        await app.loadBootstrap({
          view: app.view,
          anchor: shiftAnchor(app.anchor || todayIso(), app.view, -1),
        });
      });
    },

    next() {
      this.resetPopover();
      this._withFade(async () => {
        const app = Alpine.store("app");
        await app.loadBootstrap({
          view: app.view,
          anchor: shiftAnchor(app.anchor || todayIso(), app.view, 1),
        });
      });
    },

    goToday() {
      this.resetPopover();
      this._withFade(async () => {
        const app = Alpine.store("app");
        await app.loadBootstrap({
          view: app.view,
          anchor: app.today(),
        });
      });
    },

    openPopover(entries, entry = entries?.[0]) {
      if (!entries?.length || !entry) return;
      this.popover = {
        open: true,
        entry,
        entries: entries.slice(),
        completing: false,
      };
    },

    async markDone(moduleId) {
      if (!moduleId || this.popover.completing) return;
      this.popover.completing = true;
      const ok = await Alpine.store("app").mutate(`/api/modules/${moduleId}`, {
        method: "PATCH",
        body: JSON.stringify({ completed: true }),
      });
      if (ok) {
        showToast("Module completed!", "success");
        this.resetPopover();
        return;
      }
      this.popover.completing = false;
    },
  }));

  // Settings panel
  Alpine.data("settingsPanel", () => ({
    currentSettings() {
      return Alpine.store("app").data?.settings || null;
    },

    async toggleWeekends(event) {
      if (!this.currentSettings()) return;
      const app = Alpine.store("app");
      const includeWeekends = !!event.target.checked;
      const ok = await app.mutate("/api/settings", {
        method: "PATCH",
        body: JSON.stringify({
          include_weekends: includeWeekends,
        }),
      });
      if (!ok) {
        const settings = this.currentSettings();
        if (settings) {
          event.target.checked = !!settings.include_weekends;
        }
      }
    },

    async updateSlackDays(event) {
      if (!this.currentSettings()) return;
      const app = Alpine.store("app");
      const deadlineSlackDays = Math.max(0, Number(event.target.value) || 0);
      const ok = await app.mutate("/api/settings", {
        method: "PATCH",
        body: JSON.stringify({
          deadline_slack_days: deadlineSlackDays,
        }),
      });
      if (!ok) {
        const settings = this.currentSettings();
        if (settings) {
          event.target.value = String(settings.deadline_slack_days);
        }
      }
    },
  }));

  // Vendor form
  Alpine.data("vendorForm", () => ({
    vendorName: "",

    async create() {
      const name = this.vendorName.trim();
      if (!name) return;
      const ok = await Alpine.store("app").mutate("/api/vendors", {
        method: "POST",
        body: JSON.stringify({ name }),
      });
      if (ok) {
        this.vendorName = "";
        showToast("Vendor created", "success");
      }
    },
  }));

  // Confirm dialog
  Alpine.data("confirmDialog", () => ({
    confirm() {
      const dialog = Alpine.store("ui").confirmDialog;
      if (dialog?.resolve) dialog.resolve(true);
      Alpine.store("ui").confirmDialog = null;
    },
    cancel() {
      const dialog = Alpine.store("ui").confirmDialog;
      if (dialog?.resolve) dialog.resolve(false);
      Alpine.store("ui").confirmDialog = null;
    },
  }));

  // Course creation modal
  Alpine.data("courseModal", () => ({
    submitting: false,
    form: {
      vendor_id: "",
      name: "",
      deadline_date: Alpine.store("app").today(),
      prerequisites: "",
      mode: "explicit",
      modules: "",
      range_prefix: "Module ",
      range_start: 1,
      range_end: 5,
    },

    init() {
      const vendors = Alpine.store("app").data?.vendors || [];
      const requestedVendorId = Alpine.store("ui").courseVendorId;
      const selectedVendor = vendors.find((vendor) => vendor.id === requestedVendorId);
      this.form.vendor_id = selectedVendor?.id || vendors[0]?.id || "";
    },

    close() {
      Alpine.store("ui").courseVendorId = null;
      Alpine.store("ui").modalOpen = false;
    },

    get explicitModules() {
      return this.form.modules
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean);
    },

    get rangeIsValid() {
      const start = Number(this.form.range_start);
      const end = Number(this.form.range_end);
      return this.form.range_prefix.trim() && start >= 1 && end >= start;
    },

    get canSubmit() {
      if (this.submitting) return false;
      if (!Number(this.form.vendor_id) || !this.form.name.trim() || !this.form.deadline_date) {
        return false;
      }
      return this.form.mode === "range" ? this.rangeIsValid : this.explicitModules.length > 0;
    },

    async submit() {
      if (!this.canSubmit) return;
      this.submitting = true;

      const payload = {
        vendor_id: Number(this.form.vendor_id),
        name: this.form.name.trim(),
        deadline_date: this.form.deadline_date,
        prerequisites: this.form.prerequisites
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
      };

      if (this.form.mode === "range") {
        payload.module_range = {
          prefix: this.form.range_prefix,
          start: Number(this.form.range_start),
          end: Number(this.form.range_end),
        };
      } else {
        payload.modules = this.explicitModules;
      }

      const ok = await Alpine.store("app").mutate("/api/courses", {
        method: "POST",
        body: JSON.stringify(payload),
      });
      this.submitting = false;
      if (ok) {
        this.close();
        showToast("Course created", "success");
      }
    },
  }));

  // Manage tab (vendor accordions)
  Alpine.data("manageTab", () => ({
    vendorPalette: VENDOR_COLORS,

    toggleVendor(vendorId) {
      const ui = Alpine.store("ui");
      const idx = ui.expandedVendors.indexOf(vendorId);
      if (idx === -1) {
        ui.expandedVendors.push(vendorId);
      } else {
        ui.expandedVendors.splice(idx, 1);
      }
    },

    isVendorExpanded(vendorId) {
      return Alpine.store("ui").expandedVendors.includes(vendorId);
    },

    getVendorColor(vendorName) {
      void Alpine.store("ui").vendorColorRevision;
      const explicit = getVendorColor(vendorName);
      if (explicit) return explicit;
      return vendorName ? vendorColorFallback(vendorName) : VENDOR_COLORS[0];
    },

    setVendorColor(vendorName, color) {
      setVendorColor(vendorName, color);
    },

    openCourseModal(vendorId) {
      const vendors = Alpine.store("app").data?.vendors || [];
      const vendor = vendors.find((candidate) => candidate.id === vendorId);
      if (!vendor) return;
      const ui = Alpine.store("ui");
      ui.courseVendorId = vendor.id;
      ui.modalOpen = true;
    },

    async deleteVendor(vendorId, vendorName) {
      const vendors = Alpine.store("app").data?.vendors || [];
      const vendor = vendors.find((candidate) => candidate.id === vendorId);
      const resolvedName = vendor?.name || vendorName;
      const courseCount = vendor?.courses.length || 0;
      const moduleCount =
        vendor?.courses.reduce((count, course) => count + course.modules.length, 0) || 0;
      const message =
        courseCount > 0
          ? `Delete vendor "${resolvedName}"? This will also permanently delete ${courseCount} course${courseCount === 1 ? "" : "s"} and ${moduleCount} module${moduleCount === 1 ? "" : "s"}.`
          : `Delete vendor "${resolvedName}"?`;
      const confirmed = await requestConfirm(message);
      if (!confirmed) return;
      const ok = await Alpine.store("app").mutate(`/api/vendors/${vendorId}`, {
        method: "DELETE",
      });
      if (ok) {
        showToast("Vendor deleted", "info");
      }
    },
  }));

  // Course card (manage tab)
  // Uses reactive getters to always read fresh data from the store,
  // avoiding stale closure references after refresh().
  Alpine.data("courseCard", (initCourse, initVendor) => ({
    _courseId: initCourse.id,
    _vendorId: initVendor.id,
    editing: { name: false, deadline: false, prerequisites: false },
    prerequisiteDraft: "",
    editingModuleId: null,
    moduleNameDraft: "",
    newModuleName: "",
    _dragIndex: null,
    _draggedId: null,
    _dragSnapshot: null,
    _dropHandled: false,
    _saving: false,
    _moduleCompletionPending: Object.create(null),

    // Reactive getter: always returns fresh course from store
    get course() {
      const data = Alpine.store("app").data;
      if (!data) return null;
      for (const v of data.vendors) {
        const c = v.courses.find((c) => c.id === this._courseId);
        if (c) return c;
      }
      return null;
    },

    get vendor() {
      const data = Alpine.store("app").data;
      if (!data) return null;
      return data.vendors.find((v) => v.id === this._vendorId) || null;
    },

    dragStart(event, index) {
      if (this._saving) {
        event.preventDefault();
        return;
      }
      const course = this.course;
      if (!course) return;
      this._dragIndex = index;
      this._draggedId = course.modules[index]?.id;
      this._dragSnapshot = course.modules.slice();
      this._dropHandled = false;
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", "");
      requestAnimationFrame(() => {
        event.target.style.opacity = "0.3";
      });
    },

    dragOver(event, index) {
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      if (this._dragIndex === null || this._dragIndex === index) return;
      const course = this.course;
      if (!course) return;
      const modules = course.modules;
      const [item] = modules.splice(this._dragIndex, 1);
      modules.splice(index, 0, item);
      this._dragIndex = index;
    },

    async drop(event) {
      event.preventDefault();
      if (this._saving) return;
      this._dropHandled = true;
      this._saving = true;
      const dragSnapshot = this._dragSnapshot ? this._dragSnapshot.slice() : null;
      const course = this.course;
      if (!course || !dragSnapshot) {
        this._dragSnapshot = null;
        this._dropHandled = false;
        this._saving = false;
        return;
      }
      const modules = course.modules;
      const ok = await Alpine.store("app").mutate(`/api/courses/${course.id}/modules`, {
        method: "PATCH",
        body: JSON.stringify({
          module_ids: modules.map((m) => m.id),
        }),
      });
      if (ok) {
        showToast("Modules reordered", "success");
      } else {
        this.restoreDragSnapshot(dragSnapshot);
        await Alpine.store("app").refresh();
      }
      this._dragSnapshot = null;
      this._dropHandled = false;
      this._saving = false;
    },

    dragEnd() {
      if (!this._dropHandled) {
        this.restoreDragSnapshot();
      }
      this._dragIndex = null;
      this._draggedId = null;
      if (!this._saving) {
        this._dragSnapshot = null;
        this._dropHandled = false;
      }
      document.querySelectorAll("[draggable=true]").forEach((el) => {
        el.style.opacity = "";
      });
    },

    restoreDragSnapshot(snapshot = this._dragSnapshot) {
      const course = this.course;
      if (!course || !snapshot) return;
      course.modules.splice(0, course.modules.length, ...snapshot);
    },

    get completedCount() {
      const course = this.course;
      if (!course) return 0;
      return course.modules.filter((m) => m.completed_at).length;
    },

    get progressPct() {
      const course = this.course;
      if (!course || course.modules.length === 0) return 0;
      return Math.round(
        (course.modules.filter((m) => m.completed_at).length / course.modules.length) * 100
      );
    },

    isModuleCompletionSaving(moduleId) {
      return Object.prototype.hasOwnProperty.call(this._moduleCompletionPending, moduleId);
    },

    formatDate(dateStr) {
      if (!dateStr) return "No deadline";
      const d = new Date(`${dateStr}T00:00:00`);
      return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
    },

    parsePrerequisites(value) {
      return value
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
    },

    samePrerequisites(left, right) {
      return left.join("\n") === right.join("\n");
    },

    async persistCourse(changes = {}) {
      const course = this.course;
      if (!course) return false;
      return Alpine.store("app").mutate(`/api/courses/${course.id}`, {
        method: "PATCH",
        body: JSON.stringify(changes),
      });
    },

    async saveName(newName) {
      if (!this.editing.name) return;
      const course = this.course;
      const trimmed = newName.trim();
      if (!course || trimmed === course.name || !trimmed) {
        this.editing.name = false;
        return;
      }
      const ok = await this.persistCourse({ name: trimmed });
      if (ok) {
        this.editing.name = false;
      }
    },

    async saveDeadline(newDate) {
      if (!this.editing.deadline) return;
      const course = this.course;
      if (!course || newDate === course.deadline_date || !newDate) {
        this.editing.deadline = false;
        return;
      }
      const ok = await this.persistCourse({ deadline_date: newDate });
      if (ok) {
        this.editing.deadline = false;
      }
    },

    startPrerequisitesEdit() {
      const course = this.course;
      if (!course) return;
      this.prerequisiteDraft = course.prerequisites.join(", ");
      this.editing.prerequisites = true;
    },

    cancelPrerequisitesEdit() {
      const course = this.course;
      this.prerequisiteDraft = course ? course.prerequisites.join(", ") : "";
      this.editing.prerequisites = false;
    },

    async savePrerequisites(value) {
      if (!this.editing.prerequisites) return;
      const course = this.course;
      if (!course) return;
      const prerequisites = this.parsePrerequisites(value);
      if (this.samePrerequisites(prerequisites, course.prerequisites)) {
        this.cancelPrerequisitesEdit();
        return;
      }
      const ok = await this.persistCourse({ prerequisites });
      if (ok) {
        this.prerequisiteDraft = prerequisites.join(", ");
        this.editing.prerequisites = false;
      }
    },

    startModuleRename(mod) {
      this.editingModuleId = mod.id;
      this.moduleNameDraft = mod.name;
    },

    cancelModuleRename() {
      this.editingModuleId = null;
      this.moduleNameDraft = "";
    },

    async saveModuleName(mod) {
      const name = this.moduleNameDraft.trim();
      if (this.editingModuleId !== mod.id) return;
      if (!name || name === mod.name) {
        this.cancelModuleRename();
        return;
      }
      const ok = await Alpine.store("app").mutate(`/api/modules/${mod.id}`, {
        method: "PATCH",
        body: JSON.stringify({ name }),
      });
      if (ok) {
        this.cancelModuleRename();
      }
    },

    async toggleModule(mod, event) {
      if (this.isModuleCompletionSaving(mod.id)) {
        event.target.checked = !!this._moduleCompletionPending[mod.id];
        return;
      }
      const checked = !!event.target.checked;
      this._moduleCompletionPending[mod.id] = checked;
      event.target.disabled = true;
      try {
        const ok = await Alpine.store("app").mutate(`/api/modules/${mod.id}`, {
          method: "PATCH",
          body: JSON.stringify({ completed: checked }),
        });
        if (!ok) {
          event.target.checked = !!mod.completed_at;
        }
      } finally {
        delete this._moduleCompletionPending[mod.id];
        if (event.target.isConnected) {
          event.target.disabled = false;
        }
      }
    },

    async deleteModule(mod) {
      const confirmed = await requestConfirm(
        `Delete module "${mod.name}"?`
      );
      if (!confirmed) return;
      const ok = await Alpine.store("app").mutate(`/api/modules/${mod.id}`, {
        method: "DELETE",
      });
      if (ok) {
        showToast("Module deleted", "info");
      }
    },

    async deleteCourse() {
      const course = this.course;
      if (!course) return;
      const confirmed = await requestConfirm(
        `Delete course "${course.name}" and all its modules?`
      );
      if (!confirmed) return;
      const ok = await Alpine.store("app").mutate(`/api/courses/${course.id}`, {
        method: "DELETE",
      });
      if (ok) {
        showToast("Course deleted", "info");
      }
    },

    async addModule() {
      const name = this.newModuleName.trim();
      if (!name) return;
      const course = this.course;
      if (!course) return;
      const ok = await Alpine.store("app").mutate(`/api/courses/${course.id}/modules`, {
        method: "POST",
        body: JSON.stringify({ name }),
      });
      if (ok) {
        this.newModuleName = "";
        showToast("Module added", "success");
      }
    },
  }));
});
