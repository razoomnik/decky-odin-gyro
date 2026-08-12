// Odin Gyro v0.1.0 - prebuilt Decky frontend
// Built in the same external-global shape used by @decky/rollup:
// react -> SP_REACT, @decky/ui -> DFL.

const React = SP_REACT;
const {
  createElement: h,
  useCallback,
  useEffect,
  useState,
} = React;

const {
  ButtonItem,
  PanelSection,
  PanelSectionRow,
  staticClasses,
} = DFL;

const manifest = {
  name: "Odin Gyro",
  author: "Kirill Spitsyn",
  flags: ["_root"],
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
    {
      style: {
        display: "flex",
        justifyContent: "space-between",
        gap: 12,
      },
    },
    h("span", { style: { opacity: 0.72 } }, label),
    h(bold ? "b" : "span", null, value),
  );
}

function StatusLine({ status }) {
  if (!status) {
    return h("div", { style: { opacity: 0.7 } }, "Loading…");
  }

  return h(
    "div",
    { style: { width: "100%", fontSize: 13, lineHeight: 1.45 } },
    row("Gyro", status.gyro_ready ? "Ready" : "Not ready", true),
    row("Kernel", status.kernel || "—"),
    row("IMU", status.imu_present ? "bmi323-imu" : "Missing"),
    h(
      "div",
      { style: { marginTop: 7, opacity: 0.82 } },
      status.message || "Ready",
    ),
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
    const timer = window.setInterval(refresh, 1500);
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

  const children = [
    h(
      PanelSection,
      { title: "Status", key: "status" },
      h(
        PanelSectionRow,
        null,
        h(StatusLine, { status }),
      ),
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
          installing ? "Installing / Updating…" : "Install / Update Gyro Fix",
        ),
      ),
      h(
        PanelSectionRow,
        null,
        h(
          "div",
          { style: { fontSize: 12, opacity: 0.66, padding: "0 4px 4px" } },
          "Builds and installs the gyro fix for the current Armada kernel.",
        ),
      ),
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
            disabled: busy || !(status && status.service_active),
            onClick: () => runAction(calibrateGyro, "Gyro Calibration"),
          },
          calibrating ? "Calibrating… Keep Odin Still" : "Calibrate Gyro",
        ),
      ),
      h(
        PanelSectionRow,
        null,
        h(
          "div",
          { style: { fontSize: 12, opacity: 0.66, padding: "0 4px 4px" } },
          "Place Odin on a stable surface and keep it still until calibration completes.",
        ),
      ),
    ),
  ];

  if (status && Array.isArray(status.log_tail) && status.log_tail.length > 0) {
    children.push(
      h(
        PanelSection,
        { title: "Last Output", key: "log" },
        h(
          PanelSectionRow,
          null,
          h(
            "div",
            {
              style: {
                fontSize: 10,
                opacity: 0.62,
                maxHeight: 120,
                overflow: "hidden",
                whiteSpace: "pre-wrap",
                wordBreak: "break-word",
                padding: "0 4px",
              },
            },
            status.log_tail.slice(-8).join("\n"),
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
  titleView: h(
    "div",
    { className: staticClasses && staticClasses.Title },
    "Odin Gyro",
  ),
  content: h(Content),
  icon: h(GyroIcon),
  onDismount() {},
}));

export default plugin;
