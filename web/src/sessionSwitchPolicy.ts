export type SessionSelectionState = {
  key?: string;
  session_key?: string;
  root_id?: string;
  search_seq?: number;
  search_target_id?: string;
  search_snippet?: string;
  search_match_type?: "name" | "user" | "reply";
  [key: string]: unknown;
};

export type ServerSyncResult<T> = {
  session: T | null;
  hasDelta: boolean;
  serverConfirmed: boolean;
};

export type SessionVersion = {
  rootId: string;
  key: string;
  updatedAt: string;
};

export function withSessionRoot<T extends { root_id?: string }>(
  session: T,
  rootId: string,
): T & { root_id: string } {
  if (session.root_id === rootId) {
    return session as T & { root_id: string };
  }
  return { ...session, root_id: rootId };
}

const transientSelectionFields = [
  "search_seq",
  "search_target_id",
  "search_snippet",
  "search_match_type",
] as const;

export function createServerSyncResult<T>(
  session: T | null,
  hasDelta: boolean,
  serverConfirmed: boolean,
): ServerSyncResult<T> {
  return { session, hasDelta, serverConfirmed };
}

export function confirmedSessionForApply<T>(
  result: ServerSyncResult<T> | null | undefined,
): T | null {
  if (!result?.serverConfirmed) {
    return null;
  }
  return result.session;
}

export function shouldRefreshTokenStationForSessionVersion(
  previous: SessionVersion | null | undefined,
  next: SessionVersion | null | undefined,
): boolean {
  return Boolean(
    previous?.key &&
      previous.rootId &&
      previous.updatedAt &&
      next?.key &&
      next.rootId &&
      next.updatedAt &&
      previous.rootId === next.rootId &&
      previous.key === next.key &&
      previous.updatedAt !== next.updatedAt,
  );
}

export function sessionSelectionMatchesTarget(
  selection: SessionSelectionState | null | undefined,
  targetRoot: string,
  targetKey: string,
  currentRoot: string | null | undefined,
): boolean {
  if (!selection) {
    return false;
  }
  const selectionKey = selection.key || selection.session_key || "";
  const selectionRoot = selection.root_id || currentRoot || "";
  return selectionKey === targetKey && selectionRoot === targetRoot;
}

export function mergeSelectedSessionForTarget(
  previous: SessionSelectionState | null | undefined,
  loaded: SessionSelectionState,
  targetRoot: string,
  targetKey: string,
  currentRoot: string | null | undefined,
  selectionSeed?: SessionSelectionState | null,
): SessionSelectionState | null {
  const base =
    selectionSeed ||
    (sessionSelectionMatchesTarget(previous, targetRoot, targetKey, currentRoot)
      ? previous
      : null);
  if (!base) {
    return previous || null;
  }

  const merged: SessionSelectionState = {
    ...base,
    ...loaded,
    key: targetKey,
    session_key: targetKey,
    root_id: targetRoot,
  };
  if (selectionSeed) {
    for (const field of transientSelectionFields) {
      if (selectionSeed[field] !== undefined) {
        (merged as Record<string, unknown>)[field] = selectionSeed[field];
      }
    }
  }
  return merged;
}
