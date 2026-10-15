**002_2026-10-15_838cbae**

- 2026-10-15 02:08: NAV only simmulated also

| group | scenario | seeds | settled 2D RMSE (cm) | p95 (cm) | z RMSE (cm) | yaw RMSE (°) | NEES | in 3σ (%) | UWB-only RMSE (cm) | NAV-only at 10 s (cm) | NAV-only at end (m) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| #002 live | circle | 1 | 8.1 | 14.2 | 1.1 | 3.96 | 0.94 | 100.0 | 28.2 | 184 | 8.95 |
| #002 live | line | 1 | 7.1 | 12.7 | 1.1 | 3.93 | 0.80 | 100.0 | 30.2 | 260 | 97.04 |
| #002 live | random_smooth | 1 | 6.9 | 12.2 | 1.1 | 3.93 | 0.80 | 100.0 | 15.9 | 241 | 90.07 |
| #002 live | rectangle | 1 | 7.7 | 13.5 | 1.1 | 3.94 | 0.87 | 100.0 | 24.4 | 233 | 16.10 |
| #002 live | static | 1 | 6.7 | 11.8 | 0.3 | 3.93 | 0.77 | 100.0 | 4.6 | 254 | 96.89 |
| #002 offline | circle | 1,2,3 | 6.9 | 12.2 | 1.1 | 1.61 | 0.72 | 100.0 | 28.8 | 131 | 6.40 |
| #002 offline | line | 1,2,3 | 6.2 | 11.1 | 1.1 | 1.60 | 0.64 | 100.0 | 30.3 | 188 | 67.83 |
| #002 offline | random_smooth | 1,2,3 | 6.3 | 11.1 | 1.1 | 1.60 | 0.65 | 100.0 | 20.6 | 182 | 63.92 |
| #002 offline | rectangle | 1,2,3 | 6.7 | 11.8 | 1.1 | 1.61 | 0.66 | 100.0 | 24.7 | 174 | 11.39 |
| #002 offline | static | 1,2,3 | 6.1 | 10.6 | 0.2 | 1.60 | 0.64 | 100.0 | 4.4 | 185 | 67.77 |

rmse.png compares the seeds every group has: circle [1], line [1], random_smooth [1], rectangle [1], static [1].
