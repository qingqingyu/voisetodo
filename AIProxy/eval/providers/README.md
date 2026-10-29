# 进程内评测的 provider 条目模板(A4)

不含 key。用法(README §1 同一套评分/落盘/续跑):

```bash
OPENROUTER_KEY=sk-or-... node run.mjs \\
  --provider-file providers/openrouter-glm-4.5-air.json \\
  --key-env OPENROUTER_KEY --label or-glm-air
```

key 只从 env 读(`--key-env` 指定变量名,默认 `EVAL_PROVIDER_KEY`),
不写进本目录文件、不出现在命令行参数之外的地方(ps 可见)。
