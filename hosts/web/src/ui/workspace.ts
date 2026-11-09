import {
  readPanePreference,
  writePanePreference,
} from "../capabilities/preferences.ts";

const paneDefinitions = Object.freeze([
  Object.freeze({
    name: "files",
    button: "#view-files",
    pane: "#side-panel",
    defaultVisible: false,
    available: false,
  }),
  Object.freeze({
    name: "source",
    button: "#view-source",
    pane: "#editor-pane",
    defaultVisible: true,
    available: true,
  }),
  Object.freeze({
    name: "shapes",
    button: "#view-shapes",
    pane: "#shapes-panel",
    defaultVisible: false,
    available: true,
  }),
]);

/**
 * Bind canvas-first workspace visibility without mounting or replacing pane
 * content. The `hidden` attribute changes layout while preserving each pane's
 * DOM state, including the source textarea selection and scroll position.
 *
 * @param {Document | HTMLElement} [root]
 */
export function bindWorkspacePanes(root = document) {
  const workspace = requireElement(root, "#workspace");
  for (const definition of paneDefinitions) {
    const button = requireElement(root, definition.button);
    const pane = requireElement(root, definition.pane);
    if (!definition.available) {
      setPaneVisible(workspace, definition.name, button, pane, false);
      button.setAttribute("aria-disabled", "true");
      button.setAttribute(
        "title",
        "Files require a real browser working-copy port",
      );
      (button as HTMLButtonElement).disabled = true;
      continue;
    }

    const initialVisibility = readPanePreference(
      definition.name,
      definition.defaultVisible,
    );

    setPaneVisible(workspace, definition.name, button, pane, initialVisibility);
    button.addEventListener("click", () => {
      const visible = button.getAttribute("aria-pressed") !== "true";
      setPaneVisible(workspace, definition.name, button, pane, visible);
      writePanePreference(definition.name, visible);
    });
  }
}

/**
 * @param {HTMLElement} workspace
 * @param {string} name
 * @param {HTMLElement} button
 * @param {HTMLElement} pane
 * @param {boolean} visible
 */
function setPaneVisible(workspace, name, button, pane, visible) {
  pane.hidden = !visible;
  button.setAttribute("aria-pressed", String(visible));
  button.classList.toggle("is-active", visible);
  workspace.dataset[`${name}Visible`] = String(visible);
}

/**
 * @param {Document | HTMLElement} root
 * @param {string} selector
 * @returns {HTMLElement}
 */
function requireElement(root, selector) {
  const element = root.querySelector(selector);
  if (!(element instanceof HTMLElement)) {
    throw new Error(`Missing workspace element: ${selector}`);
  }
  return element;
}
