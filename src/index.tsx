import {
  ButtonItem,
  PanelSection,
  PanelSectionRow,
  staticClasses,
} from "@decky/ui";
import { callable, definePlugin, toaster } from "@decky/api";
import { useCallback, useEffect, useState } from "react";

type Status = {
  kernel: string;
  service_active: boolean;
  inputplumber_active: boolean;
  imu_present: boolean;
  module_present: boolean;
  gyro_ready: boolean;
  job_running: boolean;
  job_type: "install" | "calibrate" | null;
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
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <span style={{ opacity: 0.72 }}>Gyro</span>
        <b>{state}</b>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <span style={{ opacity: 0.72 }}>Kernel</span>
        <span>{status.kernel}</span>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between" }}>
        <span style={{ opacity: 0.72 }}>IMU</span>
        <span>{status.imu_present ? "bmi323-imu" : "Missing"}</span>
      </div>
      <div style={{ marginTop: 7, opacity: 0.82 }}>{status.message}</div>
    </div>
  );
};

function Content() {
  const [status, setStatus] = useState<Status | null>(null);
  const [requestBusy, setRequestBusy] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setStatus(await getStatus());
    } catch (error) {
      console.error("Odin Gyro status error", error);
    }
  }, []);

  useEffect(() => {
    refresh();
    const timer = window.setInterval(refresh, 1500);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const runAction = async (
    action: () => Promise<ActionResult>,
    title: string,
  ) => {
    if (requestBusy || status?.job_running) return;
    setRequestBusy(true);
    try {
      const result = await action();
      toaster.toast({ title, body: result.message });
      await refresh();
    } catch (error) {
      toaster.toast({ title, body: String(error) });
    } finally {
      setRequestBusy(false);
    }
  };

  const busy = requestBusy || Boolean(status?.job_running);
  const installing = status?.job_type === "install";
  const calibrating = status?.job_type === "calibrate";

  return (
    <>
      <PanelSection title="Status">
        <PanelSectionRow>
          <StatusLine status={status} />
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="Gyro Fix">
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            disabled={busy}
            onClick={() => runAction(startInstallFix, "Odin Gyro")}
          >
            {installing ? "Installing / Updating…" : "Install / Update Gyro Fix"}
          </ButtonItem>
        </PanelSectionRow>
        <PanelSectionRow>
          <div style={{ fontSize: 12, opacity: 0.66, padding: "0 4px 4px" }}>
            Builds and installs the gyro fix for the current Armada kernel.
          </div>
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="Calibration">
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            disabled={busy || !status?.service_active}
            onClick={() => runAction(calibrateGyro, "Gyro Calibration")}
          >
            {calibrating ? "Calibrating… Keep Odin Still" : "Calibrate Gyro"}
          </ButtonItem>
        </PanelSectionRow>
        <PanelSectionRow>
          <div style={{ fontSize: 12, opacity: 0.66, padding: "0 4px 4px" }}>
            Place Odin on a stable surface and keep it still until calibration completes.
          </div>
        </PanelSectionRow>
      </PanelSection>

      {status && status.log_tail.length > 0 && (
        <PanelSection title="Last Output">
          <PanelSectionRow>
            <div
              style={{
                fontSize: 10,
                opacity: 0.62,
                maxHeight: 120,
                overflow: "hidden",
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
                padding: "0 4px",
              }}
            >
              {status.log_tail.slice(-8).join("\n")}
            </div>
          </PanelSectionRow>
        </PanelSection>
      )}
    </>
  );
}

export default definePlugin(() => ({
  name: "Odin Gyro",
  titleView: <div className={staticClasses.Title}>Odin Gyro</div>,
  content: <Content />,
  icon: <span style={{ fontWeight: 700 }}>G</span>,
  onDismount() {},
}));
