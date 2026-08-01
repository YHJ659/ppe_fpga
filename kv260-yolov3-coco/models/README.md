# Model directory

Do not commit the downloaded model archive or extracted xmodel to GitHub.

Run the repository download script on the KV260:

```bash
./scripts/download_model.sh
```

It verifies the official AMD/Xilinx archive and creates:

```text
models/yolov3_coco_416_tf2/
├── yolov3_coco_416_tf2.xmodel
└── yolov3_coco_416_tf2.prototxt
```
