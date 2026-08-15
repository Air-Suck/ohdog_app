# npu_plan_server

昇腾 910 侧薄规划服务（C++）。当前为连通性 stub：固定返回元动作序列。

```bash
make && ./npu_plan_server --http --port 8443 --token robotpi
```

手机经 **中间机** 访问：见仓库 `mid/` 与 [docs/910_server_support.md](../docs/910_server_support.md)。
