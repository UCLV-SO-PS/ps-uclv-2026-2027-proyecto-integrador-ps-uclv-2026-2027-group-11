CC = gcc
AR = ar
CPPFLAGS = -D_POSIX_C_SOURCE=200809L
CFLAGS = -Wall -Wextra -Werror -std=c11 -O2

.PHONY: all clean test

all: libmonitor.a server client

libmonitor.a: bd_episodios.o utilidades.o
	$(AR) rcs $@ $^

server: server.o libmonitor.a
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ server.o libmonitor.a $(LDLIBS)

client: client.o libmonitor.a
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ client.o libmonitor.a $(LDLIBS)

bd_episodios.o: bd_episodios.c bd_episodios.h
utilidades.o: utilidades.c utilidades.h bd_episodios.h
server.o: server.c red.h utilidades.h bd_episodios.h
client.o: client.c red.h utilidades.h bd_episodios.h

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

test: all
	$(CC) $(CPPFLAGS) $(CFLAGS) -I. pruebas/prueba_utilidades.c libmonitor.a -o /tmp/prueba_utilidades_sopranos
	/tmp/prueba_utilidades_sopranos
	./server --test-run
	python3 -m unittest discover -s pruebas -p 'test_red.py' -v

clean:
	rm -f *.o libmonitor.a server client

