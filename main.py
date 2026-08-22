import asyncio
import os
import re
import shutil
import subprocess
import time
import urllib.request
from collections import deque
from pathlib import Path
from typing import Any

import decky


class Plugin:
    def __init__(self):
        self.plugin_dir = Path(__file__).resolve().parent
        self.user_home = Path(decky.DECKY_USER_HOME)
        self.runtime_dir = Path('/var/lib/odin-gyro-decky')
        self.work_dir = Path('/var/lib/odin3-gyro-recovery')
        self.bundled_script = self.plugin_dir / 'scripts' / 'odin3-gyro-recovery.sh'
        self.runtime_script = self.runtime_dir / 'odin3-gyro-recovery.sh'
        self.install_task = None
        self.calibration_task = None
        self.job_type = None
        self.job_message = 'Ready'
        self.job_exit_code = None
        self.job_stage = ''
        self.job_step = 0
        self.job_steps = 0
        self.job_progress = 0
        self.job_instruction = ''
        self.log_tail = deque(maxlen=180)
        self.source_label = 'Bundled recovery script'
        self.last_job_type = None
        self.job_started_at = None
        self.last_job_elapsed_seconds = 0

    async def _main(self):
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        decky.logger.info('Odin Gyro plugin loaded')

    async def _unload(self):
        decky.logger.info('Odin Gyro plugin unloaded')

    async def _run(self, *args: str, check: bool = False) -> subprocess.CompletedProcess:
        def execute():
            env = os.environ.copy()
            env['LD_LIBRARY_PATH'] = ''
            return subprocess.run(
                args,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=check,
                env=env,
            )
        return await asyncio.to_thread(execute)

    def _append_log(self, line: str) -> None:
        # Keep a terminal-like rolling buffer for the Decky UI. Strip ANSI
        # escape sequences/control characters that do not render well in QAM.
        clean = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(line))
        clean = clean.replace('\r', '')
        clean = ''.join(ch for ch in clean if ch == '\t' or ord(ch) >= 32)
        if clean:
            self.log_tail.append(clean[-1000:])

    def _elapsed_seconds(self) -> int:
        if self.job_started_at is not None:
            return max(0, int(time.monotonic() - self.job_started_at))
        return self.last_job_elapsed_seconds

    def _imu_present(self) -> bool:
        base = Path('/sys/bus/iio/devices')
        if not base.exists():
            return False
        for device in base.glob('iio:device*'):
            try:
                if (device / 'name').read_text().strip() == 'bmi323-imu':
                    return True
            except OSError:
                pass
        return False

    def _service_active(self, name: str) -> bool:
        result = subprocess.run(
            ['systemctl', 'is-active', '--quiet', name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0

    def _process_active(self, name: str) -> bool:
        result = subprocess.run(
            ['pgrep', '-x', name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0

    def _inputplumber_ready(self) -> bool:
        return (
            self._service_active('inputplumber.service')
            or self._process_active('inputplumber')
        )

    def _module_present(self) -> bool:
        module_root = Path('/var/lib/odin3-gyro/modules')
        try:
            return any(module_root.glob('*/sns_iio.ko'))
        except OSError:
            return False

    def _extract_version(self, path: Path) -> str:
        try:
            text = path.read_text(encoding='utf-8', errors='replace')
        except OSError:
            return 'unknown'
        match = re.search(r'^SCRIPT_VERSION="([^"]+)"', text, re.MULTILINE)
        return match.group(1) if match else 'unknown'

    def _github_raw_url_from_clone(self) -> str | None:
        repo = self.user_home / 'armada-scripts'
        if not (repo / '.git').exists():
            return None

        result = subprocess.run(
            ['git', '-c', f'safe.directory={repo}', '-C', str(repo),
             'config', '--get', 'remote.origin.url'],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            return None

        remote = result.stdout.strip()
        patterns = [
            r'https://github\.com/([^/]+)/([^/]+?)(?:\.git)?$',
            r'git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$',
            r'ssh://git@github\.com/([^/]+)/([^/]+?)(?:\.git)?$',
        ]
        for pattern in patterns:
            match = re.match(pattern, remote)
            if match:
                owner, name = match.groups()
                return (
                    f'https://raw.githubusercontent.com/{owner}/{name}/main/'
                    'scripts/odin3-gyro-recovery.sh'
                )
        return None

    def _download_with_gh(self, destination: Path) -> bool:
        candidates = [
            self.user_home / '.local' / 'bin' / 'gh',
            Path('/usr/bin/gh'),
        ]
        gh = next((path for path in candidates if path.exists()), None)
        if gh is None:
            return False

        env = os.environ.copy()
        env['HOME'] = str(self.user_home)
        env['LD_LIBRARY_PATH'] = ''

        try:
            repo = subprocess.run(
                [str(gh), 'repo', 'view', 'armada-scripts',
                 '--json', 'nameWithOwner', '--jq', '.nameWithOwner'],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                timeout=20,
            )
            if repo.returncode != 0 or '/' not in repo.stdout.strip():
                return False

            name_with_owner = repo.stdout.strip()
            result = subprocess.run(
                [str(gh), 'api',
                 '-H', 'Accept: application/vnd.github.raw+json',
                 f'repos/{name_with_owner}/contents/scripts/odin3-gyro-recovery.sh'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                timeout=60,
            )
            if result.returncode != 0:
                return False
            data = result.stdout
            if b'SCRIPT_VERSION=' not in data or len(data) < 10000:
                return False
            destination.write_bytes(data)
            destination.chmod(0o755)
            self.source_label = f'GitHub: {name_with_owner}'
            return True
        except Exception as exc:
            decky.logger.warning(f'GitHub CLI source lookup failed: {exc}')
            return False

    def _download_latest_from_github(self, destination: Path) -> bool:
        if self._download_with_gh(destination):
            return True

        url = self._github_raw_url_from_clone()
        if not url:
            return False

        for attempt in range(1, 4):
            try:
                request = urllib.request.Request(
                    url,
                    headers={'User-Agent': 'OdinGyro-Decky/0.1.14'},
                )
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = response.read()
                if b'SCRIPT_VERSION=' not in data or len(data) < 10000:
                    raise RuntimeError('Downloaded recovery script is invalid')
                destination.write_bytes(data)
                destination.chmod(0o755)
                self.source_label = 'GitHub: armada-scripts'
                return True
            except Exception as exc:
                decky.logger.warning(
                    f'GitHub recovery download attempt {attempt} failed: {exc}'
                )
        return False

    def _prepare_runtime_script(self) -> tuple[Path, str]:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        temp = self.runtime_dir / 'recovery.download'
        temp.unlink(missing_ok=True)

        if not self.bundled_script.exists():
            raise RuntimeError('Bundled recovery script is missing')

        bundled_version = self._extract_version(self.bundled_script)
        downloaded = self._download_latest_from_github(temp)
        if downloaded:
            downloaded_version = self._extract_version(temp)
            def version_tuple(value: str):
                nums = re.findall(r'\d+', value)
                return tuple(int(x) for x in nums[:3]) if nums else (0,)
            if version_tuple(downloaded_version) < version_tuple(bundled_version):
                shutil.copy2(self.bundled_script, temp)
                temp.chmod(0o755)
                self.source_label = (
                    f'Bundled recovery v{bundled_version} '
                    f'(GitHub v{downloaded_version} is older)'
                )
        else:
            shutil.copy2(self.bundled_script, temp)
            temp.chmod(0o755)
            self.source_label = f'Bundled recovery v{bundled_version}'

        text = temp.read_text(encoding='utf-8')
        version = self._extract_version(temp)

        # Decky starts this backend as root. The standalone recovery script
        # normally refuses EUID 0 because it was designed for interactive SSH.
        # The plugin is explicitly flagged root, so remove only this guard.
        root_guard = '''if [[ $EUID -eq 0 ]]; then\n    die "Run this script as the regular Armada user, without sudo."\nfi\n'''
        if root_guard in text:
            text = text.replace(
                root_guard,
                'if [[ $EUID -eq 0 ]]; then\n'
                '    note "Running under Decky root backend."\n'
                'fi\n',
                1,
            )

        self.runtime_script.write_text(text, encoding='utf-8')
        self.runtime_script.chmod(0o755)
        temp.unlink(missing_ok=True)
        return self.runtime_script, version

    async def get_status(self) -> dict[str, Any]:
        install_running = bool(self.install_task and not self.install_task.done())
        calibration_running = bool(
            self.calibration_task and not self.calibration_task.done()
        )
        service = self._service_active('odin3-sensors.service')
        inputplumber = self._inputplumber_ready()
        imu = self._imu_present()
        sensor_feed = self._process_active('snsfeed')
        adsprpcd = self._process_active('adsprpcd')
        return {
            'service_active': service,
            'inputplumber_active': inputplumber,
            'imu_present': imu,
            'sensor_feed_active': sensor_feed,
            'adsprpcd_active': adsprpcd,
            'module_present': self._module_present(),
            'gyro_ready': imu and sensor_feed and inputplumber,
            'job_running': install_running or calibration_running,
            'job_type': self.job_type,
            'last_job_type': self.last_job_type,
            'job_elapsed_seconds': self._elapsed_seconds(),
            'message': self.job_message,
            'exit_code': self.job_exit_code,
            'job_stage': self.job_stage,
            'job_step': self.job_step,
            'job_steps': self.job_steps,
            'job_progress': self.job_progress,
            'job_instruction': self.job_instruction,
            'log_tail': list(self.log_tail),
            'source': self.source_label,
        }

    async def start_install_fix(self) -> dict[str, Any]:
        if self.install_task and not self.install_task.done():
            return {'ok': False, 'message': 'Installation is already running.'}
        if self.calibration_task and not self.calibration_task.done():
            return {'ok': False, 'message': 'Calibration is running.'}

        self.install_task = asyncio.create_task(self._install_worker())
        return {'ok': True, 'message': 'Installation started.'}

    async def _install_worker(self):
        self.job_type = 'install'
        self.last_job_type = 'install'
        self.job_started_at = time.monotonic()
        self.last_job_elapsed_seconds = 0
        self.job_message = 'Preparing gyro recovery…'
        self.job_exit_code = None
        self.job_stage = 'Preparing recovery'
        self.job_step = 0
        self.job_steps = 0
        self.job_progress = 0
        self.job_instruction = 'Recovery runs in the background. Keep this panel open to watch the live terminal.'
        self.log_tail.clear()

        try:
            script, version = await asyncio.to_thread(self._prepare_runtime_script)
            self.job_message = f'Installing gyro fix v{version}…'
            self._append_log('Odin Gyro recovery terminal')
            self._append_log(f'Source: {self.source_label}')
            self._append_log(f'$ /bin/bash {script}')
            self._append_log('')

            env = os.environ.copy()
            env['HOME'] = str(self.user_home)
            env['USER'] = self.user_home.name
            env['ODIN3_GYRO_WORKDIR'] = str(self.work_dir)
            # Recovery resolves the target exclusively from the exact current
            # Armada deployment and the module it builds. Do not pass a kernel
            # release from the Decky backend environment.
            env.pop('ODIN3_RUNNING_KERNEL', None)
            env['TERM'] = 'dumb'
            env['LD_LIBRARY_PATH'] = ''

            process = await asyncio.create_subprocess_exec(
                '/bin/bash',
                str(script),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
            )

            assert process.stdout is not None
            while True:
                raw = await process.stdout.readline()
                if not raw:
                    break
                line = raw.decode('utf-8', errors='replace').rstrip()
                if not line:
                    continue

                self._append_log(line)
                decky.logger.info(f'[recovery] {line}')

                # Recovery scripts use "==>" for their major stages. Surface
                # that line above the terminal so the current operation is clear.
                clean_stage = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line).strip()
                if clean_stage.startswith('==>'):
                    stage = clean_stage[3:].strip()
                    if stage:
                        self.job_stage = stage
                        self.job_message = stage

            code = await process.wait()
            self.job_exit_code = code
            if code == 0:
                self.job_stage = 'Recovery complete'
                self.job_progress = 100
                self.job_instruction = 'Recovery finished successfully. Reboot if the recovery output requests it.'
                self.job_message = 'Gyro fix installed successfully.'
                self._append_log('')
                self._append_log('--- recovery finished successfully (exit 0) ---')
            else:
                self.job_stage = 'Recovery failed'
                self.job_instruction = 'Recovery stopped with an error. The terminal above shows the failing step.'
                self.job_message = f'Gyro fix failed (exit {code}).'
                self._append_log('')
                self._append_log(f'--- recovery failed (exit {code}) ---')
        except Exception as exc:
            self.job_exit_code = -1
            self.job_stage = 'Recovery failed'
            self.job_instruction = 'Recovery stopped with an error. The terminal above shows the failing step.'
            self.job_message = f'Install error: {exc}'
            self._append_log(f'ERROR: {exc}')
            decky.logger.exception('Gyro recovery failed')
        finally:
            if self.job_started_at is not None:
                self.last_job_elapsed_seconds = max(0, int(time.monotonic() - self.job_started_at))
            self.job_started_at = None
            self.job_type = None

    async def calibrate_gyro(self) -> dict[str, Any]:
        if self.install_task and not self.install_task.done():
            return {'ok': False, 'message': 'Wait for installation to finish.'}
        if self.calibration_task and not self.calibration_task.done():
            return {'ok': False, 'message': 'Calibration is already running.'}

        self.calibration_task = asyncio.create_task(self._calibration_worker())
        return {'ok': True, 'message': 'Calibration started. Keep Odin still.'}

    async def _calibration_worker(self):
        self.job_type = 'calibrate'
        self.last_job_type = 'calibrate'
        self.job_started_at = time.monotonic()
        self.last_job_elapsed_seconds = 0
        self.job_exit_code = None
        self.job_stage = 'Starting gyro sensor'
        self.job_step = 1
        self.job_steps = 4
        self.job_progress = 5
        self.job_instruction = 'KEEP ODIN STILL on a stable surface.'
        self.log_tail.clear()
        self.job_message = 'Restarting the Odin 3 sensor stack…'

        try:
            result = await self._run('systemctl', 'restart', 'odin3-sensors.service')
            if result.returncode != 0:
                raise RuntimeError(result.stdout.strip() or 'Failed to restart sensor service')

            # The sensor service starts adsprpcd first and launches snsfeed
            # later. Wait for the actual feed process before zero-bias sampling.
            feed_ready = False
            for waited in range(16):
                probe = await self._run('pgrep', '-x', 'snsfeed')
                if probe.returncode == 0:
                    feed_ready = True
                    break
                self.job_progress = min(38, 8 + waited * 2)
                self.job_message = f'Waiting for sensor feed… {waited + 1}s'
                await asyncio.sleep(1)

            if not feed_ready:
                raise RuntimeError('snsfeed did not start during calibration')

            self.job_stage = 'Zero-bias calibration'
            self.job_step = 2
            self.job_progress = 42
            self.job_instruction = 'KEEP ODIN COMPLETELY STILL.'

            for remaining in range(3, 0, -1):
                self.job_progress = 42 + (3 - remaining) * 8
                self.job_message = f'Capturing gyro zero point… {remaining}s'
                await asyncio.sleep(1)

            self.job_progress = 66
            self.job_stage = 'Restarting InputPlumber'
            self.job_step = 3
            self.job_instruction = 'Zero point captured. You may move Odin now.'
            self.job_message = 'Applying calibration to the Steam input path…'

            result = await self._run('systemctl', 'restart', 'inputplumber.service')
            if result.returncode != 0:
                self._append_log(
                    'InputPlumber restart returned: ' +
                    (result.stdout.strip() or f'exit {result.returncode}')[-180:]
                )

            # Recreating the IIO device can make InputPlumber take longer than
            # a normal restart. Check the real daemon as well as systemd.
            self.job_stage = 'Verifying gyro path'
            self.job_step = 4
            self.job_progress = 74
            self.job_instruction = 'Finishing setup…'
            ready = False
            for waited in range(30):
                imu = self._imu_present()
                feed = self._process_active('snsfeed')
                inputplumber = self._inputplumber_ready()
                if imu and feed and inputplumber:
                    ready = True
                    break
                self.job_progress = min(94, 74 + int((waited + 1) * 20 / 30))
                parts = []
                if not imu:
                    parts.append('IMU')
                if not feed:
                    parts.append('sensor feed')
                if not inputplumber:
                    parts.append('InputPlumber')
                waiting_for = ', '.join(parts) if parts else 'gyro path'
                self.job_message = f'Waiting for {waiting_for}… {waited + 1}s'
                await asyncio.sleep(1)

            # If restart left InputPlumber inactive, recover it explicitly.
            if not ready and not self._inputplumber_ready():
                self.job_stage = 'Recovering InputPlumber'
                self.job_progress = 94
                self.job_instruction = 'Finishing setup…'
                self.job_message = 'InputPlumber did not reconnect; starting it again…'
                await self._run('systemctl', 'reset-failed', 'inputplumber.service')
                start_result = await self._run(
                    'systemctl', 'start', 'inputplumber.service'
                )
                if start_result.returncode != 0:
                    self._append_log(
                        'InputPlumber start returned: ' +
                        (start_result.stdout.strip() or
                         f'exit {start_result.returncode}')[-180:]
                    )

                for waited in range(20):
                    if (
                        self._imu_present()
                        and self._process_active('snsfeed')
                        and self._inputplumber_ready()
                    ):
                        ready = True
                        break
                    self.job_progress = min(99, 94 + int((waited + 1) * 5 / 20))
                    self.job_message = f'Reconnecting InputPlumber… {waited + 1}s'
                    await asyncio.sleep(1)

            if not ready:
                missing = []
                if not self._imu_present():
                    missing.append('bmi323-imu')
                if not self._process_active('snsfeed'):
                    missing.append('snsfeed')
                if not self._inputplumber_ready():
                    missing.append('InputPlumber')

                status = await self._run(
                    'systemctl', 'status', 'inputplumber.service',
                    '--no-pager', '--full'
                )
                if status.stdout.strip():
                    for line in status.stdout.strip().splitlines()[-8:]:
                        self._append_log(line)

                journal = await self._run(
                    'journalctl', '-u', 'inputplumber.service',
                    '-n', '12', '--no-pager'
                )
                if journal.stdout.strip():
                    for line in journal.stdout.strip().splitlines()[-8:]:
                        self._append_log(line)

                raise RuntimeError('gyro path not ready: ' + ', '.join(missing))

            self.job_progress = 100
            self.job_stage = 'Calibration complete'
            self.job_instruction = 'Gyro is ready.'
            self.job_message = 'Gyro calibration complete. Gyro is ready.'
            self.job_exit_code = 0
        except Exception as exc:
            self.job_stage = 'Calibration failed'
            self.job_instruction = 'See Last Output for details.'
            self.job_message = f'Calibration failed: {exc}'
            self.job_exit_code = -1
            self._append_log(str(exc))
            decky.logger.exception('Gyro calibration failed')
        finally:
            if self.job_started_at is not None:
                self.last_job_elapsed_seconds = max(0, int(time.monotonic() - self.job_started_at))
            self.job_started_at = None
            self.job_type = None
