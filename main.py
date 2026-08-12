import asyncio
import os
import re
import shutil
import subprocess
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
        self.log_tail = deque(maxlen=22)
        self.source_label = 'Bundled recovery script'

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

    def _kernel(self) -> str:
        return os.uname().release

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

    def _module_present(self) -> bool:
        return Path(
            f'/var/lib/odin3-gyro/modules/{self._kernel()}/sns_iio.ko'
        ).exists()

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
                    headers={'User-Agent': 'OdinGyro-Decky/0.1.0'},
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

        if not self._download_latest_from_github(temp):
            if not self.bundled_script.exists():
                raise RuntimeError('Bundled recovery script is missing')
            shutil.copy2(self.bundled_script, temp)
            temp.chmod(0o755)
            self.source_label = 'Bundled recovery script'

        text = temp.read_text(encoding='utf-8')
        version = self._extract_version(temp)

        # Decky starts this backend as root. The standalone recovery script
        # normally refuses EUID 0 because it was designed for interactive SSH.
        # The plugin is explicitly flagged _root, so remove only this guard.
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
        imu = self._imu_present()
        return {
            'kernel': self._kernel(),
            'service_active': service,
            'inputplumber_active': self._service_active('inputplumber.service'),
            'imu_present': imu,
            'module_present': self._module_present(),
            'gyro_ready': service and imu,
            'job_running': install_running or calibration_running,
            'job_type': self.job_type,
            'message': self.job_message,
            'exit_code': self.job_exit_code,
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
        self.job_message = 'Preparing gyro recovery…'
        self.job_exit_code = None
        self.log_tail.clear()

        try:
            script, version = await asyncio.to_thread(self._prepare_runtime_script)
            self.job_message = f'Installing gyro fix v{version}…'
            self.log_tail.append(f'Source: {self.source_label}')
            self.log_tail.append(f'Kernel: {self._kernel()}')

            env = os.environ.copy()
            env['HOME'] = str(self.user_home)
            env['USER'] = self.user_home.name
            env['ODIN3_GYRO_WORKDIR'] = str(self.work_dir)
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
                if line:
                    self.log_tail.append(line[-220:])
                    decky.logger.info(f'[recovery] {line}')

            code = await process.wait()
            self.job_exit_code = code
            if code == 0:
                self.job_message = 'Gyro fix installed successfully.'
            else:
                self.job_message = f'Gyro fix failed (exit {code}).'
        except Exception as exc:
            self.job_exit_code = -1
            self.job_message = f'Install error: {exc}'
            self.log_tail.append(str(exc))
            decky.logger.exception('Gyro recovery failed')
        finally:
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
        self.job_exit_code = None
        self.log_tail.clear()
        self.job_message = 'Keep Odin completely still for 8 seconds…'

        try:
            result = await self._run('systemctl', 'restart', 'odin3-sensors.service')
            if result.returncode != 0:
                raise RuntimeError(result.stdout.strip() or 'Failed to restart sensor service')

            # The sensor service starts adsprpcd first and launches snsfeed
            # later. Wait for the actual feed process, then leave a few seconds
            # for snsfeed's startup zero-bias sampling while the device is still.
            feed_ready = False
            for waited in range(16):
                probe = await self._run('pgrep', '-x', 'snsfeed')
                if probe.returncode == 0:
                    feed_ready = True
                    break
                self.job_message = f'Keep Odin still… starting sensor ({waited + 1}s)'
                await asyncio.sleep(1)

            if not feed_ready:
                raise RuntimeError('snsfeed did not start during calibration')

            for remaining in range(3, 0, -1):
                self.job_message = f'Keep Odin still… calibrating {remaining}s'
                await asyncio.sleep(1)

            result = await self._run('systemctl', 'restart', 'inputplumber.service')
            if result.returncode != 0:
                raise RuntimeError(result.stdout.strip() or 'Failed to restart InputPlumber')

            await asyncio.sleep(1)
            if not self._imu_present():
                raise RuntimeError('bmi323-imu is not available after calibration')

            self.job_message = 'Gyro calibration complete.'
            self.job_exit_code = 0
        except Exception as exc:
            self.job_message = f'Calibration failed: {exc}'
            self.job_exit_code = -1
            self.log_tail.append(str(exc))
            decky.logger.exception('Gyro calibration failed')
        finally:
            self.job_type = None
