export type TimelineWindowItem = {
  type?: string;
  seq?: number;
};

export type TimelineWindow = {
  start: number;
  end: number;
  followLatest: boolean;
};

export const INITIAL_TIMELINE_WINDOW_ITEMS = 12;
export const TIMELINE_WINDOW_LOAD_STEP = 24;
export const TIMELINE_TARGET_OVERSCAN = 3;

export function latestTimelineWindow(
  total: number,
  limit = INITIAL_TIMELINE_WINDOW_ITEMS,
): TimelineWindow {
  const safeTotal = Math.max(0, Math.floor(total));
  const safeLimit = Math.max(1, Math.floor(limit));
  return {
    start: Math.max(0, safeTotal - safeLimit),
    end: safeTotal,
    followLatest: true,
  };
}

export function timelineWindowAroundIndex(
  total: number,
  index: number,
  limit = INITIAL_TIMELINE_WINDOW_ITEMS,
  overscanBefore = TIMELINE_TARGET_OVERSCAN,
): TimelineWindow {
  const safeTotal = Math.max(0, Math.floor(total));
  if (safeTotal === 0) {
    return { start: 0, end: 0, followLatest: false };
  }
  const safeLimit = Math.max(1, Math.floor(limit));
  const safeIndex = Math.max(0, Math.min(safeTotal - 1, Math.floor(index)));
  const start = Math.max(0, safeIndex - Math.max(0, Math.floor(overscanBefore)));
  return {
    start,
    end: Math.min(safeTotal, Math.max(safeIndex + 1, start + safeLimit)),
    followLatest: false,
  };
}

export function initialTimelineWindow(
  timeline: TimelineWindowItem[],
  targetSeq = 0,
  limit = INITIAL_TIMELINE_WINDOW_ITEMS,
): TimelineWindow {
  if (targetSeq > 0) {
    const targetIndex = timeline.findIndex(
      (item) => Number(item.seq || 0) === targetSeq,
    );
    if (targetIndex >= 0) {
      return timelineWindowAroundIndex(timeline.length, targetIndex, limit);
    }
  }
  return latestTimelineWindow(timeline.length, limit);
}

export function clampTimelineWindow(
  window: TimelineWindow,
  total: number,
  limit = INITIAL_TIMELINE_WINDOW_ITEMS,
): TimelineWindow {
  const safeTotal = Math.max(0, Math.floor(total));
  if (window.followLatest) {
    return latestTimelineWindow(safeTotal, limit);
  }
  const start = Math.max(0, Math.min(safeTotal, Math.floor(window.start)));
  const end = Math.max(start, Math.min(safeTotal, Math.floor(window.end)));
  if (start === end && safeTotal > 0) {
    return timelineWindowAroundIndex(safeTotal, Math.min(start, safeTotal - 1), limit);
  }
  return { start, end, followLatest: false };
}

export function expandTimelineEarlier(
  window: TimelineWindow,
  total: number,
  step = TIMELINE_WINDOW_LOAD_STEP,
): TimelineWindow {
  const current = clampTimelineWindow(window, total);
  return {
    start: Math.max(0, current.start - Math.max(1, Math.floor(step))),
    end: current.end,
    followLatest: false,
  };
}

export function shouldResumeTimelineFollowLatest(
  window: TimelineWindow,
  total: number,
  options: {
    isNearBottom: boolean;
    movedDown: boolean;
    suppress: boolean;
  },
): boolean {
  const safeTotal = Math.max(0, Math.floor(total));
  return Boolean(
    !window.followLatest &&
      window.end >= safeTotal &&
      options.isNearBottom &&
      options.movedDown &&
      !options.suppress,
  );
}

export function timelineIndexForUserMessage(
  timeline: TimelineWindowItem[],
  userMessageIndex: number,
): number {
  if (userMessageIndex <= 0) {
    return -1;
  }
  let seen = 0;
  for (let index = 0; index < timeline.length; index += 1) {
    if (timeline[index]?.type !== "user_text") {
      continue;
    }
    seen += 1;
    if (seen === userMessageIndex) {
      return index;
    }
  }
  return -1;
}
