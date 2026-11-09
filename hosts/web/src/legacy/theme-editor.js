/**
 * Accessible browser adapter for the structured Haskell theme editor.
 *
 * This module deliberately does not decode or mutate `Canvas.Theme` itself.
 * Haskell projects the current theme into closed controls, including every
 * displayed value, option, enabled state, and typed edit target. The browser
 * validates that projection before constructing DOM and emits immutable,
 * revision-fenced intents:
 *
 *   input  -> phase "preview"
 *   change -> phase "apply"
 *   save   -> phase "save"
 *
 * A preview and an apply carry the same edit. Haskell therefore remains the
 * sole owner of semantic update/defaulting policy, while the host can provide
 * continuous feedback without treating a preview as persistence.
 */

export const themeEditorProtocol = "slideblaster.theme-editor/1";

const identifierPattern = /^[A-Za-z_][A-Za-z0-9_-]*$/;
const rationalPattern =
  /^-?(?:0|[1-9][0-9]*)(?:(?:\.[0-9]+)|(?:\/[1-9][0-9]*))?$/;
const colourPattern = /^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$/;
const maximumCollectionLength = 512;
const maximumTextLength = 16_384;

const sectionDefinitions = Object.freeze([
  Object.freeze({ key: "palette", label: "Palette" }),
  Object.freeze({ key: "typographyRoles", label: "Typography roles" }),
  Object.freeze({ key: "background", label: "Background" }),
  Object.freeze({ key: "baseShapeStyle", label: "Base shape style" }),
  Object.freeze({ key: "nodeDistance", label: "Node distance" }),
  Object.freeze({ key: "masterRegions", label: "Master regions" }),
  Object.freeze({ key: "masterAnchors", label: "Master anchors" }),
  Object.freeze({ key: "furniture", label: "Furniture and safe area" }),
]);

const typographyProperties = new Set([
  "family_kind",
  "family_name",
  "size",
  "weight_kind",
  "weight_value",
  "posture",
  "decoration",
  "colour_kind",
  "colour_value",
  "horizontal_alignment",
  "vertical_alignment",
  "wrap_width",
  "line_spacing",
]);

const baseNodeProperties = new Set([
  "paint_kind",
  "paint_colour_kind",
  "paint_colour_value",
  "stroke_kind",
  "stroke_colour_kind",
  "stroke_colour_value",
  "stroke_width",
  "dash_kind",
  "custom_dash",
  "opacity",
  "rotation",
  "scale_x",
  "scale_y",
  "flip",
  "shadow_kind",
  "shadow_offset_x",
  "shadow_offset_y",
  "shadow_blur",
  "shadow_colour_kind",
  "shadow_colour_value",
  "shadow_opacity",
  "corner_kind",
  "corner_amount",
  "sizing_kind",
  "size_width",
  "size_height",
  "role",
  "overlay",
  ...Array.from(typographyProperties, (property) => `typography_${property}`),
]);

const baseConnectorProperties = new Set([
  "paint_kind",
  "paint_colour_kind",
  "paint_colour_value",
  "stroke_kind",
  "stroke_colour_kind",
  "stroke_colour_value",
  "stroke_width",
  "dash_kind",
  "custom_dash",
  "opacity",
  "rotation",
  "sizing_kind",
  "size_width",
  "size_height",
  "role",
  "overlay",
  "start_tip",
  "end_tip",
  "line_join",
  ...Array.from(typographyProperties, (property) => `typography_${property}`),
]);

const masterRegionProperties = new Set([
  "name",
  "left",
  "bottom",
  "width",
  "height",
  "default_role",
  "default_anchor",
]);

const masterAnchorProperties = new Set([
  "name",
  "free_x",
  "free_y",
  "attachment_kind",
  "attachment_region",
  "attachment_slot",
]);

const furnitureProperties = Object.freeze({
  page_number: new Set(["format_kind", "format_name", "anchor", "role"]),
  logo: new Set(["asset", "anchor", "width", "height"]),
  band: new Set(["position", "extent", "role"]),
});

/**
 * A decoded value violated the closed browser/Haskell theme-editor boundary.
 */
export class ThemeEditorWireError extends Error {
  constructor(message) {
    super(message);
    this.name = "ThemeEditorWireError";
  }
}

/**
 * Validate and defensively reconstruct a Haskell theme-editor projection.
 * The returned value is recursively frozen and shares no mutable records or
 * arrays with the caller.
 *
 * Wire shape:
 *
 * {
 *   protocol: "slideblaster.theme-editor/1",
 *   projectionRevision: non-negative safe integer,
 *   theme: {id, name, description},
 *   sections: {
 *     palette, typographyRoles, background, baseShapeStyle, nodeDistance,
 *     masterRegions, masterAnchors, furniture
 *   },
 *   save: {enabled, disabledReason}
 * }
 *
 * Every section is `{controls, groups, actions}`. A group is
 * `{id,label,summary,controls,actions}`. See `validateControl` and
 * `validateAction` for their closed variants.
 *
 * @param {unknown} projection
 * @returns {Readonly<Record<string, unknown>>}
 */
export function validateThemeEditorProjection(projection) {
  const controlIds = new Set();
  const groupIds = new Set();
  const actionIds = new Set();

  const root = expectRecord(projection, "projection");
  requireExactKeys(
    root,
    ["protocol", "projectionRevision", "theme", "sections", "save"],
    "projection",
  );
  expectLiteral(root.protocol, themeEditorProtocol, "projection.protocol");
  const projectionRevision = expectSafeUnsignedInteger(
    root.projectionRevision,
    "projection.projectionRevision",
  );

  const theme = expectRecord(root.theme, "projection.theme");
  requireExactKeys(theme, ["id", "name", "description"], "projection.theme");
  const validatedTheme = {
    id: expectIdentifier(theme.id, "projection.theme.id"),
    name: expectUnicodeString(theme.name, "projection.theme.name", false),
    description: expectUnicodeString(
      theme.description,
      "projection.theme.description",
      true,
    ),
  };

  const sections = expectRecord(root.sections, "projection.sections");
  requireExactKeys(
    sections,
    sectionDefinitions.map(({ key }) => key),
    "projection.sections",
  );
  const validatedSections = {};
  for (const { key } of sectionDefinitions) {
    validatedSections[key] = validateSection(
      sections[key],
      `projection.sections.${key}`,
      { controlIds, groupIds, actionIds },
    );
  }

  const save = expectRecord(root.save, "projection.save");
  requireExactKeys(save, ["enabled", "disabledReason"], "projection.save");
  const saveEnabled = expectBoolean(save.enabled, "projection.save.enabled");
  const saveDisabledReason = expectNullableString(
    save.disabledReason,
    "projection.save.disabledReason",
  );
  validateAvailability(saveEnabled, saveDisabledReason, "projection.save");

  return deepFreeze({
    protocol: themeEditorProtocol,
    projectionRevision,
    theme: validatedTheme,
    sections: validatedSections,
    save: {
      enabled: saveEnabled,
      disabledReason: saveDisabledReason,
    },
  });
}

/**
 * Mount one theme-editor content surface. Popup/window chrome intentionally
 * remains outside this feature module so it can later use the shared popup
 * surface without changing the projection or intent protocol.
 *
 * @param {HTMLElement} container
 * @param {{
 *   projection: unknown,
 *   onIntent: (intent: Readonly<Record<string, unknown>>) => unknown
 * }} options
 * @returns {{
 *   element: HTMLElement,
 *   update: (projection: unknown) => void,
 *   destroy: () => void
 * }}
 */
export function mountThemeEditor(container, options) {
  if (
    container === null ||
    typeof container !== "object" ||
    typeof container.append !== "function" ||
    container.ownerDocument === null
  ) {
    throw new TypeError("Theme editor requires a DOM container");
  }
  if (typeof options?.onIntent !== "function") {
    throw new TypeError("Theme editor requires an onIntent callback");
  }

  let currentProjection = validateThemeEditorProjection(options.projection);
  const ownerDocument = container.ownerDocument;
  const instanceId = nextInstanceId();
  const root = ownerDocument.createElement("section");
  root.className = "sb-theme-editor";
  root.dataset.themeEditor = "true";
  root.setAttribute("role", "region");
  root.style.cssText =
    "box-sizing:border-box;max-width:78rem;margin:0 auto;padding:1rem;" +
    "font-family:system-ui,sans-serif;color:#1f2937;background:#f8fafc";
  container.append(root);
  render();

  function render() {
    root.replaceChildren();
    root.dataset.projectionRevision = String(
      currentProjection.projectionRevision,
    );
    root.dataset.themeId = currentProjection.theme.id;

    const header = ownerDocument.createElement("header");
    header.style.cssText =
      "display:flex;align-items:flex-start;justify-content:space-between;" +
      "gap:1rem;margin-bottom:1rem";
    const headingBlock = ownerDocument.createElement("div");
    const heading = ownerDocument.createElement("h2");
    heading.id = `${instanceId}-title`;
    heading.textContent = `Theme editor: ${currentProjection.theme.name}`;
    heading.style.cssText = "font-size:1.2rem;margin:0";
    root.setAttribute("aria-labelledby", heading.id);
    headingBlock.append(heading);
    if (currentProjection.theme.description !== "") {
      const description = ownerDocument.createElement("p");
      description.id = `${instanceId}-description`;
      description.textContent = currentProjection.theme.description;
      description.style.cssText =
        "max-width:55rem;margin:.25rem 0 0;color:#64748b;font-size:.88rem";
      root.setAttribute("aria-describedby", description.id);
      headingBlock.append(description);
    } else {
      root.removeAttribute("aria-describedby");
    }
    header.append(headingBlock);

    const revision = ownerDocument.createElement("span");
    revision.textContent = `Revision ${currentProjection.projectionRevision}`;
    revision.style.cssText =
      "flex:none;padding:.2rem .45rem;border-radius:999px;" +
      "background:#e2e8f0;color:#475569;font-size:.72rem";
    header.append(revision);
    root.append(header);

    const form = ownerDocument.createElement("form");
    form.noValidate = true;
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      requestSave();
    });
    const grid = ownerDocument.createElement("div");
    grid.style.cssText =
      "display:grid;grid-template-columns:repeat(auto-fit,minmax(18rem,1fr));" +
      "align-items:start;gap:.8rem";
    for (const definition of sectionDefinitions) {
      grid.append(
        renderSection(definition, currentProjection.sections[definition.key]),
      );
    }
    form.append(grid);

    const footer = ownerDocument.createElement("footer");
    footer.style.cssText =
      "display:flex;align-items:center;justify-content:flex-end;gap:.75rem;" +
      "margin-top:1rem;padding-top:.8rem;border-top:1px solid #cbd5e1";
    const status = ownerDocument.createElement("span");
    status.dataset.themeEditorStatus = "true";
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    status.style.cssText =
      "min-height:1.2em;margin-right:auto;color:#475569;font-size:.8rem";
    const saveButton = ownerDocument.createElement("button");
    saveButton.type = "submit";
    saveButton.dataset.themeEditorSave = "true";
    saveButton.textContent = "Save theme";
    saveButton.disabled = !currentProjection.save.enabled;
    saveButton.style.cssText =
      "border:1px solid #315f9b;border-radius:.38rem;padding:.48rem .8rem;" +
      "background:#315f9b;color:white;font-weight:600;cursor:pointer";
    if (!currentProjection.save.enabled) {
      saveButton.title = currentProjection.save.disabledReason;
      saveButton.style.cursor = "not-allowed";
      const reason = ownerDocument.createElement("span");
      reason.textContent = currentProjection.save.disabledReason;
      reason.style.cssText = "color:#9f1239;font-size:.78rem";
      footer.append(reason);
    }
    footer.append(status, saveButton);
    form.append(footer);
    root.append(form);

    function setStatus(message, isFailure = false) {
      status.textContent = message;
      status.style.color = isFailure ? "#9f1239" : "#475569";
    }

    function deliver(intent, pendingMessage, completedMessage) {
      let result;
      try {
        result = options.onIntent(intent);
      } catch (failure) {
        setStatus(failureMessage(failure), true);
        return;
      }
      if (
        result !== null &&
        (typeof result === "object" || typeof result === "function") &&
        typeof result.then === "function"
      ) {
        setStatus(pendingMessage);
        Promise.resolve(result).then(
          () => setStatus(completedMessage),
          (failure) => setStatus(failureMessage(failure), true),
        );
      } else if (completedMessage !== "") {
        setStatus(completedMessage);
      }
    }

    function requestSave() {
      if (!currentProjection.save.enabled) {
        return;
      }
      deliver(
        makeSaveIntent(currentProjection),
        "Saving theme…",
        "Save requested",
      );
    }

    function renderSection(definition, section) {
      const surface = ownerDocument.createElement("section");
      surface.dataset.themeEditorSection = definition.key;
      surface.style.cssText =
        "min-width:0;border:1px solid #cbd5e1;border-radius:.55rem;" +
        "padding:.7rem;background:white";
      const title = ownerDocument.createElement("h3");
      title.id = `${instanceId}-section-${definition.key}`;
      title.textContent = definition.label;
      title.style.cssText =
        "margin:0 0 .55rem;font-size:.86rem;text-transform:uppercase;" +
        "letter-spacing:.035em;color:#475569";
      surface.setAttribute("aria-labelledby", title.id);
      surface.append(title);

      let contentCount = 0;
      for (const control of section.controls) {
        surface.append(renderControl(control));
        contentCount += 1;
      }
      for (const group of section.groups) {
        surface.append(renderGroup(group));
        contentCount += 1;
      }
      if (section.actions.length > 0) {
        surface.append(renderActions(section.actions));
        contentCount += 1;
      }
      if (contentCount === 0) {
        const empty = ownerDocument.createElement("p");
        empty.textContent = "No controls in the current Haskell projection.";
        empty.style.cssText =
          "margin:.25rem 0;color:#64748b;font-size:.78rem;font-style:italic";
        surface.append(empty);
      }
      return surface;
    }

    function renderGroup(group) {
      const fieldset = ownerDocument.createElement("fieldset");
      fieldset.dataset.themeEditorGroup = group.id;
      fieldset.style.cssText =
        "min-width:0;margin:.55rem 0 0;padding:.5rem;border:1px solid #e2e8f0;" +
        "border-radius:.4rem";
      const legend = ownerDocument.createElement("legend");
      legend.textContent = group.label;
      legend.style.cssText =
        "max-width:100%;padding:0 .25rem;font-size:.8rem;font-weight:600";
      fieldset.append(legend);
      if (group.summary !== null) {
        const summary = ownerDocument.createElement("p");
        summary.textContent = group.summary;
        summary.style.cssText =
          "margin:0 0 .35rem;color:#64748b;font-size:.75rem";
        fieldset.append(summary);
      }
      for (const control of group.controls) {
        fieldset.append(renderControl(control));
      }
      if (group.actions.length > 0) {
        fieldset.append(renderActions(group.actions));
      }
      return fieldset;
    }

    function renderControl(control) {
      const row = ownerDocument.createElement("div");
      row.dataset.themeEditorControl = control.id;
      row.style.cssText =
        "display:grid;grid-template-columns:minmax(7rem,1fr) minmax(8rem,1.2fr);" +
        "gap:.25rem .55rem;align-items:center;margin:.4rem 0";
      const inputId = `${instanceId}-control-${control.id}`;
      const label = ownerDocument.createElement("label");
      label.htmlFor = inputId;
      label.textContent = control.label;
      label.style.cssText = "font-size:.79rem;color:#334155";
      row.append(label);

      const inputCell = ownerDocument.createElement("div");
      inputCell.style.cssText =
        "display:flex;min-width:0;align-items:center;gap:.35rem";
      let active = control.active;
      let override = null;
      if (control.optional) {
        override = ownerDocument.createElement("input");
        override.type = "checkbox";
        override.id = `${inputId}-active`;
        override.checked = active;
        override.disabled = !control.editable;
        override.setAttribute("aria-label", `Set ${control.label}`);
        override.title = `Set ${control.label}`;
        inputCell.append(override);
      }

      const input = createInput(control, ownerDocument);
      input.id = inputId;
      input.dataset.controlId = control.id;
      input.style.cssText +=
        "box-sizing:border-box;min-width:0;width:100%;border:1px solid #94a3b8;" +
        "border-radius:.3rem;padding:.28rem .38rem;background:white;color:#0f172a";
      inputCell.append(input);
      let swatch = null;
      if (control.kind === "colour") {
        swatch = ownerDocument.createElement("span");
        swatch.setAttribute("aria-hidden", "true");
        swatch.style.cssText =
          "flex:none;width:1.15rem;height:1.15rem;border:1px solid #94a3b8;" +
          "border-radius:.22rem";
        swatch.style.backgroundColor = String(control.value);
        inputCell.append(swatch);
      }
      row.append(inputCell);

      const message = ownerDocument.createElement("span");
      message.id = `${inputId}-message`;
      message.style.cssText =
        "grid-column:2;margin-top:-.1rem;color:#64748b;font-size:.72rem";
      if (!control.editable) {
        message.textContent = control.disabledReason;
      } else if (control.help !== null) {
        message.textContent = control.help;
      }
      if (message.textContent !== "") {
        input.setAttribute("aria-describedby", message.id);
      }
      row.append(message);

      function setEnabledState() {
        input.disabled = !control.editable || !active;
        if (swatch !== null) {
          swatch.style.opacity = input.disabled ? ".45" : "1";
        }
      }

      function validateAndEmit(phase, allowUnset = false) {
        if (!control.editable || (!active && !allowUnset)) {
          return;
        }
        const value = readInputValue(control.kind, input);
        const problem = validateInputValue(
          control.kind,
          value,
          control.options,
        );
        if (problem !== null) {
          input.setAttribute("aria-invalid", "true");
          message.textContent = problem;
          message.style.color = "#9f1239";
          input.setAttribute("aria-describedby", message.id);
          return;
        }
        input.removeAttribute("aria-invalid");
        message.textContent =
          !control.editable && control.disabledReason !== null
            ? control.disabledReason
            : (control.help ?? "");
        message.style.color = "#64748b";
        if (message.textContent === "") {
          input.removeAttribute("aria-describedby");
        }
        if (swatch !== null) {
          swatch.style.backgroundColor = String(value);
        }
        const intent = makeControlIntent(
          currentProjection,
          phase,
          control,
          active,
          value,
        );
        deliver(
          intent,
          phase === "preview" ? "Previewing change…" : "Applying change…",
          phase === "preview" ? "" : "Apply requested",
        );
      }

      if (override !== null) {
        override.addEventListener("input", () => {
          active = override.checked;
          setEnabledState();
          validateAndEmit("preview", true);
        });
        override.addEventListener("change", () => {
          active = override.checked;
          setEnabledState();
          validateAndEmit("apply", true);
        });
      }
      input.addEventListener("input", () => validateAndEmit("preview"));
      input.addEventListener("change", () => validateAndEmit("apply"));
      setEnabledState();
      return row;
    }

    function renderActions(actions) {
      const actionRow = ownerDocument.createElement("div");
      actionRow.style.cssText =
        "display:flex;flex-wrap:wrap;gap:.35rem;margin-top:.5rem";
      for (const action of actions) {
        const button = ownerDocument.createElement("button");
        button.type = "button";
        button.dataset.actionId = action.id;
        button.textContent = action.label;
        button.disabled = !action.enabled;
        button.style.cssText =
          "border:1px solid #94a3b8;border-radius:.32rem;padding:.3rem .5rem;" +
          "background:white;color:#334155;font-size:.76rem;cursor:pointer";
        if (action.appearance === "danger") {
          button.style.borderColor = "#fda4af";
          button.style.color = "#9f1239";
        }
        if (!action.enabled) {
          button.title = action.disabledReason;
          button.style.cursor = "not-allowed";
        }
        button.addEventListener("click", () => {
          if (!action.enabled) {
            return;
          }
          deliver(
            makeActionIntent(currentProjection, action),
            "Applying theme action…",
            "Apply requested",
          );
        });
        actionRow.append(button);
      }
      return actionRow;
    }
  }

  return Object.freeze({
    element: root,
    update(projection) {
      const validated = validateThemeEditorProjection(projection);
      currentProjection = validated;
      render();
    },
    destroy() {
      root.remove();
    },
  });
}

function validateSection(value, path, identities) {
  const section = expectRecord(value, path);
  requireExactKeys(section, ["controls", "groups", "actions"], path);
  const controls = validateArray(
    section.controls,
    `${path}.controls`,
    (control, controlPath) =>
      validateControl(control, controlPath, identities.controlIds),
  );
  const groups = validateArray(
    section.groups,
    `${path}.groups`,
    (group, groupPath) => validateGroup(group, groupPath, identities),
  );
  const actions = validateArray(
    section.actions,
    `${path}.actions`,
    (action, actionPath) =>
      validateAction(action, actionPath, identities.actionIds),
  );
  return { controls, groups, actions };
}

function validateGroup(value, path, identities) {
  const group = expectRecord(value, path);
  requireExactKeys(
    group,
    ["id", "label", "summary", "controls", "actions"],
    path,
  );
  const id = expectUniqueIdentifier(
    group.id,
    `${path}.id`,
    identities.groupIds,
  );
  return {
    id,
    label: expectUnicodeString(group.label, `${path}.label`, false),
    summary: expectNullableString(group.summary, `${path}.summary`),
    controls: validateArray(
      group.controls,
      `${path}.controls`,
      (control, controlPath) =>
        validateControl(control, controlPath, identities.controlIds),
    ),
    actions: validateArray(
      group.actions,
      `${path}.actions`,
      (action, actionPath) =>
        validateAction(action, actionPath, identities.actionIds),
    ),
  };
}

function validateControl(value, path, controlIds) {
  const control = expectRecord(value, path);
  requireExactKeys(
    control,
    [
      "id",
      "label",
      "help",
      "kind",
      "value",
      "optional",
      "active",
      "editable",
      "disabledReason",
      "options",
      "target",
    ],
    path,
  );
  const id = expectUniqueIdentifier(control.id, `${path}.id`, controlIds);
  const kind = expectOneOf(
    control.kind,
    ["text", "rational", "colour", "select", "checkbox"],
    `${path}.kind`,
  );
  const optional = expectBoolean(control.optional, `${path}.optional`);
  const active = expectBoolean(control.active, `${path}.active`);
  if (!optional && !active) {
    throw new ThemeEditorWireError(
      `${path}.active must be true for a non-optional control`,
    );
  }
  const editable = expectBoolean(control.editable, `${path}.editable`);
  const disabledReason = expectNullableString(
    control.disabledReason,
    `${path}.disabledReason`,
  );
  validateAvailability(editable, disabledReason, path);
  const options =
    kind === "select"
      ? validateOptions(control.options, `${path}.options`)
      : expectNull(control.options, `${path}.options`);
  const validatedValue = validateProjectedValue(
    kind,
    control.value,
    options,
    `${path}.value`,
  );
  return {
    id,
    label: expectUnicodeString(control.label, `${path}.label`, false),
    help: expectNullableString(control.help, `${path}.help`),
    kind,
    value: validatedValue,
    optional,
    active,
    editable,
    disabledReason,
    options,
    target: validateControlTarget(control.target, `${path}.target`),
  };
}

function validateAction(value, path, actionIds) {
  const action = expectRecord(value, path);
  requireExactKeys(
    action,
    ["id", "label", "appearance", "enabled", "disabledReason", "target"],
    path,
  );
  const enabled = expectBoolean(action.enabled, `${path}.enabled`);
  const disabledReason = expectNullableString(
    action.disabledReason,
    `${path}.disabledReason`,
  );
  validateAvailability(enabled, disabledReason, path);
  return {
    id: expectUniqueIdentifier(action.id, `${path}.id`, actionIds),
    label: expectUnicodeString(action.label, `${path}.label`, false),
    appearance: expectOneOf(
      action.appearance,
      ["default", "danger"],
      `${path}.appearance`,
    ),
    enabled,
    disabledReason,
    target: validateActionTarget(action.target, `${path}.target`),
  };
}

function validateControlTarget(value, path) {
  const target = expectRecord(value, path);
  const kind = expectUnicodeString(target.kind, `${path}.kind`, false);
  switch (kind) {
    case "theme_metadata":
      requireExactKeys(target, ["kind", "property"], path);
      return {
        kind,
        property: expectOneOf(
          target.property,
          ["name", "description"],
          `${path}.property`,
        ),
      };
    case "palette_colour":
      requireExactKeys(target, ["kind", "name"], path);
      return {
        kind,
        name: expectIdentifier(target.name, `${path}.name`),
      };
    case "type_scale_size":
      requireExactKeys(target, ["kind", "name"], path);
      return {
        kind,
        name: expectIdentifier(target.name, `${path}.name`),
      };
    case "role_typography":
      requireExactKeys(target, ["kind", "roleId", "property"], path);
      return {
        kind,
        roleId: expectIdentifier(target.roleId, `${path}.roleId`),
        property: expectSetMember(
          target.property,
          typographyProperties,
          `${path}.property`,
        ),
      };
    case "node_role":
      requireExactKeys(target, ["kind", "roleId", "property"], path);
      return {
        kind,
        roleId: expectIdentifier(target.roleId, `${path}.roleId`),
        property: expectSetMember(
          target.property,
          baseNodeProperties,
          `${path}.property`,
        ),
      };
    case "connector_role":
      requireExactKeys(target, ["kind", "roleId", "property"], path);
      return {
        kind,
        roleId: expectIdentifier(target.roleId, `${path}.roleId`),
        property: expectSetMember(
          target.property,
          baseConnectorProperties,
          `${path}.property`,
        ),
      };
    case "base_node":
      requireExactKeys(target, ["kind", "property"], path);
      return {
        kind,
        property: expectSetMember(
          target.property,
          baseNodeProperties,
          `${path}.property`,
        ),
      };
    case "base_connector":
      requireExactKeys(target, ["kind", "property"], path);
      return {
        kind,
        property: expectSetMember(
          target.property,
          baseConnectorProperties,
          `${path}.property`,
        ),
      };
    case "node_distance":
      requireExactKeys(target, ["kind"], path);
      return { kind };
    case "list_marker":
      requireExactKeys(target, ["kind", "property"], path);
      return {
        kind,
        property: expectOneOf(
          target.property,
          ["unordered", "ordered_pattern"],
          `${path}.property`,
        ),
      };
    case "master_region":
      requireExactKeys(target, ["kind", "regionId", "property"], path);
      return {
        kind,
        regionId: expectIdentifier(target.regionId, `${path}.regionId`),
        property: expectSetMember(
          target.property,
          masterRegionProperties,
          `${path}.property`,
        ),
      };
    case "master_anchor":
      requireExactKeys(target, ["kind", "anchorId", "property"], path);
      return {
        kind,
        anchorId: expectIdentifier(target.anchorId, `${path}.anchorId`),
        property: expectSetMember(
          target.property,
          masterAnchorProperties,
          `${path}.property`,
        ),
      };
    case "safe_area":
      requireExactKeys(target, ["kind", "edge"], path);
      return {
        kind,
        edge: expectOneOf(
          target.edge,
          ["left", "top", "right", "bottom"],
          `${path}.edge`,
        ),
      };
    case "furniture":
      requireExactKeys(
        target,
        ["kind", "furnitureId", "furnitureKind", "property"],
        path,
      );
      return validateFurnitureTarget(target, path);
    default:
      throw new ThemeEditorWireError(
        `${path}.kind has unknown variant ${JSON.stringify(kind)}`,
      );
  }
}

function validateFurnitureTarget(target, path) {
  const furnitureKind = expectOneOf(
    target.furnitureKind,
    Object.keys(furnitureProperties),
    `${path}.furnitureKind`,
  );
  return {
    kind: "furniture",
    furnitureId: expectIdentifier(target.furnitureId, `${path}.furnitureId`),
    furnitureKind,
    property: expectSetMember(
      target.property,
      furnitureProperties[furnitureKind],
      `${path}.property`,
    ),
  };
}

function validateActionTarget(value, path) {
  const target = expectRecord(value, path);
  const kind = expectUnicodeString(target.kind, `${path}.kind`, false);
  switch (kind) {
    case "add_master_region":
    case "add_master_anchor":
      requireExactKeys(target, ["kind"], path);
      return { kind };
    case "remove_master_region":
      requireExactKeys(target, ["kind", "regionId"], path);
      return {
        kind,
        regionId: expectIdentifier(target.regionId, `${path}.regionId`),
      };
    case "remove_master_anchor":
      requireExactKeys(target, ["kind", "anchorId"], path);
      return {
        kind,
        anchorId: expectIdentifier(target.anchorId, `${path}.anchorId`),
      };
    case "add_furniture":
      requireExactKeys(target, ["kind", "furnitureKind"], path);
      return {
        kind,
        furnitureKind: expectOneOf(
          target.furnitureKind,
          Object.keys(furnitureProperties),
          `${path}.furnitureKind`,
        ),
      };
    case "remove_furniture":
      requireExactKeys(target, ["kind", "furnitureId"], path);
      return {
        kind,
        furnitureId: expectIdentifier(
          target.furnitureId,
          `${path}.furnitureId`,
        ),
      };
    case "edit_furniture_slot":
      requireExactKeys(target, ["kind", "furnitureId", "slot"], path);
      return {
        kind,
        furnitureId: expectIdentifier(
          target.furnitureId,
          `${path}.furnitureId`,
        ),
        slot: expectOneOf(
          target.slot,
          ["left", "centre", "right"],
          `${path}.slot`,
        ),
      };
    default:
      throw new ThemeEditorWireError(
        `${path}.kind has unknown variant ${JSON.stringify(kind)}`,
      );
  }
}

function validateOptions(value, path) {
  const options = validateArray(value, path, (option, optionPath) => {
    const record = expectRecord(option, optionPath);
    requireExactKeys(record, ["value", "label"], optionPath);
    return {
      value: expectUnicodeString(record.value, `${optionPath}.value`, true),
      label: expectUnicodeString(record.label, `${optionPath}.label`, false),
    };
  });
  if (options.length === 0) {
    throw new ThemeEditorWireError(`${path} must not be empty`);
  }
  const values = new Set();
  for (const option of options) {
    if (values.has(option.value)) {
      throw new ThemeEditorWireError(
        `${path} contains duplicate value ${JSON.stringify(option.value)}`,
      );
    }
    values.add(option.value);
  }
  return options;
}

function validateProjectedValue(kind, value, options, path) {
  switch (kind) {
    case "text":
      return expectUnicodeString(value, path, true);
    case "rational":
      return expectRational(value, path);
    case "colour":
      return expectColour(value, path);
    case "select": {
      const selected = expectUnicodeString(value, path, true);
      if (!options.some((option) => option.value === selected)) {
        throw new ThemeEditorWireError(
          `${path} is not present in the supplied options`,
        );
      }
      return selected;
    }
    case "checkbox":
      return expectBoolean(value, path);
    default:
      throw new ThemeEditorWireError(`${path} has unsupported control kind`);
  }
}

function createInput(control, ownerDocument) {
  if (control.kind === "select") {
    const select = ownerDocument.createElement("select");
    for (const option of control.options) {
      const node = ownerDocument.createElement("option");
      node.value = option.value;
      node.textContent = option.label;
      node.selected = option.value === control.value;
      select.append(node);
    }
    return select;
  }
  const input = ownerDocument.createElement("input");
  if (control.kind === "checkbox") {
    input.type = "checkbox";
    input.checked = control.value;
  } else {
    input.type = "text";
    input.value = control.value;
    if (control.kind === "rational") {
      input.inputMode = "decimal";
      input.setAttribute("pattern", rationalPattern.source);
    } else if (control.kind === "colour") {
      input.inputMode = "text";
      input.autocomplete = "off";
      input.spellcheck = false;
      input.setAttribute("pattern", colourPattern.source);
    }
  }
  return input;
}

function readInputValue(kind, input) {
  return kind === "checkbox" ? input.checked : input.value;
}

function validateInputValue(kind, value, options) {
  switch (kind) {
    case "text":
      return unicodeProblem(value);
    case "rational":
      return typeof value === "string" && rationalPattern.test(value)
        ? null
        : "Enter an integer, decimal, or exact fraction.";
    case "colour":
      return typeof value === "string" && colourPattern.test(value)
        ? null
        : "Enter #RRGGBB or #RRGGBBAA.";
    case "select":
      return typeof value === "string" &&
        options.some((option) => option.value === value)
        ? null
        : "Choose one of the supplied values.";
    case "checkbox":
      return typeof value === "boolean"
        ? null
        : "Choose an enabled or disabled value.";
    default:
      return "Unsupported control.";
  }
}

function makeControlIntent(projection, phase, control, active, value) {
  return deepFreeze({
    protocol: themeEditorProtocol,
    projectionRevision: projection.projectionRevision,
    themeId: projection.theme.id,
    phase,
    edit: {
      kind: "set_control",
      controlId: control.id,
      target: control.target,
      state: active ? { kind: "set", value } : { kind: "unset" },
    },
  });
}

function makeActionIntent(projection, action) {
  return deepFreeze({
    protocol: themeEditorProtocol,
    projectionRevision: projection.projectionRevision,
    themeId: projection.theme.id,
    phase: "apply",
    edit: {
      kind: "invoke_action",
      actionId: action.id,
      target: action.target,
    },
  });
}

function makeSaveIntent(projection) {
  return deepFreeze({
    protocol: themeEditorProtocol,
    projectionRevision: projection.projectionRevision,
    themeId: projection.theme.id,
    phase: "save",
    edit: { kind: "save_theme" },
  });
}

function validateArray(value, path, validateEntry) {
  if (!Array.isArray(value)) {
    throw new ThemeEditorWireError(`${path} must be an array`);
  }
  if (value.length > maximumCollectionLength) {
    throw new ThemeEditorWireError(
      `${path} exceeds ${maximumCollectionLength} entries`,
    );
  }
  return value.map((entry, index) => validateEntry(entry, `${path}[${index}]`));
}

function validateAvailability(enabled, disabledReason, path) {
  if (enabled && disabledReason !== null) {
    throw new ThemeEditorWireError(
      `${path}.disabledReason must be null when enabled`,
    );
  }
  if (!enabled && (disabledReason === null || disabledReason === "")) {
    throw new ThemeEditorWireError(
      `${path}.disabledReason must explain why it is disabled`,
    );
  }
}

function expectRecord(value, path) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ThemeEditorWireError(`${path} must be an object`);
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    throw new ThemeEditorWireError(`${path} must be a plain object`);
  }
  return value;
}

function requireExactKeys(value, expectedKeys, path) {
  const actual = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new ThemeEditorWireError(
      `${path} must contain exactly: ${expected.join(", ")}`,
    );
  }
}

function expectLiteral(value, expected, path) {
  if (value !== expected) {
    throw new ThemeEditorWireError(
      `${path} must be ${JSON.stringify(expected)}`,
    );
  }
  return value;
}

function expectBoolean(value, path) {
  if (typeof value !== "boolean") {
    throw new ThemeEditorWireError(`${path} must be a boolean`);
  }
  return value;
}

function expectSafeUnsignedInteger(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ThemeEditorWireError(
      `${path} must be a non-negative safe integer`,
    );
  }
  return value;
}

function expectIdentifier(value, path) {
  const text = expectUnicodeString(value, path, false);
  if (!identifierPattern.test(text)) {
    throw new ThemeEditorWireError(
      `${path} must match ${identifierPattern.source}`,
    );
  }
  return text;
}

function expectUniqueIdentifier(value, path, seen) {
  const identifier = expectIdentifier(value, path);
  if (seen.has(identifier)) {
    throw new ThemeEditorWireError(
      `${path} duplicates identifier ${JSON.stringify(identifier)}`,
    );
  }
  if (seen.size >= maximumCollectionLength) {
    throw new ThemeEditorWireError(
      `${path} exceeds the projection-wide identifier budget`,
    );
  }
  seen.add(identifier);
  return identifier;
}

function expectUnicodeString(value, path, allowEmpty) {
  if (typeof value !== "string") {
    throw new ThemeEditorWireError(`${path} must be a string`);
  }
  if ((!allowEmpty && value.length === 0) || value.length > maximumTextLength) {
    throw new ThemeEditorWireError(`${path} has an invalid length`);
  }
  const problem = unicodeProblem(value);
  if (problem !== null) {
    throw new ThemeEditorWireError(`${path} ${problem.toLowerCase()}`);
  }
  return value;
}

function unicodeProblem(value) {
  if (typeof value !== "string") {
    return "Enter text.";
  }
  if (value.length > maximumTextLength) {
    return `Text exceeds ${maximumTextLength} UTF-16 code units.`;
  }
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        return "Text contains an unpaired Unicode surrogate.";
      }
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return "Text contains an unpaired Unicode surrogate.";
    }
  }
  return null;
}

function expectNullableString(value, path) {
  return value === null ? null : expectUnicodeString(value, path, true);
}

function expectNull(value, path) {
  if (value !== null) {
    throw new ThemeEditorWireError(`${path} must be null`);
  }
  return null;
}

function expectRational(value, path) {
  const text = expectUnicodeString(value, path, false);
  if (!rationalPattern.test(text)) {
    throw new ThemeEditorWireError(
      `${path} must be a canonical integer, decimal, or exact fraction`,
    );
  }
  return text;
}

function expectColour(value, path) {
  const text = expectUnicodeString(value, path, false);
  if (!colourPattern.test(text)) {
    throw new ThemeEditorWireError(`${path} must be #RRGGBB or #RRGGBBAA`);
  }
  return text;
}

function expectOneOf(value, variants, path) {
  const text = expectUnicodeString(value, path, false);
  if (!variants.includes(text)) {
    throw new ThemeEditorWireError(
      `${path} has unknown variant ${JSON.stringify(text)}`,
    );
  }
  return text;
}

function expectSetMember(value, variants, path) {
  const text = expectUnicodeString(value, path, false);
  if (!variants.has(text)) {
    throw new ThemeEditorWireError(
      `${path} has unknown variant ${JSON.stringify(text)}`,
    );
  }
  return text;
}

function failureMessage(failure) {
  return `Theme edit failed: ${
    failure instanceof Error ? failure.message : String(failure)
  }`;
}

function deepFreeze(value) {
  if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const nested of Object.values(value)) {
      deepFreeze(nested);
    }
  }
  return value;
}

let instanceSequence = 0;

function nextInstanceId() {
  instanceSequence += 1;
  return `sb-theme-editor-${instanceSequence}`;
}
