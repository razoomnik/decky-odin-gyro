// Odin Gyro v0.1.10 - prebuilt Decky frontend
// External-global shape used by Decky: react -> SP_REACT, @decky/ui -> DFL.

const React = SP_REACT;
const { createElement: h, useCallback, useEffect, useRef, useState } = React;
const { ButtonItem, PanelSection, PanelSectionRow, staticClasses } = DFL;

const manifest = {
  name: "Odin Gyro",
  author: "Kirill Spitsyn",
  flags: ["root"],
  api_version: 1,
};

const internalAPIConnection =
  window.__DECKY_SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED_deckyLoaderAPIInit;
if (!internalAPIConnection) {
  throw new Error("[Odin Gyro]: Decky Loader API is unavailable.");
}

let api;
try {
  api = internalAPIConnection.connect(2, manifest.name);
} catch (_) {
  api = internalAPIConnection.connect(1, manifest.name);
  console.warn("[Odin Gyro] Loader API v2 unavailable; using v1.");
}

const callable = api.callable;
const toaster = api.toaster;
const definePlugin = (fn) => (...args) => fn(...args);
const getStatus = callable("get_status");
const startInstallFix = callable("start_install_fix");
const calibrateGyro = callable("calibrate_gyro");

function row(label, value, bold = false) {
  return h(
    "div",
    { style: { display: "flex", justifyContent: "space-between", gap: 12 } },
    h("span", { style: { opacity: 0.72 } }, label),
    h(bold ? "b" : "span", null, value),
  );
}

function StatusLine({ status }) {
  if (!status) return h("div", { style: { opacity: 0.7 } }, "Loading…");
  return h(
    "div",
    { style: { width: "100%", fontSize: 13, lineHeight: 1.45 } },
    row("Gyro", status.gyro_ready ? "Ready" : "Not ready", true),
    row("IMU", status.imu_present ? "bmi323-imu" : "Missing"),
    row("Sensor feed", status.sensor_feed_active ? "Active" : "Stopped"),
    row("InputPlumber", status.inputplumber_active ? "Active" : "Stopped"),
    h("div", { style: { marginTop: 7, opacity: 0.82 } }, status.message || "Ready"),
  );
}

function CalibrationProgress({ status }) {
  const progress = Math.max(0, Math.min(100, Number(status.job_progress || 0)));
  const stepText =
    status.job_step > 0 && status.job_steps > 0
      ? `Step ${status.job_step}/${status.job_steps}`
      : "";
  const keepStill = status.job_step > 0 && status.job_step <= 2;

  return h(
    "div",
    { style: { width: "100%", padding: "4px 4px 8px" } },
    h(
      "div",
      { style: { display: "flex", justifyContent: "space-between", gap: 12, fontSize: 13 } },
      h("b", null, status.job_stage || "Calibrating"),
      h("span", { style: { opacity: 0.78 } }, stepText),
    ),
    h(
      "div",
      {
        style: {
          height: 8,
          marginTop: 9,
          borderRadius: 8,
          overflow: "hidden",
          background: "rgba(255,255,255,0.15)",
        },
      },
      h("div", {
        style: {
          width: `${progress}%`,
          height: "100%",
          borderRadius: 8,
          background: "currentColor",
          transition: "width 0.4s ease",
        },
      }),
    ),
    h(
      "div",
      {
        style: {
          display: "flex",
          justifyContent: "space-between",
          gap: 10,
          marginTop: 5,
          fontSize: 11,
          opacity: 0.67,
        },
      },
      h("span", null, status.message || ""),
      h("span", null, `${progress}%`),
    ),
    status.job_instruction
      ? h(
          "div",
          {
            style: {
              marginTop: 10,
              padding: "8px 10px",
              borderRadius: 6,
              background: keepStill
                ? "rgba(255,255,255,0.12)"
                : "rgba(255,255,255,0.08)",
              fontSize: 12,
              fontWeight: keepStill ? 700 : 500,
              lineHeight: 1.35,
            },
          },
          status.job_instruction,
        )
      : null,
  );
}

function formatElapsed(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds || 0)));
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

function RecoveryTerminal({ status }) {
  const terminalRef = useRef(null);
  const lines = Array.isArray(status.log_tail) ? status.log_tail : [];
  const lastLine = lines.length ? lines[lines.length - 1] : "";

  useEffect(() => {
    const el = terminalRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lines.length, lastLine]);

  const running = status.job_running && status.job_type === "install";
  const stateText = running
    ? "RUNNING"
    : status.exit_code === 0
      ? "FINISHED · EXIT 0"
      : status.exit_code != null
        ? `STOPPED · EXIT ${status.exit_code}`
        : "IDLE";

  return h(
    "div",
    { style: { width: "100%", padding: "2px 3px 8px" } },
    h(
      "div",
      {
        style: {
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          gap: 8,
          marginBottom: 7,
          fontSize: 11,
        },
      },
      h("b", null, stateText),
      h("span", { style: { opacity: 0.65 } }, formatElapsed(status.job_elapsed_seconds)),
    ),
    h(
      "div",
      { style: { fontSize: 11, marginBottom: 7, lineHeight: 1.3 } },
      h("div", { style: { opacity: 0.72 } }, "Current step"),
      h("b", null, status.job_stage || "Waiting"),
    ),
    h(
      "div",
      {
        ref: terminalRef,
        style: {
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
        },
      },
      lines.length ? lines.join("\n") : "Waiting for recovery output…",
    ),
    h(
      "div",
      { style: { marginTop: 7, fontSize: 10.5, opacity: 0.62, lineHeight: 1.3 } },
      "The recovery continues in the Decky backend even if you close this Quick Access panel. Reopen Odin Gyro to see the latest output.",
    ),
    !running && status.exit_code != null
      ? h(
          "div",
          { style: { marginTop: 8, fontSize: 11, fontWeight: 600 } },
          status.exit_code === 0
            ? "Recovery completed successfully."
            : "Recovery failed. The last terminal lines show where it stopped.",
        )
      : null,
  );
}

function Content() {
  const [status, setStatus] = useState(null);
  const [requestBusy, setRequestBusy] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setStatus(await getStatus());
    } catch (error) {
      console.error("[Odin Gyro] status error", error);
    }
  }, []);

  useEffect(() => {
    refresh();
    const timer = window.setInterval(refresh, 650);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const runAction = async (action, title) => {
    if (requestBusy || (status && status.job_running)) return;
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

  const busy = requestBusy || Boolean(status && status.job_running);
  const installing = status && status.job_type === "install";
  const calibrating = status && status.job_type === "calibrate";
  const showRecoveryTerminal = Boolean(
    status &&
      (installing ||
        (status.last_job_type === "install" &&
          Array.isArray(status.log_tail) &&
          status.log_tail.length > 0)),
  );

  const children = [
    h(
      PanelSection,
      { title: "Status", key: "status" },
      h(PanelSectionRow, null, h(StatusLine, { status })),
    ),
    h(
      PanelSection,
      { title: "Gyro Fix", key: "fix" },
      h(
        PanelSectionRow,
        null,
        h(
          ButtonItem,
          {
            layout: "below",
            disabled: busy,
            onClick: () => runAction(startInstallFix, "Odin Gyro"),
          },
          installing ? "Recovery running…" : "Install / Update Gyro Fix",
        ),
      ),
      h(
        PanelSectionRow,
        null,
        h(
          "div",
          { style: { fontSize: 12, opacity: 0.66, padding: "0 4px 4px" } },
          "Builds and installs the gyro fix for the current Armada kernel. Kernel updates can take several minutes to rebuild.",
        ),
      ),
      showRecoveryTerminal && status
        ? h(PanelSectionRow, null, h(RecoveryTerminal, { status }))
        : null,
    ),
    h(
      PanelSection,
      { title: "Calibration", key: "cal" },
      h(
        PanelSectionRow,
        null,
        h(
          ButtonItem,
          {
            layout: "below",
            disabled: busy,
            onClick: () => runAction(calibrateGyro, "Gyro Calibration"),
          },
          calibrating ? "Calibration in progress…" : "Calibrate Gyro",
        ),
      ),
      calibrating && status
        ? h(PanelSectionRow, null, h(CalibrationProgress, { status }))
        : h(
            PanelSectionRow,
            null,
            h(
              "div",
              { style: { fontSize: 12, opacity: 0.66, padding: "0 4px 4px" } },
              "Place Odin on a stable surface and keep it still until the plugin says the zero point has been captured.",
            ),
          ),
    ),
  ];

  if (
    status &&
    status.last_job_type === "calibrate" &&
    status.exit_code !== 0 &&
    Array.isArray(status.log_tail) &&
    status.log_tail.length > 0 &&
    !calibrating
  ) {
    children.push(
      h(
        PanelSection,
        { title: "Calibration Log", key: "cal-log" },
        h(
          PanelSectionRow,
          null,
          h(
            "div",
            {
              style: {
                fontSize: 10,
                opacity: 0.68,
                maxHeight: 150,
                overflowY: "auto",
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
                padding: "0 4px",
              },
            },
            status.log_tail.slice(-20).join("\n"),
          ),
        ),
      ),
    );
  }

  return h(React.Fragment, null, ...children);
}

function GyroIcon() {
  return h(
    "div",
    {
      style: {
        width: 18,
        height: 18,
        border: "2px solid currentColor",
        borderRadius: "50%",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        fontSize: 10,
        fontWeight: 700,
      },
    },
    "G",
  );
}

const plugin = definePlugin(() => ({
  name: "Odin Gyro",
  titleView: h("div", { className: staticClasses && staticClasses.Title }, "Odin Gyro"),
  content: h(Content),
  icon: h(GyroIcon),
  onDismount() {},
}));

export default plugin;
