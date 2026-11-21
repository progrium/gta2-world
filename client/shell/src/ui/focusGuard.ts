// Keep the game screen's controls out of focus navigation while playing.
// iPad Safari (and other browsers with controller navigation) move focus to
// page controls from gamepad buttons: a trigger landed on the on-foot scheme
// dropdown and changed it. Controls here can only take focus from a pointer
// (mouse, touch, pen); any other focus goes back to the game view, and a
// control lets go of focus once it has been used.

/** How long after a pointer press a focus still counts as coming from it. */
const POINTER_WINDOW_MS = 800;

export function guardFocus(controls: HTMLElement, home: HTMLElement, now: () => number = () => performance.now()): () => void {
  if (!home.hasAttribute("tabindex")) home.setAttribute("tabindex", "-1");
  let pointerAt = -Infinity;
  const goHome = (): void => {
    const a = document.activeElement;
    if (a instanceof HTMLElement && controls.contains(a)) a.blur();
    home.focus({ preventScroll: true });
  };
  const onPointer = (): void => {
    pointerAt = now();
  };
  const onFocusIn = (e: FocusEvent): void => {
    if (now() - pointerAt <= POINTER_WINDOW_MS) return;
    (e.target as HTMLElement | null)?.blur?.();
    home.focus({ preventScroll: true });
  };
  // A used control hands focus back, so later pad or key presses can't reach it.
  // A select keeps focus while its picker is open; it gives it back on change.
  const onUsed = (e: Event): void => {
    const t = e.target as HTMLElement;
    if (e.type === "click" && t instanceof HTMLSelectElement) return;
    queueMicrotask(goHome);
  };
  controls.addEventListener("pointerdown", onPointer, true);
  controls.addEventListener("mousedown", onPointer, true);
  controls.addEventListener("touchstart", onPointer, { capture: true, passive: true });
  controls.addEventListener("focusin", onFocusIn);
  controls.addEventListener("change", onUsed);
  controls.addEventListener("click", onUsed);
  home.focus({ preventScroll: true });
  return () => {
    controls.removeEventListener("pointerdown", onPointer, true);
    controls.removeEventListener("mousedown", onPointer, true);
    controls.removeEventListener("touchstart", onPointer, { capture: true });
    controls.removeEventListener("focusin", onFocusIn);
    controls.removeEventListener("change", onUsed);
    controls.removeEventListener("click", onUsed);
  };
}
