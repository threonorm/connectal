
all: parsetab.py

BOARD=zedboard

parsetab.py: syntax.py
	python syntax.py

test: test-echo/echo.bit.bin.gz test-memcpy/memcpy.bit.bin.gz test-hdmi/hdmidisplay.bit.bin.gz

test-echo/echo.bit.bin.gz: examples/echo/Echo.bsv
	rm -fr test-echo
	mkdir test-echo
	./genxpsprojfrombsv -B $(BOARD) -p test-echo -b Echo examples/echo/Echo.bsv
	cd test-echo; make verilog && make bits && make echo.bit.bin.gz
	cp examples/echo/testecho.cpp test-echo/jni
	(cd test-echo; ndk-build)
	echo test-echo built successfully

test-memcpy/memcpy.bit.bin.gz: examples/memcpy/Memcpy.bsv
	rm -fr test-memcpy
	mkdir test-memcpy
	./genxpsprojfrombsv -B $(BOARD) -p test-memcpy -b Memcpy examples/memcpy/Memcpy.bsv bsv/BlueScope.bsv bsv/AxiSDMA.bsv bsv/PortalMemory.bsv
	cd test-memcpy; make verilog && make bits && make memcpy.bit.bin.gz
	cp examples/memcpy/testmemcpy.cpp test-memcpy/jni
	(cd test-memcpy; ndk-build)
	echo test-memcpy built successfully

test-loadstore/loadstore.bit.bin.gz: examples/loadstore/LoadStore.bsv
	rm -fr test-loadstore
	mkdir test-loadstore
	./genxpsprojfrombsv -B $(BOARD) -p test-loadstore -b LoadStore examples/loadstore/LoadStore.bsv
	cd test-loadstore; make verilog && make bits && make loadstore.bit.bin.gz
	cp examples/loadstore/testloadstore.cpp test-loadstore/jni
	(cd test-loadstore; ndk-build)
	echo test-loadstore built successfully

test-hdmi/hdmidisplay.bit.bin.gz: bsv/HdmiDisplay.bsv
	rm -fr test-hdmi
	mkdir test-hdmi
	./genxpsprojfrombsv -B $(BOARD) -p test-hdmi -b HdmiDisplay bsv/HdmiDisplay.bsv
	cd test-hdmi; make verilog && make bits && make hdmidisplay.bit.bin.gz
	echo test-hdmi built successfully

test-imageon/imagecapture.bit.bin.gz: examples/imageon/ImageCapture.bsv
	rm -fr test-imageon
	mkdir test-imageon
	./genxpsprojfrombsv -B zc702 -p test-imageon -b ImageCapture --verilog=../imageon/sources/fmc_imageon_vita_receiver_v1_13_a examples/imageon/ImageCapture.bsv bsv/BlueScope.bsv bsv/AxiSDMA.bsv bsv/PortalMemory.bsv
	cd test-imageon; make verilog && make bits && make imagecapture.bit.bin.gz
	echo test-imageon built successfully
