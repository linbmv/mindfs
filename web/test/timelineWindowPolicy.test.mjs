import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { createServer } from "vite";

let policy;
let vite;

before(async () => {
  vite = await createServer({
    configFile: false,
    server: { middlewareMode: true },
    appType: "custom",
  });
  policy = await vite.ssrLoadModule("/src/timelineWindowPolicy.ts");
});

after(async () => {
  await vite?.close();
});

describe("timeline window policy", () => {
  const timeline = Array.from({ length: 40 }, (_, index) => ({
    type: index % 2 === 0 ? "user_text" : "assistant_text",
    seq: index + 1,
  }));

  it("renders only the latest bounded window by default", () => {
    assert.deepEqual(policy.initialTimelineWindow(timeline, 0, 12), {
      start: 28,
      end: 40,
      followLatest: true,
    });
  });

  it("places a search target inside a bounded window", () => {
    const window = policy.initialTimelineWindow(timeline, 6, 12);
    assert.deepEqual(window, { start: 2, end: 14, followLatest: false });
    assert.ok(window.start <= 5 && window.end > 5);
  });

  it("expands earlier history without dropping the current tail", () => {
    assert.deepEqual(
      policy.expandTimelineEarlier({ start: 28, end: 40, followLatest: true }, 40, 10),
      { start: 18, end: 40, followLatest: false },
    );
  });

  it("resumes following only after a real downward scroll reaches the current tail", () => {
    const expanded = { start: 4, end: 40, followLatest: false };
    const shouldResume = policy.shouldResumeTimelineFollowLatest;

    assert.equal(
      shouldResume(expanded, 40, {
        isNearBottom: true,
        movedDown: true,
        suppress: false,
      }),
      true,
    );
    assert.equal(
      shouldResume(expanded, 40, {
        isNearBottom: true,
        movedDown: true,
        suppress: true,
      }),
      false,
    );
    assert.equal(
      shouldResume({ start: 4, end: 20, followLatest: false }, 40, {
        isNearBottom: true,
        movedDown: true,
        suppress: false,
      }),
      false,
    );
    assert.equal(
      shouldResume(expanded, 40, {
        isNearBottom: true,
        movedDown: false,
        suppress: false,
      }),
      false,
    );
  });

  it("locates a user-message summary in the full timeline", () => {
    assert.equal(policy.timelineIndexForUserMessage(timeline, 1), 0);
    assert.equal(policy.timelineIndexForUserMessage(timeline, 4), 6);
    assert.equal(policy.timelineIndexForUserMessage(timeline, 99), -1);
  });
});
