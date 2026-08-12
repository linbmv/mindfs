import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const actionBarSource = await readFile(
  new URL("../src/components/ActionBar.tsx", import.meta.url),
  "utf8",
);

describe("ActionBar Escape policy", () => {
  it("does not register Escape as a current-task cancellation shortcut", () => {
    assert.doesNotMatch(actionBarSource, /cancelOnEscape/);
    assert.doesNotMatch(
      actionBarSource,
      /addEventListener\(\s*["']keydown["'][\s\S]{0,800}handleCancel/,
    );
  });

  it("keeps explicit cancellation on the stop button", () => {
    assert.match(actionBarSource, /const handleCancel = useCallback/);
    assert.match(actionBarSource, /onClick=\{showCancel \? handleCancel : handleSend\}/);
  });

  it("keeps Escape available for dismissing the input candidate menu", () => {
    assert.match(
      actionBarSource,
      /if \(e\.key === ["']Escape["']\)[\s\S]{0,240}setCandidates\(\[\]\)/,
    );
  });
});
