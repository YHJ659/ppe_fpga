PYTHON ?= python3
PYTHONPATH := python
BUILD_DIR := build

.PHONY: demo-pass demo-fail test vectors sim-mac sim-control clean

demo-pass:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) python/run_verification.py --mode mock-pass

demo-fail:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) python/run_verification.py --mode mock-fail

test:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) -m pytest -q

vectors:
	PYTHONPATH=$(PYTHONPATH) $(PYTHON) python/generate_mac_vectors.py

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

sim-mac: vectors | $(BUILD_DIR)
	iverilog -g2012 -o $(BUILD_DIR)/tb_mac rtl/mac_core.sv tb/tb_mac_core.sv
	vvp $(BUILD_DIR)/tb_mac

sim-control: | $(BUILD_DIR)
	iverilog -g2012 -o $(BUILD_DIR)/tb_control rtl/ppe_control_mock.sv tb/tb_ppe_control.sv
	vvp $(BUILD_DIR)/tb_control

clean:
	rm -rf $(BUILD_DIR) .pytest_cache python/ppe_verify/__pycache__ tests/__pycache__

