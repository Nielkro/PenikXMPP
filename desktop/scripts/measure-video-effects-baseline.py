#!/usr/bin/env python3
"""Measure Direct/Off/basic-effect CPU, RSS and frame gates for libwebrtc.

The native harness drives the real external DinoX WebRTC worker.  This script
samples the complete process tree so the report cannot accidentally describe
only the tiny launcher process while omitting the worker that owns video.
"""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import datetime as dt
import json
import math
import os
import pathlib
import platform
import queue
import statistics
import struct
import subprocess
import sys
import threading
import time
from typing import Iterable


RESULT_PREFIX = "DINOX_VIDEO_EFFECT_BASELINE_RESULT "
MEASURE_PREFIX = "DINOX_VIDEO_EFFECT_BASELINE_MEASURE "
READY_PREFIX = "DINOX_VIDEO_EFFECT_BASELINE_READY "
MIB = 1024 * 1024
READER_EOF = object()


class BaselineError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class ProcessInfo:
    pid: int
    ppid: int
    name: str
    cpu_seconds: float
    rss_bytes: int


@dataclasses.dataclass(frozen=True)
class ProcessSnapshot:
    total_cpu_seconds: float
    total_rss_bytes: int
    worker_cpu_seconds: float
    worker_rss_bytes: int
    process_count: int
    worker_count: int


class ProcessTreeSampler:
    def snapshot(self, root_pid: int) -> ProcessSnapshot:
        processes = self._all_processes()
        descendants = {root_pid}
        changed = True
        while changed:
            changed = False
            for process in processes.values():
                if process.ppid in descendants and process.pid not in descendants:
                    descendants.add(process.pid)
                    changed = True

        selected = [processes[pid] for pid in descendants if pid in processes]
        workers = [process for process in selected if self._is_worker(process.name)]
        return ProcessSnapshot(
            total_cpu_seconds=sum(process.cpu_seconds for process in selected),
            total_rss_bytes=sum(process.rss_bytes for process in selected),
            worker_cpu_seconds=sum(process.cpu_seconds for process in workers),
            worker_rss_bytes=sum(process.rss_bytes for process in workers),
            process_count=len(selected),
            worker_count=len(workers),
        )

    @staticmethod
    def _is_worker(name: str) -> bool:
        lowered = pathlib.Path(name).name.lower()
        return lowered.startswith("dinox-webrtc-worker") or lowered.startswith("dinox-webrtc-wo")

    def _all_processes(self) -> dict[int, ProcessInfo]:
        if os.name == "nt":
            return self._windows_processes()
        if sys.platform.startswith("linux"):
            return self._linux_processes()
        raise BaselineError(f"unsupported process sampler platform: {sys.platform}")

    @staticmethod
    def _linux_processes() -> dict[int, ProcessInfo]:
        clock_ticks = os.sysconf("SC_CLK_TCK")
        page_size = os.sysconf("SC_PAGE_SIZE")
        processes: dict[int, ProcessInfo] = {}
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                raw = (entry / "stat").read_text(encoding="utf-8", errors="replace")
                closing = raw.rfind(")")
                if closing < 0:
                    continue
                fields = raw[closing + 2 :].split()
                pid = int(entry.name)
                ppid = int(fields[1])
                cpu_seconds = (int(fields[11]) + int(fields[12])) / clock_ticks
                rss_bytes = max(0, int(fields[21])) * page_size
                try:
                    name = pathlib.Path(os.readlink(entry / "exe")).name
                except OSError:
                    name = raw[raw.find("(") + 1 : closing]
                processes[pid] = ProcessInfo(pid, ppid, name, cpu_seconds, rss_bytes)
            except (OSError, ValueError, IndexError):
                continue
        return processes

    @staticmethod
    def _windows_processes() -> dict[int, ProcessInfo]:
        from ctypes import wintypes

        class ProcessEntry32W(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        class ProcessMemoryCounters(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W)]
        kernel32.Process32FirstW.restype = wintypes.BOOL
        kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W)]
        kernel32.Process32NextW.restype = wintypes.BOOL
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.GetProcessTimes.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
            ctypes.POINTER(wintypes.FILETIME),
        ]
        kernel32.GetProcessTimes.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        psapi.GetProcessMemoryInfo.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(ProcessMemoryCounters),
            wintypes.DWORD,
        ]
        psapi.GetProcessMemoryInfo.restype = wintypes.BOOL

        snapshot = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
        if snapshot == wintypes.HANDLE(-1).value:
            raise BaselineError(f"CreateToolhelp32Snapshot failed: {ctypes.get_last_error()}")
        entries: list[tuple[int, int, str]] = []
        try:
            entry = ProcessEntry32W()
            entry.dwSize = ctypes.sizeof(entry)
            present = bool(kernel32.Process32FirstW(snapshot, ctypes.byref(entry)))
            while present:
                entries.append(
                    (int(entry.th32ProcessID), int(entry.th32ParentProcessID), entry.szExeFile)
                )
                present = bool(kernel32.Process32NextW(snapshot, ctypes.byref(entry)))
        finally:
            kernel32.CloseHandle(snapshot)

        def filetime_value(value: wintypes.FILETIME) -> int:
            return (int(value.dwHighDateTime) << 32) | int(value.dwLowDateTime)

        processes: dict[int, ProcessInfo] = {}
        for pid, ppid, name in entries:
            handle = kernel32.OpenProcess(0x1000 | 0x0400 | 0x0010, False, pid)
            if not handle:
                continue
            try:
                creation = wintypes.FILETIME()
                exit_time = wintypes.FILETIME()
                kernel = wintypes.FILETIME()
                user = wintypes.FILETIME()
                if not kernel32.GetProcessTimes(
                    handle,
                    ctypes.byref(creation),
                    ctypes.byref(exit_time),
                    ctypes.byref(kernel),
                    ctypes.byref(user),
                ):
                    continue
                memory = ProcessMemoryCounters()
                memory.cb = ctypes.sizeof(memory)
                rss = 0
                if psapi.GetProcessMemoryInfo(handle, ctypes.byref(memory), memory.cb):
                    rss = int(memory.WorkingSetSize)
                cpu = (filetime_value(kernel) + filetime_value(user)) / 10_000_000.0
                processes[pid] = ProcessInfo(pid, ppid, name, cpu, rss)
            finally:
                kernel32.CloseHandle(handle)
        return processes


def reader_thread(stream: Iterable[str], output: queue.Queue[object]) -> None:
    try:
        for line in stream:
            output.put(line.rstrip("\r\n"))
    finally:
        output.put(READER_EOF)


def resolve_binary(build_dir: pathlib.Path, explicit: pathlib.Path | None) -> pathlib.Path:
    if explicit is not None:
        candidates = [explicit]
    else:
        suffix = ".exe" if os.name == "nt" else ""
        name = f"google-webrtc-video-effects-baseline{suffix}"
        candidates = [build_dir / name, build_dir / "google-webrtc" / name]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise BaselineError("baseline harness not found; build google-webrtc-video-effects-baseline")


def resolve_worker(
    build_dir: pathlib.Path,
    runtime_root: pathlib.Path | None,
    explicit: pathlib.Path | None,
) -> pathlib.Path:
    if explicit is not None:
        candidates = [explicit]
    elif runtime_root is not None:
        candidates = [
            runtime_root / ("bin/dinox-webrtc-worker.exe" if os.name == "nt" else "lib/dinox-webrtc-worker")
        ]
    else:
        suffix = ".exe" if os.name == "nt" else ""
        candidates = [build_dir / "google-webrtc" / f"dinox-webrtc-worker{suffix}"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise BaselineError("external dinox-webrtc-worker not found")


def runtime_environment(
    binary: pathlib.Path,
    worker: pathlib.Path,
    runtime_root: pathlib.Path | None,
) -> dict[str, str]:
    environment = os.environ.copy()
    environment["DINOX_WEBRTC_WORKER_PATH"] = str(worker)
    if os.name == "nt":
        library_dir = runtime_root / "bin" if runtime_root is not None else binary.parent
        environment["PATH"] = str(library_dir) + os.pathsep + environment.get("PATH", "")
    else:
        library_dir = runtime_root / "lib" if runtime_root is not None else binary.parent
        environment["LD_LIBRARY_PATH"] = (
            str(library_dir) + os.pathsep + environment.get("LD_LIBRARY_PATH", "")
        )
    return environment


def run_effect(
    effect: str,
    binary: pathlib.Path,
    worker: pathlib.Path,
    runtime_root: pathlib.Path | None,
    width: int,
    height: int,
    fps: int,
    warmup_seconds: int,
    measure_seconds: int,
    sample_interval: float,
) -> dict[str, object]:
    command = [
        str(binary),
        "--effect",
        effect,
        "--width",
        str(width),
        "--height",
        str(height),
        "--fps",
        str(fps),
        "--warmup-seconds",
        str(warmup_seconds),
        "--measure-seconds",
        str(measure_seconds),
    ]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=runtime_environment(binary, worker, runtime_root),
    )
    if process.stdout is None:
        raise BaselineError("failed to capture baseline harness output")
    lines: queue.Queue[object] = queue.Queue()
    thread = threading.Thread(target=reader_thread, args=(process.stdout, lines), daemon=True)
    thread.start()
    sampler = ProcessTreeSampler()
    deadline = time.monotonic() + warmup_seconds + measure_seconds + 45
    measure_started = False
    ready = False
    result: dict[str, object] | None = None
    start_snapshot: ProcessSnapshot | None = None
    end_snapshot: ProcessSnapshot | None = None
    last_live_snapshot: ProcessSnapshot | None = None
    start_wall = 0.0
    end_wall = 0.0
    last_live_wall = 0.0
    worker_rss_samples: list[int] = []
    total_rss_samples: list[int] = []
    logs: list[str] = []
    next_sample = time.monotonic()
    worker_missing_since: float | None = None
    reader_eof = False

    try:
        while time.monotonic() < deadline:
            now = time.monotonic()
            output_wait = min(sample_interval, 0.25)
            if measure_started and result is None:
                output_wait = min(output_wait, max(0.0, next_sample - now))
            try:
                item = lines.get(timeout=output_wait)
            except queue.Empty:
                item = None
            if item is READER_EOF:
                reader_eof = True
            elif isinstance(item, str) and item:
                line = item
                if line.startswith(READY_PREFIX):
                    ready = True
                elif line.startswith(MEASURE_PREFIX):
                    if not ready or measure_started:
                        raise BaselineError(f"{effect}: invalid measurement marker order")
                    start_snapshot = sampler.snapshot(process.pid)
                    if start_snapshot.worker_count == 0:
                        raise BaselineError(f"{effect}: external worker was not sampled")
                    start_wall = time.monotonic()
                    last_live_snapshot = start_snapshot
                    last_live_wall = start_wall
                    measure_started = True
                    next_sample = start_wall
                elif line.startswith(RESULT_PREFIX):
                    if not measure_started:
                        raise BaselineError(f"{effect}: result arrived before measurement marker")
                    candidate = sampler.snapshot(process.pid)
                    candidate_wall = time.monotonic()
                    if candidate.worker_count != 0:
                        last_live_snapshot = candidate
                        last_live_wall = candidate_wall
                    end_snapshot = last_live_snapshot
                    end_wall = last_live_wall
                    result = json.loads(line[len(RESULT_PREFIX) :])
                else:
                    logs.append(line)
            now = time.monotonic()
            if measure_started and result is None and now >= next_sample:
                snapshot = sampler.snapshot(process.pid)
                if snapshot.worker_count == 0:
                    # RESULT is emitted directly before worker teardown.  The
                    # reader thread can deliver that line a few milliseconds
                    # after the OS has reaped the child, so one empty terminal
                    # sample is not itself evidence of a worker crash.
                    if worker_missing_since is None:
                        worker_missing_since = now
                    elif (
                        process.poll() is None
                        and now - worker_missing_since >= max(1.0, sample_interval * 4.0)
                    ):
                        raise BaselineError(
                            f"{effect}: external worker disappeared during measurement"
                        )
                else:
                    worker_missing_since = None
                    last_live_snapshot = snapshot
                    last_live_wall = now
                    worker_rss_samples.append(snapshot.worker_rss_bytes)
                    total_rss_samples.append(snapshot.total_rss_bytes)
                next_sample = now + sample_interval
            if result is not None and process.poll() is not None:
                break
            if process.poll() is not None and result is None and reader_eof:
                break
        if process.poll() is None:
            process.kill()
            raise BaselineError(f"{effect}: baseline harness timed out")
        return_code = process.wait(timeout=5)
        thread.join(timeout=2)
        if return_code != 0 or result is None or start_snapshot is None or end_snapshot is None:
            detail = "\n".join(logs[-20:])
            raise BaselineError(
                f"{effect}: harness failed rc={return_code}; {detail or 'no result'}"
            )
        if not worker_rss_samples:
            worker_rss_samples.append(end_snapshot.worker_rss_bytes)
            total_rss_samples.append(end_snapshot.total_rss_bytes)
        elapsed = max(0.001, end_wall - start_wall)
        result["process"] = {
            "sample_seconds": elapsed,
            "sample_count": len(worker_rss_samples),
            "worker_cpu_core_percent":
                max(0.0, end_snapshot.worker_cpu_seconds - start_snapshot.worker_cpu_seconds)
                / elapsed
                * 100.0,
            "process_tree_cpu_core_percent":
                max(0.0, end_snapshot.total_cpu_seconds - start_snapshot.total_cpu_seconds)
                / elapsed
                * 100.0,
            "worker_rss_median_bytes": int(statistics.median(worker_rss_samples)),
            "worker_rss_peak_bytes": max(worker_rss_samples),
            "worker_rss_end_bytes": end_snapshot.worker_rss_bytes,
            "process_tree_rss_median_bytes": int(statistics.median(total_rss_samples)),
            "process_tree_rss_peak_bytes": max(total_rss_samples),
            "process_count": end_snapshot.process_count,
            "worker_count": end_snapshot.worker_count,
        }
        return result
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def git_metadata(source_dir: pathlib.Path) -> dict[str, object]:
    def git(*args: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(source_dir), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        return completed.stdout.strip()

    try:
        return {
            "commit": git("rev-parse", "HEAD"),
            "branch": git("branch", "--show-current"),
            "dirty": bool(git("status", "--porcelain")),
        }
    except (OSError, subprocess.CalledProcessError):
        return {"commit": None, "branch": None, "dirty": None}


def physical_core_count() -> int | None:
    if sys.platform.startswith("linux"):
        cores: set[tuple[str, str]] = set()
        physical = "0"
        core = ""
        try:
            for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines() + [""]:
                if line.startswith("physical id"):
                    physical = line.split(":", 1)[1].strip()
                elif line.startswith("core id"):
                    core = line.split(":", 1)[1].strip()
                elif not line.strip() and core:
                    cores.add((physical, core))
                    physical, core = "0", ""
        except OSError:
            return None
        return len(cores) or None
    if os.name == "nt":
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetLogicalProcessorInformationEx.argtypes = [
            wintypes.DWORD,
            ctypes.c_void_p,
            ctypes.POINTER(wintypes.DWORD),
        ]
        kernel32.GetLogicalProcessorInformationEx.restype = wintypes.BOOL
        size = wintypes.DWORD(0)
        kernel32.GetLogicalProcessorInformationEx(0, None, ctypes.byref(size))
        if size.value == 0:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if not kernel32.GetLogicalProcessorInformationEx(0, buffer, ctypes.byref(size)):
            return None
        count = 0
        offset = 0
        while offset + 8 <= size.value:
            relationship, record_size = struct.unpack_from("<II", buffer.raw, offset)
            if record_size < 8 or offset + record_size > size.value:
                return None
            if relationship == 0:
                count += 1
            offset += record_size
        return count or None
    return None


def total_memory_bytes() -> int | None:
    if os.name != "nt":
        try:
            return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
        except (ValueError, OSError):
            return None
    from ctypes import wintypes

    class MemoryStatusEx(ctypes.Structure):
        _fields_ = [
            ("dwLength", wintypes.DWORD),
            ("dwMemoryLoad", wintypes.DWORD),
            ("ullTotalPhys", ctypes.c_ulonglong),
            ("ullAvailPhys", ctypes.c_ulonglong),
            ("ullTotalPageFile", ctypes.c_ulonglong),
            ("ullAvailPageFile", ctypes.c_ulonglong),
            ("ullTotalVirtual", ctypes.c_ulonglong),
            ("ullAvailVirtual", ctypes.c_ulonglong),
            ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
        ]

    status = MemoryStatusEx()
    status.dwLength = ctypes.sizeof(status)
    if not ctypes.WinDLL("kernel32").GlobalMemoryStatusEx(ctypes.byref(status)):
        return None
    return int(status.ullTotalPhys)


def cpu_model() -> str:
    if sys.platform.startswith("linux"):
        try:
            for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return os.environ.get("PROCESSOR_IDENTIFIER") or platform.processor() or "unknown"


def detected_power_profile() -> str:
    if sys.platform.startswith("linux"):
        try:
            return subprocess.run(
                ["powerprofilesctl", "get"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=3,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
        governor = pathlib.Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
        try:
            return governor.read_text().strip()
        except OSError:
            return "unknown"
    if os.name == "nt":
        try:
            return subprocess.run(
                ["powercfg.exe", "/GETACTIVESCHEME"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return "unknown"
    return "unknown"


def runtime_metadata(runtime_root: pathlib.Path | None) -> dict[str, object] | None:
    if runtime_root is None:
        return None
    manifest = runtime_root / "manifest.json"
    try:
        return json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BaselineError(f"invalid runtime manifest {manifest}: {error}") from error


def minimum_process_sample_count(measure_seconds: int, sample_interval: float) -> int:
    return max(1, math.ceil(measure_seconds / sample_interval * 0.95))


def calculate_gates(
    direct: dict[str, object],
    off: dict[str, object],
    grayscale: dict[str, object],
    warm_tone: dict[str, object],
    width: int,
    height: int,
    fps: int,
) -> tuple[dict[str, bool], dict[str, float | int]]:
    direct_process = direct["process"]
    off_process = off["process"]
    assert (
        isinstance(direct_process, dict)
        and isinstance(off_process, dict)
    )
    off_preview_fps = int(off["preview_frames"]) / max(0.001, float(off["measure_seconds"]))
    direct_preview_fps = int(direct["preview_frames"]) / max(
        0.001, float(direct["measure_seconds"])
    )
    frame_bytes = width * height * 3 // 2
    cold_off_rss_delta = int(off_process["worker_rss_median_bytes"]) - int(
        direct_process["worker_rss_median_bytes"]
    )
    cold_off_cpu_delta = float(off_process["worker_cpu_core_percent"]) - float(
        direct_process["worker_cpu_core_percent"]
    )
    gates = {
        "exactly_one_external_worker_per_mode": all(
            int(result["process"]["worker_count"]) == 1  # type: ignore[index]
            for result in (direct, off, grayscale, warm_tone)
        ),
        "direct_has_no_effect_pipeline_work": all(
            int(direct[field]) == 0
            for field in (
                "captured",
                "enqueued",
                "processed",
                "frame_copy_count",
                "diagnostic_observation_count",
                "effect_owned_allocated_bytes",
                "effect_thread_count",
                "effect_handle_count",
            )
        ),
        "cold_off_has_no_effect_work": all(
            int(off[field]) == 0
            for field in (
                "captured",
                "enqueued",
                "processed",
                "frame_copy_count",
                "effect_owned_allocated_bytes",
                "effect_thread_count",
                "effect_handle_count",
            )
        ),
        "direct_preview_fps_within_one": direct_preview_fps >= fps - 1.0,
        "cold_off_preview_fps_within_one": off_preview_fps >= fps - 1.0
        and abs(off_preview_fps - direct_preview_fps) <= 1.0,
        "cold_off_worker_cpu_delta_at_most_5_core_percent": cold_off_cpu_delta <= 5.0,
        "cold_off_worker_rss_delta_at_most_16_mib": cold_off_rss_delta <= 16 * MIB,
    }
    comparison: dict[str, float | int] = {
        "direct_preview_fps": direct_preview_fps,
        "off_preview_fps": off_preview_fps,
        "cold_off_worker_cpu_delta_core_percent": cold_off_cpu_delta,
        "cold_off_worker_rss_median_delta_bytes": cold_off_rss_delta,
    }
    for gate_prefix, result in (
        ("grayscale", grayscale),
        ("warm_tone", warm_tone),
    ):
        process = result["process"]
        assert isinstance(process, dict)
        captured = int(result["captured"])
        submitted = int(result["submitted"])
        processed = int(result["processed"])
        replaced = int(result["queue_replaced"])
        bypassed = int(result["bypassed"])
        failed = int(result["failed"])
        elapsed = float(result["measure_seconds"])
        preview_fps = int(result["preview_frames"]) / max(0.001, elapsed)
        processed_ratio = processed / captured if captured else 0.0
        captured_ratio = captured / submitted if submitted else 0.0
        drop_ratio = (replaced + bypassed + failed) / captured if captured else 1.0
        cpu_delta = float(process["worker_cpu_core_percent"]) - float(
            off_process["worker_cpu_core_percent"]
        )
        rss_delta = int(process["worker_rss_median_bytes"]) - int(
            off_process["worker_rss_median_bytes"]
        )
        gates.update({
            f"{gate_prefix}_rolling_p95_max_at_most_8_ms": int(
                result["processing_time_rolling_p95_max_us"]
            ) <= 8000,
            f"{gate_prefix}_rolling_p99_max_at_most_16_ms": int(
                result["processing_time_rolling_p99_max_us"]
            ) <= 16000,
            f"{gate_prefix}_timing_observed_throughout_measurement": int(
                result["diagnostic_observation_count"]
            ) >= int(float(result["measure_seconds"])),
            f"{gate_prefix}_processed_ratio_at_least_0_97": processed_ratio >= 0.97,
            f"{gate_prefix}_captured_ratio_at_least_0_97": captured_ratio >= 0.97,
            f"{gate_prefix}_enqueued_matches_captured": int(result["enqueued"]) == captured,
            f"{gate_prefix}_frame_copy_matches_processed": int(
                result["frame_copy_count"]
            ) == processed,
            f"{gate_prefix}_preview_fps_at_least_29": preview_fps >= fps - 1.0,
            f"{gate_prefix}_drop_ratio_at_most_0_01": drop_ratio <= 0.01,
            f"{gate_prefix}_no_watchdog": int(result["watchdog_bypass"]) == 0,
            f"{gate_prefix}_one_bounded_executor": int(result["effect_thread_count"]) == 1
            and int(result["effect_handle_count"]) == 1,
            f"{gate_prefix}_pool_at_most_three_frames": int(
                result["effect_owned_allocated_bytes"]
            ) <= frame_bytes * 3,
            f"{gate_prefix}_worker_cpu_delta_at_most_5_core_percent": cpu_delta <= 5.0,
            f"{gate_prefix}_worker_rss_delta_at_most_16_mib": rss_delta <= 16 * MIB,
        })
        comparison.update({
            f"{gate_prefix}_preview_fps": preview_fps,
            f"{gate_prefix}_processed_ratio": processed_ratio,
            f"{gate_prefix}_captured_ratio": captured_ratio,
            f"{gate_prefix}_drop_ratio": drop_ratio,
            f"{gate_prefix}_worker_cpu_delta_core_percent": cpu_delta,
            f"{gate_prefix}_worker_rss_median_delta_bytes": rss_delta,
        })
    return gates, comparison


def sampler_grandchild() -> int:
    memory = bytearray(32 * MIB)
    end = time.monotonic() + 1.2
    accumulator = 0
    while time.monotonic() < end:
        accumulator = (accumulator + sum(memory[::4096])) & 0xFFFFFFFF
    return accumulator & 0


def sampler_child() -> int:
    memory = bytearray(32 * MIB)
    child = subprocess.Popen([sys.executable, __file__, "--sampler-grandchild"])
    end = time.monotonic() + 1.0
    accumulator = 0
    while time.monotonic() < end:
        accumulator = (accumulator + sum(memory[::4096])) & 0xFFFFFFFF
    return child.wait(timeout=5) or (accumulator & 0)


def sampler_self_test() -> int:
    process = subprocess.Popen([sys.executable, __file__, "--sampler-child"])
    sampler = ProcessTreeSampler()
    try:
        start = sampler.snapshot(process.pid)
        maximum_processes = start.process_count
        maximum_rss = start.total_rss_bytes
        time.sleep(0.6)
        end = sampler.snapshot(process.pid)
        maximum_processes = max(maximum_processes, end.process_count)
        maximum_rss = max(maximum_rss, end.total_rss_bytes)
        if process.wait(timeout=5) != 0:
            raise BaselineError("sampler child failed")
        if maximum_processes < 2 or maximum_rss < 64 * MIB:
            raise BaselineError("sampler did not observe the full child process tree and memory")
        if end.total_cpu_seconds <= start.total_cpu_seconds:
            raise BaselineError("sampler did not observe increasing process CPU time")
        def fixture(effect: str, cpu: float, rss: int) -> dict[str, object]:
            active = effect in ("grayscale", "warm-tone")
            return {
                "effect": effect,
                "width": 640,
                "height": 480,
                "fps": 30,
                "warmup_seconds": 30,
                "measure_seconds": 60.0,
                "submitted": 1800,
                "preview_frames": 1800,
                "captured": 1800 if active else 0,
                "enqueued": 1800 if active else 0,
                "processed": 1800 if active else 0,
                "bypassed": 0,
                "queue_replaced": 0,
                "failed": 0,
                "watchdog_bypass": 0,
                "frame_copy_count": 1800 if active else 0,
                "processing_time_rolling_p95_max_us": 1000 if active else 0,
                "processing_time_rolling_p99_max_us": 2000 if active else 0,
                "processing_time_max_us": 3000 if active else 0,
                "diagnostic_observation_count": 62 if effect != "direct" else 0,
                "effect_owned_allocated_bytes": 460800 if active else 0,
                "effect_thread_count": 1 if active else 0,
                "effect_handle_count": 1 if active else 0,
                "process": {
                    "worker_cpu_core_percent": cpu,
                    "worker_rss_median_bytes": rss,
                    "worker_count": 1,
                },
            }

        direct = fixture("direct", 50.0, 100 * MIB)
        off = fixture("off", 54.0, 108 * MIB)
        grayscale = fixture("grayscale", 58.0, 116 * MIB)
        warm_tone = fixture("warm-tone", 57.0, 114 * MIB)
        gates, _ = calculate_gates(direct, off, grayscale, warm_tone, 640, 480, 30)
        if not all(gates.values()):
            raise BaselineError("known-good performance gate fixture did not pass")
        off["process"]["worker_cpu_core_percent"] = 56.0  # type: ignore[index]
        gates, _ = calculate_gates(direct, off, grayscale, warm_tone, 640, 480, 30)
        if gates["cold_off_worker_cpu_delta_at_most_5_core_percent"]:
            raise BaselineError("CPU delta gate accepted a value above five percent")
        off["process"]["worker_cpu_core_percent"] = 54.0  # type: ignore[index]
        warm_tone["process"]["worker_cpu_core_percent"] = 60.0  # type: ignore[index]
        gates, _ = calculate_gates(direct, off, grayscale, warm_tone, 640, 480, 30)
        if gates["warm_tone_worker_cpu_delta_at_most_5_core_percent"]:
            raise BaselineError("warm-tone CPU delta gate accepted a value above five percent")
        if minimum_process_sample_count(60, 0.25) != 228:
            raise BaselineError("process sample coverage gate is not the documented 95 percent")
        print("OK: video-effect process-tree sampler self-test")
        return 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=pathlib.Path, default=pathlib.Path("build"))
    parser.add_argument("--binary", type=pathlib.Path)
    parser.add_argument("--worker", type=pathlib.Path)
    parser.add_argument("--runtime-root", type=pathlib.Path)
    parser.add_argument("--source-dir", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--report", type=pathlib.Path)
    parser.add_argument("--package-type", default="development-build")
    parser.add_argument("--power-profile", default="auto")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--warmup-seconds", type=int, default=30)
    parser.add_argument("--measure-seconds", type=int, default=60)
    parser.add_argument("--sample-interval", type=float, default=0.25)
    parser.add_argument("--quick", action="store_true", help="use a 2 s warm-up and 5 s sample")
    parser.add_argument("--no-require-gates", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--sampler-child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--sampler-grandchild", action="store_true", help=argparse.SUPPRESS)
    return parser


def main() -> int:
    args = argument_parser().parse_args()
    if args.sampler_grandchild:
        return sampler_grandchild()
    if args.sampler_child:
        return sampler_child()
    if args.self_test:
        return sampler_self_test()
    if args.quick:
        args.warmup_seconds = 2
        args.measure_seconds = 5
    if (
        args.width < 16
        or args.height < 16
        or args.width % 2
        or args.height % 2
        or args.fps < 1
        or args.warmup_seconds < 1
        or args.measure_seconds < 1
        or args.sample_interval <= 0
    ):
        raise BaselineError("invalid dimensions, rate or measurement duration")

    build_dir = args.build_dir.resolve()
    runtime_root = args.runtime_root.resolve() if args.runtime_root else None
    binary = resolve_binary(build_dir, args.binary.resolve() if args.binary else None)
    worker = resolve_worker(
        build_dir,
        runtime_root,
        args.worker.resolve() if args.worker else None,
    )
    print(f"Measuring Direct with {binary.name} and worker {worker.name}...", flush=True)
    direct = run_effect(
        "direct",
        binary,
        worker,
        runtime_root,
        args.width,
        args.height,
        args.fps,
        args.warmup_seconds,
        args.measure_seconds,
        args.sample_interval,
    )
    print("Measuring cold Off...", flush=True)
    off = run_effect(
        "off",
        binary,
        worker,
        runtime_root,
        args.width,
        args.height,
        args.fps,
        args.warmup_seconds,
        args.measure_seconds,
        args.sample_interval,
    )
    print("Measuring Grayscale...", flush=True)
    grayscale = run_effect(
        "grayscale",
        binary,
        worker,
        runtime_root,
        args.width,
        args.height,
        args.fps,
        args.warmup_seconds,
        args.measure_seconds,
        args.sample_interval,
    )
    print("Measuring Warm tone...", flush=True)
    warm_tone = run_effect(
        "warm-tone",
        binary,
        worker,
        runtime_root,
        args.width,
        args.height,
        args.fps,
        args.warmup_seconds,
        args.measure_seconds,
        args.sample_interval,
    )
    gates, comparison = calculate_gates(
        direct, off, grayscale, warm_tone, args.width, args.height, args.fps
    )
    expected_results = (
        (direct, "direct"),
        (off, "off"),
        (grayscale, "grayscale"),
        (warm_tone, "warm-tone"),
    )
    minimum_process_samples = minimum_process_sample_count(
        args.measure_seconds, args.sample_interval
    )
    release_profile_met = (
        args.width == 640
        and args.height == 480
        and args.fps == 30
        and args.warmup_seconds >= 30
        and args.measure_seconds >= 60
        and abs(args.sample_interval - 0.25) < 1e-9
        and all(
            str(result["effect"]) == expected_effect
            and int(result["width"]) == args.width
            and int(result["height"]) == args.height
            and int(result["fps"]) == args.fps
            and int(result["warmup_seconds"]) == args.warmup_seconds
            and float(result["measure_seconds"])
            >= args.measure_seconds - (1.0 / args.fps)
            and int(result["process"]["sample_count"])  # type: ignore[index]
            >= minimum_process_samples
            for result, expected_effect in expected_results
        )
    )
    performance_gates_passed = all(gates.values())
    acceptance_passed = performance_gates_passed and release_profile_met
    report = {
        "schema": "dinox-video-effects-baseline-v2",
        "generated_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "machine": {
            "cpu_model": cpu_model(),
            "logical_cores": os.cpu_count(),
            "physical_cores": physical_core_count(),
            "ram_bytes": total_memory_bytes(),
            "operating_system": platform.platform(),
            "power_profile": detected_power_profile()
            if args.power_profile == "auto"
            else args.power_profile,
            "graphics_backend": "synthetic-I420",
            "hardware_acceleration": "not used by synthetic source",
        },
        "source": git_metadata(args.source_dir.resolve()),
        "runtime": runtime_metadata(runtime_root),
        "package_type": args.package_type,
        "profile": {
            "width": args.width,
            "height": args.height,
            "fps": args.fps,
            "warmup_seconds": args.warmup_seconds,
            "measure_seconds": args.measure_seconds,
            "sample_interval_seconds": args.sample_interval,
            "minimum_process_samples_for_acceptance": minimum_process_samples,
        },
        "results": {
            "direct": direct,
            "off": off,
            "grayscale": grayscale,
            "warm_tone": warm_tone,
        },
        "comparison": comparison,
        "gates": gates,
        "performance_gates_passed": performance_gates_passed,
        "release_profile_met": release_profile_met,
        "all_gates_passed": acceptance_passed,
        "scope": (
            "Deterministic external-worker synthetic baseline; it does not replace "
            "live 1:1/MUJI, network, camera-device or audio-continuity tests."
        ),
    }
    encoded = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.report.with_name(args.report.name + f".tmp.{os.getpid()}")
        temporary.write_text(encoded, encoding="utf-8")
        os.replace(temporary, args.report)
        print(f"Baseline report: {args.report}")
    else:
        print(encoded, end="")
    if acceptance_passed:
        result_label = "PASS"
    elif performance_gates_passed:
        result_label = "NON-ACCEPTANCE PROFILE"
    else:
        result_label = "FAIL"
    print(
        "Result: "
        + result_label
        + "; cold-Off CPU/RSS delta "
        + f"{comparison['cold_off_worker_cpu_delta_core_percent']:.2f} %-core / "
        + f"{comparison['cold_off_worker_rss_median_delta_bytes'] / MIB:.2f} MiB; "
        + "Grayscale CPU/RSS delta "
        + f"{comparison['grayscale_worker_cpu_delta_core_percent']:.2f} %-core / "
        + f"{comparison['grayscale_worker_rss_median_delta_bytes'] / MIB:.2f} MiB; "
        + "Warm tone CPU/RSS delta "
        + f"{comparison['warm_tone_worker_cpu_delta_core_percent']:.2f} %-core / "
        + f"{comparison['warm_tone_worker_rss_median_delta_bytes'] / MIB:.2f} MiB",
        flush=True,
    )
    return 0 if acceptance_passed or args.no_require_gates or (
        args.quick and performance_gates_passed
    ) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BaselineError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
