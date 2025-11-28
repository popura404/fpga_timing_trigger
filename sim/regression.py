"""Absolute-edge reference schedules and directed command regressions.

The oracle never advances a phase/repeat counter. On accepted triggers it
constructs half-open intervals from t0 + repeat * P + D for each channel.
"""
from dataclasses import dataclass, replace
import random

NOP, COMMIT, ARM, CANCEL, STOP = range(5)


@dataclass(frozen=True)
class Config:
    period: int = 4
    repeats: int = 1
    enable: int = 1
    delay: tuple = (0, 0, 0, 0)
    width: tuple = (1, 1, 1, 1)

    def legal(self):
        return self.period > 0 and self.repeats > 0 and all(
            not (self.enable & (1 << lane)) or
            (self.width[lane] > 0 and
             self.delay[lane] + self.width[lane] <= self.period)
            for lane in range(4))


class Reference:
    def __init__(self, time_w=32, repeat_w=16, count_w=32):
        self.time_w, self.repeat_w, self.count_w = time_w, repeat_w, count_w
        self.edge = -1
        self.state, self.valid, self.count = "IDLE", False, 0
        self.active = self.inputs = Config()
        self.windows, self.finish, self.t0 = (), None, None
        self.rows = []
        self.context = "initial"

    def packed(self, values):
        return sum(value << (lane * self.time_w) for lane, value in enumerate(values))

    def step(self, command=NOP, trigger=0, rst=0, config=None, probe_phase=None):
        if probe_phase is not None:
            # White-box arithmetic probe: omit uninteresting cycles only in
            # the first repetition. Expected intervals remain absolute.
            assert self.state == "RUN" and command == NOP and not trigger and not rst
            assert config is None and self.edge - self.t0 < self.active.period
            assert self.edge - self.t0 + 1 < probe_phase < self.active.period
            self.edge = self.t0 + probe_phase - 1
        self.edge += 1
        if config is not None:
            assert 0 <= config.enable < 16
            assert 0 <= config.period < (1 << self.time_w)
            assert 0 <= config.repeats < (1 << self.repeat_w)
            assert all(0 <= value < (1 << self.time_w)
                       for value in config.delay + config.width)
            self.inputs = config
        done = aborted = error = False
        old_state = self.state
        if rst:
            self.state, self.valid, self.count = "IDLE", False, 0
            self.windows, self.finish = (), None
        elif command == STOP:
            self.state = "IDLE"
            aborted = old_state == "RUN"
        elif old_state == "IDLE":
            if command == COMMIT:
                self.valid = self.inputs.legal()
                error = not self.valid
                if self.valid:
                    self.active = self.inputs
            elif command == ARM and self.valid:
                self.state = "ARMED"
            elif command != NOP:
                error = True
        elif old_state == "ARMED":
            if command == CANCEL:
                self.state = "IDLE"
            else:
                error = command != NOP
                if trigger:
                    self.state = "RUN"
                    self.t0 = self.edge
                    cfg = self.active
                    self.finish = self.edge + cfg.repeats * cfg.period
                    self.windows = [
                        [(self.edge + repeat * cfg.period + cfg.delay[lane],
                          self.edge + repeat * cfg.period + cfg.delay[lane] + cfg.width[lane])
                         for repeat in range(cfg.repeats)]
                        if cfg.enable & (1 << lane) else [] for lane in range(4)]
        else:
            error = command != NOP
            if trigger:
                self.count = (self.count + 1) % (1 << self.count_w)
            if self.edge == self.finish:
                self.state, done = "IDLE", True
        pulse = sum(1 << lane for lane, intervals in enumerate(self.windows)
                    if self.state == "RUN" and
                    any(begin <= self.edge < end for begin, end in intervals))
        cfg = self.inputs
        row = (rst, command, trigger, cfg.enable, self.packed(cfg.delay),
               self.packed(cfg.width), cfg.period, cfg.repeats, pulse,
               self.state == "RUN", self.state == "ARMED", done, aborted,
               error, self.valid, self.count, probe_phase is not None, probe_phase or 0)
        self.rows.append((row, f"{self.context}:edge={self.edge}"))

    def begin(self, name, config):
        self.context = name
        self.step(rst=1, config=config)
        self.step(COMMIT)
        self.step(ARM)

    def drain(self):
        assert self.state == "RUN"
        for _ in range(self.finish - self.edge + 2):
            self.step()


def directed(model):
    # t0 and the completion edge, including continuous high across repeats.
    for delay, width, period, repeats in [(0, 1, 1, 1), (0, 1, 4, 1),
                                          (1, 1, 2, 1), (1, 3, 4, 1),
                                          (0, 1, 1, 4), (0, 4, 4, 3)]:
        model.begin(f"boundary-D{delay}-W{width}-P{period}-R{repeats}",
                    Config(period, repeats, delay=(delay, 0, 0, 0),
                           width=(width, 1, 1, 1)))
        model.step(trigger=1)
        model.drain()
    for name, cfg in [
            ("simultaneous", Config(6, 3, 15, (0, 0, 0, 0), (2, 2, 2, 2))),
            ("stagger-overlap", Config(8, 3, 15, (0, 1, 3, 7), (4, 2, 4, 1))),
            ("disabled-garbage", Config(4, 2, 5, (0, 15, 3, 15), (4, 0, 1, 15))),
            ("all-disabled", Config(3, 2, 0, (15, 15, 15, 15), (0, 0, 0, 0)))]:
        model.begin(name, cfg)
        model.step(trigger=1)
        model.drain()

    # Invalid submissions invalidate a previously usable configuration.
    maximum = (1 << model.time_w) - 1
    invalid = [Config(0), Config(repeats=0), Config(width=(0, 1, 1, 1)),
               Config(4, delay=(4, 0, 0, 0)),
               Config(maximum, delay=(maximum, 0, 0, 0), width=(2, 1, 1, 1))]
    for index, cfg in enumerate(invalid):
        model.context = f"invalid-{index}"
        model.step(rst=1, config=Config())
        model.step(COMMIT)
        model.step(COMMIT, config=cfg)
        model.step(ARM, trigger=1)
        model.step(trigger=1)
        model.step(COMMIT, config=Config())
        model.step(ARM)
        model.step(trigger=1)
        model.drain()

    cfg = Config(6, 2, 15, (0, 1, 2, 5), (6, 1, 3, 1))
    model.begin("locked-config-and-busy-commands", cfg)
    model.step(COMMIT, config=Config(0))  # ARMED rejects, active remains valid.
    model.step(ARM)  # Another illegal command must not cancel the wait.
    model.step(COMMIT, trigger=1, config=Config(1))
    for command in [COMMIT, ARM, CANCEL, 5, 6, 7, NOP, NOP, NOP, NOP, NOP, COMMIT]:
        model.step(command, trigger=1, config=Config(0))
    model.step(trigger=1)  # IDLE trigger must not restart.
    model.step(ARM, trigger=1)  # ARM + trigger only arms.
    model.step()
    model.step(trigger=1)
    model.drain()

    model.begin("cancel-beats-trigger", Config())
    model.step(CANCEL, trigger=1)
    model.step(trigger=1)
    model.step(ARM)
    model.step(trigger=1)
    model.drain()

    # Stop before acceptance, on both pulse transitions, and at completion.
    model.begin("armed-stop", Config())
    model.step(STOP, trigger=1)
    model.step()
    for offset in (1, 2, 4, 6):
        model.begin(f"run-stop-offset-{offset}", Config(6, delay=(2, 0, 0, 0),
                                                      width=(2, 1, 1, 1)))
        model.step(trigger=1)
        for _ in range(offset - 1):
            model.step()
        model.step(STOP, trigger=1)
        model.step()
        model.step(ARM)  # A stop retained the valid configuration.
        model.step(trigger=1)
        model.drain()

    for state in ("IDLE", "ARMED", "RUN"):
        model.begin(f"reset-from-{state}", Config(3, 2))
        if state == "IDLE":
            model.step(CANCEL)
        elif state == "RUN":
            model.step(trigger=1)
            model.step(trigger=1)
        model.step(STOP, trigger=1, rst=1)
        model.step(ARM)
        model.step(trigger=1)
        model.step(COMMIT)
        model.step(ARM)
        model.step(trigger=1)
        model.drain()

    model.context = "idle-illegal-commands"
    model.step(rst=1)
    for command in (ARM, CANCEL, 5, 6, 7, STOP, NOP):
        model.step(command, trigger=1)
    model.step()


def randomized(model):
    """Small reproducible samples supplement explicit boundaries, not replace them."""
    for seed in (7, 29, 83, 211, 997):
        rng = random.Random(seed)
        for case in range(12):
            period = rng.randint(1, min(12, (1 << model.time_w) - 1))
            repeats = rng.randint(1, min(4, (1 << model.repeat_w) - 1))
            delay = tuple(rng.randrange(period) for _ in range(4))
            width = tuple(rng.randint(1, period - value) for value in delay)
            cfg = Config(period, repeats, rng.randrange(16), delay, width)
            model.begin(f"seed-{seed}-case-{case}", cfg)
            if case % 4 == 0:
                model.step(CANCEL, trigger=1)
                model.step(ARM, trigger=1)
            model.step(trigger=1)
            # Six of twelve samples per seed finish naturally. The others
            # stop/reset amid a bounded schedule, then prove full recovery.
            cut = rng.randint(1, period * repeats)
            while model.state == "RUN":
                elapsed = model.edge - model.t0 + 1
                trigger = int(rng.randrange(3) == 0)
                command = rng.choice((NOP, NOP, NOP, COMMIT, ARM, CANCEL, 5, 6, 7))
                if case % 4 == 1 and elapsed == cut:
                    model.step(STOP, trigger=1)
                elif case % 4 == 3 and elapsed == cut:
                    model.step(command, trigger=1, rst=1)
                else:
                    # Inputs can change without a successful IDLE commit.
                    model.step(command, trigger, config=Config(0))
            model.step()
            if case % 2:
                model.step(COMMIT, config=cfg)
                model.step(ARM)
                model.step(trigger=1)
                model.drain()
            # Each lane gets a width-zero failure and a period-overrun
            # failure, spread across the fixed-seed samples.
            if case % 3 == 0:
                lane = case // 3
                invalid_width = list(cfg.width)
                invalid_width[lane] = 0
                bad = replace(cfg, enable=cfg.enable | (1 << lane),
                              width=tuple(invalid_width))
                model.step(COMMIT, config=bad)
                model.step(ARM, trigger=1)
                model.step(trigger=1)
            elif case % 3 == 1:
                lane = case // 3
                invalid_delay = list(cfg.delay)
                invalid_delay[lane] = period
                bad = replace(cfg, enable=cfg.enable | (1 << lane),
                              delay=tuple(invalid_delay))
                model.step(COMMIT, config=bad)
                model.step(ARM)
                model.step()


def width_boundaries(model):
    maximum = (1 << model.time_w) - 1
    max_repeats = (1 << model.repeat_w) - 1
    if model.time_w <= 8 and model.repeat_w <= 8:
        model.begin("small-max-period-repeats-count-wrap",
                    Config(maximum, max_repeats, 15,
                           (0, 1, maximum - 1, maximum - 2),
                           (maximum, 1, 1, 2)))
        model.step(trigger=1)
        # Full execution: phase/repetition boundaries and many modulo
        # diagnostic-counter wraps, including a trigger on completion.
        while model.state == "RUN":
            model.step(trigger=1)
        model.step()
        model.step(ARM)
        model.step(trigger=1)
        model.step(STOP)
        model.step(rst=1)
        model.step(ARM)
    elif model.time_w == 32:
        for name, delay, width, period in (
                ("max-endpoint", maximum - 1, 1, maximum),
                ("unsigned-half-range", 1 << 31, 1, (1 << 31) + 1),
                ("max-full-width", 0, maximum, maximum)):
            model.begin(f"arithmetic-probe-{name}",
                        Config(period, 1, 1, (delay, 0, 0, 0), (width, 1, 1, 1)))
            model.step(trigger=1)
            model.step(probe_phase=period - 2)
            model.drain()
        model.begin("max-repeat-start-stop", Config(2, max_repeats))
        model.step(trigger=1)
        model.step()
        model.step()
        model.step(STOP, trigger=1)
        model.step()


def write_vectors(path, time_w=32, repeat_w=16, count_w=32):
    model = Reference(time_w, repeat_w, count_w)
    directed(model)
    randomized(model)
    width_boundaries(model)
    scenarios = len({context.split(":")[0] for _, context in model.rows})
    probes = sum(row[16] for row, _ in model.rows)
    print(f"Vectors: {len(model.rows)} checked edges, {scenarios} scenarios, "
          f"5 seeds x 12 configurations, {probes} arithmetic probes; "
          f"widths {time_w}/{repeat_w}/{count_w}", flush=True)
    path.write_text("".join(" ".join(f"{int(value):x}" for value in row) +
                            " " + context + "\n" for row, context in model.rows))
    return len(model.rows)
