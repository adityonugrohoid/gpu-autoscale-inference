"""Render one full-cycle run directory as a PNG figure.

Reads the logs written by scripts/full-cycle-run.sh:
  timeline.log       T+ offsets, phase boundaries and milestones
  redis-queue.log    queue depth per poll
  pod-lifecycle.log  vLLM ready replicas, worker replicas, GPU node count per poll
  vllm-output.log    vLLM throughput lines (only when the capture is non-empty)

Usage:
  python scripts/plot_run.py <run-dir> <output.png>
"""

import logging
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.axes import Axes  # noqa: E402

logger = logging.getLogger("plot_run")

TIMELINE_RE = re.compile(r"^T\+(\d+)s \| (\S+) \| (.*)$")
THROUGHPUT_RE = re.compile(r"^(\S+Z) .*Avg generation throughput: ([\d.]+) tokens/s")
KEDA_THRESHOLD = 5


@dataclass
class Event:
    offset: int
    label: str


@dataclass
class QueuePoint:
    t: float
    depth: int


@dataclass
class PodPoint:
    t: float
    vllm_ready: int
    workers: int
    gpu_nodes: int | None


@dataclass
class ThroughputPoint:
    t: float
    tokens_per_s: float


@dataclass
class Span:
    name: str
    start: int
    end: int


@dataclass
class Marker:
    name: str
    offset: float
    color: str


def parse_ts(value: str) -> float:
    """Parse a UTC log timestamp into epoch seconds.

    Args:
        value: ISO timestamp with a Z suffix, optionally with nanoseconds.

    Returns:
        Seconds since the epoch.
    """
    value = value.rstrip("Z")
    if "." in value:
        head, frac = value.split(".", 1)
        parsed = datetime.strptime(f"{head}.{frac[:6]}", "%Y-%m-%dT%H:%M:%S.%f")
    else:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%S")
    return parsed.replace(tzinfo=timezone.utc).timestamp()


def read_lines(path: Path) -> list[str]:
    """Read a log file into non-empty lines.

    Args:
        path: Log file path.

    Returns:
        The file's non-empty lines.

    Raises:
        FileNotFoundError: If the file does not exist.
    """
    if not path.exists():
        raise FileNotFoundError(f"missing log file: {path}")
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_timeline(run_dir: Path) -> tuple[float, list[Event]]:
    """Load timeline.log and derive the run's T+0 instant.

    Args:
        run_dir: Run directory.

    Returns:
        T+0 as epoch seconds, and the timeline events in file order.

    Raises:
        ValueError: If a line does not match the timeline format or the file is empty.
    """
    events = []
    t0 = None
    for line in read_lines(run_dir / "timeline.log"):
        match = TIMELINE_RE.match(line.strip())
        if match is None:
            raise ValueError(f"unexpected timeline.log line: {line!r}")
        offset, ts, label = match.groups()
        if t0 is None:
            t0 = parse_ts(ts) - int(offset)
        events.append(Event(offset=int(offset), label=label))
    if t0 is None:
        raise ValueError(f"empty timeline.log in {run_dir}")
    return t0, events


def load_queue(run_dir: Path, t0: float) -> list[QueuePoint]:
    """Load queue depth samples from redis-queue.log.

    Args:
        run_dir: Run directory.
        t0: Run start as epoch seconds.

    Returns:
        Queue depth per poll, timed as seconds since T+0.
    """
    points = []
    for line in read_lines(run_dir / "redis-queue.log"):
        ts, value = (part.strip() for part in line.split("|"))
        points.append(QueuePoint(t=parse_ts(ts) - t0, depth=int(value.removeprefix("queue="))))
    return points


def load_pods(run_dir: Path, t0: float) -> list[PodPoint]:
    """Load replica and GPU node counts from pod-lifecycle.log.

    The script logged three shapes over time: `vllm=<ready>/<total> <status>`
    per pod, a bare `vllm=<ready replicas>`, or an empty `vllm=` before the
    pod exists. Phase 2 drain lines omit gpu_nodes.

    Args:
        run_dir: Run directory.
        t0: Run start as epoch seconds.

    Returns:
        vLLM ready replicas, worker replicas and GPU nodes (None when not logged) per poll.

    Raises:
        ValueError: If a line lacks the vllm or workers field.
    """
    points = []
    for line in read_lines(run_dir / "pod-lifecycle.log"):
        ts, *parts = (part.strip() for part in line.split("|"))
        fields = dict(part.split("=", 1) for part in parts)
        if "vllm" not in fields or "workers" not in fields:
            raise ValueError(f"unexpected pod-lifecycle.log line: {line!r}")
        vllm = fields["vllm"].split(" ", 1)[0]
        points.append(
            PodPoint(
                t=parse_ts(ts) - t0,
                vllm_ready=int(vllm.split("/")[0]) if vllm else 0,
                workers=int(fields["workers"]),
                gpu_nodes=int(fields["gpu_nodes"]) if "gpu_nodes" in fields else None,
            )
        )
    return points


def load_throughput(run_dir: Path, t0: float) -> list[ThroughputPoint]:
    """Load vLLM generation throughput from vllm-output.log.

    The early runs have an empty vllm-output.log (a capture bug fixed later),
    so an empty result is expected for them.

    Args:
        run_dir: Run directory.
        t0: Run start as epoch seconds.

    Returns:
        Generation tokens/s per vLLM stats line.
    """
    path = run_dir / "vllm-output.log"
    if not path.exists():
        return []
    points = []
    for line in read_lines(path):
        match = THROUGHPUT_RE.match(line)
        if match is not None:
            points.append(ThroughputPoint(t=parse_ts(match.group(1)) - t0, tokens_per_s=float(match.group(2))))
    return points


def find_event(events: list[Event], prefix: str) -> int | None:
    """Return the offset of the first event whose label starts with prefix.

    Args:
        events: Timeline events.
        prefix: Label prefix to match.

    Returns:
        The event's T+ offset in seconds, or None when the run never logged it.
    """
    for event in events:
        if event.label.startswith(prefix):
            return event.offset
    return None


def node_losses(pods: list[PodPoint], cool_down_start: int | None) -> list[float]:
    """Find mid-run GPU node losses.

    A GPU node count dropping from above zero to zero before cool down
    means the node went away while the run still needed it.

    Args:
        pods: Pod lifecycle samples.
        cool_down_start: T+ offset of COOL DOWN START, or None.

    Returns:
        T+ offsets of the first sample after each loss.
    """
    known = [p for p in pods if p.gpu_nodes is not None]
    return [
        after.t
        for before, after in zip(known, known[1:])
        if before.gpu_nodes > 0
        and after.gpu_nodes == 0
        and (cool_down_start is None or after.t < cool_down_start)
    ]


def draw_annotations(axes: list[Axes], spans: list[Span], markers: list[Marker]) -> None:
    """Shade phases and draw milestone lines on every panel, labels on the top one.

    Args:
        axes: Figure panels, top first.
        spans: Load phases to shade.
        markers: Milestones to draw as vertical lines.
    """
    for ax in axes:
        for span in spans:
            ax.axvspan(span.start, span.end, color="tab:blue", alpha=0.08)
        for marker in markers:
            ax.axvline(marker.offset, color=marker.color, linestyle=":", linewidth=1)
    top = axes[0]
    for span in spans:
        top.text((span.start + span.end) / 2, 1.02, span.name, transform=top.get_xaxis_transform(), ha="center", fontsize=9)
    for marker in markers:
        top.text(
            marker.offset, 0.95, f" {marker.name}", transform=top.get_xaxis_transform(),
            rotation=90, va="top", fontsize=8, color=marker.color,
        )


def plot(run_dir: Path, out_path: Path) -> None:
    """Render the run's queue, replica, node and throughput curves to a PNG.

    Args:
        run_dir: Run directory written by full-cycle-run.sh.
        out_path: PNG file to write.
    """
    t0, events = load_timeline(run_dir)
    queue = load_queue(run_dir, t0)
    pods = load_pods(run_dir, t0)
    throughput = load_throughput(run_dir, t0)

    spans = []
    for name, start_prefix, end_prefix in (
        ("Phase 1 (cold start)", "PHASE 1 START", "PHASE 1 DONE"),
        ("Phase 2 (warm)", "PHASE 2 START", "PHASE 2 DONE"),
    ):
        start, end = find_event(events, start_prefix), find_event(events, end_prefix)
        if start is not None and end is not None:
            spans.append(Span(name=name, start=start, end=end))
    markers = []
    for name, prefix in (
        ("vLLM ready", "vLLM READY"),
        ("pods at zero", "PODS SCALED TO ZERO"),
        ("GPU node removed", "GPU NODE REMOVED"),
    ):
        offset = find_event(events, prefix)
        if offset is not None:
            markers.append(Marker(name=name, offset=offset, color="black"))
    markers += [
        Marker(name="GPU node lost", offset=t, color="tab:red")
        for t in node_losses(pods, find_event(events, "COOL DOWN START"))
    ]

    rows = 3 if throughput else 2
    fig, axes = plt.subplots(rows, 1, figsize=(12, 3.2 * rows), sharex=True)

    ax = axes[0]
    ax.step([p.t for p in queue], [p.depth for p in queue], where="post", color="tab:blue")
    ax.axhline(KEDA_THRESHOLD, color="tab:gray", linestyle=":", linewidth=1, label=f"KEDA threshold ({KEDA_THRESHOLD})")
    ax.set_ylabel("queue depth")
    # Milestone labels sit along the top edge, so keep the legend clear of them
    ax.legend(loc="center right")

    ax = axes[1]
    times = [p.t for p in pods]
    ax.step(times, [p.vllm_ready for p in pods], where="post", label="vLLM ready replicas", color="tab:green")
    ax.step(times, [p.workers for p in pods], where="post", label="worker replicas", color="tab:orange")
    nodes = [p for p in pods if p.gpu_nodes is not None]
    ax.step([p.t for p in nodes], [p.gpu_nodes for p in nodes], where="post", label="GPU nodes", color="tab:red", linestyle="--")
    ax.set_ylabel("count")
    top_count = max(max(p.vllm_ready, p.workers, p.gpu_nodes or 0) for p in pods)
    ax.set_yticks(range(top_count + 1))
    ax.legend(loc="upper right")

    if throughput:
        ax = axes[2]
        ax.plot([p.t for p in throughput], [p.tokens_per_s for p in throughput], color="tab:purple")
        ax.set_ylabel("generation tok/s")

    draw_annotations(list(axes), spans, markers)
    # Leave room right of the last milestone line for its rotated label
    right = max([p.t for p in queue] + [m.offset for m in markers])
    axes[-1].set_xlim(right=right * 1.04)
    axes[-1].set_xlabel("seconds since run start (T+)")
    fig.suptitle(f"{run_dir.name}: regenerated from the committed logs", y=0.995)
    fig.tight_layout()
    fig.savefig(out_path, dpi=110)
    plt.close(fig)
    logger.info("wrote %s", out_path)


def main() -> None:
    """Parse the command line and render one run."""
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if len(sys.argv) != 3:
        raise SystemExit("usage: python scripts/plot_run.py <run-dir> <output.png>")
    run_dir = Path(sys.argv[1])
    if not run_dir.is_dir():
        raise SystemExit(f"not a directory: {run_dir}")
    plot(run_dir, Path(sys.argv[2]))


if __name__ == "__main__":
    main()
