# Validation evidence

These logs were captured from the verified KV260 run on 2026-07-30 UTC.

- `hardware-query.log`: active B4096 overlay, Vitis AI versions, DPU architecture and fingerprint
- `xmodel-query.log`: official YOLOv3 xmodel subgraphs, architecture and fingerprint
- `dpu-benchmark.log`: five-second single-thread DPU benchmark (`Test PASS`)
- `webcam-run.log`: 60-frame USB webcam inference console output
- `webcam-summary.txt`: measured end-to-end summary
- `provenance.log`: downloaded asset and container hashes

Camera JPEGs were intentionally excluded because they contain a real room and
people. New runs create their own images under the ignored `results/` folder.

