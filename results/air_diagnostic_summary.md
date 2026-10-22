# BART＋状态空间模型：实验记录汇总

本文件自动整理执行状态、原始分数和诊断。跑通、取得更低的pilot误差、后验诊断通过是三个不同结论；失败和未完成运行保留。数值比较不构成创新性、因果机制或可发表性的证明。

## 20261022T173136675021Z-air_diagnostic-e52735dd

任务：`air`；阶段：`exploratory`；**执行结束**。
运行目录：`artifacts/20261022T173136675021Z-air_diagnostic-e52735dd`。配置 SHA-256：`e52735dd1209f98897d19ed4eda88b8da3192eeae390057e229bcf30abc7785e`；Git：`b98f138371c72033549f7b4a73ed615c63b83294`。
链数 4；每链保留抽样 1000；burn-in 1000；运行耗时 110.7 秒。
已记录 12 个 case/model 分数，预期 12；失败记录 0。
执行时工作树有改动；复现还需运行目录内的 source 快照与 tracked_changes.diff，不能只依赖 Git SHA。
运行记录声明未使用封存确认集。

### 各case等权的描述性均值

每个case权重相同；RMSE列是各case RMSE的算术平均，**不是**合并观测后的RMSE。Σn只表示评分行数，小时、期限和复用的缺口并非独立样本。不同运行及不同应用不合并排名；未通过诊断的数值仅供pilot排查。

| 模型 | case数 | Σn | RMSE均值 | MAE均值 | CRPS均值 | 覆盖80 | 宽度80 | 覆盖95 | 宽度95 | case诊断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| bart_joint | 3 | 1928 | 0.67264 | 0.441 | 0.33595 | 0.80269 | 1.3569 | 0.91128 | 2.0774 | 未通过：仅pilot 3 |
| bart_static | 3 | 1928 | 0.64501 | 0.40413 | 0.31171 | 0.68839 | 0.85817 | 0.82578 | 1.3205 | 未通过：仅pilot 3 |
| bart_two_stage | 3 | 1928 | 0.6955 | 0.44208 | 0.3485 | 0.71438 | 1.0521 | 0.83882 | 1.6104 | 未通过：仅pilot 3 |
| linear_dynamic | 3 | 1928 | 0.77115 | 0.52403 | 0.40144 | 0.78998 | 1.6229 | 0.90136 | 2.4841 | 未通过：仅pilot 3 |

### 原始case分数

| case | 模型 | n | RMSE | MAE | CRPS | 覆盖80 | 宽度80 | 覆盖95 | 宽度95 | 诊断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gap24 | bart_static | 281 | 0.63096 | 0.37737 | 0.2923 | 0.72242 | 0.86029 | 0.82562 | 1.328 | 未通过：仅pilot |
| gap72 | bart_static | 847 | 0.66882 | 0.42543 | 0.32972 | 0.67651 | 0.85829 | 0.82172 | 1.3187 | 未通过：仅pilot |
| gap168 | bart_static | 800 | 0.63525 | 0.40959 | 0.31313 | 0.66625 | 0.85592 | 0.83 | 1.3146 | 未通过：仅pilot |
| gap24 | linear_dynamic | 281 | 0.76954 | 0.49993 | 0.38889 | 0.7331 | 1.1777 | 0.86477 | 1.8041 | 未通过：仅pilot |
| gap72 | linear_dynamic | 847 | 0.83964 | 0.58883 | 0.4425 | 0.75561 | 1.6621 | 0.8843 | 2.5432 | 未通过：仅pilot |
| gap168 | linear_dynamic | 800 | 0.70426 | 0.48333 | 0.37294 | 0.88125 | 2.0288 | 0.955 | 3.1049 | 未通过：仅pilot |
| gap24 | bart_two_stage | 281 | 0.75555 | 0.45617 | 0.36716 | 0.63345 | 0.81074 | 0.80071 | 1.241 | 未通过：仅pilot |
| gap72 | bart_two_stage | 847 | 0.71372 | 0.47424 | 0.36866 | 0.7072 | 1.0713 | 0.817 | 1.6394 | 未通过：仅pilot |
| gap168 | bart_two_stage | 800 | 0.61722 | 0.39585 | 0.30967 | 0.8025 | 1.2741 | 0.89875 | 1.9508 | 未通过：仅pilot |
| gap24 | bart_joint | 281 | 0.69119 | 0.43918 | 0.33527 | 0.74377 | 1.0336 | 0.88968 | 1.5847 | 未通过：仅pilot |
| gap72 | bart_joint | 847 | 0.72017 | 0.48375 | 0.36325 | 0.77804 | 1.3873 | 0.88666 | 2.1221 | 未通过：仅pilot |
| gap168 | bart_joint | 800 | 0.60657 | 0.40008 | 0.30933 | 0.88625 | 1.6499 | 0.9575 | 2.5253 | 未通过：仅pilot |

### 联合模型与基准的配对CRPS

ΔCRPS = bart_joint − 基准；负值表示本次记录的联合模型误差较小。先对同一标签配对，再在整段缺口/目标月份/模拟重复内平均，最后对块等权；不把小时或期限单独重采样。模拟按DGP与噪声分层，不把不同DGP凑成重复样本。

至少 8 个匹配块、运行完整且所有相关阶段通过诊断才给出探索性95%区间。模拟按重复重采样；真实数据使用按时间排序的循环移动块（块长 ceil(n^(1/3))、至少2），保留相邻组的相关性。这不证明块相互独立，也不替代更大样本验证。固定种子 20261023，2000次重采样。

| 分层 | 基准 | 匹配块 | 匹配评分行 | ΔCRPS块均值 | 探索性95%区间 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| gap168 | bart_two_stage | 5 | 800 | 0.00041793 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| gap24 | bart_two_stage | 12 | 281 | -0.03231 | 不计算 | 至少一个模型或首阶段诊断未通过/缺失 |
| gap72 | bart_two_stage | 12 | 847 | -0.0055417 | 不计算 | 至少一个模型或首阶段诊断未通过/缺失 |
| gap168 | bart_static | 5 | 800 | -0.0026798 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| gap24 | bart_static | 12 | 281 | 0.041911 | 不计算 | 至少一个模型或首阶段诊断未通过/缺失 |
| gap72 | bart_static | 12 | 847 | 0.033069 | 不计算 | 至少一个模型或首阶段诊断未通过/缺失 |

### 诊断明细

通过要求每个记录的随机量均满足 Rhat < 1.01、bulk ESS ≥ 400、tail ESS ≥ 400，并且原始 passed 为真。两阶段方法的随机首阶段也纳入判定；点估计基准的NA只表示MCMC不适用，绝不算作收敛通过。

| 拟合case | 模型/阶段 | 通过变量/全部 | 最大Rhat | 最小bulk ESS | 最小tail ESS | 原始原因 |
| --- | --- | --- | --- | --- | --- | --- |
| air_validation | bart_joint | 0/8 | 2.7925 | 4.6495 | 10.699 | Convergence/ESS threshold not met |
| air_validation | bart_static | 0/6 | 2.1114 | 5.2539 | 11.847 | Convergence/ESS threshold not met |
| air_validation | bart_two_stage | 1/3 | 1.0657 | 56.832 | 209.55 | Convergence/ESS threshold not met |
| air_validation | bart_two_stage:first_stage | 0/6 | 2.1114 | 5.2539 | 11.847 | Convergence/ESS threshold not met |
| air_validation | linear_dynamic | 0/8 | 2.5831 | 4.8249 | 12.212 | Convergence/ESS threshold not met |

## 20261022T173136683849Z-simulation_air_diagnostic-036e60dc

任务：`simulation_air`；阶段：`exploratory`；**执行结束**。
运行目录：`artifacts/20261022T173136683849Z-simulation_air_diagnostic-036e60dc`。配置 SHA-256：`036e60dc77d6e74bb17dd637c6f4f7db90339912ba044142883a807333b04d82`；Git：`b98f138371c72033549f7b4a73ed615c63b83294`。
链数 4；每链保留抽样 1000；burn-in 1000；运行耗时 106.51 秒。
已记录 24 个 case/model 分数，预期 24；失败记录 0。
执行时工作树有改动；复现还需运行目录内的 source 快照与 tracked_changes.diff，不能只依赖 Git SHA。
运行记录声明未使用封存确认集。

### 各case等权的描述性均值

每个case权重相同；RMSE列是各case RMSE的算术平均，**不是**合并观测后的RMSE。Σn只表示评分行数，小时、期限和复用的缺口并非独立样本。不同运行及不同应用不合并排名；未通过诊断的数值仅供pilot排查。

| 模型 | case数 | Σn | RMSE均值 | MAE均值 | CRPS均值 | 覆盖80 | 宽度80 | 覆盖95 | 宽度95 | case诊断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| bart_joint | 6 | 690 | 0.32259 | 0.25788 | 0.18333 | 0.84783 | 0.88075 | 0.96087 | 1.3467 | 未通过：仅pilot 6 |
| bart_static | 6 | 690 | 0.32622 | 0.2613 | 0.18637 | 0.8058 | 0.85288 | 0.94058 | 1.299 | 未通过：仅pilot 6 |
| bart_two_stage | 6 | 690 | 0.32287 | 0.25721 | 0.19226 | 0.56812 | 0.50137 | 0.75507 | 0.76811 | 未通过：仅pilot 6 |
| linear_dynamic | 6 | 690 | 0.55393 | 0.42542 | 0.30946 | 0.82899 | 1.4865 | 0.94058 | 2.2789 | 未通过：仅pilot 6 |

### 原始case分数

| case | 模型 | n | RMSE | MAE | CRPS | 覆盖80 | 宽度80 | 覆盖95 | 宽度95 | 诊断 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| no_drift_1 | bart_static | 115 | 0.28457 | 0.20693 | 0.14798 | 0.85217 | 0.68438 | 0.96522 | 1.0443 | 未通过：仅pilot |
| no_drift_1 | linear_dynamic | 115 | 0.61461 | 0.46494 | 0.33837 | 0.8087 | 1.5812 | 0.93043 | 2.4154 | 未通过：仅pilot |
| no_drift_1 | bart_two_stage | 115 | 0.28737 | 0.20931 | 0.15532 | 0.6087 | 0.40484 | 0.8 | 0.61935 | 未通过：仅pilot |
| no_drift_1 | bart_joint | 115 | 0.24775 | 0.18725 | 0.13391 | 0.91304 | 0.721 | 0.98261 | 1.0922 | 未通过：仅pilot |
| no_drift_2 | bart_static | 115 | 0.20445 | 0.16115 | 0.12127 | 0.92174 | 0.73081 | 0.9913 | 1.1095 | 未通过：仅pilot |
| no_drift_2 | linear_dynamic | 115 | 0.53222 | 0.38548 | 0.28878 | 0.84348 | 1.4718 | 0.95652 | 2.2506 | 未通过：仅pilot |
| no_drift_2 | bart_two_stage | 115 | 0.20289 | 0.16034 | 0.11575 | 0.72174 | 0.41342 | 0.89565 | 0.63198 | 未通过：仅pilot |
| no_drift_2 | bart_joint | 115 | 0.21883 | 0.16585 | 0.12468 | 0.93043 | 0.77154 | 0.9913 | 1.1705 | 未通过：仅pilot |
| drift_1 | bart_static | 115 | 0.44739 | 0.37176 | 0.25555 | 0.84348 | 1.2047 | 0.96522 | 1.844 | 未通过：仅pilot |
| drift_1 | linear_dynamic | 115 | 0.67578 | 0.53501 | 0.37973 | 0.78261 | 1.607 | 0.90435 | 2.4611 | 未通过：仅pilot |
| drift_1 | bart_two_stage | 115 | 0.37692 | 0.30866 | 0.21768 | 0.63478 | 0.7471 | 0.90435 | 1.1471 | 未通过：仅pilot |
| drift_1 | bart_joint | 115 | 0.34597 | 0.28396 | 0.20012 | 0.81739 | 0.98229 | 0.98261 | 1.4989 | 未通过：仅pilot |
| drift_2 | bart_static | 115 | 0.30152 | 0.23822 | 0.17351 | 0.92174 | 1.0435 | 0.9913 | 1.5911 | 未通过：仅pilot |
| drift_2 | linear_dynamic | 115 | 0.60881 | 0.47119 | 0.34253 | 0.8 | 1.5054 | 0.92174 | 2.297 | 未通过：仅pilot |
| drift_2 | bart_two_stage | 115 | 0.31157 | 0.24837 | 0.17928 | 0.68696 | 0.61518 | 0.84348 | 0.94044 | 未通过：仅pilot |
| drift_2 | bart_joint | 115 | 0.27326 | 0.22355 | 0.15723 | 0.87826 | 0.82356 | 0.97391 | 1.254 | 未通过：仅pilot |
| slow_covariates_1 | bart_static | 115 | 0.35347 | 0.29475 | 0.20628 | 0.66087 | 0.79329 | 0.91304 | 1.2033 | 未通过：仅pilot |
| slow_covariates_1 | linear_dynamic | 115 | 0.42401 | 0.34719 | 0.24335 | 0.87826 | 1.3079 | 0.98261 | 2.0214 | 未通过：仅pilot |
| slow_covariates_1 | bart_two_stage | 115 | 0.37212 | 0.30716 | 0.24117 | 0.35652 | 0.41569 | 0.52174 | 0.63854 | 未通过：仅pilot |
| slow_covariates_1 | bart_joint | 115 | 0.37456 | 0.30931 | 0.21572 | 0.84348 | 1.0351 | 0.96522 | 1.603 | 未通过：仅pilot |
| slow_covariates_2 | bart_static | 115 | 0.36592 | 0.29498 | 0.21365 | 0.63478 | 0.66069 | 0.81739 | 1.0017 | 未通过：仅pilot |
| slow_covariates_2 | linear_dynamic | 115 | 0.46813 | 0.34871 | 0.26399 | 0.86087 | 1.4458 | 0.94783 | 2.2276 | 未通过：仅pilot |
| slow_covariates_2 | bart_two_stage | 115 | 0.38636 | 0.30939 | 0.24438 | 0.4 | 0.41197 | 0.56522 | 0.63127 | 未通过：仅pilot |
| slow_covariates_2 | bart_joint | 115 | 0.47516 | 0.37737 | 0.26834 | 0.70435 | 0.95101 | 0.86957 | 1.4616 | 未通过：仅pilot |

模拟真值恢复（沿用运行定义；不存在的状态不应解读为准确恢复）：

| case | 模型 | 状态RMSE | 函数RMSE |
| --- | --- | --- | --- |
| no_drift_1 | bart_static | 0 | 0.11986 |
| no_drift_1 | linear_dynamic | 0.043312 | 0.58627 |
| no_drift_1 | bart_two_stage | 0.02124 | 0.11986 |
| no_drift_1 | bart_joint | 0.030807 | 0.1158 |
| no_drift_2 | bart_static | 0 | 0.10607 |
| no_drift_2 | linear_dynamic | 0.031816 | 0.53183 |
| no_drift_2 | bart_two_stage | 0.022 | 0.10607 |
| no_drift_2 | bart_joint | 0.033086 | 0.11032 |
| drift_1 | bart_static | 0.33531 | 0.21136 |
| drift_1 | linear_dynamic | 0.15766 | 0.52887 |
| drift_1 | bart_two_stage | 0.11805 | 0.21136 |
| drift_1 | bart_joint | 0.088431 | 0.13633 |
| drift_2 | bart_static | 0.40693 | 0.34905 |
| drift_2 | linear_dynamic | 0.29704 | 0.59203 |
| drift_2 | bart_two_stage | 0.32153 | 0.34905 |
| drift_2 | bart_joint | 0.21539 | 0.23272 |
| slow_covariates_1 | bart_static | 0.45327 | 0.45505 |
| slow_covariates_1 | linear_dynamic | 0.3556 | 0.37906 |
| slow_covariates_1 | bart_two_stage | 0.44336 | 0.45505 |
| slow_covariates_1 | bart_joint | 0.3182 | 0.32973 |
| slow_covariates_2 | bart_static | 0.64919 | 0.64915 |
| slow_covariates_2 | linear_dynamic | 0.44967 | 0.48168 |
| slow_covariates_2 | bart_two_stage | 0.63985 | 0.64915 |
| slow_covariates_2 | bart_joint | 0.27272 | 0.29538 |

### 联合模型与基准的配对CRPS

ΔCRPS = bart_joint − 基准；负值表示本次记录的联合模型误差较小。先对同一标签配对，再在整段缺口/目标月份/模拟重复内平均，最后对块等权；不把小时或期限单独重采样。模拟按DGP与噪声分层，不把不同DGP凑成重复样本。

至少 8 个匹配块、运行完整且所有相关阶段通过诊断才给出探索性95%区间。模拟按重复重采样；真实数据使用按时间排序的循环移动块（块长 ceil(n^(1/3))、至少2），保留相邻组的相关性。这不证明块相互独立，也不替代更大样本验证。固定种子 20261023，2000次重采样。

| 分层 | 基准 | 匹配块 | 匹配评分行 | ΔCRPS块均值 | 探索性95%区间 | 限制 |
| --- | --- | --- | --- | --- | --- | --- |
| drift | bart_two_stage | 2 | 230 | -0.019805 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| no_drift | bart_two_stage | 2 | 230 | -0.0062442 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| slow_covariates | bart_two_stage | 2 | 230 | -0.00074449 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| drift | bart_static | 2 | 230 | -0.035855 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| no_drift | bart_static | 2 | 230 | -0.0053299 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |
| slow_covariates | bart_static | 2 | 230 | 0.032066 | 不计算 | 有效块不足8：不计算区间；至少一个模型或首阶段诊断未通过/缺失 |

### 诊断明细

通过要求每个记录的随机量均满足 Rhat < 1.01、bulk ESS ≥ 400、tail ESS ≥ 400，并且原始 passed 为真。两阶段方法的随机首阶段也纳入判定；点估计基准的NA只表示MCMC不适用，绝不算作收敛通过。

| 拟合case | 模型/阶段 | 通过变量/全部 | 最大Rhat | 最小bulk ESS | 最小tail ESS | 原始原因 |
| --- | --- | --- | --- | --- | --- | --- |
| drift_1 | bart_joint | 0/8 | 1.5458 | 7.101 | 19.285 | Convergence/ESS threshold not met |
| drift_1 | bart_static | 0/6 | 1.5239 | 7.2896 | 21.274 | Convergence/ESS threshold not met |
| drift_1 | bart_two_stage | 2/3 | 1.0303 | 138.25 | 267.56 | Convergence/ESS threshold not met |
| drift_1 | bart_two_stage:first_stage | 0/6 | 1.5239 | 7.2896 | 21.274 | Convergence/ESS threshold not met |
| drift_1 | linear_dynamic | 1/8 | 1.1911 | 15.881 | 46.153 | Convergence/ESS threshold not met |
| drift_2 | bart_joint | 0/8 | 1.4697 | 7.9228 | 28.129 | Convergence/ESS threshold not met |
| drift_2 | bart_static | 0/6 | 1.3026 | 10.177 | 21.38 | Convergence/ESS threshold not met |
| drift_2 | bart_two_stage | 2/3 | 1.0311 | 118.42 | 211.56 | Convergence/ESS threshold not met |
| drift_2 | bart_two_stage:first_stage | 0/6 | 1.3026 | 10.177 | 21.38 | Convergence/ESS threshold not met |
| drift_2 | linear_dynamic | 1/8 | 1.0451 | 81.423 | 156.11 | Convergence/ESS threshold not met |
| no_drift_1 | bart_joint | 0/8 | 1.6329 | 6.625 | 23.384 | Convergence/ESS threshold not met |
| no_drift_1 | bart_static | 0/6 | 2.126 | 5.2615 | 11.945 | Convergence/ESS threshold not met |
| no_drift_1 | bart_two_stage | 2/3 | 1.045 | 110.76 | 221.37 | Convergence/ESS threshold not met |
| no_drift_1 | bart_two_stage:first_stage | 0/6 | 2.126 | 5.2615 | 11.945 | Convergence/ESS threshold not met |
| no_drift_1 | linear_dynamic | 7/8 | 1.055 | 57.749 | 116.2 | Convergence/ESS threshold not met |
| no_drift_2 | bart_joint | 0/8 | 1.6759 | 6.4498 | 27.93 | Convergence/ESS threshold not met |
| no_drift_2 | bart_static | 0/6 | 1.5637 | 7.1685 | 14.041 | Convergence/ESS threshold not met |
| no_drift_2 | bart_two_stage | 2/3 | 1.028 | 144 | 180.64 | Convergence/ESS threshold not met |
| no_drift_2 | bart_two_stage:first_stage | 0/6 | 1.5637 | 7.1685 | 14.041 | Convergence/ESS threshold not met |
| no_drift_2 | linear_dynamic | 3/8 | 1.0473 | 53.744 | 99.021 | Convergence/ESS threshold not met |
| slow_covariates_1 | bart_joint | 0/8 | 2.0328 | 5.3691 | 11.458 | Convergence/ESS threshold not met |
| slow_covariates_1 | bart_static | 0/6 | 1.7833 | 5.9632 | 13.118 | Convergence/ESS threshold not met |
| slow_covariates_1 | bart_two_stage | 2/3 | 1.0396 | 118.8 | 204.57 | Convergence/ESS threshold not met |
| slow_covariates_1 | bart_two_stage:first_stage | 0/6 | 1.7833 | 5.9632 | 13.118 | Convergence/ESS threshold not met |
| slow_covariates_1 | linear_dynamic | 0/8 | 1.9663 | 5.6924 | 11.985 | Convergence/ESS threshold not met |
| slow_covariates_2 | bart_joint | 0/8 | 1.8219 | 5.8773 | 11.284 | Convergence/ESS threshold not met |
| slow_covariates_2 | bart_static | 0/6 | 1.6219 | 6.6185 | 15.81 | Convergence/ESS threshold not met |
| slow_covariates_2 | bart_two_stage | 2/3 | 1.0482 | 82.668 | 183.84 | Convergence/ESS threshold not met |
| slow_covariates_2 | bart_two_stage:first_stage | 0/6 | 1.6219 | 6.6185 | 15.81 | Convergence/ESS threshold not met |
| slow_covariates_2 | linear_dynamic | 0/8 | 2.8002 | 4.6718 | 13.075 | Convergence/ESS threshold not met |
