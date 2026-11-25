FASM ?= fasm -m 131072
TARGETS := hello mandel ray gl

.PHONY: all run clean

all: $(TARGETS)

gl: gl.asm
	$(FASM) $< gl.o
	ld -o $@ gl.o -dynamic-linker /lib64/ld-linux-x86-64.so.2 -lX11 -lGL -lm -lc

ray: ray.asm
	$(FASM) $< $@
	chmod +x $@

%: %.asm
	$(FASM) $< $@
	chmod +x $@

run: hello
	./hello

mandel-run: mandel
	./mandel

gl-run: gl
	./gl

clean:
	rm -f $(TARGETS) gl.o

ray-run: ray
	./ray
