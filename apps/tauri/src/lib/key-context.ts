// What the keys' `when` clauses can ask besides where the focus is (`turnRunning`, `modelPickerOpen`, `composerDraft`
// on the Mac): the views that know set these, the shell adds them when it resolves a key.
export const keyFlags: { turnRunning: boolean; modelPickerOpen: boolean; composerDraft: boolean } = {
  turnRunning: false,
  modelPickerOpen: false,
  composerDraft: false,
};
