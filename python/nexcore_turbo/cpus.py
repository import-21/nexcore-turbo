"""CPUs this process may actually use: affinity mask and cgroup v1/v2 quota."""

import math
import os


def _cgroup_quota():
    try:
        with open("/sys/fs/cgroup/cpu.max", encoding="ascii") as fh:
            quota, period = fh.read().split()[:2]
            if quota != "max":
                return int(quota) / int(period)
    except (OSError, ValueError):
        pass
    try:
        with open("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", encoding="ascii") as fh:
            quota = int(fh.read())
        with open("/sys/fs/cgroup/cpu/cpu.cfs_period_us", encoding="ascii") as fh:
            period = int(fh.read())
        if quota > 0:
            return quota / period
    except (OSError, ValueError):
        pass
    return None


def available_cpus():
    try:
        count = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):  # macOS, some BSDs
        count = os.cpu_count() or 1
    quota = _cgroup_quota()
    if quota:
        count = min(count, math.ceil(quota))
    return max(1, count)
