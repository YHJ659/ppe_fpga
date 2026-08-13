# YOLOv8n model.6 C2f FPGA Integration

Kria KV260에서 YOLOv8n `model.6 C2f`의 일부를 HLS IP와 AXI-Stream 기반으로
통합한 자료입니다.

```text
PS/DDR -> AXI DMA -> cv1 -> BN/SiLU -> Split
                              -> Bottleneck x2
                              -> Concat -> AXI DMA -> PS/DDR
```

최종 하드웨어 경계는 자원·routing 혼잡을 고려해 `cv1~Concat`으로 조정했고,
`cv2` 이후는 CPU에서 처리하는 방향으로 검토했습니다.

- `hls/`: 로컬에서 확인된 HLS 원본과 testbench
- `hls_ip_repo/`: Vivado IP Catalog 등록용 export package
- `vivado/`: Block Design, 프로젝트 진입 파일, Tcl, XSA
- `vitis/`: DMA 보드 시험용 C 코드

Vivado/Vitis 버전은 2022.2를 기준으로 합니다.
