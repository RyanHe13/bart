# 第一轮探索性结果

由 `python3 scripts/plot_results.py` 从运行目录导出。当前状态：选定运行均已完成；仍为探索性结果。

- 选定 9 个运行，130 个 case/model 分数。
- 随机模型完整诊断通过 0 个；8 个点估计基准不适用MCMC诊断，不算通过。
- 包含随机首阶段的拟合阶段通过 0/117。
- 旧失败运行 2 个，保留在运行账本，未用于成功结果表与图。
- 独立采样器审计 5/5 档执行完成，诊断通过 0；只用于定位采样问题，不混入模型预测比较。

未通过诊断的误差比较只用于发现问题，不支持模型优势、机制或创新成立的结论；诊断未通过也不证明研究假设为假。

| 文件 | 内容 |
| --- | --- |
| `run_ledger.csv` | 全部运行状态、是否纳入、配置/数据/源码汇总哈希与Git提交 |
| `provenance.json` | 完整配置、逐源码文件哈希、原始结果文件哈希、失败与诊断记录 |
| `case_scores.csv` | 选定完成运行的原始case分数与诊断状态 |
| `model_summary.csv` | 每个case等权的描述性均值；RMSE不是合并观测RMSE |
| `paired_crps.csv` | 同标签配对后按整段缺口/月份/模拟重复汇总；区间不可用原因完整保留 |
| `diagnostic_stages.csv` | 主阶段与随机首阶段的Rhat/ESS及是否通过 |
| `audit_ledger.csv`、`audit_provenance.json` | 独立静态BART采样器审计及其配置/模拟真值/源码哈希 |
| `export_manifest.json` | 精确选定run IDs、导出脚本哈希和本目录输出校验值 |

四组图提供PNG与可缩放SVG：`observed_data_crps`、`yield_simulation_crps`、`air_simulation_crps`、`diagnostic_stage_counts`。
斜线柱表示相关MCMC诊断未通过或缺失；不同应用、数据版本和链长的结果不合并。
旧运行未完整记录条件均值和预测观测诊断，已在case表中标明旧门禁；不能当作完整预测诊断通过。
所有真实数据评价仅针对探索集，确认集使用情况以各运行的 `summary.json` 记录为准。
原始观测、预测逐行真值和后验链不复制到此目录。
