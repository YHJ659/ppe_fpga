CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -Werror -fPIC -I../include/uapi

all: libmodel6_hw_driver.so

libmodel6_hw_driver.so: hw_driver.o
	$(CC) -shared -o $@ $^

hw_driver.o: hw_driver.c hw_driver.h
	$(CC) $(CFLAGS) -c -o $@ hw_driver.c

clean:
	rm -f hw_driver.o libmodel6_hw_driver.so

.PHONY: all clean
