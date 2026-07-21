import { protectedFetch, protectedJSON } from "./api";
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

// Downloads a tar.gz archive of all channel configuration (config profiles,
// profile env values, API providers, agents.json) via the browser save dialog.
// The archive contains API keys and auth tokens — treat it like a password file.
export async function downloadConfigBackup(): Promise<void> {
  const response = await protectedFetch(appURL("/api/config-backup/download"));
  if (!response.ok) {
    throw new Error(`backup download failed: ${response.status}`);
  }
  const disposition = response.headers.get("Content-Disposition") || "";
  const match = disposition.match(/filename="?([^";]+)"?/);
  const filename = match?.[1] || "mindfs-config-backup.tar.gz";
  const blob = await response.blob();
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}
