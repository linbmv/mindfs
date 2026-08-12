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
  policy = await vite.ssrLoadModule("/src/sessionSwitchPolicy.ts");
});

after(async () => {
  await vite?.close();
});

describe("session switch policy", () => {
  it("initializes a memory-hit target instead of retaining the previous session", () => {
    const previous = {
      key: "session-a",
      session_key: "session-a",
      root_id: "root-a",
      exchanges: [{ seq: 1, content: "A" }],
    };
    const selectionSeed = {
      key: "session-b",
      session_key: "session-b",
      root_id: "root-b",
      search_seq: 9,
      search_target_id: "session-b:9:1",
    };
    const cached = {
      key: "session-b",
      root_id: "root-b",
      search_seq: 3,
      search_target_id: "session-b:3:old",
      exchanges: [{ seq: 1, content: "B" }],
    };

    const selected = policy.mergeSelectedSessionForTarget(
      previous,
      cached,
      "root-b",
      "session-b",
      "root-a",
      selectionSeed,
    );

    assert.deepEqual(selected, {
      ...selectionSeed,
      ...cached,
      session_key: "session-b",
      search_seq: 9,
      search_target_id: "session-b:9:1",
    });
  });

  it("does not let an asynchronous result replace a different current session", () => {
    const previous = {
      key: "session-b",
      session_key: "session-b",
      root_id: "root-a",
    };
    const lateSessionA = {
      key: "session-a",
      root_id: "root-a",
      exchanges: [{ seq: 1, content: "late A" }],
    };

    assert.deepEqual(
      policy.mergeSelectedSessionForTarget(
        previous,
        lateSessionA,
        "root-a",
        "session-a",
        "root-a",
      ),
      previous,
    );
  });

  it("matches both root and key before applying a reconnect replay", () => {
    const selected = {
      key: "shared-key",
      session_key: "shared-key",
      root_id: "root-b",
    };

    assert.equal(
      policy.sessionSelectionMatchesTarget(
        selected,
        "root-a",
        "shared-key",
        "root-b",
      ),
      false,
    );
    assert.equal(
      policy.sessionSelectionMatchesTarget(
        selected,
        "root-b",
        "shared-key",
        "root-b",
      ),
      true,
    );
  });

  it("commits only server-confirmed synchronization results", () => {
    const olderIndexedDBSession = {
      key: "session-a",
      exchanges: [{ seq: 1 }],
    };
    const fallback = policy.createServerSyncResult(
      olderIndexedDBSession,
      false,
      false,
    );
    const confirmed = policy.createServerSyncResult(
      { key: "session-a", exchanges: [{ seq: 1 }, { seq: 2 }] },
      true,
      true,
    );

    assert.equal(policy.confirmedSessionForApply(fallback), null);
    assert.deepEqual(
      policy.confirmedSessionForApply(confirmed),
      confirmed.session,
    );
  });

  it("refreshes Token Station only when the selected session version advances", () => {
    const shouldRefresh =
      policy.shouldRefreshTokenStationForSessionVersion;

    assert.equal(
      shouldRefresh(null, { rootId: "root-a", key: "session-a", updatedAt: "v1" }),
      false,
    );
    assert.equal(
      shouldRefresh(
        { rootId: "root-a", key: "session-a", updatedAt: "v1" },
        { rootId: "root-a", key: "session-b", updatedAt: "v2" },
      ),
      false,
    );
    assert.equal(
      shouldRefresh(
        { rootId: "root-a", key: "session-a", updatedAt: "v1" },
        { rootId: "root-a", key: "session-a", updatedAt: "v1" },
      ),
      false,
    );
    assert.equal(
      shouldRefresh(
        { rootId: "root-a", key: "session-a", updatedAt: "v1" },
        { rootId: "root-a", key: "session-a", updatedAt: "v2" },
      ),
      true,
    );
    assert.equal(
      shouldRefresh(
        { rootId: "root-a", key: "shared-key", updatedAt: "v1" },
        { rootId: "root-b", key: "shared-key", updatedAt: "v2" },
      ),
      false,
    );
    assert.equal(
      shouldRefresh(
        { rootId: "root-a", key: "", updatedAt: "v1" },
        { rootId: "root-a", key: "", updatedAt: "v2" },
      ),
      false,
    );
    assert.equal(
      shouldRefresh(
        { rootId: "root-a", key: "session-a", updatedAt: "" },
        { rootId: "root-a", key: "session-a", updatedAt: "v2" },
      ),
      false,
    );
  });

  it("reuses an already-rooted multi-project session object", () => {
    const rooted = { key: "session-a", root_id: "root-a" };
    assert.equal(policy.withSessionRoot(rooted, "root-a"), rooted);
    assert.deepEqual(policy.withSessionRoot({ key: "session-b" }, "root-b"), {
      key: "session-b",
      root_id: "root-b",
    });
  });
});
