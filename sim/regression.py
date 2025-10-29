"""Independent absolute-edge schedules; no DUT phase recurrence is copied."""


def write_vectors(path):
    rows = []
    for delay, width, period in [(0, 1, 1), (0, 1, 4), (1, 1, 2), (1, 3, 4)]:
        rows.append((1, 0, delay, width, period, 0, 0, 0))
        # t0 = 0; the high interval and completion edge are absolute times.
        high_edges = set(range(delay, delay + width))
        for edge in range(period + 2):
            rows.append((0, int(edge == 0), delay, width, period,
                         int(edge in high_edges), int(edge < period), int(edge == period)))
    path.write_text("".join(" ".join(map(str, row)) + "\n" for row in rows))
    return len(rows)
