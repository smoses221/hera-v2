"""Ground-truth trajectories of the tag (NAV board + UWB board, one rigid point).

Every scenario is on the z = 0 plane, starts at rest, and keeps the tag on
the y > 0 side of the two anchors (the side the filter is initialised on).
Apart from `static`, a small vertical "bob" (sigma ~1 cm) is added, as a
hand-held or cart-mounted board would have. Roll and pitch are 0.

A scenario is a function (t, rng) -> (xy [N, 2], yaw [N], bob: bool),
sampled on a fine time grid; velocities and accelerations are derived
numerically by generate.py.
"""

import numpy as np

DURATION = 60.0


def smoothstep(u):
    """Quintic smoothstep: 0 -> 1 with zero velocity and acceleration at both ends."""
    u = np.clip(u, 0.0, 1.0)
    return u**3 * (10 - 15 * u + 6 * u**2)


def keyframes(t, frames):
    """Piecewise motion through (time, values) keyframes, smoothstep between them,
    held constant before the first and after the last."""
    times = np.array([f[0] for f in frames], dtype=float)
    vals = np.array([f[1] for f in frames], dtype=float)
    out = np.empty((len(t), vals.shape[1]))
    out[:] = vals[0]
    for (t0, v0), (t1, v1) in zip(zip(times, vals), zip(times[1:], vals[1:])):
        m = t >= t0
        out[m] = v0 + (v1 - v0) * smoothstep((t[m] - t0) / (t1 - t0))[:, None]
    return out


def static(t, rng):
    xy = np.tile([2.0, 2.0], (len(t), 1))
    return xy, np.full(len(t), 0.3), False


def line(t, rng):
    """Back and forth between x = 1 and x = 3 at y = 1.5, yaw fixed at 0.5 rad
    (the board is not aligned with the motion, so both body axes see it)."""
    frames, now, x = [(0.0, [1.0, 1.5])], 2.0, 1.0
    frames.append((now, [x, 1.5]))
    while now < DURATION:
        x = 4.0 - x
        now += 4.0
        frames.append((now, [x, 1.5]))
        now += 1.0
        frames.append((now, [x, 1.5]))
    return keyframes(t, frames), np.full(len(t), 0.5), True


def circle(t, rng, speed=0.5, radius=1.2, centre=(2.0, 2.2)):
    """Constant speed on a circle after a 3 s smooth start, heading along the path."""
    omega = speed / radius * smoothstep(t / 3.0)
    theta = np.concatenate([[0.0], np.cumsum(0.5 * (omega[1:] + omega[:-1]) * np.diff(t))])
    xy = np.column_stack([centre[0] + radius * np.sin(theta),
                          centre[1] - radius * np.cos(theta)])
    return xy, theta, True


def rectangle(t, rng):
    """Two laps of a 2 m x 2 m square: drive an edge facing forward (4 s), stop,
    turn 90 degrees in place (2 s), and so on."""
    corners = [(1.0, 1.0), (3.0, 1.0), (3.0, 3.0), (1.0, 3.0)]
    now, yaw = 2.0, 0.0
    frames = [(0.0, [*corners[0], yaw]), (now, [*corners[0], yaw])]
    for k in range(8):
        nxt = corners[(k + 1) % 4]
        now += 4.0
        frames.append((now, [*nxt, yaw]))
        now += 0.5
        frames.append((now, [*nxt, yaw]))
        yaw += np.pi / 2
        now += 2.0
        frames.append((now, [*nxt, yaw]))
    path = keyframes(t, frames)
    return path[:, :2], path[:, 2], True


def random_smooth(t, rng):
    """A seeded sum of slow sinusoids around (2, 2), kept within +/-1 m, with a
    yaw that wanders independently (up to +/-0.8 rad)."""
    ramp = smoothstep(t / 3.0)

    def wander(n, fmin, fmax, amplitude):
        f = rng.uniform(fmin, fmax, n)
        a = rng.uniform(0.5, 1.0, n)
        phase = rng.uniform(0, 2 * np.pi, n)
        s = (a[None, :] * np.sin(2 * np.pi * f[None, :] * t[:, None] + phase[None, :])).sum(axis=1)
        return amplitude * s / np.max(np.abs(s))

    xy = np.column_stack([2.0 + ramp * wander(4, 0.03, 0.15, 1.0),
                          2.0 + ramp * wander(4, 0.03, 0.15, 1.0)])
    return xy, ramp * wander(3, 0.02, 0.08, 0.8), True


SCENARIOS = {
    "static": static,
    "line": line,
    "circle": circle,
    "rectangle": rectangle,
    "random_smooth": random_smooth,
}


def bob(t, rng):
    """Vertical motion of the board, ~1 cm, starting at rest."""
    phase = rng.uniform(0, 2 * np.pi, 2)
    ramp = smoothstep(t / 3.0)
    return ramp * (0.010 * np.sin(2 * np.pi * 0.5 * t + phase[0])
                   + 0.005 * np.sin(2 * np.pi * 1.7 * t + phase[1]))
