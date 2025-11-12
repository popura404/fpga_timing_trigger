"""Absolute-edge reference schedules and directed command regressions.

The oracle never advances a phase/repeat counter. On accepted triggers it
constructs half-open intervals from t0 + repeat * P + D for each channel.
"""
from dataclasses import dataclass

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
        self.windows, self.finish = (), None
        self.rows = []
        self.context = "initial"

    def packed(self, values):
        return sum(value << (lane * self.time_w) for lane, value in enumerate(values))

    def step(self, command=NOP, trigger=0, rst=0, config=None):
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
               error, self.valid, self.count)
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


def write_vectors(path, time_w=32, repeat_w=16, count_w=32):
    model = Reference(time_w, repeat_w, count_w)
    directed(model)
    path.write_text("".join(" ".join(f"{int(value):x}" for value in row) +
                            " " + context + "\n" for row, context in model.rows))
    return len(model.rows)
