**001_2026-10-14_d009c98**

- 2026-10-14 15:42: baseline on laptop

| group | scenario | seeds | settled 2D RMSE (cm) | p95 (cm) | z RMSE (cm) | yaw RMSE (°) | NEES | in 3σ (%) | UWB-only RMSE (cm) |
|---|---|---|---|---|---|---|---|---|---|
| #001 live | circle | 1 | 8.1 | 14.2 | 1.1 | 3.96 | 0.94 | 100.0 | 28.2 |
| #001 live | line | 1 | 7.1 | 12.7 | 1.1 | 3.93 | 0.80 | 100.0 | 30.2 |
| #001 live | random_smooth | 1 | 6.9 | 12.2 | 1.1 | 3.93 | 0.80 | 100.0 | 15.9 |
| #001 live | rectangle | 1 | 7.8 | 13.5 | 1.1 | 3.92 | 0.88 | 100.0 | 24.4 |
| #001 live | static | 1 | 6.7 | 11.8 | 0.3 | 3.93 | 0.77 | 100.0 | 4.6 |
| #001 offline | circle | 1,2,3 | 6.9 | 12.2 | 1.1 | 1.61 | 0.72 | 100.0 | 28.8 |
| #001 offline | line | 1,2,3 | 6.2 | 11.1 | 1.1 | 1.60 | 0.64 | 100.0 | 30.3 |
| #001 offline | random_smooth | 1,2,3 | 6.3 | 11.1 | 1.1 | 1.60 | 0.65 | 100.0 | 20.6 |
| #001 offline | rectangle | 1,2,3 | 6.7 | 11.8 | 1.1 | 1.61 | 0.66 | 100.0 | 24.7 |
| #001 offline | static | 1,2,3 | 6.1 | 10.6 | 0.2 | 1.60 | 0.64 | 100.0 | 4.4 |

rmse.png compares the seeds every group has: circle [1], line [1], random_smooth [1], rectangle [1], static [1].
