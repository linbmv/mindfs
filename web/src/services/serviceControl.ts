import { protectedFetch, protectedJSON } from "./api";
import { appURL } from "./base";
import { e2eeService } from "./e2ee";

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

export async function waitForMindFSService(previousPID?: number, timeoutMs = 20_000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 500));
    try {
      const status = await fetchMindFSServiceStatus();
      if (status.status === "running" && (!previousPID || status.pid !== previousPID)) {
        return true;
      }
    } catch {
      // A short connection failure is expected while the old process exits.
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
    let payload: { message?: string; error?: string } = {};
    try {
      payload = await e2eeService.parseProtectedJSONResponse<{ message?: string; error?: string }>(response.clone());
    } catch {
      // Keep the HTTP status as the fallback when an error response is not JSON.
    }
    throw new Error(String(payload.message || payload.error || `backup download failed: ${response.status}`));
  }
  const disposition = response.headers.get("Content-Disposition") || "";
  const match = disposition.match(/filename="?([^";]+)"?/);
  const filename = match?.[1] || "mindfs-config-backup.tar.gz";
  const bytes = await e2eeService.parseProtectedBytesResponse(response);
  const rawBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const blob = new Blob([rawBuffer], { type: "application/gzip" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}
