import { protectedJSON } from "./api";
import { appURL } from "./base";

export type MindFSServiceStatus = {
  status: "running" | "restarting" | string;
  version?: string;
  pid?: number;
};

export async function fetchMindFSServiceStatus(): Promise<MindFSServiceStatus> {
  return protectedJSON<MindFSServiceStatus>(appURL("/api/app/status"));
}

export async function restartMindFSService(): Promise<MindFSServiceStatus> {
  return protectedJSON<MindFSServiceStatus>(appURL("/api/app/restart"), {
    method: "POST",
  });
}

export async function waitForMindFSService(timeoutMs = 20_000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 500));
    try {
      const response = await fetch(appURL("/health"), {
        cache: "no-store",
      });
      if (response.ok) {
        return true;
      }
    } catch {
    }
  }
  return false;
}
