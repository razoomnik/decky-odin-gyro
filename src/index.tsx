import {
  ButtonItem,
  PanelSection,
  PanelSectionRow,
  staticClasses,
} from "@decky/ui";
import { callable, definePlugin, toaster } from "@decky/api";
import { useCallback, useEffect, useRef, useState } from "react";

type Status = {
  service_active: boolean;
  inputplumber_active: boolean;
  imu_present: boolean;
  sensor_feed_active: boolean;
  adsprpcd_active: boolean;
  module_present: boolean;
  gyro_ready: boolean;
  job_running: boolean;
  job_type: "install" | "calibrate" | null;
  last_job_type: "install" | "calibrate" | null;
  job_elapsed_seconds: number;
  job_stage: string;
  job_step: number;
  job_steps: number;
  job_progress: number;
  job_instruction: string;
  message: string;
  exit_code: number | null;
  log_tail: string[];
  source: string;
};

type ActionResult = { ok: boolean; message: string };

const getStatus = callable<[], Status>("get_status");
const startInstallFix = callable<[], ActionResult>("start_install_fix");
const calibrateGyro = callable<[], ActionResult>("calibrate_gyro");

const StatusLine = ({ status }: { status: Status | null }) => {
  if (!status) return <div style={{ opacity: 0.7 }}>Loading…</div>;
  const state = status.gyro_ready ? "Ready" : "Not ready";
  return (
    <div style={{ width: "100%", fontSize: 13, lineHeight: 1.45 }}>
      <div style={{ display: "flex", justifyContent: "space-between" }}><span style={{ opacity: 0.72 }}>Gyro</span><b>{state}</b></div>
      <div style={{ display: "flex", justifyContent: "space-between" }}><span style={{ opacity: 0.72 }}>IMU</span><span>{status.imu_present ? "bmi323-imu" : "Missing"}</span></div>
      <div style={{ display: "flex", justifyContent: "space-between" }}><span style={{ opacity: 0.72 }}>Sensor feed</span><span>{status.sensor_feed_active ? "Active" : "Stopped"}</span></div>
      <div style={{ display: "flex", justifyContent: "space-between" }}><span style={{ opacity: 0.72 }}>InputPlumber</span><span>{status.inputplumber_active ? "Active" : "Stopped"}</span></div>
      <div style={{ marginTop: 7, opacity: 0.82 }}>{status.message}</div>
    </div>
  );
};

const CalibrationProgress = ({ status }: { status: Status }) => {
  const progress = Math.max(0, Math.min(100, Number(status.job_progress || 0)));
  return (
    <div style={{ width: "100%", padding: "4px 4px 8px" }}>
      <div style={{ display: "flex", justifyContent: "space-between", gap: 12, fontSize: 13 }}>
        <b>{status.job_stage || "Calibrating"}</b>
        <span>{status.job_step > 0 && status.job_steps > 0 ? `Step ${status.job_step}/${status.job_steps}` : ""}</span>
      </div>
      <div style={{ height: 8, marginTop: 9, borderRadius: 8, overflow: "hidden", background: "rgba(255,255,255,0.15)" }}>
        <div style={{ width: `${progress}%`, height: "100%", borderRadius: 8, background: "currentColor", transition: "width 0.4s ease" }} />
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 5, fontSize: 11, opacity: 0.65 }}>
        <span>{status.message}</span><span>{progress}%</span>
      </div>
      {status.job_instruction && (
        <div style={{ marginTop: 10, padding: "8px 10px", borderRadius: 6, background: "rgba(255,255,255,0.08)", fontSize: 12, fontWeight: status.job_step <= 2 ? 700 : 500 }}>
          {status.job_instruction}
        </div>
      )}
    </div>
  );
};

const formatElapsed = (seconds: number) => {
  const total = Math.max(0, Math.floor(Number(seconds || 0)));
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return `${minutes}:${String(secs).padStart(2, "0")}`;
};

const RecoveryTerminal = ({ status }: { status: Status }) => {
  const terminalRef = useRef<HTMLDivElement | null>(null);
  const lines = Array.isArray(status.log_tail) ? status.log_tail : [];

  useEffect(() => {
    const el = terminalRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lines.length, lines.length ? lines[lines.length - 1] : ""]);

  const running = status.job_running && status.job_type === "install";
  const stateText = running
    ? "RUNNING"
    : status.exit_code === 0
      ? "FINISHED · EXIT 0"
      : status.exit_code != null
        ? `STOPPED · EXIT ${status.exit_code}`
        : "IDLE";

  return (
    <div style={{ width: "100%", padding: "2px 3px 8px" }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 8, marginBottom: 7, fontSize: 11 }}>
        <b>{stateText}</b>
        <span style={{ opacity: 0.65 }}>{formatElapsed(status.job_elapsed_seconds)}</span>
      </div>
      <div style={{ fontSize: 11, marginBottom: 7, lineHeight: 1.3 }}>
        <div style={{ opacity: 0.72 }}>Current step</div>
        <b>{status.job_stage || "Waiting"}</b>
      </div>
      <div
        ref={terminalRef}
        style={{
          width: "100%",
          minHeight: 150,
          maxHeight: 280,
          overflowY: "auto",
          overflowX: "auto",
          boxSizing: "border-box",
          padding: "9px 10px",
          borderRadius: 6,
          border: "1px solid rgba(255,255,255,0.16)",
          background: "rgba(0,0,0,0.58)",
          fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
          fontSize: 10,
          lineHeight: 1.38,
          whiteSpace: "pre-wrap",
          overflowWrap: "anywhere",
        }}
      >
        {lines.length ? lines.join("\n") : "Waiting for recovery output…"}
      </div>
      <div style={{ marginTop: 7, fontSize: 10.5, opacity: 0.62, lineHeight: 1.3 }}>
        The recovery continues in the Decky backend even if you close this Quick Access panel. Reopen Odin Gyro to see the latest output.
      </div>
      {!running && status.exit_code != null && (
        <div style={{ marginTop: 8, fontSize: 11, fontWeight: 600 }}>
          {status.exit_code === 0 ? "Recovery completed successfully." : "Recovery failed. The last terminal lines show where it stopped."}
        </div>
      )}
    </div>
  );
};

function Content() {
  const [status, setStatus] = useState<Status | null>(null);
  const [requestBusy, setRequestBusy] = useState(false);
  const refresh = useCallback(async () => { try { setStatus(await getStatus()); } catch (error) { console.error("Odin Gyro status error", error); } }, []);
  useEffect(() => { refresh(); const timer = window.setInterval(refresh, 650); return () => window.clearInterval(timer); }, [refresh]);

  const runAction = async (action: () => Promise<ActionResult>, title: string) => {
    if (requestBusy || status?.job_running) return;
    setRequestBusy(true);
    try { const result = await action(); toaster.toast({ title, body: result.message }); await refresh(); }
    catch (error) { toaster.toast({ title, body: String(error) }); }
    finally { setRequestBusy(false); }
  };

  const busy = requestBusy || Boolean(status?.job_running);
  const installing = status?.job_type === "install";
  const calibrating = status?.job_type === "calibrate";
  const showRecoveryTerminal = Boolean(
    status && (installing || (status.last_job_type === "install" && status.log_tail.length > 0)),
  );

  return <>
    <PanelSection title="Status"><PanelSectionRow><StatusLine status={status} /></PanelSectionRow></PanelSection>
    <PanelSection title="Gyro Fix">
      <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => runAction(startInstallFix, "Odin Gyro")}>{installing ? "Recovery running…" : "Install / Update Gyro Fix"}</ButtonItem></PanelSectionRow>
      <PanelSectionRow><div style={{ fontSize: 12, opacity: 0.66, padding: "0 4px 4px" }}>Builds and installs the gyro fix for the current Armada kernel. Kernel updates can take several minutes to rebuild.</div></PanelSectionRow>
      {showRecoveryTerminal && status ? <PanelSectionRow><RecoveryTerminal status={status} /></PanelSectionRow> : null}
    </PanelSection>
    <PanelSection title="Calibration">
      <PanelSectionRow><ButtonItem layout="below" disabled={busy} onClick={() => runAction(calibrateGyro, "Gyro Calibration")}>{calibrating ? "Calibration in progress…" : "Calibrate Gyro"}</ButtonItem></PanelSectionRow>
      {calibrating && status ? <PanelSectionRow><CalibrationProgress status={status} /></PanelSectionRow> : <PanelSectionRow><div style={{ fontSize: 12, opacity: 0.66, padding: "0 4px 4px" }}>Place Odin on a stable surface and keep it still until the plugin says the zero point has been captured.</div></PanelSectionRow>}
    </PanelSection>
    {status && status.last_job_type === "calibrate" && status.exit_code !== 0 && status.log_tail.length > 0 && !calibrating ? <PanelSection title="Calibration Log"><PanelSectionRow><div style={{ fontSize: 10, opacity: 0.68, maxHeight: 150, overflowY: "auto", whiteSpace: "pre-wrap", wordBreak: "break-word", padding: "0 4px" }}>{status.log_tail.slice(-20).join("\n")}</div></PanelSectionRow></PanelSection> : null}
  </>;
}

export default definePlugin(() => ({
  name: "Odin Gyro",
  titleView: <div className={staticClasses.Title}>Odin Gyro</div>,
  content: <Content />,
  icon: <span style={{ fontWeight: 700 }}>G</span>,
  onDismount() {},
}));
